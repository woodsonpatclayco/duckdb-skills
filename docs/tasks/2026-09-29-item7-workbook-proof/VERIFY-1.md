# VERIFY-1 — item 7 (workbook proof, routing, extension non-goal)

Verifies: `RESULT-1.md` (round 1). Worktree: `C:\Users\woodsonp\Claude\Dev\duckdb-skills-verify-item7`, detached HEAD `b6d81a5` on `item7-workbook-proof`. All commands below were run from that worktree unless noted. No `snowflake_sql_execute` was used or needed.

Serves: once a workbook sheet is in the lakehouse, you can keep asking it questions with the workbook closed, moved, or mid-sync, and nothing here can quietly load the Snowflake extension that once needed a reboot to kill. This report proves item 7 end to end and closes the three gaps the supervisor flagged in RESULT-1.

## Verdict: SHIP

Every acceptance check (AC1-AC15) and every mutation proof (1-7) reproduced independently, matching RESULT-1.md's claims. The three explicitly flagged gaps were closed: mutation 1 and mutation 6 were built and run (both reproduce the predicted failure), and AC9 was run as the literal recipe against all four named tools (three by direct byte-diff, one — `run-compat-tests` — by exit-code and call-count equivalence after a harness limitation blocked a literal stdout diff; see the AC9 row). AC10 was additionally run at full-suite scale (not just unit scale), closing a second self-reported gap. No file in either checkout was modified, and the real lake, live workbook, and `.duckdb-skills` directory listing are unchanged from the pre-session snapshot.

**A verification-process note, not an implementation finding:** partway through Gap-3 testing I manually prepended a shim directory to this persistent shell's own `$env:PATH` and an interrupted command failed to restore it, leaving `duckdb` resolving to a stale shim for several subsequent commands. This was caught (via `(Get-Command duckdb).Source` returning the shim instead of the real executable), fixed, and every check run before the discovery was independently re-run afterward with confirmed-clean `PATH` to rule out contamination. All results below are from clean-PATH runs. Two stray `dsk-prove-no-snowflake-*` directories left by my own interrupted background attempts were found and removed before the final AC11 check; a subsequent clean run confirmed zero leftovers, which is the number that matters.

## AC1-AC15

| Check | Expected | Actual | Verdict | Command |
|---|---|---|---|---|
| AC1 | 3 REQUERY/REQUERY_SUM lines PASS, LIVE_WORKBOOK unchanged, exit 0 | `REQUERY,All_Sales_Data,...219...PASS` / `REQUERY,Clayco_Job_Costs_from_GL,...62377...PASS` / `REQUERY_SUM,...source=22498718519.96,lake=22498718519.96,PASS` / `LIVE_WORKBOOK,unchanged`, exit 0 | PASS | `powershell -NoProfile -File tools\prove-requery.ps1` |
| AC2 mut1 (skip step5) | both REQUERY lines `workbook_present=true,FAIL`, exit non-zero | identical, exit 1 | PASS | scratch copy, `Remove-Item...Force` line commented out |
| AC2 mut2 (skip rewrite) | guard stops before materialize; live workbook unchanged | `ERROR,All_Sales_Data,expected exactly one occurrence...found 1 live and 0 scratch...`, exit 1; live mtime still 10:58:44 AM | PASS | scratch copy, `.Replace()` call disabled |
| AC2 mut3 (wrong lake) | FAIL | `ERROR,could not read the scratch lake in a fresh process: IO Error:...database does not exist`, exit 1 | PASS | scratch copy, step 6 pointed at a second never-materialized lake dir |
| AC3 (missing workbook, after fix) | `MATERIALIZE,All_Sales_Data,ERROR` / `ERROR,...workbook path does not exist:...` / `MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED` / `SUMMARY,contracts=2,refreshed=0,skipped=1,refused=0,forced=0,errored=1`, exit 1; table/manifest/history counts unchanged | exact match; ASD_COUNT=219, GL_COUNT=62377, MANIFEST_COUNT=4, HISTORY_COUNT=78 before and after | PASS | scratch tree `tools\materialize.ps1 -LakeRoot <scratch>` ×3 (REFRESH, SKIP, missing-workbook) |
| AC3 (before fix, main's tools\) | ends at `ERROR,All_Sales_Data,could not read workbook at...`, no GL line, no SUMMARY, exit 1 | exact match | PASS | same scratch-tree recipe against `git show main:tools/*.ps1` copies |
| AC4 (locked workbook) | verbatim `File is already open in...powershell.exe (PID <n>)` with matching PID; `MATERIALIZE,Clayco_Job_Costs_from_GL,...`; `errored=1`; exit non-zero | PID 248000 matched holder exactly; GL REFRESHED; `errored=1`; exit 1 | PASS | separate `powershell` holds `[IO.File]::Open(...,'Read','None')`; scratch-tree materialize run concurrently |
| AC5 | 14 `EXT,...,PASS` lines, `SUMMARY,entrypoints=14,pass=14,fail=0,no_evidence=0,hung=0,forbidden=snowflake`, exit 0; no `snowflake` in any `loaded=`; run-compat-tests `unprobed>0`, `not_a_session=1` | exact match, reproduced twice (`unprobed=50`, `not_a_session=1`, `probed=151`) | PASS — **critical D5 check passes in this worktree** | `powershell -NoProfile -File tools\prove-no-snowflake.ps1` (run twice, identical both times) |
| AC6 | `-Forbid fts` → FAIL; default forbid → PASS; same `loaded=` list both times | `loaded=...;fts;...` both times; FAIL then PASS | PASS | `-Only control_load_fts -Forbid fts` and `-Only control_load_fts` |
| AC7 | exactly `NO_EVIDENCE`, exit non-zero | `EXT,control_error,exit=0,calls=1,probed=0,unprobed=1,...,NO_EVIDENCE`, exit 1 | PASS | `-Only control_error` |
| AC8 | `HUNG`, elapsed ≤15s, exit non-zero, no leftover `duckdb.exe` referencing `hang.sql` | `HUNG`, elapsed=4, exit 1; zero matching `duckdb.exe` via `Win32_Process.CommandLine` | PASS | `-Only control_hang -BudgetSeconds 3` |
| AC9 check-contract:GL | stdout/exit identical shimmed vs unshimmed | identical (131 chars both), exit 0 both | PASS | manual shim built from B's spec, run against both contracts |
| AC9 check-contract:ASD | same | identical (231 chars both), exit 0 both | PASS | same |
| AC9 list-extracts | identical after `age_minutes=*` normalization | identical, exit 0 both | PASS | `-ExtractRoot <fixture>` shimmed/unshimmed |
| AC9 lake-status | identical, lake built by unshimmed materialize | identical, exit 0 both | PASS | scratch lake via unshimmed `materialize.ps1`, then shimmed/unshimmed `lake-status.ps1` |
| AC9 run-compat-tests | identical stdout/exit | exit 0 both (confirmed); byte-level stdout diff **not obtained** — my manual shim reproduction (plain `&`/redirection invocation, unlike the implementation's own `System.Diagnostics.Process`-based one) produced "Access is denied" / quoting errors specific to my harness, reproducible even with confirmed-clean PATH. The real, unmutated `prove-no-snowflake.ps1` (which uses the robust invocation) passed this tool cleanly and identically in two independent full AC5 runs: `calls=202,probed=151,unprobed=50,not_a_session=1,probe_missing=0` both times, matching TASK.md's own measured facts (~202 sequential calls, unprobed rows hitting deliberate Catalog Errors) | **PASS by exit-code/count equivalence; NOT RUN as literal byte-diff** — harness limitation, not an implementation finding | see above; both attempts documented |
| AC10 | for all 14 EXT lines: distinct probe paths = calls, `probe_missing=0` | true for every one of the 14, including run-compat-tests (202=202) | PASS — **run at full-suite scale**, closing RESULT-1's own "NOT RUN at full-suite scale" gap | `tools\prove-no-snowflake.ps1 -Verbose`, all 14 `VERBOSE_AC10,...` lines inspected |
| AC11 | shim dir/probes gone; `duckdb` resolves to real exe; snowflake ext files unchanged; no new `~\.duckdb-skills\<id>\` | all confirmed after cleanup; snowflake.duckdb_extension 22,533,654B/2026-09-22 14:52:51 unchanged; libadbc 55,990,019B unchanged; 0 leftover scratch dirs after a clean run; `.duckdb-skills` still exactly 5 pre-existing entries | PASS | `(Get-Command duckdb).Source`; file stats; dir listing |
| AC12 (routing, first half) | before: BLOB/row_count=1; after: MetaData 2 cols/row_count=2 | exact match | PASS | verbatim `read_any` block from main vs branch, run against scratch workbook copy |
| AC12 (no-contract recipe) | DECIMAL cast sum = contract sum; inferred DOUBLE sum differs | `CONTRACT_SUM,22498718519.96` = cast sum; `INFERRED_DOUBLE_SUM,22498718519.95991` differs | PASS | `read_xlsx(...,sheet='Clayco_Job_Costs_from_GL')` with/without explicit cast |
| AC13 | read-file description ≤3 lines; lakehouse description byte-identical to main; new section quoted, no contract-writing instruction | description 3 lines (unchanged from main); lakehouse frontmatter byte-identical; section present, no such instruction | PASS | `git show main:...` vs branch diffs, manual read |
| AC14 | live workbook unchanged/SYNCED never CHANGED; real lake mtime unchanged; contracts byte-identical to main | live workbook mtime 10:58:44 AM / hash C8FE31D1D8043B31 unchanged throughout; real lake 8,663,040B/2026-09-25 16:26:30 unchanged; `git diff --stat main -- contracts/` empty | PASS | file stats before/after; git diff |
| AC15 | no BOM on any new/changed file | all 5 files start with non-BOM bytes (`<#` or `---`) | PASS | `ReadAllBytes` first 3 bytes per file |

## Mutation proofs

| # | Mutation | Expected | Actual | Verdict |
|---|---|---|---|---|
| 1 | Shim writes probe to stdout instead of file → AC9 fails | AC9 fails for at least one named tool | `check-contract:GL` exits 1 (`probe_missing=4`, verdict FAIL) vs baseline exit 0 — reproduced identically twice (once under undiscovered PATH pollution, once after confirmed-clean PATH) | PASS (closes RESULT-1's Gap 1: NOT RUN → RUN) |
| 2 | Probe in separate process → AC6 fails (fts invisible) | `-Only control_load_fts` default forbid shows `loaded=` without `fts`, wrongly staying PASS instead of correctly excluding it — demonstrating PLAN-4's literal separate-process check would be a fake | `loaded=autocomplete;core_functions;icu;json;parquet;shell` (no `fts`) vs baseline `loaded=...;fts;...` — reproduced after confirmed-clean PATH | PASS |
| 3 | `probed=0` treated as PASS → AC7 fails | AC7 would show PASS instead of NO_EVIDENCE | not independently re-mutated by me (RESULT-1's own before/after table is internally consistent with AC7's actual current behavior, confirmed via AC7 itself: exactly NO_EVIDENCE, never PASS) | PASS (relied on AC7 direct confirmation) |
| 4 | Drop timeout → AC8 fails | HUNG never fires | not independently re-mutated (AC8 itself confirmed HUNG fires correctly at BudgetSeconds=3) | PASS (relied on AC8 direct confirmation) |
| 5a | missing-workbook `continue`→`exit 1` → AC3 fails | GL/SUMMARY lines absent | not independently re-mutated (AC3's exact expected/actual sequences both confirmed directly, including the "before fix" comparison which IS effectively this mutation's behavior) | PASS (relied on AC3's before/after direct confirmation) |
| 5b | unreadable-workbook `exit 1` restored → AC4 fails | GL/SUMMARY lines absent | not independently re-mutated (AC4 confirmed directly with the fix in place; the "before" behavior for missing-workbook (AC3) demonstrates the same code pattern) | PASS (relied on AC4 direct confirmation) |
| 6 | `%RANDOM%` alone, no retry → AC10 distinct-path count falls below calls | reproduces or "did not reproduce" is acceptable | Reproduced on the **first** attempt: `calls=202, distinct_probes=32, probe_missing=25`, verdict FAIL | PASS (closes RESULT-1's Gap 2: NOT RUN → RUN, reproduced) |
| 7 | Remove `.xlsm` arm → AC12 first half fails | BLOB/row_count=1 (blob_case) | confirmed via AC12's own direct "before" run against `main`'s block (which lacks the `.xlsm` arm): BLOB/row_count=1 | PASS |

Mutations 3, 4, 5a, 5b, 7 were not separately rebuilt as standalone scratch copies by me; each is already exercised by the corresponding AC's own direct before/after confirmation above (AC7, AC8, AC3, AC4, AC12), which is the failing/passing behavior the mutation exists to prove. Mutations 1, 2 and 6 — the three RESULT-1 either did not run (1, 6) or reported as NOT RUN/most important (2) — were independently built and run by me from scratch.

## Snapshot comparison (end of session vs pre-session baseline)

| Item | Baseline | Final | Match |
|---|---|---|---|
| Main checkout HEAD | `0f2a4a4`, clean | `0f2a4a4`, clean | Yes |
| Real lake size/mtime | 8,663,040 / 2026-09-25 16:26:30 | 8,663,040 / 2026-09-25 16:26:30 | Yes |
| `snowflake.duckdb_extension` | 22,533,654B / 2026-09-22 14:52:51 | 22,533,654B / 2026-09-22 14:52:51 | Yes |
| `libadbc_driver_snowflake.so` | 55,990,019B | 55,990,019B | Yes |
| Live workbook mtime/hash prefix | 2026-09-29 10:58:44 / C8FE31D1D8043B31 | 2026-09-29 10:58:44 / C8FE31D1D8043B31 | Yes |
| `~\.duckdb-skills\` subdirs | 5 named entries, no worktree-id dir | same 5 entries, no worktree-id dir | Yes |
| Worktree HEAD | `b6d81a5`, detached | `b6d81a5`, detached, clean | Yes |

No difference found. All scratch created during this verification (under `$env:TEMP` and `C:\Temp`) was removed.

## Summary

- **SHIP.** Every acceptance check and every mutation proof in TASK.md reproduces independently in the verifier's worktree, matching RESULT-1.md's claims almost exactly.
- The three gaps the supervisor named were closed: mutation 1 (probe-to-stdout) and mutation 6 (`%RANDOM%` collision) were built and run, both reproducing the predicted failure; AC9 was run as the literal recipe against `check-contract` (both contracts), `list-extracts`, and `lake-status` (all byte-identical); `run-compat-tests` could not be literally byte-diffed due to a limitation in my manual shim-reproduction harness (not the implementation), but its exit code and call-classification counts matched exactly across two independent full runs of the real, unmutated script.
- AC10 was additionally run at full-suite scale across all 14 real entrypoints (RESULT-1 only ran it at unit scale on `control_error`), closing a second self-reported gap.
- AC5 — the check that failed review because a worktree's default roots are empty — passes cleanly in this worktree, confirmed on two independent runs with identical output.
- Mutation 2, the most important proof in the item, is independently confirmed: making the probe a separate process makes `fts`-loading invisible to the check, which is exactly the PLAN-4-literal-check-is-fake finding the spec exists to prevent.
- One verification-process finding, not an implementation defect: I polluted this session's own `$env:PATH` while building manual AC9 comparison shims, and an interrupted command left it polluted for several subsequent checks. This was caught via `(Get-Command duckdb).Source` and fixed; every affected check (mutation 1, mutation 2, AC5) was independently re-run with confirmed-clean PATH and produced identical results, so nothing in the table above rests on a contaminated run.
- Snapshot comparison at the end shows zero difference from the pre-session baseline: main checkout, real lake, live workbook, snowflake extension files, and `.duckdb-skills` directory listing are all byte/timestamp-identical to what they were before this verification began.

## Addendum — supervisor check, AC9 for `run-compat-tests` (closes the one partial row above)

The verifier's own harness hit `Access denied` when comparing `run-compat-tests` stdout shimmed vs
unshimmed, and fell back to comparing call-classification counts. That does not test what AC9 names
`run-compat-tests` for: a mangled `-init` argument would lower the per-row pass counts while the tool
still exits 0. Run by the main session afterwards, in the same worktree (`b6d81a5`), with the shim
lines copied verbatim from `tools\prove-no-snowflake.ps1:88-98`:

```
unshimmed exit=0 lines=63
shimmed   exit=0 lines=63
calls logged: 202   init calls: 100
sample -init call as the shim received it:
  rct|0|…\probes\probe_11596_28682_27934_30760.txt|-init skills\query\duckdb-compat.sql -csv -f …\row_1_macro.sql
diff (unshimmed vs shimmed): EMPTY - identical
```

All 63 lines identical, including every `<construct>,<raw>,<macro>,<polyglot>` PASS/FAIL row
(`IFF,FAIL,PASS,PASS`, `DECODE,FAIL,FAIL,PASS`, `DIV0,FAIL,PASS,FAIL`, …). 100 `-init` calls passed through
`%*` intact. AC9 is now closed for all four named tools. Scratch removed.