# REVIEW-task-1 — task-reviewer on the first item-1 draft (commit dbfb3c1)

**Verdict: NOT READY.** The design is sound, and the cited facts were accurate apart from one
line number. But AC2–AC5 and the Final check would have failed for reasons unrelated to item 1.
All findings below were folded into TASK.md.

## Round-2 risks — fixed

1. **Both shipped contracts fail their checks against today's workbook.** It was modified
   2026-10-06 11:39.
   - `Clayco_Job_Costs_from_GL` gets `glperiod_ratio_floor FAIL`, plus cell I3,
     `'City of DeKalb'`, not DOUBLE.
   - `All_Sales_Data` gets `matchproject_ratio_floor FAIL` plus snapshot drift.
   - The main session confirmed this. Checks now accept `REFRESHED` or `REFUSED`, and AC4
     discriminates on `contracts=1`.
   - Also, the first-run word is `REFRESHED`, not `MATERIALIZED`.
2. **`cross-query -Sql` takes a file path.** A query with no inputs is refused before the lake
   is checked. Inputs are now pinned as `$Q\lakex.sql`, and the no-lake refusal exits 1.
3. **The stderr capture method was unspecified, and the obvious methods give wrong answers in
   PowerShell 5.1.**
   - **Capture:** pinned to `Start-Process` with separate stdout and stderr files.
   - **Write:** pinned to `[Console]::Error.WriteLine`.
4. **`prove-no-snowflake.ps1:326` would throw once `materialize` writes to stderr.** Fixed by
   decision 8 and AC8.
5. **A silent mode for `run-assertions` is unnecessary.** `materialize`'s parser ignores
   unknown lines. Removed.
6. **`materialize` resolves (and could create) the lake before refusing for a missing
   `-Contract`.** Decision 3 now says refusals come first, and AC2 checks the lake folder is
   absent.
7. **AC3's base-commit comparison could not match.** Replaced with measured literals.
8. **When the project line prints was ambiguous.** Decision 6 now has a table. The missing
   catch blocks are named.
9. **AC1's inputs were unpinned.** They are now fixed.
10. **AC6 cannot fail at base.** It is labelled control, and its staging is pinned outside the
    root along with a valid sidecar.
11. **Cleanup inside the home folder had no guard.** Guarded cleanup was added.
12. **The base commit and masks for AC5 were undefined.** Both are pinned now.
13. **Negative scope was missing.** Added: the `query` and `attach-db` fallbacks, and the
    README.

## Drift from the plan — now stated in TASK.md

- **All project lines go to stderr.** This departs from PLAN-5, with the reason given.
- **`-Create` applies to explicit roots too.** Both resulting behaviour changes are stated as
  intended.
