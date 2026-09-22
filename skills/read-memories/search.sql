-- read-memories/search.sql
--
-- Searches Cortex Code's own session logs (~/.snowflake/cortex/conversations/),
-- NOT Claude Code's (~/.claude/projects/). Logs live at two glob depths and the
-- schema varies by session age, so every read below is explicit-columns and
-- reads `content` as JSON rather than letting DuckDB auto-detect a struct type
-- (a struct built from a sampled subset silently drops keys absent from the
-- sample and then errors with "Could not find key" on any file that has them).
--
-- Driven by three env vars the caller sets before invoking this file:
--   DSK_MODE    'search' | 'sqlresults' | 'coverage'  (required)
--   DSK_KEYWORD substring to match; '' = no keyword filter
--   DSK_CWD     current directory for --here scoping; '' = no directory filter
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\search.sql"

-- ---- fail fast on an unrecognized mode --------------------------------
SELECT CASE WHEN getenv('DSK_MODE') NOT IN ('search', 'sqlresults', 'coverage')
            THEN error('unknown DSK_MODE: ' || coalesce(getenv('DSK_MODE'), '(unset)'))
       END AS guard
WHERE getenv('DSK_MODE') NOT IN ('search', 'sqlresults', 'coverage');

-- ================================ coverage ==============================
-- Distinct file count from THIS query's own read_ndjson call, at both glob
-- depths (top-level sessions and hashed-subfolder sessions). A file DuckDB
-- doesn't read here isn't covered, regardless of what the filesystem holds.
SELECT count(DISTINCT filename) AS distinct_files
FROM read_ndjson(
  [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
   coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
  columns = {role: 'VARCHAR', content: 'JSON'},
  ignore_errors = true, filename = true
)
WHERE getenv('DSK_MODE') = 'coverage';

-- ================================ sqlresults =============================
-- Recovers past SQL result sets, which live as CSV text at
-- tool_result.content[*].text. Two tool names hold this history across the
-- corpus's lifetime; match both via a forward-compatible LIKE so a future
-- rename doesn't silently halve coverage again.

-- sqlresults / no keyword: coverage summary (how much is recoverable).
WITH hist AS (
  SELECT content
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON'},
    ignore_errors = true, filename = true
  )
  WHERE getenv('DSK_MODE') = 'sqlresults' AND coalesce(getenv('DSK_KEYWORD'), '') = ''
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
FROM tool_results
WHERE getenv('DSK_MODE') = 'sqlresults' AND coalesce(getenv('DSK_KEYWORD'), '') = '';

-- sqlresults / with keyword: render matching recovered result set(s).
WITH hist AS (
  SELECT content, filename
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON'},
    ignore_errors = true, filename = true
  )
  WHERE getenv('DSK_MODE') = 'sqlresults' AND coalesce(getenv('DSK_KEYWORD'), '') <> ''
),
blocks AS (
  SELECT unnest(content::JSON[]) AS c, filename FROM hist
),
tool_results AS (
  SELECT
    filename,
    json_extract_string(c, '$.tool_result.name') AS tool_name,
    json_extract_string(c, '$.tool_result.content[0].text') AS result_text
  FROM blocks
  WHERE json_extract_string(c, '$.type') = 'tool_result'
    AND json_extract_string(c, '$.tool_result.name') LIKE '%sql_execute'
)
SELECT
  regexp_extract(filename, '([^/\\]+)\.history\.jsonl$', 1) AS session_id,
  tool_name,
  result_text
FROM tool_results
WHERE result_text ILIKE '%' || getenv('DSK_KEYWORD') || '%'
ORDER BY session_id
LIMIT 20;

-- ================================ search ==================================
-- Keyword search restricted to `type = 'text'` blocks only (tool_use,
-- tool_result, thinking, and image blocks are excluded from search mode
-- entirely — recovering SQL results is a separate documented mode above).
-- <system-reminder> blocks (injected context, not conversation) are excluded.
-- Joined to each session's metadata sidecar for `title` and for --here
-- scoping. Sidecars come in two shapes (finding 7): only session_id, title,
-- and working_directory exist in both, so those are the only sidecar fields
-- used besides the timestamp fallbacks below.
WITH hist AS (
  SELECT
    role, content, user_sent_time, assistant_sent_time,
    regexp_extract(filename, '([^/\\]+)\.history\.jsonl$', 1) AS session_id
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON', user_sent_time: 'VARCHAR', assistant_sent_time: 'VARCHAR'},
    ignore_errors = true, filename = true
  )
  WHERE getenv('DSK_MODE') = 'search'
),
side AS (
  SELECT session_id AS s_session_id, title, working_directory, created_at, creationDate
  FROM read_json(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.json',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.json'],
    columns = {session_id: 'VARCHAR', title: 'VARCHAR', working_directory: 'VARCHAR',
               created_at: 'VARCHAR', creationDate: 'BIGINT'},
    ignore_errors = true, filename = true
  )
  WHERE getenv('DSK_MODE') = 'search'
),
blocks AS (
  SELECT h.session_id, h.role, h.user_sent_time, h.assistant_sent_time, unnest(h.content::JSON[]) AS c
  FROM hist h
)
SELECT
  b.session_id,
  coalesce(b.user_sent_time::TIMESTAMP, b.assistant_sent_time::TIMESTAMP,
           s.created_at::TIMESTAMP, epoch_ms(s.creationDate)) AS ts,
  b.role,
  s.title,
  left(json_extract_string(b.c, '$.text'), 500) AS snippet
FROM blocks b
LEFT JOIN side s ON b.session_id = s.s_session_id
WHERE json_extract_string(b.c, '$.type') = 'text'
  AND json_extract_string(b.c, '$.text') ILIKE '%' || getenv('DSK_KEYWORD') || '%'
  AND json_extract_string(b.c, '$.text') NOT ILIKE '%<system-reminder>%'
  AND (coalesce(getenv('DSK_CWD'), '') = ''
       OR lower(replace(s.working_directory, '/', '\')) = lower(replace(getenv('DSK_CWD'), '/', '\')))
ORDER BY ts
LIMIT 40;
