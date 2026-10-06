# VERIFY-1 — independent verification of item 1 (commit 92c3240)

- **Verifier:** the `verifier` agent, in a throwaway worktree at
  `%TEMP%\claude\C--Users-woodsonp-Claude-Dev-duckdb-skills\1b0d93fe-…\scratchpad\verify-item1`,
  detached at `92c3240`.
- **AC5 base:** a second worktree at `a3d7e7f`, removed afterwards.
- **Who wrote this file:** the verifier has no write tool, so the main session saved its report
  here verbatim in substance.
- **Tree gate:** `git -C $W status --short` was empty after the run, so the verifier changed
  nothing in the code under test.

**Method:**
- **How tools were run:** every tool ran as a child process via `Start-Process`, with separate
  stdout and stderr files.
- **Scratch folders:** fresh non-repo `$S`/`$Q` and `git init`'d `$G` folders under `%TEMP%`.
- **`snap`:** taken as `Get-ChildItem -Recurse -Directory ~\.duckdb-skills`.
- **Cleanup:** guarded, so ids must start `c-users-woodsonp-appdata-local-temp-`. The real
  project folders and the `_verify-*` folders were never touched.

**RESULT-1.md:** all of its claims reproduced. No discrepancy.

| Check | Actual (quoted) | Verdict |
|---|---|---|
| AC1 — 9 tools from non-repo `$S` | All 9 exit 2, stderr empty, e.g. `ERROR: not inside a git repository: C:\Users\woodsonp\AppData\Local\Temp\vf_S_3661181. Run from your project folder, or pass -LakeRoot.` (options listed per tool). `snap equal: True`, `S empty: True` | PASS |
| AC2a `lake-status -LakeRoot $S\nolake` | exit 0, `no lake`, stderr `project: none (explicit roots)`, `nolake exists: False` | PASS |
| AC2b `materialize -LakeRoot $Q\lake` (no `-Contract`) | exit 2, `… or pass -LakeRoot and -Contract.`, `Q\lake exists: False` | PASS |
| AC2c `materialize -LakeRoot $Q\lake -Contract …Clayco_Job_Costs_from_GL.sql` | exit 1, `MATERIALIZE,Clayco_Job_Costs_from_GL,REFUSED,reason=checks_failed`, `SUMMARY,contracts=1,…refused=1`, stderr `project: none (explicit roots)`, `ducklake exists: True` | PASS |
| AC3 — five read-only tools in a new repo | Literals matched exactly; exits 0,0,0,0,1. Each stderr `project: c-users-…vf_g_1331556899 (…)`. `snap equal: True`, `G id folder exists: False` | PASS |
| AC4 — `$G` with only Clayco contract, `materialize` no options | stderr `contracts: …\vf_G_58002816\contracts`; stdout `SUMMARY,contracts=1,refreshed=0,skipped=0,refused=1,forced=0,errored=0`; ducklake exists; `lake-status` lists `Clayco_Job_Costs_from_GL … outcome=REFUSED` | PASS |
| AC5 — real roots, read-only, base vs new | All three: exit 0/0, `stdoutIdentical=True`; base stderr empty; new stderr exactly one `project:` line; `snap equal: True` | PASS |
| AC6 (control) — `publish-extract` in new repo | `pre-exists: False`; exit 0 `published C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-appdata-local-temp-vf_g6_905077277\extracts\ac6_demo`; `list-extracts` shows `name=ac6_demo … row_count=1 … bytes_check=AGREES` | PASS |
| AC7 — `ensure-duckdb-compat` in new repo | line 1 `…\vf_G7_841567152\.duckdb-skills\state.sql`; one `.read` line; stderr `project: …` | PASS |
| AC8 — `prove-no-snowflake.ps1 -Only lake-status` | exit 0, `SUMMARY,entrypoints=1,pass=1,fail=0,no_evidence=0,hung=0,forbidden=snowflake` (throw at base not demonstrated) | PASS |
| M1 — contracts folder back to script's parent | mutated: `SUMMARY,contracts=2`; reverted: `contracts=1` | PASS (fails, then passes) |
| M2 — `Resolve-ExtractRoot` ignores `-Create` | mutated: `snap equal: False`, G folder created; reverted: `snap equal: True` | PASS (fails, then passes) |

**Deviations the implementer noted:**
1. **`publish-extract` with a missing `-StagingDir` leaves an empty extract root** inside a
   repo. Not separately tested. It is harmless: it happens only on a user error, inside the
   project's own folder. Not a ship blocker.
2. **`cross-query.ps1:689` repeats a `Resolve-LakeRoot` call** after the one at line 558.
   - **What it is:** dead code, confirmed by grep. The project note printed exactly once in
     AC3.
   - **Effect:** none on behaviour. Not a ship blocker.

**Overall verdict: SHIP.**
