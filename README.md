# SQL Server DB Scripts Pipeline

This repository validates and executes ordered SQL Server scripts through Azure DevOps YAML pipelines. Each run publishes evidence artifacts showing:

- which script ran
- which SQL Server and database it ran against
- whether it succeeded or failed
- how many rows were affected
- the exact script files included in the run

## Repository Layout

```text
.
|-- azure-pipelines.yml
|-- pipelines/
|   |-- deploy-sql-scripts.yml
|   `-- templates/
|       `-- run-sql-scripts.yml
|-- scripts/
|   `-- 001_Verify_Target_Database.sql
|-- tools/
|   `-- Invoke-SqlScriptDeployment.ps1
`-- docs/
    `-- artifacts.md
```

## Pipelines

Create these Azure DevOps pipeline definitions:

| Purpose | YAML path | Trigger |
| --- | --- | --- |
| Validate SQL scripts | `azure-pipelines.yml` | Runs on `main` and pull requests |
| Deploy SQL scripts | `pipelines/deploy-sql-scripts.yml` | Manual only |

Both pipelines use a self-hosted Windows agent pool through the `agentPoolName` parameter. The default is `Default`; change it to the exact Azure DevOps pool name if your self-hosted pool uses another name.

The validation pipeline runs the deployment runner in dry-run mode. It checks script discovery, execution order, `GO` batch splitting, and artifact creation without opening a SQL connection.

The deployment pipeline is manual and uses an Azure DevOps deployment environment. Configure approvals and checks on that environment when production deployments need a gate.

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

Create these variables in Azure DevOps for the deployment pipeline:

| Variable | Required | Secret | Example |
| --- | --- | --- | --- |
| `SqlServerName` | Yes for deployment | No | `myserver.database.windows.net` or `SQLHOST01` |
| `SqlUsername` | No | No | `deployment_user` |
| `SqlPassword` | Required when `SqlUsername` is set | Yes | password for `SqlUsername` |
| `SqlEncrypt` | No | No | `true` |
| `SqlTrustServerCertificate` | No | No | `false` |

If `SqlUsername` is blank, the runner uses Windows integrated authentication. Use a self-hosted Windows agent for integrated authentication or for private network SQL Server targets.

## Run The Deployment Pipeline

When manually running `pipelines/deploy-sql-scripts.yml`, set:

- `agentPoolName`: Azure DevOps self-hosted Windows agent pool name
- `environmentName`: Azure DevOps environment name, such as `dev`, `test`, or `prod`
- `targetDatabases`: comma-separated database names, such as `AppDb,AuditDb`
- `dryRun`: validates script discovery and artifact creation without opening SQL connections
- `continueOnError`: continues after a script failure when set to `true`
- `commandTimeoutSeconds`: SQL command timeout; `0` means no timeout

## Evidence Artifacts

Every run publishes a pipeline artifact:

- validation: `sql-validation-evidence`
- deployment: `sql-execution-evidence`

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
