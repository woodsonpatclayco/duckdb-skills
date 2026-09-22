-- read-memories/sqlresults.sql
--
-- Recovers past SQL result sets, which live as CSV text at
-- tool_result.content[*].text. Two tool names hold this history across the
-- corpus's lifetime, match both via a forward-compatible LIKE so a future
-- rename doesn't silently halve coverage again.
--
-- Driven by env vars the caller sets before invoking this file:
--   DSK_KEYWORD substring to match, required (error()s if empty)
--
-- For a coverage summary instead of rendered results, use
-- sqlresults-summary.sql, which ignores DSK_KEYWORD entirely.
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\sqlresults.sql"
WITH kw_guard AS (
  SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
              THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok
),
hist AS (
  SELECT content, filename
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON'},
    ignore_errors = true, filename = true
  )
),
blocks AS (
  SELECT unnest(h.content::JSON[]) AS c, h.filename, kw_guard.ok FROM hist h, kw_guard
),
tool_results AS (
  SELECT
    filename,
    json_extract_string(c, '$.tool_result.name') AS tool_name,
    json_extract_string(c, '$.tool_result.content[0].text') AS result_text,
    ok
  FROM blocks
  WHERE json_extract_string(c, '$.type') = 'tool_result'
    AND json_extract_string(c, '$.tool_result.name') LIKE '%sql_execute'
)
SELECT
  regexp_extract(filename, '([^/\\]+)\.history\.jsonl$', 1) AS session_id,
  tool_name,
  result_text
FROM tool_results
WHERE ok = 1
  AND result_text ILIKE '%' || getenv('DSK_KEYWORD') || '%'
ORDER BY session_id
LIMIT 20;
