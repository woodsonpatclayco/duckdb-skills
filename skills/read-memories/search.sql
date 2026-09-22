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
--   DSK_KEYWORD substring to match, required (error()s if empty). Matched as a
--               literal case-insensitive substring, NOT a LIKE pattern, so
--               `_` and `%` in the keyword are not wildcards.
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
--
-- The snippet is a match-centred window, not a prefix: it starts 120 chars
-- before the match and covers 500 chars, with a leading/trailing "..." when
-- text was cut on that side. `chars` reports the full untruncated length so
-- "how much did I not see" needs no arithmetic. `matches` reports the total
-- row count before LIMIT, so the 40-row cap is visible rather than silent.
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
  SELECT h.session_id, h.role, h.user_sent_time, h.assistant_sent_time,
         unnest(h.content::JSON[]) AS c, kw_guard.ok
  FROM hist h, kw_guard
),
texted AS (
  SELECT
    b.session_id, b.role, b.user_sent_time, b.assistant_sent_time, b.ok,
    json_extract_string(b.c, '$.type') AS block_type,
    json_extract_string(b.c, '$.text') AS txt
  FROM blocks b
),
windowed AS (
  SELECT
    t.*,
    strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) AS p
  FROM texted t
),
positioned AS (
  SELECT w.*, greatest(1, w.p - 120) AS win_start
  FROM windowed w
)
SELECT
  left(md5(w.txt), 8) AS id,
  w.session_id,
  coalesce(w.user_sent_time::TIMESTAMP, w.assistant_sent_time::TIMESTAMP,
           sd.created_at::TIMESTAMP, epoch_ms(sd.creationDate)) AS ts,
  w.role,
  sd.title,
  (CASE WHEN w.win_start > 1 THEN '...' ELSE '' END)
    || substr(w.txt, w.win_start, 500)
    || (CASE WHEN length(w.txt) > w.win_start + 499 THEN '...' ELSE '' END) AS snippet,
  length(w.txt) AS chars,
  count(*) OVER () AS matches
FROM positioned w
LEFT JOIN side sd ON w.session_id = sd.s_session_id
WHERE w.ok = 1
  AND w.block_type = 'text'
  AND w.p > 0
  AND w.txt NOT ILIKE '%<system-reminder>%'
  AND (coalesce(getenv('DSK_CWD'), '') = ''
       OR lower(replace(sd.working_directory, '/', '\')) = lower(replace(getenv('DSK_CWD'), '/', '\')))
ORDER BY ts DESC, w.session_id, md5(w.txt)
LIMIT 40;
