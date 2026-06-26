[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    [Parameter(Mandatory = $true)]
    [string[]]$Database,

    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\scripts'),

    [string]$ArtifactPath = (Join-Path $PSScriptRoot '..\artifacts\sql-execution'),

    [string]$Username,

    [string]$Password,

    [bool]$Encrypt = $true,

    [bool]$TrustServerCertificate = $false,

    [int]$CommandTimeoutSeconds = 0,

    [switch]$DryRun,

    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Data

$script:CurrentSqlMessages = $null

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = [regex]::Replace($Value, '[^A-Za-z0-9._-]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'unnamed'
    }

    return $safe
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFullPath = (Resolve-Path -LiteralPath $BasePath).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $targetFullPath = (Resolve-Path -LiteralPath $Path).Path
    $baseUri = [Uri]$baseFullPath
    $targetUri = [Uri]$targetFullPath

    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Split-SqlBatch {
    param([Parameter(Mandatory = $true)][string]$SqlText)

    $batches = New-Object 'System.Collections.Generic.List[string]'
    $currentLines = New-Object 'System.Collections.Generic.List[string]'
    $lines = $SqlText -split "`r?`n"

    foreach ($line in $lines) {
        if ($line -match '^\s*GO(?:\s+(\d+))?\s*(?:--.*)?$') {
            $batchText = ($currentLines -join [Environment]::NewLine).Trim()
            if ($batchText.Length -gt 0) {
                $repeatCount = 1
                if ($Matches[1]) {
                    $repeatCount = [int]$Matches[1]
                }

                for ($index = 0; $index -lt $repeatCount; $index++) {
                    [void]$batches.Add($batchText)
                }
            }

            $currentLines.Clear()
            continue
        }

        [void]$currentLines.Add($line)
    }

    $finalBatch = ($currentLines -join [Environment]::NewLine).Trim()
    if ($finalBatch.Length -gt 0) {
        [void]$batches.Add($finalBatch)
    }

    return $batches.ToArray()
}

function New-ConnectionString {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDatabase
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $ServerInstance
    $builder['Initial Catalog'] = $TargetDatabase
    $builder['Application Name'] = 'SqlScriptPipeline'
    $builder['Encrypt'] = $Encrypt
    $builder['TrustServerCertificate'] = $TrustServerCertificate

    if ([string]::IsNullOrWhiteSpace($Username)) {
        $builder['Integrated Security'] = $true
    }
    else {
        $builder['Integrated Security'] = $false
        $builder['User ID'] = $Username
        $builder['Password'] = $Password
    }

    return $builder.ConnectionString
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Value
    )

    Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

$targetDatabases = @(
    $Database |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

if ($targetDatabases.Count -eq 0) {
    throw 'At least one target database must be supplied.'
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$scripts = @(
    Get-ChildItem -LiteralPath $resolvedScriptPath -Recurse -File -Filter '*.sql' |
        ForEach-Object {
            [PSCustomObject]@{
                FullName = $_.FullName
                RelativePath = Get-RelativePath -BasePath $resolvedScriptPath -Path $_.FullName
            }
        } |
        Sort-Object RelativePath
)

if ($scripts.Count -eq 0) {
    throw "No .sql files were found under '$resolvedScriptPath'."
}

$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$runArtifactPath = Join-Path $ArtifactPath $runId
$logsPath = Join-Path $runArtifactPath 'logs'
$scriptCopiesPath = Join-Path $runArtifactPath 'scripts'

New-Directory -Path $runArtifactPath
New-Directory -Path $logsPath
New-Directory -Path $scriptCopiesPath

$summaryRows = New-Object 'System.Collections.Generic.List[object]'
$batchRows = New-Object 'System.Collections.Generic.List[object]'
$manifestRows = New-Object 'System.Collections.Generic.List[object]'

foreach ($scriptItem in $scripts) {
    $copyDestination = Join-Path $scriptCopiesPath $scriptItem.RelativePath
    New-Directory -Path (Split-Path -Path $copyDestination -Parent)
    Copy-Item -LiteralPath $scriptItem.FullName -Destination $copyDestination -Force

    $fileHash = Get-FileHash -LiteralPath $scriptItem.FullName -Algorithm SHA256
    [void]$manifestRows.Add([PSCustomObject]@{
        Script = $scriptItem.RelativePath
        Sha256 = $fileHash.Hash
        SourcePath = $scriptItem.FullName
    })
}

$manifestRows | Export-Csv -LiteralPath (Join-Path $runArtifactPath 'script-manifest.csv') -NoTypeInformation -Encoding UTF8
$manifestRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runArtifactPath 'script-manifest.json') -Encoding UTF8

$hadFailure = $false

foreach ($targetDatabase in $targetDatabases) {
    if ($hadFailure -and -not $ContinueOnError) {
        break
    }

    $connection = $null
    $infoHandler = [System.Data.SqlClient.SqlInfoMessageEventHandler]{
        param($sender, $eventArgs)

        if ($null -eq $script:CurrentSqlMessages) {
            return
        }

        foreach ($sqlError in $eventArgs.Errors) {
            [void]$script:CurrentSqlMessages.Add(('[{0}] {1}' -f $sqlError.Number, $sqlError.Message))
        }
    }

    try {
        if (-not $DryRun) {
            $connection = New-Object System.Data.SqlClient.SqlConnection (New-ConnectionString -TargetDatabase $targetDatabase)
            $connection.FireInfoMessageEventOnUserErrors = $true
            $connection.add_InfoMessage($infoHandler)
            $connection.Open()
        }

        foreach ($scriptItem in $scripts) {
            if ($hadFailure -and -not $ContinueOnError) {
                break
            }

            $startedUtc = (Get-Date).ToUniversalTime()
            $status = 'Succeeded'
            $errorMessage = ''
            $rowsAffected = 0
            $batchesExecuted = 0
            $script:CurrentSqlMessages = New-Object 'System.Collections.Generic.List[string]'

            $safeDatabase = Get-SafeName -Value $targetDatabase
            $safeScript = Get-SafeName -Value $scriptItem.RelativePath
            $logPath = Join-Path $logsPath ("{0}__{1}.log" -f $safeDatabase, $safeScript)

            try {
                $sqlText = Get-Content -LiteralPath $scriptItem.FullName -Raw
                $batches = @(Split-SqlBatch -SqlText $sqlText)

                if ($DryRun) {
                    $status = 'DryRun'
                    $batchesExecuted = $batches.Count
                }
                else {
                    for ($batchNumber = 1; $batchNumber -le $batches.Count; $batchNumber++) {
                        $command = $connection.CreateCommand()
                        $command.CommandText = $batches[$batchNumber - 1]
                        $command.CommandTimeout = $CommandTimeoutSeconds

                        try {
                            $recordsAffected = $command.ExecuteNonQuery()
                            $batchRowsAffected = 0
                            if ($recordsAffected -gt 0) {
                                $batchRowsAffected = $recordsAffected
                                $rowsAffected += $recordsAffected
                            }

                            [void]$batchRows.Add([PSCustomObject]@{
                                Server = $ServerInstance
                                Database = $targetDatabase
                                Script = $scriptItem.RelativePath
                                BatchNumber = $batchNumber
                                Status = 'Succeeded'
                                RowsAffected = $batchRowsAffected
                                Error = ''
                            })
                        }
                        catch {
                            [void]$batchRows.Add([PSCustomObject]@{
                                Server = $ServerInstance
                                Database = $targetDatabase
                                Script = $scriptItem.RelativePath
                                BatchNumber = $batchNumber
                                Status = 'Failed'
                                RowsAffected = 0
                                Error = $_.Exception.Message
                            })

                            throw
                        }
                        finally {
                            $command.Dispose()
                        }

                        $batchesExecuted++
                    }
                }
            }
            catch {
                $status = 'Failed'
                $errorMessage = $_.Exception.Message
                $hadFailure = $true
            }

            $endedUtc = (Get-Date).ToUniversalTime()
            $durationSeconds = [Math]::Round(($endedUtc - $startedUtc).TotalSeconds, 3)

            [void]$summaryRows.Add([PSCustomObject]@{
                RunId = $runId
                Server = $ServerInstance
                Database = $targetDatabase
                Script = $scriptItem.RelativePath
                Status = $status
                RowsAffected = $rowsAffected
                BatchesExecuted = $batchesExecuted
                StartedUtc = $startedUtc.ToString('o')
                EndedUtc = $endedUtc.ToString('o')
                DurationSeconds = $durationSeconds
                Error = $errorMessage
            })

            $logLines = @(
                "RunId: $runId",
                "Server: $ServerInstance",
                "Database: $targetDatabase",
                "Script: $($scriptItem.RelativePath)",
                "Status: $status",
                "RowsAffected: $rowsAffected",
                "BatchesExecuted: $batchesExecuted",
                "StartedUtc: $($startedUtc.ToString('o'))",
                "EndedUtc: $($endedUtc.ToString('o'))",
                "DurationSeconds: $durationSeconds",
                "Error: $errorMessage",
                '',
                'SQL messages:'
            )

            if ($script:CurrentSqlMessages.Count -gt 0) {
                $logLines += $script:CurrentSqlMessages.ToArray()
            }
            else {
                $logLines += '(none)'
            }

            Write-TextFile -Path $logPath -Value $logLines

            if ($hadFailure -and -not $ContinueOnError) {
                break
            }
        }
    }
    finally {
        if ($null -ne $connection) {
            $connection.remove_InfoMessage($infoHandler)
            $connection.Dispose()
        }

        $script:CurrentSqlMessages = $null
    }
}

$summaryCsvPath = Join-Path $runArtifactPath 'execution-summary.csv'
$summaryJsonPath = Join-Path $runArtifactPath 'execution-summary.json'
$batchCsvPath = Join-Path $runArtifactPath 'batch-results.csv'
$batchJsonPath = Join-Path $runArtifactPath 'batch-results.json'

$summaryRows | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation -Encoding UTF8
$summaryRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8
$batchRows | Export-Csv -LiteralPath $batchCsvPath -NoTypeInformation -Encoding UTF8
$batchRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $batchJsonPath -Encoding UTF8

Write-Host "SQL execution artifacts written to: $runArtifactPath"
Write-Host "Execution summary: $summaryCsvPath"

if ($hadFailure) {
    throw "One or more SQL scripts failed. Review the execution artifacts at '$runArtifactPath'."
}
