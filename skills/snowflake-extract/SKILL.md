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
4. `COPY INTO @~/duckdb-skills/<project-id>/<name>__<8 hex>/ FROM (<query>)
   FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE`. Capture
   `rows_unloaded` -> `row_count` and `output_bytes`. The random 8-hex suffix means
   two sessions materializing the same name cannot collide on the stage.
5. `GET @~/duckdb-skills/<project-id>/<name>__<suffix>/ 'file://<root>/<name>.new/'`.
6. Look up `TOTAL_ELAPSED_TIME` for that `COPY INTO` via
   `<db>.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION()`, `EXECUTION_STATUS = 'SUCCESS'`
   only, -> `runtime_seconds`. If unobtainable, omit the field and say so.
7. `tools\publish-extract.ps1 -Name <name> -StagingDir <root>\<name>.new
   -SidecarPath <path to the JSON built from steps 2-6> -ExtractRoot <root>`. It
   stamps `sidecar_version`/`materialized_at`/`window_minutes`/`expires_at` itself --
   do not include them.
8. `REMOVE @~/duckdb-skills/<project-id>/<name>__<suffix>/` to stop the stage copy
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
