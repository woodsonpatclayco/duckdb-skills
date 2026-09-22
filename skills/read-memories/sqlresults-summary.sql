-- read-memories/sqlresults-summary.sql
--
-- How much SQL result history is recoverable across the whole corpus: total
-- tool_result blocks matching the sql_execute tool name, and how many of
-- those actually carry a rendered "N row(s) returned" result set. Ignores
-- DSK_KEYWORD entirely — this is a corpus-wide count, not a lookup.
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\sqlresults-summary.sql"
WITH hist AS (
  SELECT content
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON'},
    ignore_errors = true, filename = true
  )
),
blocks AS (
  SELECT unnest(content::JSON[]) AS c FROM hist
),
tool_results AS (
  SELECT json_extract_string(c, '$.tool_result.content[0].text') AS result_text
  FROM blocks
  WHERE json_extract_string(c, '$.type') = 'tool_result'
    AND json_extract_string(c, '$.tool_result.name') LIKE '%sql_execute'
)
SELECT
  count(*) AS total,
  sum(CASE WHEN result_text LIKE '%row(s) returned%' THEN 1 ELSE 0 END) AS with_rows_returned
FROM tool_results;
