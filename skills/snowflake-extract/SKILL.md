---
name: snowflake-extract
description: >
  Materialize a named Snowflake query as local Parquet, tracked by a sidecar
  that records row-count and last-altered baselines. Reads check the registry
  first and re-pull silently only when stale, via a two-stage row/last_altered
  check that costs no warehouse compute when nothing changed.
allowed-tools: Bash
---

Materialize a named Snowflake query to `~\.duckdb-skills\<project-id>\extracts\<name>\`,
publish it with a sidecar (`skills/snowflake-extract/SIDECAR.md`), and re-pull it
silently when a freshness check says stale. Every decision and every filesystem
mutation is a script (`${CLAUDE_PLUGIN_ROOT}/tools/extract-decide.ps1`, `${CLAUDE_PLUGIN_ROOT}/tools/publish-extract.ps1`); the
agent only moves bytes and feeds values in.

## Running the tools

Run every script with
`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/tools/<script>.ps1" <args>`
from the project folder (the tools resolve the project from the current folder).
Quote the path; it may contain spaces. `dsk-paths.ps1` is a library, not a tool. Read
the extract root from `list-extracts`' `extract root:` line instead of dot-sourcing it.

## Running Snowflake SQL

All Snowflake SQL goes through one runner, `sf.py`, which uses the Python connector
(connection `DATAHUB` unless `--connection` says otherwise):

- `py -3.12 "${CLAUDE_PLUGIN_ROOT}/tools/sf.py" query --sql-file <f>` runs **one** read-only
  statement and prints the result as CSV (header row first) on stdout.
- `py -3.12 "${CLAUDE_PLUGIN_ROOT}/tools/sf.py" unload --name <name> --project-id <id>
  --database <db> --sql-file <query.sql> --dest <root>\<name>.new` does the unload, download,
  timing lookup and stage cleanup in one session (see Materialize step 5).

SQL is never passed on the command line: write it to a temporary `.sql` file first, as
UTF-8 (a BOM is tolerated). `query` only accepts `SELECT`, `WITH`, `SHOW` and
`DESC`/`DESCRIBE`; anything else is refused with exit 2 before connecting. One statement
per file. Timestamps print as ISO 8601, UTC with a `Z` suffix when timezone-aware.

If the cached sign-in token has expired, a browser sign-in opens mid-run (the prompt
text goes to stderr, not stdout). Phil signs in, and the call then continues.

## Which project the tools act on

These tools run **inside the project's git repo** (the project is the git root of the
current folder -- there is no current-folder fallback), or with explicit roots
(`-LakeRoot` / `-ExtractRoot`; `materialize` also needs `-Contract` outside a repo).
Outside a repo without them they print `ERROR: not inside a git repository: ...` and
exit 2. Read-only tools never create folders -- only `materialize` and
`publish-extract` do. Every tool writes `project: <id> (<root>)` to **stderr**, naming
what it resolved; check it before trusting the answer.

**A refusal is the answer -- stop there.** If a tool prints `ERROR: not inside a git
repository: ...`, tell the user this folder has no project, and ask which project they
mean. Do **not** look under `~\.duckdb-skills\` for some other project's lake or
extracts, and do **not** pass `-LakeRoot` / `-ExtractRoot` / `-Contract` unless the user
named that folder or file themselves. Reading another project's data without being asked
is exactly what the refusal exists to prevent.

## Registry first -- check before querying Snowflake

Before running any query against Snowflake, run `${CLAUDE_PLUGIN_ROOT}/tools/list-extracts.ps1` to see
whether a named extract already covers the need. This is documentation, not an
enforceable check -- skills are stateless shell invocations and nothing compels a
future session to look first.

## Materialize (first time, or `-Name` not yet registered)

1. Resolve the extract root: read
   `${CLAUDE_PLUGIN_ROOT}/tools/list-extracts.ps1`'s `extract root:` header. **Create `<root>` if it is
   missing (read-only tools no longer create it)**; `sf.py unload` creates
   `<root>\<name>.new\` itself.
2. For each source object (each statement written to a `.sql` file and run with
   `sf.py query`): `SHOW TABLES LIKE '<object>'` for `rows` and `bytes`
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
     trap as `QUERY_HISTORY_BY_SESSION`, which `sf.py unload` already qualifies.
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
5. Write step 4's query to a temporary `.sql` file and run
   `py -3.12 "${CLAUDE_PLUGIN_ROOT}/tools/sf.py" unload --name <name> --project-id <id>
   --database <db> --sql-file <query.sql> --dest <root>\<name>.new`. `<id>` is the
   `project-id:` line `list-extracts` prints. In one connector session it runs
   `COPY INTO @~/duckdb-skills/<id>/<name>__<8 hex>/ ... (TYPE = PARQUET)`, `GET`s the files
   into `--dest` (creating it), looks up `TOTAL_ELAPSED_TIME` for that COPY, and `REMOVE`s
   the stage copy (in a `finally`, so a failure still cleans up; it writes `removed=<n>`
   to stderr). The random 8-hex suffix means two sessions materializing the same name
   cannot collide on the stage. It prints one JSON object on stdout; use its `row_count`,
   `output_bytes` and `runtime_seconds` (omitted only if `unload` omitted it -- say so)
   in the sidecar. On a COPY failure it prints Snowflake's error to stderr and exits 1;
   do not retry or widen a cast (see step 4).
8. `${CLAUDE_PLUGIN_ROOT}/tools/publish-extract.ps1 -Name <name> -StagingDir <root>\<name>.new
   -SidecarPath <path to the JSON built from steps 2-5> -ExtractRoot <root>`. It
   stamps `sidecar_version`/`materialized_at`/`window_minutes`/`expires_at` itself --
   do not include them. The sidecar's `query` records step 4's determined query
   verbatim, using `\n` alone as the line separator.

## Read (an extract already exists)

Call `${CLAUDE_PLUGIN_ROOT}/tools/extract-decide.ps1 -Name <name>` with **no current values**.

- `FRESH` -- stop. No Snowflake call.
- `STALE (probe required) age=<n> window=<w> objects=<list>` -- probe each printed
  object in order (`SHOW TABLES` rows + `LAST_ALTERED`, each run through `sf.py query`), then call
  `${CLAUDE_PLUGIN_ROOT}/tools/extract-decide.ps1` again with `-CurrentRows`/`-CurrentLastAltered`
  positional against that same object list. For more than one object,
  `powershell -File` cannot bind separate values to an array parameter, so pass
  a single comma-joined string per parameter instead of two bare tokens. Worked
  example, two objects probed as `objects=DB.SCH.A,DB.SCH.B` with rows 100 and
  205: `${CLAUDE_PLUGIN_ROOT}/tools/extract-decide.ps1 -Name <name> -CurrentRows 100,205
  -CurrentLastAltered "<a-timestamp>,<b-timestamp>"` -- each value lands
  positionally against the object printed in that same order.
- Any `REFRESH (...)`, including `REFRESH (no evidence past ceiling)` --
  re-materialize **silently, no prompt**. Print the sidecar's `row_count` and
  `runtime_seconds` *before* refreshing (the wait is otherwise unpredictable),
  and one line of elapsed time after. The first-ever materialize has no prior
  runtime to print.
- `SKIPPED (...)` -- serve the existing extract as current. `SKIPPED (no
  evidence) age=<n>` means the probe returned no comparable row count or
  last_altered for **any** object -- it is not a claim that the source is
  unchanged, only that nothing was available to compare. The other `SKIPPED`
  variants reflect real evidence of no change.

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

## Joining an extract to a lake table

`${CLAUDE_PLUGIN_ROOT}/tools/cross-query.ps1` (item 8) answers one question across a lake table and a Snowflake extract
in a single SQL statement, printing the age of both inputs beside the answer -- see the README's
"Joining a Snowflake extract to a workbook sheet" section for the walkthrough and the freshness rule.

