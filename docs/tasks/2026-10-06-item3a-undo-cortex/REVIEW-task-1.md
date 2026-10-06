# REVIEW-task-1 — task-reviewer on the first item-3a draft (commit 66b797c)

**Verdict: NOT READY.**
- **The build:** its instructions are sound.
- **The checks:** several would have failed or misled for reasons unrelated to the item.
- **How the reviewer checked:** it ran AC1–AC4 with a simulated trim, against scratch clones
  and a scratch lake.

All findings below were folded into TASK.md.

## Round-2 risks — fixed

1. **AC6 failed at the base commit today.** `prove-no-snowflake` gives
   `entrypoints=14,pass=13,fail=1`. The `gl-facts` check hits the same `'City of DeKalb'` cell
   through its deliberately type-inferred `bare` view.
   - **Now:** AC5 compares base against new. It expects 14 entrypoints at base and 12 after,
     with the same verdict on each shared label. The exit code is not the criterion.
2. **The final check was wrong for GL.** Its last real run failed checks, so its first rerun
   prints `reason=previous_checks_failed`, which outranks the compat hash. This is now stated.
   AC3 also marks itself NOT RUN if the baseline's checks fail.
3. **AC2 had no literal command.** A case-insensitive `IFF(` search hits `date_diff(`, and
   `git grep` exits 1 on no match. AC2 now uses an exact case-sensitive `git grep`, with
   "exit 1 = pass" stated.
4. **AC4's completeness sub-check raced the growing logs.** 22,987 rows became 23,041 during
   the review. The sub-check guarded upstream's query, not this work. Deleted.
5. **The drive-letter retry would never fire.** NTFS and DuckDB's glob are case-insensitive
   (measured). Removed.
6. **`xl_date()` would become undiscoverable from the query skill.** A one-paragraph pointer now
   replaces the deleted section.
7. **A second dangling pointer** at `registry.sql:5-6` is now named.
8. **The entrypoint-count comment** at `prove-no-snowflake.ps1:334` is now named.
9. **Line ranges disagreed with their prose.** Fixed:
   - query `SKILL.md` 164–200;
   - README line 78 only;
   - the fork note at lines 5–10 stays, for item 4.
10. **Negative scope:** `.claude-plugin\`, `.cortex-plugin\` and `checks\gl-facts.sql` are now
    named as out of scope. Windows-only is stated.

## Strengthened

- **AC1** now lists every non-internal function after loading the compat file: exactly
  `xl_date` at the new commit, all 17 names at base.
- **AC3** ran end to end in the review: about 35 s, `reason=compat_sha256` for both, and
  `EXCEPT ALL` 0 in both directions.

## Known and left alone

`checks\gl-facts.sql` fails on today's workbook. It is dev scaffolding from item 4 of the old
plan, and outside this item.
