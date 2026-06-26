# SQL Server DB Scripts Pipeline

This repository executes ordered SQL Server scripts through an Azure DevOps YAML pipeline and publishes evidence artifacts showing:

- which script ran
- which SQL Server and database it ran against
- whether it succeeded or failed
- how many rows were affected
- the exact script files included in the run

## Repository Layout

```text
.
├── azure-pipelines.yml
├── scripts/
│   └── 001_Verify_Target_Database.sql
├── tools/
│   └── Invoke-SqlScriptDeployment.ps1
└── docs/
    └── artifacts.md
```

## Add SQL Scripts

Place deployment scripts in `scripts/` and prefix them in execution order:

```text
scripts/
  001_Create_Table.sql
  002_Backfill_Data.sql
  003_Add_Index.sql
```

Scripts are executed by relative path order. `GO` batch separators are supported.

Use `SET NOCOUNT OFF` when row counts matter. SQL Server can suppress affected-row counts when `NOCOUNT` is enabled.

## Pipeline Variables

Create these variables in Azure DevOps before running the pipeline:

| Variable | Required | Secret | Example |
| --- | --- | --- | --- |
| `SqlServerName` | Yes | No | `myserver.database.windows.net` or `SQLHOST01` |
| `SqlUsername` | No | No | `deployment_user` |
| `SqlPassword` | No | Yes | password for `SqlUsername` |
| `SqlEncrypt` | No | No | `true` |
| `SqlTrustServerCertificate` | No | No | `false` |

If `SqlUsername` is blank, the runner uses Windows integrated authentication. Use a self-hosted Windows agent for integrated authentication.

## Run The Pipeline

When manually running the pipeline, set:

- `environmentName`: Azure DevOps environment name, such as `dev`, `test`, or `prod`
- `targetDatabases`: comma-separated database names, such as `AppDb,AuditDb`
- `dryRun`: validates script discovery and artifact creation without opening SQL connections
- `continueOnError`: continues after a script failure when set to `true`

## Evidence Artifacts

Every run publishes the `sql-execution-evidence` pipeline artifact.

Key files:

- `execution-summary.csv`: one row per database and script
- `execution-summary.json`: JSON version of the summary
- `batch-results.csv`: one row per database, script, and `GO` batch
- `script-manifest.csv`: scripts included in the run with SHA-256 hashes
- `scripts/`: copies of the exact scripts included in the run
- `logs/`: human-readable per-database, per-script logs

See [docs/artifacts.md](docs/artifacts.md) for the artifact schema.

## Local Dry Run

```powershell
.\tools\Invoke-SqlScriptDeployment.ps1 `
  -ServerInstance "localhost" `
  -Database "MyDatabase" `
  -DryRun
```

Dry runs do not connect to SQL Server. They are useful for checking script order and artifact output.

## Local Execution

SQL authentication:

```powershell
.\tools\Invoke-SqlScriptDeployment.ps1 `
  -ServerInstance "myserver.database.windows.net" `
  -Database "AppDb","AuditDb" `
  -Username "deployment_user" `
  -Password $env:SQL_PASSWORD
```

Integrated authentication:

```powershell
.\tools\Invoke-SqlScriptDeployment.ps1 `
  -ServerInstance "SQLHOST01" `
  -Database "AppDb"
```
