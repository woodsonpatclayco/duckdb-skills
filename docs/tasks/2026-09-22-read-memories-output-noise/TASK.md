# TASK — remove the multi-statement output noise from `read-memories`

Plan: none (single self-contained task; no multi-task plan exists)

Serves: **"do you remember what we decided about X?"** — the same feature shipped on
2026-09-22 (`docs/tasks/2026-09-22-coco-read-memories/`). It works, but every run prints
three irrelevant result blocks around the real answer, two of which state *false facts*.
After this task, a run prints exactly one result block: the answer.

After this task: nothing further is planned for `read-memories`.

---

## Context

`skills/read-memories/search.sql` holds **four SQL statements** in one file — a mode
guard plus one statement per mode (`coverage`, `sqlresults`, `search`) — each
self-suppressing with `WHERE getenv('DSK_MODE') = '<mode>'`.

DuckDB executes every statement in a `-f` file and prints a result block for each. So
every run emits four blocks regardless of mode. Suppressing the *rows* does not suppress
the *block*.

Repo: `C:\Users\woodsonp\Claude\Dev\duckdb-skills`, branch `main` (merged and pushed;
`origin` = `woodsonpatclayco/duckdb-skills`, `upstream` = `duckdb/duckdb-skills`).
Create a branch for this work.

**Scope: `skills/read-memories/` only.** Do not modify the other 8 skills — they must keep
merging cleanly from `upstream/main`. That clean-merge property is the one thing that must
not break. `README.md` may be touched **only** if a requirement below makes a specific line
wrong; say which line in `RESULT-1.md` first.

Environment: Windows, PowerShell 5.1. DuckDB CLI v1.5.5.

---

## The corpus grows while you work — read before quoting any count

Every Cortex Code session, including yours, appends to the logs being searched. Counts in
this spec are **floors, not equalities**. Above a stated number is expected drift — quote
the actual figure and continue. Below it is a real failure.

Current floors: **399** log files, **1,179** recoverable SQL result blocks of which
**1,033** contain `row(s) returned`.

---

## The defect, measured

Actual console output, captured 2026-09-22. The answer is marked; everything else is noise.

### `DSK_MODE=coverage`

```
guard                          ← noise (empty guard statement)
distinct_files
399                            ← THE ANSWER
total,with_rows_returned
0,NULL                         ← noise, AND FALSE
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```

### `DSK_MODE=search`

```
guard                          ← noise
distinct_files
0                              ← noise, AND FALSE — reads as "no logs found"
total,with_rows_returned
0,NULL                         ← noise, AND FALSE
session_id,tool_name,result_text
session_id,ts,role,title,snippet
<rows>                         ← THE ANSWER
```

### `DSK_MODE=sqlresults` (no keyword)

```
guard                          ← noise
distinct_files
0                              ← noise, AND FALSE
total,with_rows_returned
1179,1033                      ← THE ANSWER
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```

**Why the false rows exist:** `coverage` and the `sqlresults` summary are **aggregates**.
`count(*)` over an empty input returns one row containing `0`, not zero rows — so
`WHERE getenv('DSK_MODE') = '...'` suppresses the input but cannot suppress the output.
Non-aggregate statements correctly emit a header and no rows.

**This is not merely untidy.** `distinct_files / 0` printed during a `search` run is a
fabricated corpus-is-empty claim, sitting *above* the real answer, in the same CSV stream.
The original verification called this cosmetic; that assessment was made before anyone
looked at what the suppressed aggregates print.

---
## The fix

**Split `search.sql` into one file per mode.** A file containing exactly one statement
prints exactly one result block; no gating, no suppressed aggregates, nothing to fabricate.

```
skills/read-memories/search.sql             ← keyword search
skills/read-memories/sqlresults.sql         ← render recovered SQL result sets
skills/read-memories/sqlresults-summary.sql ← how much SQL history is recoverable
skills/read-memories/coverage.sql           ← file-count check
```

Four files, not three: `sqlresults` today serves two different behaviours off whether
`DSK_KEYWORD` is empty, and the summary branch is an **aggregate** — the exact construct
proven below to fabricate `0,NULL` when gated. Keeping them in one file would re-enter the
trap this task removes. `DSK_MODE` becomes meaningless and is removed: the mode *is* the
filename.

### Alternatives considered and rejected

- **Keep one file, make the aggregates return zero rows** (a `HAVING`, or a `LIMIT 0`
  gate). Kills the false rows but leaves three stray header lines, and preserves the
  structural trap — the next statement added reintroduces the bug, and the next aggregate
  reintroduces false rows.
- **Suppress headers with `.headers off`.** Removes visual noise but keeps `0` and
  `0,NULL` as bare unlabelled rows: strictly worse, since it is false data with nothing
  identifying which statement produced it.
- **One statement returning a union of all modes.** The modes have different column shapes
  (coverage 1 column, sqlresults 3, search 5); unioning forces a lowest-common-denominator
  shape and makes every mode worse to read.
- **Dispatch with `duckdb -c` per mode, or a `.read` include.** `-c` reintroduces the
  PowerShell `$`-expansion hazard already documented in `SKILL.md` (double-quoted `-c`
  strings silently break `'$.type'`); `.read` reintroduces multi-statement output.

---

## Requirements

1. Split `search.sql` into the **four** files named above under `skills/read-memories/`,
   each containing **exactly one** SQL statement — **one terminating semicolon per file**.
   A `WITH` clause is part of that single statement and is permitted, including one whose
   only purpose is an `error()` guard (requirement 4). A second semicolon-terminated
   statement is not permitted.
2. Preserve the existing SQL logic of each mode **unchanged in behaviour**. This is a
   restructure, not a rewrite. Specifically preserve, because each was a hard-won finding
   of the previous task:
   - `content` read as `JSON`, never as an auto-detected struct;
   - both glob depths (`conversations\*.history.jsonl` and
     `conversations\*\*.history.jsonl`) in every file that reads history;
   - explicit `columns = {...}` on **every** `read_ndjson` / `read_json` call;
   - `tool_result.name LIKE '%sql_execute'` — matches both the legacy `sql_execute` and
     the current `snowflake_sql_execute`. Narrowing this to `= 'sql_execute'` recovers
     4.8% of history while still returning data, so it fails silently;
   - `ts = coalesce(user_sent_time::TIMESTAMP, assistant_sent_time::TIMESTAMP,
     created_at::TIMESTAMP, epoch_ms(creationDate))` — all four terms; the last two cover
     the two different sidecar shapes;
   - the `--here` comparison **verbatim**, both `lower()` and both `replace()` calls:
     ```sql
     lower(replace(s.working_directory, '/', '\')) = lower(replace(getenv('DSK_CWD'), '/', '\'))
     ```
     Dropping the `replace()` calls leaves a check that still passes, because `$PWD.Path`
     on Windows already uses backslashes — so the separator normalisation is never
     exercised by the test that guards it;
   - `search.sql` must filter `$.type = 'text'` and must exclude blocks whose text
     contains `<system-reminder>`. The two `sqlresults` files must filter
     `$.type = 'tool_result'`. (The original defect this skill was built to fix was that
     every returned hit was an injected `<system-reminder>`, so losing that filter in a
     restructure would silently restore the original bug.)
3. Remove `DSK_MODE` entirely — from the SQL, from `SKILL.md`, and from every invocation
   example. `DSK_KEYWORD` and `DSK_CWD` remain unchanged.
4. **Empty-keyword handling, per file:**
   - `search.sql` and `sqlresults.sql` filter on `DSK_KEYWORD`. Both must `error()` with a
     clear message and a **non-zero exit** when it is empty. Today an empty keyword makes
     the filter `ILIKE '%%'`, silently returning 40 (search) or 20 (sqlresults) arbitrary
     rows — that is how the noise documented above was discovered.
   - `coverage.sql` and `sqlresults-summary.sql` must **ignore** `DSK_KEYWORD` entirely.

   The guard goes inside the single statement. This shape is verified working:
   ```sql
   WITH g AS (SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
                          THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok)
   ```
5. Update `SKILL.md`: the four filenames, `DSK_MODE` gone, and the documented modes
   matching the files that exist. Frontmatter stays exactly `name` and `description`.
6. Keep the behavioural contract in `SKILL.md`: search silently, do not narrate, absorb
   results into the answer rather than dumping logs.
7. **Order of operations**, because getting it wrong fails B12 on otherwise-correct work:
   finish all repo edits ←’ commit on your branch ←’ copy to the live plugin ←’ run the
   checks ←’ write `RESULT-1.md`.
8. Deploy to the live plugin at
   `C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\`:
   copy `SKILL.md` and all four `.sql` files, then **delete any other `.sql` file in that
   directory**. It must end up containing exactly `SKILL.md`, `search.sql`,
   `sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql` — nothing else.

   That directory is a clone of `duckdb/duckdb-skills` which this work does not own. Copy
   files; do **not** commit, stage, or clean there. Its `git status` will show modified and
   untracked files afterwards — leave it exactly so. Note in `RESULT-1.md` that the live
   plugin now holds branch-only work that `main` does not yet have.

## Non-requirements

- Do **not** change what any mode returns — same columns, same rows, same ordering, same
  limits. Only the number of printed blocks changes.
- Do **not** add modes, flags, or output formats beyond the four files specified.
- Do **not** diagnose the `tool_result.sqldata` mystery (47 raw-text occurrences, 0
  extractable rows). Noted in the previous task; still out of scope.
- Do **not** touch the other 8 skills, `.claude-plugin/`, or `.cortex-plugin/`.
- Do **not** create or use `state.sql`. `read-memories` stays outside that convention.
- Do **not** merge to `main` or push. The supervising session does that.
- Do **not** create a sentinel file, wrapper script, or anything else to make B8 pass —
  B8 is a control that already passes. See its note.
- Do **not** pin a DuckDB version in the skill.

---

## Acceptance checks

Run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills`. `RESULT-1.md` must quote the
**actual console output** of every check. A check not run is a FAIL, not a blank. State
RAN/PASS/FAIL per check.

Checks marked **CONTROL** already pass on the untouched repo. They exist to catch
regressions, not to evidence work — do not "fix" anything to make them pass.

**B1 — exactly one result block per run (the whole point)**

For each of the **four** files, paste the complete, unabridged console output.

```
Expected per run: ONE header line and its rows, nothing else.
ZERO occurrences of "guard" in any output.
ZERO occurrences of "distinct_files" outside coverage.sql's own output.
ZERO occurrences of "total,with_rows_returned" outside sqlresults-summary.sql's.
Any mode's header appearing in another mode's output ←’ FAIL.
```

Plus the structural assertion for requirement 1:

```
Get-ChildItem skills\read-memories\*.sql | ForEach-Object {
  "$($_.Name): $((Select-String -Path $_.FullName -Pattern ';' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }
Expected: exactly 1 per file. A file with 2 statements where one prints nothing
would pass the block test above and still violate requirement 1.
```

**B2 — the false zeros are gone**

```
search.sql output:             "distinct_files" must not appear; no line may be a bare `0`.
sqlresults.sql output:         same.
sqlresults-summary.sql output: "distinct_files" must not appear.
coverage.sql output:           "0,NULL" must not appear.
These are the fabricated facts this task exists to remove.
```

**B3 — coverage still sees the whole corpus**

Measure the sub-level count fresh rather than trusting a literal — it grows:

```
(Get-ChildItem "$env:USERPROFILE\.snowflake\cortex\conversations\*\*.history.jsonl").Count
```

```
Expected: coverage.sql's distinct_files >= 399 AND strictly greater than that
freshly measured sub-level number (363 at time of writing). Paste both figures.
Equal to the sub-level count means a glob was dropped in the split ←’ FAIL.
A value of 0 ←’ FAIL.
```

**B4 — sqlresults still covers both tool names**

```
sqlresults-summary.sql ←’ total >= 1,179 and with_rows_returned >= 1,033 (floors).
A result of 56/50 means `LIKE '%sql_execute'` became `= 'sql_execute'` ←’ FAIL.

Then sqlresults.sql with a keyword: at least one rendered result set whose text
contains a comma-delimited header line and a line matching "N row(s) returned".
Paste it and the keyword used.
```

**B5 — search still returns readable, attributed prose**

Keyword `read_xlsx`:

```
Expected: >= 1 hit; `role` and `ts` non-empty on every row; snippet is readable
prose, not a JSON struct dump.
Margin: only ~2 clean `text` blocks in the corpus contained this token before this
task. Search mode must NOT filter by `role`, dedupe by session, or require a
non-NULL raw timestamp. If this returns 0, the cause is over-filtering.
Note: `read_xlsx` appears in this spec, so your own session log will add hits.
That is expected drift, not a defect.
```

**B6 — `--here` still scopes, and the separator normalisation survived**

From this repo directory, with `DSK_CWD = $PWD.Path`:

```
Expected: >= 1 session, all with working_directory equal to this path
case-insensitively (it is stored with a lowercase drive letter as
`c:\Users\woodsonp\Claude\Dev\duckdb-skills`).
ZERO sessions is a FAIL, not a pass — a case-sensitive comparison returns nothing
and looks deceptively like clean scoping.
Full corpus returned ←’ the sidecar join broke in the split ←’ FAIL.
```

```
Select-String -Pattern "replace" skills\read-memories\search.sql
Expected: the working_directory comparison line, carrying BOTH replace() calls.
Paste it. One or zero replace() calls ←’ FAIL (requirement 2), even though the
row-level check above still passes.
```

**B7 — empty keyword fails loudly in both keyword-filtered files**

```
$env:DSK_KEYWORD = ''   then run search.sql, and separately sqlresults.sql.
Expected for BOTH: a clear error naming the missing keyword, and non-zero
$LASTEXITCODE. Paste both messages and both exit codes.
Returning rows, or exiting 0, ←’ FAIL (requirement 4).

Then coverage.sql and sqlresults-summary.sql with DSK_KEYWORD = '':
Expected for BOTH: normal output, exit 0. They must ignore the variable.
```

**B8 — CONTROL — a nonexistent mode file fails loudly**

```
duckdb -csv -f "<abs path>\skills\read-memories\bogus.sql"
Expected: non-zero $LASTEXITCODE. Paste the exit code and message.
Verified 2026-09-22 on the untouched repo: exit 1,
  IO Error: Failed to open file "...bogus.sql"
This confirms DuckDB's behaviour, not the implementer's — it needs no
implementation. An exit code of 0 would mean a typo'd filename silently returns
nothing, which is worse than the wart being fixed, so it is worth re-confirming.
```

**B9 — no struct-key or missing-column failures anywhere**

```
Expected: no output from B1-B8 contains "Could not find key" or "Referenced column
... not found". Either string means the JSON-typed read was lost in the split.
```

Plus the structural assertion for requirement 2:

```
Count `read_ndjson(` + `read_json(` occurrences across all four .sql files, and
count `columns = {` occurrences. Paste both.
Expected: equal. An unequal count means a read lost its explicit column list and
will break later on a corpus it did not sample.
```

```
Select-String -Pattern "\$\.type" skills\read-memories\*.sql
Expected: search.sql filters = 'text'; sqlresults*.sql filter = 'tool_result'.
Paste every matched line.
```

**B10 — `<system-reminder>` still excluded (the original defect)**

Keyword `Project Miner` against `search.sql`:

```
Expected: >= 1 hit, and ZERO hits whose text contains "<system-reminder>".
Paste the hit count and the Select-String result.
Before this skill was ported, all 5 hits for this keyword were system-reminders.
Losing this filter in a restructure silently restores the original bug, so this is
the highest-risk regression on the list.
```

**B11 — behaviour genuinely unchanged, not just quieter**

The risk of a restructure is a silent logic change. Prove equivalence mechanically —
prose comparison is not a check. Old version is commit **`2e23118`** (`main` HEAD before
this task).

```powershell
git show 2e23118:skills/read-memories/search.sql > $env:TEMP\old.sql
$env:DSK_MODE = 'search'; $env:DSK_KEYWORD = 'read_xlsx'; $env:DSK_CWD = ''
duckdb -csv -f "$env:TEMP\old.sql" > "$env:TEMP\old.csv"
duckdb -csv -f ".\skills\read-memories\search.sql" > "$env:TEMP\new.csv"
```

```
From old.csv keep only the lines at and after the LAST occurrence of
`session_id,ts,role,title,snippet` — that is the old answer block, the other three
being the noise this task removes. Compare to new.csv with Compare-Object.

Expected: every row present in old is present in new.
Rows present only in new are corpus drift (your own session appends while you
work) — quote them and continue.
A row in old and MISSING from new is a FAIL.

Repeat for the summary: old search.sql under DSK_MODE='sqlresults' with an empty
keyword, versus sqlresults-summary.sql. Expected: new counts >= old counts.
Do NOT expect equality — the corpus grows between the two runs.
```

**B12 — live plugin updated, with no stale files**

```
Get-ChildItem C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories |
  Select-Object -ExpandProperty Name
Expected EXACTLY these five names, no more:
  SKILL.md  search.sql  sqlresults.sql  sqlresults-summary.sql  coverage.sql
Paste the listing. Any additional .sql file ←’ FAIL (requirement 8).
```

```
Get-FileHash on each live file and its repo counterpart.
Expected: all five pairs match. Paste both hashes per file.
A mismatch means the copy happened before the last edit — see requirement 7.
```

```
Then run one search from the LIVE path (not the repo path) and paste the output:
one block, >= 1 hit.
```

**B13 — blast radius contained**

```
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
Expected: EMPTY output.  [CONTROL — empty on the untouched repo today]
```

The exclude list is deliberately the whole artifact set. An enumerated subset goes stale
the moment a round is added — which is exactly how the previous task's equivalent check
failed on an untouched repo.

```
git status --short
Expected: every line is one of `?? TASK.md`, `?? RESULT-1.md`, `?? REVIEW-task-1.md`.
Any other path, and any M / A / D line, is a FAIL. Paste the full output.
```

An emptiness expectation here is wrong by construction: the task's own artifacts are
untracked. The previous task's version of this check failed for exactly that reason.

**B14 — committed before RESULT-1.md was written**

```
git log --oneline -1   ←’ your implementation commit.
git status --short     ←’ no M lines (requirement 7).
Paste both.
```

**B15 — frontmatter and documented contract intact**

```
Get-Content skills\read-memories\SKILL.md -TotalCount 10
Expected: frontmatter exactly `name` and `description`; description names Cortex Code.

Select-String -Pattern "DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
Expected: >= 1 match per pattern; paste the matched lines.

Select-String -Pattern "DSK_MODE" skills\read-memories\SKILL.md skills\read-memories\*.sql
Expected: ZERO matches anywhere (requirement 3).

Plus: quote the lines carrying the do-not-narrate contract (requirement 6).
```
