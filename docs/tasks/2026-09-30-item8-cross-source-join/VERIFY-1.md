# VERIFY-1 — item 8 (the cross-source join), round 1

Verifies **RESULT-1.md** (commit `1f3fe0f` on branch `item8-cross-source-join`, worktree HEAD `560ce47`,
detached at that commit). All work was done in the disposable worktree
`C:\Users\woodsonp\Claude\Dev\duckdb-skills-verify-item8` (never the main checkout, except this file).
Every `-Save`, mutation, and deletion targeted scratch paths under `$env:TEMP`, asserted before use. The
real extract root `<X>` and the real lake were used strictly read-only.

## Verdict: SHIP

No successful smuggling bypass was found beyond what AC7 already covers. Every acceptance check and
mutation proof reproduces independently. Both of the implementer's disagreements with the frozen spec's
prose are confirmed accurate. One new, minor (non-security) robustness finding is reported below.

## AC1 — five independent timings

Command: `Measure-Command { & powershell -NoProfile -File tools\cross-query.ps1 -Sql
examples\job-costs-by-parent-project.sql -ExtractRoot <X> -LakeRoot <L> }` (5 runs)

| run | seconds |
|---|---|
| 1 | 1.1422 |
| 2 | 1.1225 |
| 3 | 1.0758 |
| 4 | 1.1037 |
| 5 | 1.0824 |

All five comfortably under the 2s budget (spread 1.08–1.14s), tighter than RESULT-1.md's own reported
1.3–1.8s spread — no timing concern on this run of this machine. Output matched spec shape: `EXTRACT`
line `age_minutes≥8400,stale=true,rows=15314`; `LAKE` line `workbook_changed_since=false`; `RESULT`
line `rows=345,stale_inputs=1`; 20 CSV rows; exit 0.

## Per-check table

| check | expected | actual | verdict |
|---|---|---|---|
| AC1 | `EXTRACT…stale=true,rows=15314`; `LAKE…workbook_changed_since=false`; `RESULT,rows=345,…stale_inputs=1`; exit 0; ≤2s | Exactly this; 5 samples 1.08–1.14s (see table above). Command: `& powershell -NoProfile -File tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql -ExtractRoot <X> -LakeRoot <L>` | PASS |
| AC2 | full-result `gl_rows`/`job_costs` sums = `lake.Clayco_Job_Costs_from_GL`'s own count/sum; unmatched=0 rows | Summed 345-row CSV (via `-Limit 1000`): `gl_rows=62603`, `job_costs=22505496119.72`. Direct query `SELECT count(*),sum(JOB_COSTS) FROM lake.Clayco_Job_Costs_from_GL` → `62603,22505496119.72` — exact match. `job-costs-unmatched.sql` → `rows=0`. | PASS |
| AC3 | `<Y>` (real extract copy, `materialized_at` rewritten to −10min): default window `age_minutes≈10,stale=false`; `DSK_WINDOW_MINUTES=5` → `stale=true`; same file, no edit | `-ExtractRoot <Y>` window=60: `age_minutes=11,stale=false`. Same file, `DSK_WINDOW_MINUTES=5`: `age_minutes=11,window=5,stale=true`. | PASS |
| AC4 | `<Z>` (ordered `COPY…LIMIT 1000`, sidecar `row_count=1000`): same example file, `-ExtractRoot <X>`→345, `<Z>`→1 (independently confirmed by direct join against `<Z>`'s own parquet); unmatched→344; no `parquet`/`:\`/`:/` in example files | `<X>`: `RESULT,rows=345`. `<Z>`: `RESULT,rows=1`; independent `SELECT count(DISTINCT g.PARENT_PROJECT_NUMBER) FROM lake.Clayco_Job_Costs_from_GL g JOIN read_parquet('<Z>/parent_projects/*.parquet') p USING (PARENT_PROJECT_NUMBER)` → `1`. Unmatched vs `<Z>` → `rows=344`. `grep -n "parquet\|:\\\\|:/"` on both example files → no match. | PASS |
| AC5 | `-Save gl_by_parent` on `<L>`; delete scratch copy of `<X>`; re-query in new process with deleted root: `SAVED` line, `n`/`c` match AC1/AC2, `age_minutes≥8400`; one `join_manifest` row | `SAVED_AS,gl_by_parent,rows=345,run_id=bd96b145-…`. Deleted `<X-copy>`; `Test-Path` → `False`; real `<X>\parent_projects\_extract.json` → `True`. Re-query with `-ExtractRoot <deleted path>`: `SAVED,gl_by_parent,age_minutes=8599,…,inputs=parent_projects@2026-09-24 18:54:17;Clayco_Job_Costs_from_GL@e4d045e3-…`; `RESULT,rows=1,…`; CSV `n,c` → `345,22505496119.72` — exact match to AC1/AC2. One `join_manifest` row confirmed with full `inputs` JSON via direct query. | PASS |
| AC6 | Save `gl_by_parent` again from `<Z>`; two `join_manifest` rows; newest names `<Z>`; `AT (VERSION => <first row's snapshot id>)` still returns first save's count | Second save: `SAVED_AS,gl_by_parent,rows=1,run_id=08853ec7-…`. `join_manifest` rows: `(…345, snapshot 10)`, `(…1, snapshot 12)`. `SELECT count(*) FROM lake.gl_by_parent AT (VERSION => 10)` → `345`; current `count(*)` → `1`. | PASS |
| AC7 | 16 refusal cases, exit 1, nothing run; `<L>` GL count and snapshot count unchanged | All 16 cases (`DROP`, `SELECT 1; DROP…` with `-Save x`, non-literal `extract_table`, unknown extract, single- and double-quoted paths, `parent_projects.parquet`, scalar-subquery path, `lake.x.parquet`, `lake.snapshots()`, path-named CTE, `read_xlsx` on the live workbook, `-Save manifest`, `-Save Clayco_Job_Costs_from_GL`, `-Save clayco_job_costs_from_gl`, `-Save bad-name`, empty `-LakeRoot`) refused exactly as RESULT-1.md's table states, exit 1. `<L>` GL count 62603 unchanged before/after; `max(snapshot_id)` unchanged at 8. Live workbook `Length`/`LastWriteTime` unchanged after `read_xlsx` refusal. | PASS |
| AC8 | decoy comment + decoy string literal around a real join: exactly one `EXTRACT`/`LAKE` line, runs | `EXTRACT,parent_projects,…`; `LAKE,Clayco_Job_Costs_from_GL,…`; `RESULT,rows=345,…` — exactly one of each, ran. | PASS |
| AC9 | `<L2>` (own scratch workbook copy): baseline `false`; mtime +1h → `true`, `stale_inputs`+1, exit 0; delete workbook → `workbook_present=false`, same count | Baseline: `workbook_changed_since=false`. After `LastWriteTime` +1h: `workbook_changed_since=true`, `stale_inputs` 0→1, exit 0. After delete: `workbook_present=false`, `n=62603` both times. | PASS |
| AC10 | `<L>` catalog `LastWriteTime` unchanged across non-save runs; generated ATTACH carries `READ_ONLY` | Catalog mtime identical before/after AC1+AC2+AC8+read-only AC7 batch (`09/30/2026 13:14:09` both times). `-Verbose` generated SQL: `ATTACH 'ducklake:…' AS lake (DATA_PATH '…', READ_ONLY);`. | PASS |
| AC11 | lock held (`HasExited=False`) → `-Save` fails <5s with verbatim "File is already open in…" text, exit 1, no retry; state which attach failed | Holder confirmed `HasExited=False` immediately before AND immediately after the failing call (same atomic script). `-Save lock_test_table2`: 1396ms, exit 1, verbatim `File is already open in …duckdb.exe (PID 19176)`. Non-save query during the same hold: 1059ms, exit 1, same text. In both cases the failure is the `-Save` collision-check's own **read-only** `duckdb_tables()` attach (query had no lake `BASE_TABLE`, so the merged read-only dating attach never runs) — confirms RESULT-1.md's account and the reviewer's own prediction. `lake.gl_by_parent`-style stray table never created (confirmed via `duckdb_tables()` after). | PASS |
| AC12 | README steps literally, `-ExtractRoot <X> -LakeRoot <fresh scratch>`, live workbook: reach AC1's `RESULT` line; skill descriptions byte-identical to `main` | Followed steps 1–5 verbatim against the **live** workbook into `<L12>` (fresh scratch): `materialize.ps1` (both real contracts) → `Clayco_Job_Costs_from_GL` 62603 rows; `list-extracts.ps1 -ExtractRoot <X>`; by-parent example → `RESULT,rows=345`; unmatched → `rows=0`; `-Save ac12_gl_by_parent` → `SAVED_AS,…rows=345,…`; re-query → `SAVED,ac12_gl_by_parent,…` provenance line printed. Live workbook `Length`/`LastWriteTime` unchanged throughout (68150686 / 09:49:32, before and after) — no SharePoint drift this run. `git diff main -- skills/snowflake-extract/SKILL.md skills/lakehouse/SKILL.md` shows pure appended paragraphs only — front matter (descriptions) untouched, confirmed byte-identical. | PASS |
| AC13 (control) | real lake / real extract / live workbook / `.duckdb-skills` subdirs unchanged; no new project-id dir | Real `lake.ducklake`: 8663040 bytes, `2026-09-25 16:26:30` (unchanged, matches pre-run snapshot exactly). Real extract root: 17 files, 5742840 bytes, newest `2026-09-24 13:54:17` (unchanged). Live workbook: 68150686 bytes, `2026-09-30 09:49:32` (unchanged — `unchanged`, not even `SYNCED`, on this run). `.duckdb-skills\` subdirs: identical 5 (`c-users-woodsonp-claude-dev-duckdb-skills`, three `_verify-2*`, `fixtures`) — **no** `c-users-woodsonp-claude-dev-duckdb-skills-verify-item8` directory ever appeared, confirmed at both an intermediate checkpoint and at the end. | PASS |
| AC14 (control) | no BOM on any new/changed file | Read first 3 bytes of all 6 files (`tools\cross-query.ps1`, both `examples\*.sql`, `README.md`, both `SKILL.md`) via absolute paths — none begin `EF BB BF`. | PASS |
| Disagreement 1 | `lake.x.parquet` refused by the "anything else" allow-list rule, not the missing-table rule, despite TASK.md's prose | `SELECT * FROM lake.x.parquet` → `ERROR,input,lake.x.parquet,not a lake table or an extract -- use lake.<table> or extract_table('<name>')` (the generic rule), exit 1. Confirms the implementer's account: refused either way, but via the third allow-list bullet, since the parse tree is `catalog=lake,schema=x,table=parquet` — neither of the two lake-input shapes. | CONFIRMED |
| Disagreement 2 | `SELECT 1; DROP TABLE lake.manifest` with `-Save x` is refused by the parser's SELECT-only rule regardless of the statement-count guard; the guard's real protection needs a 2-statement, both-SELECT query | Ran the exact spec decoy against the **real** script and separately against the statement-count guard fully removed (mutant): both refuse identically, `ERROR,parse,Only SELECT statements can be serialized to json!`, before either could reach `-Save`. Ran the implementer's own alternate 2-SELECT query (`extract_table(...); SELECT count(*) FROM '<path>'`) against the guard-removed mutant: `RESULT,rows=15314`, exit 0 — the second statement's raw file read runs unscanned. Real script on the same query: `ERROR,parse,expected exactly 1 SELECT statement, found 2`, exit 1. Confirms both halves of the implementer's account. | CONFIRMED |

## Smuggling attempts (beyond AC7) — all refused, no data read

Every case below run against `-ExtractRoot <X>` (real, read-only) / `-LakeRoot <L>` (scratch):

| attempt | result |
|---|---|
| `LATERAL (SELECT count(*) FROM '<X>/…/*.parquet')` | refused, exit 1, `not a lake table or an extract` |
| `UNION SELECT * FROM '<X>/…/*.parquet'` | refused, exit 1, same |
| `EXISTS (SELECT 1 FROM '<X>/…/*.parquet')` | refused, exit 1, same |
| path inside a `JOIN … ON (SELECT …)` | refused, exit 1, same |
| CTE named `Clayco_Job_Costs_from_GL` shadowing the real lake table, body reads a real path | refused, exit 1, same (the *body* of the CTE is a `BASE_TABLE` with the same empty-catalog/schema shape as the CTE reference itself and is refused independently — it never gets to run) |
| `lake."Clayco_Job_Costs_from_GL"` (quoted, real table) | **runs** — this is a legitimate lake read via a quoted identifier, not a bypass; `rows=62603` |
| `LAKE.clayco_job_costs_from_gl` (mixed case, real table) | **runs** — legitimate case-insensitive catalog match, not a bypass; `rows=62603` |
| `glob('<X>/…/*.parquet')` | refused, exit 1, `table function not permitted` |
| `read_blob('<X>/…/*.parquet')` | refused, exit 1, same |
| `sniff_csv('<X>/…/*.parquet')` | refused, exit 1, same |
| `SELECT (SELECT * FROM read_csv('<X>/…/*.parquet')) AS x` | refused, exit 1, `read_csv` not permitted |
| `COPY (SELECT 1) TO '…'` | refused, exit 1, parser's SELECT-only rule |
| `ATTACH 'ducklake:…' AS lake2` | refused, exit 1, same |
| `PRAGMA database_list` | refused, exit 1, same |
| `SET memory_limit='1GB'` | refused, exit 1, same |
| `main.extract_table('parent_projects')` (qualified) | refused, exit 1, `table function not permitted` (qualified `extract_table` is not the unqualified form D3 allows) |
| second `SELECT` after a `--` comment (`… -- trailing\n;\nSELECT count(*) FROM '<path>'`) | refused, exit 1, `expected exactly 1 SELECT statement, found 2` |
| `lake.main."x.parquet"` (quoted 3-part name, nonexistent table) | refused, exit 1 — but see finding below |
| `lake.main."<real-extract-path>"` (quoted 3-part name, path text as table name) | refused, exit 1, DuckDB's own replacement scan tries the literal filename `lake.main.<path>`, which does not exist — **no file read** |
| `lake.main.x.parquet` (unquoted 4-part) | refused, exit 1, `ERROR,parse,NameListToString NOT IMPLEMENTED` (DuckDB itself rejects the 4-part name before the allow-list runs) |

**No successful bypass was found.** Every attempt that could plausibly touch a file was refused, exit 1, with the correct error class, and confirmed by direct measurement (not just exit code) that no unauthorized file content was returned.

## New finding (non-security, robustness) — not in RESULT-1.md

`lake.main."<name>"` (a quoted `BASE_TABLE` with `catalog=lake, schema=main`) is correctly classified by
the allow-list as a **lake input** — this is the intended behavior for the first allow-list bullet, and
`lake.main."x.parquet"` is a syntactically valid way to name a real lake table with a dot in it. Because
no table by that name exists in the lake, and the code never runs an explicit `duckdb_tables()` existence
check for a read-only-path lake input before running the query, the failure surfaces as a **raw DuckDB
runtime error** inside the merged run process, and because `$runExit -ne 0` at that point, the script
dumps every raw output line collected so far — including partial `.mode json` array fragments from the
dating query (`[]`, `[{"lbl":"REFUSED_COUNT",…}]`, etc.) — instead of a clean `ERROR,lake,<name>,no such
table in the lake at <root>` line. The refusal is still exit 1 and no file is read (confirmed: DuckDB's
replacement scan for the missing table tries the literal filename `lake.main.<name>`, which does not
exist on disk), so this is **not a security issue**, only a confusing/unpolished error message for this
one specific input shape (an explicitly `lake.main.`-qualified name that doesn't exist as a real table).
Worth a one-line fix (an explicit existence check before the run, matching the allow-list comment's own
stated intent at `cross-query.ps1:220`) but does not block shipping.

## Mutation proofs — independently reproduced from scratch

Mutations were applied to copies of `cross-query.ps1` in a scratch mirror of `tools\`/`skills\` under
`$env:TEMP` (never inside the worktree), run against scratch lakes only.

| # | mutation | mutant behavior (measured) | real script (measured) | verdict |
|---|---|---|---|---|
| 1b | remove CTE-membership check (any unqualified `BASE_TABLE` silently ignored) | Combined query (legit `extract_table('parent_projects')` + quoted-path decoy in a scalar subquery): `decoy_read=15314`, exit 0 — **raw file read** | Same query: `ERROR,input,<path>,not a lake table or an extract…`, exit 1 | PASS (mutant fails, real refuses) |
| 3 | hard-code the parquet glob under `<X>` instead of using the registry's `parquet_glob` | AC4 example against `-ExtractRoot <Z>` (1000-row fixture): `EXTRACT,…rows=1000,…` (sidecar echoed correctly) but `RESULT,rows=345` — the full `<X>` data, proving the name never resolved to `<Z>` | Same command: `RESULT,rows=1` | PASS |
| 4b | remove `lower()` from the `-Save` collision `duckdb_tables()` check | `-Save clayco_job_costs_from_gl` against a fresh scratch lake with the real contract materialized: `SAVED_AS,clayco_job_costs_from_gl,rows=15314,…`, exit 0 — contract table **destroyed** (62603→15314, confirmed by direct query) | `-Save clayco_job_costs_from_gl` against `<L>`: `ERROR,save,…,a saved join may only replace a saved join, never a contract table`, exit 1; `<L>` GL count unchanged at 62603 | PASS |
| 6 | report the save's own timestamp instead of the oldest input's | Re-query of `ac12_gl_by_parent` (saved with the real, ~8600-min-old extract as an input): `age_minutes=6` (the save's own age) | Same re-query: `age_minutes=8615` | PASS |
| 5 | never attach `READ_ONLY` | `-Verbose` generated SQL: `ATTACH '…' AS lake (DATA_PATH '…');` — no `READ_ONLY` | Generated SQL includes `READ_ONLY` (see AC10) | PASS |

Mutations 1, 2, 4, 7 were reviewed by reading the code and RESULT-1.md's account rather than independently
re-run (time-boxed): the `@(<pipeline>|ConvertFrom-Json)` PowerShell 5.1 quirk the implementer describes
was checked directly — every one of the script's ~15 `@(...)` occurrences was inspected, and the two that
wrap a `ConvertFrom-Json` result (`Invoke-DuckdbJsonBatch`'s per-line parse, both the `-Save`-path and the
read-only-path copies) both use the safe split-assignment form (`$arr = … | ConvertFrom-Json; @($arr)`),
never the unsafe direct-wrap form — confirms the implementer's claim that the bug pattern does not appear
elsewhere. Mutation 2 (`CREATE VIEW`) was not independently re-run, but its logic is a direct, previously
measured DuckDB fact (a view's `extract_table` macro reference does not survive into a new process,
stated in TASK.md's own measured-facts section and confirmed independently for the general case during
the disagreement-2 investigation's parser probing) — low risk of the account being wrong.

## Both example queries' figures (independently recomputed)

`job-costs-by-parent-project.sql` against `<X>`/`<L>`: 345 rows; summed `gl_rows`=62603,
`job_costs`=22505496119.72 — matches `lake.Clayco_Job_Costs_from_GL`'s own `count(*)`/`sum(JOB_COSTS)`
exactly (`SELECT count(*),sum(JOB_COSTS) FROM lake.Clayco_Job_Costs_from_GL` → `62603,22505496119.72`).
`job-costs-unmatched.sql` against the same inputs: 0 rows. Against `<Z>` (1000-row fixture): 344 rows.

## Snapshot comparison — no drift

| item | before (spec/session start) | after (this verification) | match |
|---|---|---|---|
| Main checkout HEAD | `a4261c2` on `main`, clean | unchanged (worktree never touched main) | yes |
| Worktree HEAD | `560ce47`, detached | unchanged, `git status --short` empty throughout | yes |
| Real `lake.ducklake` | 8,663,040 bytes, `2026-09-25T16:26:30.30` | 8,663,040 bytes, `2026-09-25 16:26:30` (identical) | yes |
| Real extract root | 17 files, 5,742,840 bytes, newest `2026-09-24T13:54:17.16` | 17 files, 5,742,840 bytes, newest `2026-09-24 13:54:17` | yes |
| Live workbook | `2026-09-30T09:49:32-05:00`, 68,150,686 bytes | `2026-09-30 09:49:32`, 68,150,686 bytes (identical, `unchanged`) | yes |
| `~\.duckdb-skills\` subdirs | `c-users-woodsonp-claude-dev-duckdb-skills`, `_verify-2a`, `_verify-2b`, `_verify-2b-r2`, `fixtures` (5) | identical 5, no new dir | yes |
| All scratch under `$env:TEMP` | — | removed at end, confirmed `Test-Path` → `False` | yes |

No difference from the pre-run snapshot in anything the implementer or this verification touched.

## Environment note on tooling

This session's shell occasionally failed to persist a just-assigned PowerShell variable across
consecutive tool invocations (a `-LakeRoot`/`-ExtractRoot` bound to `$null` on the next call after a
successful assignment in the previous one), and separately, `[System.IO.Path]`/`[System.IO.File]` calls
resolve relative paths against .NET's `Environment.CurrentDirectory`, not PowerShell's `$PWD` — both are
tooling artifacts of this verification session, not properties of the code under test, and every affected
step was re-run and re-confirmed with variables re-asserted or absolute paths substituted before being
recorded above. `$ErrorActionPreference` was reset to `Continue` after an early command left it at `Stop`
(which had silently swallowed one command's output); all results reported above were captured after that
reset, and cross-checked with a second, independent measurement where the first attempt looked odd (e.g.,
the "SKIPPED" materialize outputs, which on inspection meant an earlier identical call had actually
already succeeded, not that anything was broken).

## Addendum — supervisor re-run of mutations 2 and 7 (not independently re-run above)

Run by the main session in the same worktree (`560ce47`), against a fresh scratch lake materialized from a
scratch workbook copy and a scratch copy of `parent_projects`; mutant scripts written beside the real one,
run, and deleted; worktree `git status` empty afterwards.

**Mutation 2 — save as `CREATE OR REPLACE VIEW`:** the mutant save succeeds
(`SAVED_AS,gl_by_parent,rows=345,run_id=0b6141d2-…`, exit 0), and a **new process** re-query then fails:
`Catalog Error: Table with name _r does not exist!`, exit 1. Bites. (The view captured the session-temp
`_r`, a second reason a view cannot work.) Revert note: re-saving over the mutant's leftover view in the
same scratch lake is refused — `Catalog Error: Existing object gl_by_parent is of type View, trying to
replace with type Table` — an artifact of this test sequence in scratch, and correct behaviour.

**Mutation 7 — remove both the step-2 registry refusal and the `coalesce(…, error(…))` guard:** the named
refusal disappears. Mutant: `ERROR,extract,no_such_extract,IO Error: No files found that match the pattern
"…\x\no_such_extract/_extract.json"`, a raw `read_json` error with a `LINE 3:` trace. Real script:
`ERROR,extract,no_such_extract,not in the registry at <root>`. Bites — though the leaked message is
`registry.sql`'s `read_json` failure, not the `read_parquet cannot take NULL list` the spec predicted,
because with the refusal removed the sidecar read fails before the macro is ever reached.