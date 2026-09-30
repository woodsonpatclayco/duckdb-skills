# REVIEW-task-1 — item 8 (the cross-source join), round 1

> Written by the task-reviewer, which reports it could not create files under its constraints. Saved
> verbatim by the main session. The reviewer's own side effect — an empty directory tree at
> `C:\nonexistent_zz_probe\` created by DuckLake's `DATA_PATH` during an in-memory probe — was confirmed
> to contain 0 files and removed by the main session.

Round 1, first draft: `TASK.md` untracked; no `RESULT-*.md` or prior `REVIEW-task-*.md`. `Plan: PLAN-4.md`
is the newest plan, unedited since 2026-09-24 14:18 — frozen, not edited after freezing.

## Verdict: NOT READY — the design holds; one rule tells the implementer to build a hole

"An unqualified `BASE_TABLE` is a CTE name … the runner ignores it" is measured to be the exact route by
which a raw file read bypasses D3. Several other items would each cost a round; all are wording.

## What the implementer will build (from TASK.md alone)

`tools\cross-query.ps1` takes one `.sql` file holding a single SELECT; uses DuckDB's parser to list
inputs; accepts only `lake.<table>` and `extract_table('<literal>')`; dates every input first (extract via
`registry.sql`; lake table via `lake.manifest` vs the workbook's current `LastWriteTime`, or
`lake.join_manifest` for a saved join); prints `EXTRACT`/`LAKE`/`SAVED` lines; runs the query in one
process with the lake `READ_ONLY` and `extract_table` as a macro over registry-resolved paths; prints
`RESULT` and 20 CSV rows. Stale is reported, never refused. `-Save` writes a real table and records each
input's version in `lake.join_manifest`. Plus two example queries, a README walkthrough and freshness
rule, and one pointer paragraph in each of two skills whose descriptions do not change. Matches PLAN-4 §8
plus a save feature taken from the plan's `Serves:` line.

## Round-2 risks, most likely first

### 1. D3 is bypassable — a quoted path and a CTE name are the same node shape

Measured (`json_serialize_sql` + `json_tree`, v1.5.5):

| query | node |
|---|---|
| `FROM 'C:/x/*.parquet'` | `BASE_TABLE`, catalog `""`, schema `""`, table `C:/x/*.parquet` |
| `FROM "C:/x/y.parquet"` | same shape |
| `FROM parent_projects.parquet` | `BASE_TABLE`, schema `parent_projects`, table `parquet` — a *qualified* node |
| `WITH Clayco_Job_Costs_from_GL AS (…) SELECT * FROM Clayco_Job_Costs_from_GL` | `BASE_TABLE`, catalog/schema empty — same shape as a quoted path |
| `SELECT (SELECT count(*) FROM 'C:/x/a.parquet') …` | `BASE_TABLE` inside a scalar subquery |
| `lake."Quoted Name"` | schema `lake`, table `Quoted Name` |
| `lake.snapshots()` | `TABLE_FUNCTION` `snapshots`, `function.schema` = `lake` |

Each reads files (real extract, read-only): single-quoted path → 15314; double-quoted → 15314; path in a
scalar subquery → 15314; `FROM parent_projects.parquet` → `IO Error: No files found that match the pattern
"parent_projects.parquet"` (a replacement scan on a *qualified* name); with `lake` attached,
`FROM lake.x.parquet` → `No files found that match the pattern "lake.x.parquet"` — a `lake`-qualified node
the spec would classify as a lake input. A CTE named with a file path, referenced **outside that CTE's
scope**, read the real file (`n = 28`) — so a scope-blind CTE allow-list is also bypassable unless path
characters in CTE names are refused. `.xlsm` gets no replacement scan (`Catalog Error`); `.xlsx`, `.csv`,
`.json` do.

**Replacement for step 1's last two bullets and the paragraph after:**

> Collect every CTE name — the `key` of each `cte_map.map[]` entry at any depth. Refuse any CTE whose name
> contains `.`, `/`, `\` or `:`. Then classify every `BASE_TABLE` node:
> - `catalog_name = lake` and `schema_name = main`, or `catalog_name` empty and `schema_name = lake` → a
>   **lake input** named `table_name`. Step 2 confirms it exists (`duckdb_tables()` with
>   `database_name = 'lake'`, case-insensitive), else refuse
>   `ERROR,lake,<table>,no such table in the lake at <root>`.
> - `catalog_name` and `schema_name` both empty and `table_name` case-insensitively equal to a collected
>   CTE name → a CTE, ignored.
> - **Anything else is refused**: `ERROR,input,<name>,not a lake table or an extract — use lake.<table> or extract_table('<name>')`.
>
> Every `TABLE_FUNCTION` other than an unqualified `extract_table` is refused, including `lake.snapshots()`,
> `range()`, `query()`, `query_table()`. Say so in the README.

Add to AC7: double-quoted path, `FROM parent_projects.parquet`, `FROM lake.x.parquet`, path in a scalar
subquery — each refused, exit 1, nothing run. Fix the facts table: the quoted-path shape is now known.

### 2. "The same row `tools\lake-status.ps1` reports" is false

Default-mode `lake-status.ps1` takes the latest row of any outcome (`lake-status.ps1:211`, `QUALIFY
row_number() OVER (… ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC) = 1`, no outcome
filter). Only `-AsOf` filters `(checks_passed OR forced)` (`:159`). The real lake has a REFUSED GL row
(`7e9d53bb…, 2026-09-25 21:26:05, row_count NULL, lake_snapshot_id 14, false, false`) carrying the same
snapshot id as the landed row before it.

**Replacement:**

> Take `… FROM lake.manifest WHERE lower(contract_name) = lower('<table>') AND (checks_passed OR forced)
> ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1` — the row
> `lake-status.ps1 -AsOf <now> -Contract <table>` reports as effective, not its default mode. If a newer
> REFUSED row exists, append `,refused_since=<n>` to the `LAKE` line.

### 3. `source_mtime` is local time, not UTC

`materialize.ps1:305` records `(Get-Item …).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')` — local,
truncated to the second; `materialized_at` is `timezone('UTC', now())`. Real lake: `source_mtime
2026-09-25 08:48:13` beside `materialized_at 2026-09-25 21:23:23.99`. Local vs UTC here: `16:26:30` vs
`21:26:30`. The spec's "compare UTC … never `now()`" pushes toward `LastWriteTimeUtc`, which makes
`workbook_changed_since=true` everywhere and fails AC1/AC9.

**Replacement:**

> Compare the workbook's `LastWriteTime` (**local**, not `LastWriteTimeUtc`), formatted
> `yyyy-MM-dd HH:mm:ss` exactly as `materialize.ps1:305`, with `source_mtime`'s text. Unequal → `true`. A
> moved mtime with identical content still counts `true` — `materialize.ps1` would refresh on its next
> run, which is what the flag means. Only `LAKE`'s `age_minutes` uses UTC.

### 4. `-Save` can overwrite a contract table by case

Measured: `CREATE TABLE "Clayco_Job_Costs_from_GL" …; CREATE OR REPLACE TABLE "clayco_job_costs_from_gl" …`
leaves one table with the replacement's data — quoted identifiers are case-insensitive, so quoting does
not protect. A case-sensitive refusal check lets `-Save clayco_job_costs_from_gl` destroy the contract
table; step 2 lookups would print `provenance=NONE` for `lake.clayco_job_costs_from_gl`.

**Replacement:** all name comparisons (refusal list, `lake.manifest` and `lake.join_manifest` lookups,
existing tables) use `lower()` both sides. Also refuse a `-Save` name matching any existing lake table
without a `lake.join_manifest` row — a saved join may only replace a saved join. Add to AC7:
`-Save clayco_job_costs_from_gl` refused, `<L>` GL row count unchanged.

### 5. Default roots get created in the verifier's worktree → AC13 fails

`Resolve-ExtractRoot`/`Resolve-LakeRoot` **create** the default directory when no root is passed
(`dsk-paths.ps1:65-67`, `:84-86`); `Resolve-LakeRoot` also creates an explicit root (`:77-79`). AC5's
re-query and several AC7 cases omit `-ExtractRoot`. Earlier worktrees left exactly such directories:
`c-users-woodsonp-claude-dev-_verify-2a`, `_verify-2b`, `_verify-2b-r2`.

**Replacement (Conventions):** every check passes both `-ExtractRoot` and `-LakeRoot` explicitly; the
runner resolves the extract root only when the query has an `extract_table` input. AC5: run with
`-ExtractRoot <the deleted scratch path>` and show `Test-Path` `False` for it before and after.

### 6. Real-lake safety depends on where the implementer runs

In the main checkout, `Resolve-LakeRoot`'s default **is** the real lake; a `-Save` without `-LakeRoot`
writes it, and mutation 4 without `-LakeRoot` drops the real `lake.manifest`. AC5's "delete the scratch
copy" is a `Remove-Item -Recurse` on a variable.

**Replacement (Conventions):** before any `-Save`, mutation or `Remove-Item`, assert the target's full path
starts with `$env:TEMP` and is not `<X>`, and print the assertion. After AC5's deletion, show
`Test-Path <X>\parent_projects\_extract.json` → `True`. Mutation 4 only with `-LakeRoot <L>` under
`$env:TEMP`.

### 7. The save record is underspecified in three places

**(a) Capture timing of `lake_snapshot_id`.** In-memory DuckLake: after `CREATE`, max snapshot = 1;
`INSERT INTO join_manifest SELECT …, max(snapshot_id) FROM lake.snapshots()` recorded **2** because the
intervening `CREATE TABLE join_manifest` took snapshot 2; after `CREATE OR REPLACE`, 4.
`AT (VERSION => 2)` returned the pre-replace 5 rows; `AT (VERSION => 0)` → `Catalog Error: … does not
exist at version 0`. `materialize.ps1:497` captures immediately after its `CREATE OR REPLACE`.

**Replacement:** `CREATE TABLE IF NOT EXISTS lake.join_manifest …` first; then
`CREATE OR REPLACE TABLE lake."<t>" AS SELECT * FROM _r` (not the query a second time); then capture
`max(snapshot_id) FROM lake.snapshots()` as `lake_snapshot_id` as `materialize.ps1:497` does; then insert.

**(b) D5 vs step 4.** D5 records the lake table's "`run_id` and `materialized_at`"; step 4's JSON is
`{kind, name, version, row_count}`. **Replacement:** `{kind, name, version, materialized_at, row_count}`,
`materialized_at` naive UTC for every kind.

**(c) `saved` inputs and staleness.** **Replacement:** a `saved` input's `materialized_at` is the oldest
among that saved join's own recorded inputs; a saved join is stale when its oldest input's age exceeds
`DSK_WINDOW_MINUTES`. With no extract inputs, `RESULT` reads `extract_ages=none`.

### 8. A trailing `--` comment breaks the embedding

Measured: `CREATE TEMP TABLE _q AS SELECT 7 AS k -- trailing comment;` — the appended `;` is inside the
comment, the next statement merges: `Parser Error: syntax error at or near "SELECT"`. The parse step
passes (inside a string literal the comment ends cleanly), so it fails only at run time. AC8's decoy is a
comment. **Replacement (step 1):** wherever the query is embedded, append a newline before any following
`;` or text. (A line starting with `.` inside a statement is **not** run as a dot-command — measured
`Parser Error` at `.print` — so no rule is needed.)

### 9. AC1's `workbook_changed_since=false` depends on SharePoint

The spec records a sync landing mid-session (62,377 → 62,603). A sync between materialize and query flips
`LAKE` to `true` and `stale_inputs` to 2 with a correct implementation. **Replacement:** build `<L>` for
AC1–AC8 and AC10–AC11 from a scratch copy of the workbook (AC9's rewrite); only AC12 uses the live file,
where `workbook_changed_since=true` is quoted as drift and `stale_inputs` may be 2.

### 10. `registry.sql` exits 0 on a name mismatch

`DSK_EXTRACT_NAME='other'` → `reason = name mismatch`, **exit 0**; `parallel array mismatch` likewise.
**Replacement:** set `DSK_EXTRACT_DIR`/`DSK_EXTRACT_NAME` as `list-extracts.ps1:43-45`; refuse on non-zero
exit, missing `_extract.json`, or non-empty `reason`: `ERROR,extract,<name>,<reason>`. NULL or negative
`age_minutes` is `UNKNOWN` and counts as stale (SIDECAR.md:51-52). `parquet_glob` has mixed separators
(`C:\…\extracts\parent_projects/*.parquet`); `read_parquet` accepts it (15314); double any single quotes
if embedded as a literal.

### 11. AC3/AC4 fixtures can silently get the age wrong

`'2026-09-30T09:10:00-05:00'::TIMESTAMP` → `09:10:00` (offset dropped; `+05:00` the same), so a
PowerShell local `ToString('o')` lands 300 minutes off. **Replacement:** `materialized_at` =
`(Get-Date).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')`; copy the whole directory
and rewrite only that field. AC4: unordered `LIMIT 1000` matched 52 of 345 GL projects — use
`COPY (SELECT * FROM read_parquet('<X>/parent_projects/*.parquet') ORDER BY PARENT_PROJECT_NUMBER LIMIT 1000) TO …`,
expected `RESULT` rows = a same-run `count(DISTINCT)` of GL projects in that file. `EXTRACT rows=1000`
only echoes the sidecar — `RESULT` is the proof. `expires_at`/`output_bytes` need not be consistent;
`bytes_check` reads `DISAGREES` in `list-extracts.ps1` for `<Z>`, harmless — say so.

### 12. Timing — see Drift.

### 13. AC11's lock probably surfaces earlier

Step 2 attaches `<L>` **READ_ONLY** before the `-Save` attach; a read-write holder likely blocks that too
(**not measured** — needs an on-disk scratch lake). **Replacement:** a lock may surface at step 2's
read-only attach or at the save attach; either is reported verbatim, exit 1, no retry; measure which and
state it. Confirm `HasExited=False` at the moment of failure, as item 6's AC17 did.

### 14. Controls not labelled

AC13, AC14 and AC12's "descriptions byte-identical" pass on today's repo. Label them controls.

## Drift from the plan

- **Timing.** PLAN-4 §8: "process exiting under 2s". The spec gates only the statement. Measured pieces:
  `powershell -NoProfile` 272–278 ms; parse ~60 ms; `registry.sql` 79 ms; manifest lookup with
  `LOAD ducklake` 164–213 ms; join process 159–194 ms — total ~0.8–1.2 s, so the plan's wording is
  achievable. **AC1:** whole `powershell -File tools\cross-query.ps1 …` wall time ≤ 2 s via
  `Measure-Command`, plus `elapsed` for the statement.
- **Risks bullet (PLAN-4:674-675).** The plan says item 6's manifest records the extract's
  `materialized_at`; the spec records it in a new `lake.join_manifest` and leaves `lake.manifest` alone —
  stated openly (D5), reasoning sound, but a change to where the plan said the fact lives. One line to Phil.
- **Expansion, none silent:** `-Save`/`join_manifest` (from the `Serves:` line), D3's refusals, and
  `workbook_changed_since`/`stale_inputs` (from the measured stale lake). `-Save` is ~40% of the spec
  (AC5, AC6, AC11, mutations 2/4/6) and where findings 4, 6, 7 live — put it to Phil as keep-or-cut; do not
  cut it unilaterally, the `Serves:` line asks for it.
- **Omissions:** none. README patterns and freshness rule are part C; "Phil follows the doc … reaches a
  specific joined row count with the extract age beside it" is AC12 via AC1's `RESULT` line.

## Weak acceptance checks

| check | weakness | stronger |
|---|---|---|
| AC1 `elapsed ≤ 2 s` | statement only | whole-command `Measure-Command` ≤ 2 s |
| AC1 `workbook_changed_since=false` | a sync flips it | `<L>` from a scratch workbook copy |
| AC4 `rows=1000` on `EXTRACT` | echoes the sidecar | `RESULT` rows = same-run distinct GL projects in `<Z>`, `ORDER BY` in the `COPY` |
| AC7 quoted path | one shape | add double-quoted, `parent_projects.parquet`, `lake.x.parquet`, scalar subquery |
| AC7 `-Save` names | exact case only | add `-Save clayco_job_costs_from_gl` |
| AC5 "no extract directory exists" | no command | `Test-Path <scratch>\parent_projects` False; `<X>\…\_extract.json` True |
| AC6 `AT (VERSION => …)` | unpinned capture timing | finding 7a |
| AC11 | failing attach unidentified | measure which; `HasExited=False` |
| AC13, AC14 | pass before any work | label controls |

## Commands run (all read-only or in-memory)

Parse-tree shapes (every claim in the spec's table confirmed — `DROP`/`CTAS` refusal text, `statements`
length 2, parser `error_type`, `FUNCTION` vs `CONSTANT`) plus the new shapes above; replacement-scan reads
against the real extract root, read-only; the real lake's manifest and snapshots `READ_ONLY` (8,663,040
bytes, `2026-09-25T16:26:30`, unchanged before and after); the join/anti-join figures (345 / 62,230 /
`22478661033.93` / 0 unmatched, matching the spec); `registry.sql` output including name mismatch;
timestamp-offset casts; DuckLake `AT VERSION` in memory; identifier case-folding; trailing-comment
embedding; per-piece timings. Loaded extensions: `autocomplete`, `core_functions`, `icu`, `json`,
`parquet`, `shell`, plus `ducklake` in lake probes. Nothing touched the real lake, the extracts, the live
workbook, or the `snowflake` extension.
