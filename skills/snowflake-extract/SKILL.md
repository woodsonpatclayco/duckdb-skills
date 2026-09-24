---
name: snowflake-extract
description: >
  Materialize a named Snowflake query as local Parquet, tracked by a sidecar
  that records row-count and last-altered baselines. Reads check the registry
  first and re-pull silently only when stale, via a two-stage row/last_altered
  check that costs no warehouse compute when nothing changed.
allowed-tools: Bash, snowflake_sql_execute
---

Materialize a named Snowflake query to `~\.duckdb-skills\<project-id>\extracts\<name>\`,
publish it with a sidecar (`skills/snowflake-extract/SIDECAR.md`), and re-pull it
silently when a freshness check says stale. Every decision and every filesystem
mutation is a script (`tools\extract-decide.ps1`, `tools\publish-extract.ps1`); the
agent only moves bytes and feeds values in.

## Registry first -- check before querying Snowflake

Before running any query against Snowflake, run `tools\list-extracts.ps1` to see
whether a named extract already covers the need. This is documentation, not an
enforceable check -- skills are stateless shell invocations and nothing compels a
future session to look first (precedent: `skills/read-memories/SKILL.md:15-18`).

## Materialize (first time, or `-Name` not yet registered)

1. Resolve the extract root: dot-source `tools\dsk-paths.ps1` or read
   `tools\list-extracts.ps1`'s `extract root:` header. **Create `<root>\<name>.new\`
   before `GET`** -- `GET` fails `ENOENT` against a directory that does not exist yet.
2. For each source object: `SHOW TABLES LIKE '<object>'` for `rows` and `bytes`
   (`source_rows`, `source_bytes`), and
   `SELECT CONVERT_TIMEZONE('UTC', LAST_ALTERED) FROM <db>.INFORMATION_SCHEMA.TABLES
   WHERE ...` for `source_last_altered`.
3. Capture provenance: `role` from `CURRENT_ROLE()`, `warehouse` from
   `CURRENT_WAREHOUSE()`, `connection` = the literal `DATAHUB` (no SQL returns the
   connection name), `database` = the database qualifier of the first
   `source_objects` entry (`CURRENT_DATABASE()` is empty on this connection). **Do
   not invent a value for any field; if one cannot be obtained, stop and report.**
4. **Determine the query -- never issue a blind `SELECT *` without checking first.**
   `COPY INTO ... FILE_FORMAT=(TYPE=PARQUET)` refuses to unload `TIMESTAMP_TZ` or
   `TIMESTAMP_LTZ` columns, so the query must be built, not assumed. This step
   applies to a whole-object `SELECT * FROM <object>` with exactly one entry in
   `source_objects`; for a hand-written or multi-object query the author supplies
   the projection and owns the same TZ risk described here.
   - Split the fully-qualified source object into `<db>`/`<sch>`/`<obj>` and query
     `<db>.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '<sch>' AND
     TABLE_NAME = '<obj>' ORDER BY ORDINAL_POSITION`. **Bare `INFORMATION_SCHEMA`
     fails `invalid identifier` on this connection** -- qualify with `<db>`, same
     trap as `QUERY_HISTORY_BY_SESSION` below.
   - If no column has `DATA_TYPE IN ('TIMESTAMP_TZ','TIMESTAMP_LTZ')`, the query
     stays `SELECT * FROM <object>` -- unchanged for the common case.
   - Otherwise build an explicit column list **in ordinal order** (this is what
     makes the projection produce the same column set `SELECT *` would have):
     every TZ/LTZ column projects as
     `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"`; every other
     column is named plainly. **Every column name is emitted double-quoted, in
     both forms.** `COLUMN_NAME` comes back from `INFORMATION_SCHEMA.COLUMNS`
     without its own quotes, so a bare identifier is a syntax error on a reserved
     word or on any column actually created as a quoted identifier; double any
     `"` that appears inside a `COLUMN_NAME`.
   - **The resulting DuckDB type is a naive `TIMESTAMP` holding UTC**, not
     `TIMESTAMPTZ` -- the same discipline as `materialized_at` applies: compare
     against `timezone('UTC', now())`, never `now()`.
   - **Re-derive the projection on every materialize, including every refresh --
     never replay a stored column list.** An upstream column added after the
     first materialize (including a new TZ column) would be silently dropped
     otherwise. The extract's identity is its `name`, never its query text.
   - **If `COPY INTO` still fails with a type-unload error after projection, stop
     and report the column and its type. Do not widen the cast to make it pass.**
     A TZ column nested inside another type is not caught by the check above,
     and this is what turns that miss into a loud stop instead of a silent one.
5. `COPY INTO @~/duckdb-skills/<project-id>/<name>__<8 hex>/ FROM (<query>)
   FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE`. Capture
   `rows_unloaded` -> `row_count` and `output_bytes`. The random 8-hex suffix means
   two sessions materializing the same name cannot collide on the stage.
6. `GET @~/duckdb-skills/<project-id>/<name>__<suffix>/ 'file://<root>/<name>.new/'`.
7. Look up `TOTAL_ELAPSED_TIME` for that `COPY INTO` via
   `<db>.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION()`, `EXECUTION_STATUS = 'SUCCESS'`
   only, -> `runtime_seconds`. If unobtainable, omit the field and say so.
8. `tools\publish-extract.ps1 -Name <name> -StagingDir <root>\<name>.new
   -SidecarPath <path to the JSON built from steps 2-7> -ExtractRoot <root>`. It
   stamps `sidecar_version`/`materialized_at`/`window_minutes`/`expires_at` itself --
   do not include them. The sidecar's `query` records step 4's determined query
   verbatim, using `\n` alone as the line separator.
9. `REMOVE @~/duckdb-skills/<project-id>/<name>__<suffix>/` to stop the stage copy
   billing storage.

## Read (an extract already exists)

Call `tools\extract-decide.ps1 -Name <name>` with **no current values**.

- `FRESH` -- stop. No Snowflake call.
- `STALE (probe required) age=<n> window=<w> objects=<list>` -- probe each printed
  object in order (`SHOW TABLES` rows + `LAST_ALTERED`), then call
  `tools\extract-decide.ps1` again with `-CurrentRows`/`-CurrentLastAltered`
  positional against that same object list.
- Any `REFRESH (...)` -- re-materialize **silently, no prompt**. Print the sidecar's
  `row_count` and `runtime_seconds` *before* refreshing (the wait is otherwise
  unpredictable), and one line of elapsed time after. The first-ever materialize
  has no prior runtime to print.
- `SKIPPED (...)` -- serve the existing extract as current.

**A failed re-pull must not serve stale data as current.** Print the literal
`STALE: refresh failed, serving nothing; extract age <n> minutes` and stop.

## Freshness window

`DSK_WINDOW_MINUTES` follows work mode: 60 minutes for analysis, 1440 for dev
(`AGENTS.md`'s convention). The reader's mode governs what it passes; the sidecar's
`window_minutes` is the writer's fact only, never consulted for a decision. The
window is the only throttle -- there is no per-session cap, because a refresh
rewrites `materialized_at` and an all-day session with a short window is meant to
refresh repeatedly, not once.

## Stage-path collision

Settled by construction: the random 8-hex suffix per materialize plus the `REMOVE`
after `GET` means two sessions choosing the same extract name cannot collide on the
stage. `publish-extract.ps1`'s rename-aside sequence settles the local side.
