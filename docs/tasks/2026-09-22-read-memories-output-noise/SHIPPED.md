# SHIPPED — one result block per run, instead of four

Date: 2026-09-22 · Branch: `coco-read-memories-noise` · Implementation commit: `5635576`
Verified at `5635576` in a disposable worktree. Verdict: **SHIP**, all 15 checks PASS.

Follow-up to `docs/tasks/2026-09-22-coco-read-memories/`, which shipped the skill itself.

## The point of it

**Before:** every run printed four CSV result blocks — one per mode plus a guard — because
all four statements lived in one `.sql` file, self-suppressed with
`WHERE getenv('DSK_MODE') = '<mode>'`. Two of those blocks stated **false facts**:

```
guard                    ← noise
distinct_files
0                        ← FALSE: reads as "no logs found", during a search that found hits
total,with_rows_returned
0,NULL                   ← FALSE
session_id,tool_name,result_text
session_id,ts,role,title,snippet
<the actual answer>
```

Cause: `count(*)` over an empty input returns **one row containing zero**, not zero rows.
The `WHERE` gate suppressed each aggregate's input but could not suppress its output.

**After:** one file per mode, one statement per file, one printed block per run. Nothing to
fabricate, because there is no suppressed aggregate left.

## What shipped

Four files under `skills/read-memories/`, each with exactly one semicolon:

| File | Purpose |
|---|---|
| `search.sql` | keyword search |
| `sqlresults.sql` | render recovered SQL result sets |
| `sqlresults-summary.sql` | how much SQL history is recoverable |
| `coverage.sql` | file-count check |

`DSK_MODE` is gone — the mode is the filename. `DSK_KEYWORD` and `DSK_CWD` unchanged.
`search.sql` and `sqlresults.sql` now `error()` with exit 1 on an empty keyword instead of
silently matching everything via `ILIKE '%%'`.

Deployed to `~/.snowflake/cortex/plugins/duckdb-skills/skills/read-memories/` — exactly
five files, hashes verified matching, and a search run from the live path confirmed.

## The one thing that nearly shipped broken

The spec quoted a guard shape the **reviewer had verified working**:

```sql
WITH g AS (SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'),'') = ''
                       THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok)
```

Cross-joined but never read, DuckDB's optimizer **eliminates it as dead code and the
`error()` never fires**. It works in isolation, which is how it passed review. The
implementer caught it only because check B7 failed with exit 0.

Fixed by threading the guard's `ok` column through the CTE chain into the final `WHERE`,
which forces evaluation. The verifier then tested the obvious risk of that fix — a guard in
a `WHERE` clause is a filter, and filters drop rows — by comparing guard-threaded against
guard-removed variants using `COUNT(*)` with no `LIMIT`, across four keywords: identical
counts every time (3/3, 17/17, 16/16, 1037/1037).

**Lesson worth keeping: a SQL snippet verified in isolation is not verified in place.**

## What deliberately did NOT change

- **What any mode returns.** Same columns, rows, ordering, limits. B11 proved it
  mechanically: every row the old version returned is still returned.
- **Every item on the preserve-verbatim list**, each a hard-won finding of the previous
  task — both glob depths, explicit `columns = {}` on all 5 reads, `LIKE '%sql_execute'`
  (not narrowed to the legacy name, which recovers 4.8% of history), the four-term `ts`
  coalesce covering both sidecar shapes, both `replace()` calls in the `--here` comparison,
  `$.type = 'text'` plus the `<system-reminder>` exclusion in search.
- **The `tool_result.sqldata` mystery.** 47 raw-text occurrences, 0 extractable rows. Still
  undiagnosed, still out of scope.
- **The other 8 skills, `README.md`, `.claude-plugin/`, `.cortex-plugin/`.** Untouched, so
  the fork keeps merging cleanly from `upstream/main`.
- **`state.sql`.** `read-memories` stays outside that convention.

## Known pre-existing issue, deliberately left alone

`sqlresults.sql` uses `ORDER BY session_id LIMIT 20`, which is **nondeterministic when rows
tie on `session_id`** — the verifier ran the unmodified file twice and got 306 then 228
output lines. It confirmed this exact pattern already existed at `2e23118`, so it is not a
regression from this split, and fixing it was outside a restructure-only scope. **If
`sqlresults` output ever looks inconsistent between runs, this is why.**

## Process notes

- Two blockers were caught in spec review, both the same shape: requirements that could not
  all be satisfied at once ("exactly one statement" vs "use `error()`"; a delegated
  file-split decision that three checks then contradicted).
- Four acceptance checks were found to already pass on the untouched repo and were
  relabelled CONTROL, with a non-requirement forbidding anyone from building something to
  satisfy them.
- The `git status`-emptiness check defect from the previous task recurred here — it had been
  corrected in one command and left in its sibling. Now an artifact-set assertion.
