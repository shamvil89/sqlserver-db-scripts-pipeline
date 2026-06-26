# SQL Execution Artifacts

Every pipeline run publishes the `sql-execution-evidence` artifact.

The artifact contains one timestamped folder per run:

```text
sql-execution/
  20260626T193000Z/
    execution-summary.csv
    execution-summary.json
    batch-results.csv
    batch-results.json
    script-manifest.csv
    script-manifest.json
    logs/
      DatabaseName__001_Verify_Target_Database.sql.log
    scripts/
      001_Verify_Target_Database.sql
```

## Files

`execution-summary.csv` and `execution-summary.json`

One row per database and script. This is the main audit file and includes:

- `Server`
- `Database`
- `Script`
- `Status`
- `RowsAffected`
- `BatchesExecuted`
- `StartedUtc`
- `EndedUtc`
- `DurationSeconds`
- `Error`

`batch-results.csv` and `batch-results.json`

One row per database, script, and `GO` batch. Use this when you need to see which batch changed rows or failed.

`script-manifest.csv` and `script-manifest.json`

The list of scripts included in the run, with SHA-256 hashes.

`scripts/`

Copies of the exact `.sql` files that were included in the run artifact.

`logs/`

Human-readable execution logs for each database and script.

## Row Counts

The runner records SQL Server `RecordsAffected` for each executed batch. Keep `SET NOCOUNT OFF` in scripts where row counts matter. If a script turns `NOCOUNT ON`, SQL Server may suppress affected-row counts and the artifact can show `0` even when data changed.
