-- read-memories/search.sql
--
-- Searches Cortex Code's own session logs (~/.snowflake/cortex/conversations/),
-- NOT Claude Code's (~/.claude/projects/). Logs live at two glob depths and the
-- schema varies by session age, so every read below is explicit-columns and
-- reads `content` as JSON rather than letting DuckDB auto-detect a struct type
-- (a struct built from a sampled subset silently drops keys absent from the
-- sample and then errors with "Could not find key" on any file that has them).
--
-- Driven by env vars the caller sets before invoking this file:
--   DSK_KEYWORD substring to match, required (error()s if empty)
--   DSK_CWD     current directory for --here scoping, '' = no directory filter
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
--
-- Keyword search restricted to `type = 'text'` blocks only (tool_use,
-- tool_result, thinking, and image blocks are excluded from search mode
-- entirely — recovering SQL results is a separate documented file,
-- sqlresults.sql).
-- <system-reminder> blocks (injected context, not conversation) are excluded.
-- Joined to each session's metadata sidecar for `title` and for --here
-- scoping. Sidecars come in two shapes (finding 7): only session_id, title,
-- and working_directory exist in both, so those are the only sidecar fields
-- used besides the timestamp fallbacks below.
WITH kw_guard AS (
  SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
              THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok
),
hist AS (
  SELECT
    role, content, user_sent_time, assistant_sent_time,
    regexp_extract(filename, '([^/\\]+)\.history\.jsonl$', 1) AS session_id
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON', user_sent_time: 'VARCHAR', assistant_sent_time: 'VARCHAR'},
    ignore_errors = true, filename = true
  )
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
),
blocks AS (
  SELECT h.session_id, h.role, h.user_sent_time, h.assistant_sent_time, unnest(h.content::JSON[]) AS c, kw_guard.ok
  FROM hist h, kw_guard
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
WHERE b.ok = 1
  AND json_extract_string(b.c, '$.type') = 'text'
  AND json_extract_string(b.c, '$.text') ILIKE '%' || getenv('DSK_KEYWORD') || '%'
  AND json_extract_string(b.c, '$.text') NOT ILIKE '%<system-reminder>%'
  AND (coalesce(getenv('DSK_CWD'), '') = ''
       OR lower(replace(s.working_directory, '/', '\')) = lower(replace(getenv('DSK_CWD'), '/', '\')))
ORDER BY ts
LIMIT 40;
