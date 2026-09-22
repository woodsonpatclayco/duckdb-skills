-- read-memories/coverage.sql
--
-- Distinct file count from this query's own read_ndjson call, at both glob
-- depths (top-level sessions and hashed-subfolder sessions). A file DuckDB
-- doesn't read here isn't covered, regardless of what the filesystem holds.
-- Ignores DSK_KEYWORD entirely — this is a corpus sanity count, not a lookup.
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\coverage.sql"
SELECT count(DISTINCT filename) AS distinct_files
FROM read_ndjson(
  [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
   coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
  columns = {role: 'VARCHAR', content: 'JSON'},
  ignore_errors = true, filename = true
);
