/*
This starter script proves the pipeline can connect to each target database.
Replace it with your numbered deployment scripts, or keep it as a first smoke test.
*/

SET NOCOUNT OFF;

SELECT
    DB_NAME() AS TargetDatabase,
    SYSDATETIMEOFFSET() AS ExecutedAt;
GO
