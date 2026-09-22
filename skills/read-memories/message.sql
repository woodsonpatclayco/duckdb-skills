-- read-memories/message.sql
--
-- Returns the complete untruncated text of the message(s) addressed by an
-- 8-character id minted from search.sql's `id` column (left(md5(txt), 8)).
-- No window, no truncation, no LIMIT -- the whole point of this file is to
-- undo the 500-character snippet search.sql deliberately applies.
--
-- Reads Cortex Code's own session logs (~/.snowflake/cortex/conversations/),
-- NOT Claude Code's (~/.claude/projects/). Same two glob depths, same
-- explicit-columns reads, and content is read as JSON for the same reason
-- documented in search.sql: a struct type inferred from a sampled subset of
-- the glob silently drops keys absent from the sample.
--
-- Driven by env vars the caller sets before invoking this file:
--   DSK_MSG     the 8-character id, required (error()s if empty). Matched as
--               lower(trim(getenv('DSK_MSG'))) against left(md5(txt), 8), so
--               an id pasted uppercase or with stray whitespace still resolves.
--   DSK_SESSION the session id to scope to, '' = every session sharing the id.
--
-- DSK_KEYWORD and DSK_CWD are not used by this file and are ignored.
--
-- Invoke:
--   duckdb -csv -f "<abs path>\skills\read-memories\message.sql"
--
-- Applies the SAME block filters as search.sql (`$.type = 'text'`,
-- <system-reminder> excluded) -- if these two files disagreed, an id minted
-- by search could resolve to a different message than the one it was copied
-- from. See TASK.md for the measurement backing this.
--
-- An id can legitimately span several sessions with identical text and
-- different session_id/ts/title (measured: 19 ids, worst case 5 rows across
-- 4 sessions) -- all matching rows are returned, never DISTINCTed away.
WITH msg_guard AS (
  SELECT CASE WHEN coalesce(getenv('DSK_MSG'), '') = ''
              THEN error('DSK_MSG is required') ELSE 1 END AS ok
),
hist AS (
  SELECT
    role, content, user_sent_time, assistant_sent_time, msg_guard.ok,
    regexp_extract(filename, '([^/\\]+)\.history\.jsonl$', 1) AS session_id
  FROM read_ndjson(
    [coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*.history.jsonl',
     coalesce(getenv('USERPROFILE'), getenv('HOME')) || '\.snowflake\cortex\conversations\*\*.history.jsonl'],
    columns = {role: 'VARCHAR', content: 'JSON', user_sent_time: 'VARCHAR', assistant_sent_time: 'VARCHAR'},
    ignore_errors = true, filename = true
  ), msg_guard
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
         unnest(h.content::JSON[]) AS c, h.ok
  FROM hist h
),
texted AS (
  SELECT
    b.session_id, b.role, b.user_sent_time, b.assistant_sent_time, b.ok,
    json_extract_string(b.c, '$.type') AS block_type,
    json_extract_string(b.c, '$.text') AS txt
  FROM blocks b
)
SELECT
  left(md5(w.txt), 8) AS id,
  w.session_id,
  coalesce(w.user_sent_time::TIMESTAMP, w.assistant_sent_time::TIMESTAMP,
           sd.created_at::TIMESTAMP, epoch_ms(sd.creationDate)) AS ts,
  w.role,
  sd.title,
  length(w.txt) AS chars,
  w.txt AS txt
FROM texted w
LEFT JOIN side sd ON w.session_id = sd.s_session_id
WHERE w.ok = 1
  AND w.block_type = 'text'
  AND w.txt NOT ILIKE '%<system-reminder>%'
  AND left(md5(w.txt), 8) = lower(trim(getenv('DSK_MSG')))
  AND (coalesce(getenv('DSK_SESSION'), '') = ''
       OR w.session_id = getenv('DSK_SESSION'))
ORDER BY ts DESC, session_id;
