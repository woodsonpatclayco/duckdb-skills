-- skills/snowflake-extract/registry.sql
--
-- Reads exactly one extract's sidecar and emits one CSV row of derived facts.
-- Run with `duckdb -csv -f registry.sql`, never `-c` -- PowerShell expands `$`
-- inside double-quoted `-c` strings and breaks any `'$.field'` JSON path (see
-- skills/read-memories/SKILL.md for the same rule applied there).
--
-- Inputs, via environment variables (never substituted into the SQL text):
--   DSK_EXTRACT_DIR      absolute path to the extract directory (required)
--   DSK_EXTRACT_NAME     the directory's own leaf name, for the name-mismatch check (required)
--   DSK_WINDOW_MINUTES   freshness window in minutes; unset means 60
--   DSK_MAX_AGE_MINUTES  reporting ceiling in minutes; unset means 1440
--
-- Invoked once per extract directory -- never over a glob of sidecars -- because one
-- malformed sidecar exits 1 for the whole query and ignore_errors is refused for
-- non-newline-delimited JSON. A non-zero exit from this script means the sidecar itself
-- is unreadable (invalid JSON, or materialized_at unparseable against its pinned TIMESTAMP
-- type); the caller reports that as UNKNOWN (unreadable sidecar). A directory with no
-- _extract.json is never passed to this script at all -- the caller checks for the file's
-- existence first and reports UNKNOWN (no sidecar) without invoking duckdb.
--
-- See SIDECAR.md for the schema this pins, field by field.

SET VARIABLE dsk_dir = getenv('DSK_EXTRACT_DIR');
SET VARIABLE dsk_name = getenv('DSK_EXTRACT_NAME');
SET VARIABLE dsk_sidecar = getvariable('dsk_dir') || '/_extract.json';
SET VARIABLE dsk_window = coalesce(try_cast(nullif(getenv('DSK_WINDOW_MINUTES'), '') AS INTEGER), 60);
SET VARIABLE dsk_ceiling = coalesce(try_cast(nullif(getenv('DSK_MAX_AGE_MINUTES'), '') AS INTEGER), 1440);

WITH sidecar AS (
    SELECT *
    FROM read_json(
        getvariable('dsk_sidecar'),
        columns = {
            sidecar_version: 'INTEGER',
            name: 'VARCHAR',
            query: 'VARCHAR',
            source_objects: 'VARCHAR[]',
            materialized_at: 'TIMESTAMP',
            window_minutes: 'INTEGER',
            expires_at: 'VARCHAR',
            row_count: 'BIGINT',
            output_bytes: 'BIGINT',
            connection: 'VARCHAR',
            role: 'VARCHAR',
            database: 'VARCHAR',
            warehouse: 'VARCHAR',
            source_rows: 'BIGINT[]',
            source_bytes: 'BIGINT[]',
            source_last_altered: 'VARCHAR[]',
            runtime_seconds: 'DOUBLE'
        }
    )
)
SELECT
    name,
    getvariable('dsk_dir') AS path,
    getvariable('dsk_dir') || '/*.parquet' AS parquet_glob,
    query,
    to_json(source_objects) AS source_objects,
    materialized_at,
    expires_at,
    row_count,
    output_bytes,
    connection,
    role,
    database,
    warehouse,
    window_minutes,
    sidecar_version,
    to_json(source_rows) AS source_rows,
    to_json(source_bytes) AS source_bytes,
    to_json(source_last_altered) AS source_last_altered,
    runtime_seconds,
    date_diff('minute', materialized_at, timezone('UTC', now())) AS age_minutes,
    CASE
        WHEN name IS DISTINCT FROM getvariable('dsk_name') THEN 'name mismatch'
        WHEN len(source_rows) IS DISTINCT FROM len(source_objects)
          OR len(source_bytes) IS DISTINCT FROM len(source_objects)
          OR len(source_last_altered) IS DISTINCT FROM len(source_objects) THEN 'parallel array mismatch'
        ELSE ''
    END AS reason,
    -- Guarded per SIDECAR.md's freshness rule: a NULL age must never compare as "fresh".
    coalesce(date_diff('minute', materialized_at, timezone('UTC', now())) > getvariable('dsk_window'), true) AS stale,
    coalesce(date_diff('minute', materialized_at, timezone('UTC', now())) > getvariable('dsk_ceiling'), true) AS past_ceiling
FROM sidecar;
