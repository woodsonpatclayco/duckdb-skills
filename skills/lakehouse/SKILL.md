---
name: lakehouse
description: >
  Query the materialized contracts lakehouse (DuckLake) and read its check
  history. Freshness is four-way; SKIPPED writes no history rows, REFUSED
  does. Quality directives (@anchor/@rows_floor/@assert) are opt-in -- a
  contract without them still gets truncation, consistency, fingerprint checks.
allowed-tools: Bash
---

Materialize contracts into a DuckLake lakehouse (`${CLAUDE_PLUGIN_ROOT}/tools/materialize.ps1`) and read
back its status and check history (`${CLAUDE_PLUGIN_ROOT}/tools/lake-status.ps1`). This is item 6:
downstream of item 5's assertion harness, which it invokes rather than
reimplements.

## Running the tools

Run every script with
`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/tools/<script>.ps1" <args>`
from the project folder (the tools resolve the project from the current folder).
Quote the path; it may contain spaces. `dsk-paths.ps1` is a library, not a tool. Read
the extract root from `list-extracts`' `extract root:` line instead of dot-sourcing it.

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

## Querying the lake directly

`ATTACH 'ducklake:<lakeRoot>\lake.ducklake' AS lake (DATA_PATH '<lakeRoot>\data')`
after `LOAD ducklake;`, in a fresh `duckdb` invocation -- there is no persistent
session between invocations in this project. `<lakeRoot>` defaults to
`~\.duckdb-skills\<project-id>\lake` (`${CLAUDE_PLUGIN_ROOT}/tools/dsk-paths.ps1`'s `Resolve-LakeRoot`);
override with `-LakeRoot` on either tool. For a **read-only** query, add
`READ_ONLY` to the `ATTACH` options -- confirmed this session that DuckLake
accepts it, and it is what `${CLAUDE_PLUGIN_ROOT}/tools/lake-status.ps1` uses so a status check never
creates a lake that does not yet exist. `lake.<contract_name>` holds the current
data; `lake.manifest` and `lake.check_history` hold provenance and check results.
Once a contract is materialized, the lake is the place to answer questions about
that sheet, and it does not need the workbook present — see
`${CLAUDE_PLUGIN_ROOT}/tools/prove-requery.ps1`.

## The four-way freshness key -- and why the compat hash is in it

`${CLAUDE_PLUGIN_ROOT}/tools/materialize.ps1` re-decides per contract by comparing the workbook's
`LastWriteTime` and SHA-256, the contract file's SHA-256, and
`${CLAUDE_PLUGIN_ROOT}/skills/query/duckdb-compat.sql`'s SHA-256 against the newest `lake.manifest` row
for that contract. **All four, not three.** Both shipped contracts call
`xl_date()`, defined in the compat file -- change its epoch or its trailing
`::DATE` and every decoded date in the lake changes while the workbook and the
contract are both byte-identical, so a decision keyed on only the first three
would SKIP and keep serving the old decode silently. This is the same class of
failure as item 1's three-macros-wrong-at-17/17-passing and the items-3+4
decoder that was wrong for 6,654 of 18,764 dates -- both times undetected by
checks that never looked at what actually produced the value.

The workbook hash is read via DuckDB (`sha256(content) FROM read_blob(...)`),
never `Get-FileHash`: confirmed this session that on a `FileShare.None`-locked
file, `Get-FileHash`'s exception names no process, while DuckDB's own I/O layer
enriches the identical error with the holder's name and PID -- the shape a
locked-workbook run must report verbatim. The target's own existence (and row
count) is also checked every run and overrides a clean hash match: a manifest row
can outlive its table (the lake's Parquet is separately deletable scratch), and a
manifest row with `checks_passed = false` never satisfies freshness either --
forced bad data is always re-checked, never served from a stale-but-matching row.

## SKIPPED vs REFRESHED (vs REFUSED, vs FORCED)

`SKIPPED` means none of the four hashes moved, the target still exists with rows,
and the last run's checks passed -- **and writes no row to either `manifest` or
`check_history`.** There is deliberately no record of a no-op run; do not read a
gap in the history as missing data. Every other outcome writes both tables,
sharing one `run_id`: `REFRESHED` (checks passed, table replaced),
`REFUSED` (checks failed, previous table left untouched, non-zero exit),
`FORCED` (`-Force` overrode a `REFUSED`, table replaced anyway,
`manifest.forced = true`). A `REFUSED` run still gets a manifest row -- otherwise
`-AsOf`/`-History` could never date it, since `check_history` carries no
timestamp of its own.

## Data is real Parquet -- an empty `DATA_PATH` would be abnormal

`ducklake_default_data_inlining_row_limit` is 10; both shipped contracts are far
above it (62,230 and 219 rows), so `DATA_PATH\main\<contract>\` always holds
`*.parquet` after a `REFRESHED`/`FORCED` run, and `snapshots()` shows
`tables_created`/`tables_inserted_into`, never `inlined_insert`, for that write.
Decide whether a materialization happened from `lake.snapshots()` and the
manifest -- never from the filesystem.

## DuckLake's own lock is the serializer -- there is no hand-rolled one

A second writer's `ATTACH` fails immediately against a held catalog with
`IO Error: Failed to attach DuckLake MetaData ... File is already open in
...duckdb.exe (PID <n>)`, exits non-zero, and writes nothing -- confirmed this
session with a genuine ~12s non-foldable hold (`max(hash(i*7+1)) FROM
range(2000000000)`; `count(*) FROM range(n)` is constant-folded and produces no
real overlap). `${CLAUDE_PLUGIN_ROOT}/tools/materialize.ps1` reports this verbatim and does not retry;
the tuning knobs are `ducklake_max_retry_count`, `ducklake_retry_backoff`,
`ducklake_retry_wait_ms` if retrying is ever wanted later.

## Recovering a superseded write

`SELECT * FROM lake.<contract> AT (VERSION => <lake_snapshot_id>)`, reading
`lake_snapshot_id` from the manifest row for the run you want -- **never a
hardcoded version literal.** Snapshot ids are per-lake and every write to
`manifest`/`check_history` (including a `REFUSED` run's own bookkeeping) advances
the counter too, so the id you want is always the one recorded on that
contract's own manifest row, not an assumed small integer.

## `check_history.kind` -- the `_floor` suffix decides it

An `-- @assert <name>: ...` line becomes `kind = floor` iff `<name>` ends
`_floor`, else `invariant`; `ROWS_FLOOR` is always `floor`; `ANCHOR`,
`TRUNCATION_ROWS_LOST`, `CONSISTENCY_VIEW_ROWS` are always `invariant`;
`SNAPSHOT`/`FINGERPRINT` lines are always `snapshot`. A future contract with an
unsuffixed floor is filed as an invariant -- the suffix is the only
machine-readable signal there is. `check_history.observed` for an `@assert` row
is the emitted PASS/FAIL/ERROR verdict itself, never the underlying ratio/date/
sum: the harness (`${CLAUDE_PLUGIN_ROOT}/tools/run-assertions.ps1`) never emits that value (item 4's
Decision 1 keeps only the verdict), and this tool never recomputes an
assertion's expression to recover it -- a second evaluation would be a second
source of truth. `${CLAUDE_PLUGIN_ROOT}/tools/lake-status.ps1 -History <contract>` prints an explicit
note on every such row for this reason.

## Joining a lake table to a Snowflake extract

`${CLAUDE_PLUGIN_ROOT}/tools/cross-query.ps1` (item 8) answers one question across a lake table and a Snowflake extract
in a single SQL statement, printing the age of both inputs beside the answer -- see the README's
"Joining a Snowflake extract to a workbook sheet" section for the walkthrough and the freshness rule.

