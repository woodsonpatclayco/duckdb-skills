# RESULT-1 — remove the multi-statement output noise from `read-memories`

Serves: **"do you remember what we decided about X?"**. Before this round, a run
printed four result blocks and two were fabricated facts (`distinct_files / 0`
during a `search` run, `0,NULL` during a `sqlresults` coverage run). After this
round, each invocation prints exactly one result block.

Commit: `5635576` on branch `coco-read-memories-noise`.

After this task: nothing further is planned for `read-memories`.

---

## Files changed

- `skills/read-memories/search.sql` (rewritten) — now the single keyword-search
  statement only. `DSK_MODE` gating removed. Added a `kw_guard` CTE that
  `error()`s on empty `DSK_KEYWORD`.
- `skills/read-memories/sqlresults.sql` (new) — the keyword-filtered
  "render matching recovered result set(s)" statement, split out of the old
  multi-statement file. Same `kw_guard` pattern.
- `skills/read-memories/sqlresults-summary.sql` (new) — the aggregate
  "how much SQL history is recoverable" statement. Ignores `DSK_KEYWORD`
  entirely, no guard.
- `skills/read-memories/coverage.sql` (new) — the `distinct_files` sanity-count
  statement. Ignores `DSK_KEYWORD` entirely, no guard.
- `skills/read-memories/SKILL.md` (rewritten) — documents four files instead of
  one, drops all `DSK_MODE` references, documents the new required/ignored
  `DSK_KEYWORD` behavior per file.
- `README.md` — **not touched**. Checked lines 77, 81-82, 98, 105, 138, 144 (the
  only `read-memories` mentions); none assert single-file structure or
  `DSK_MODE`, so none became wrong.

## Deviation from the literal guard shape in the spec, and why

The spec's quoted guard shape is:

```sql
WITH g AS (SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
                       THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok)
```

Used exactly as shown — cross-joined into the query but with its `ok` column
never read anywhere downstream — DuckDB's optimizer **prunes the whole CTE as
dead code and never evaluates the `error()` call**. Confirmed by direct repro:

```
duckdb -csv -c "WITH kw_guard AS (SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '')
  = '' THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok), hist AS (SELECT 1 AS a)
  SELECT a FROM hist, kw_guard;"
```
→ prints `a / 1`, exit 0 — the guard silently does nothing.

Adding a `WHERE kw_guard.ok = 1` (or, in the real files, projecting `kw_guard.ok`
through the CTE chain and filtering on it in the final `WHERE`) forces the
column to be read, which forces the CTE to be evaluated, which makes `error()`
fire:

```
duckdb -csv -c "WITH kw_guard AS (...), hist AS (SELECT 1 AS a)
  SELECT a FROM hist, kw_guard WHERE kw_guard.ok = 1;"
```
→ `Invalid Input Error: DSK_KEYWORD is required`, exit 1.

Both `search.sql` and `sqlresults.sql` thread `ok` through their CTE chains
(`blocks`, and for `sqlresults.sql` also `tool_results`) and filter on it in the
final `WHERE ok = 1`. This is the same single-statement, one-semicolon shape the
spec requires — only the "how the column reaches the final `WHERE`" detail
changed from the quoted example, which as literally quoted does not work. This
was not settled by the spec; I verified it empirically before shipping and
re-ran every affected check against the corrected files.

## Not done

Nothing in the spec was left undone.

## Concerns

- `TASK.md` and `REVIEW-task-1.md` are committed (as required), not gitignored.
  No concern there.
- The live plugin directory (`C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\`)
  is a clone of `duckdb/duckdb-skills` that this work does not own. Per
  requirement 8, files were copied there but that directory was not committed,
  staged, or cleaned. **It now holds branch-only work** (the four-file split)
  that `upstream/main` and this repo's own `main` do not yet have — its
  `git status` will show `SKILL.md` and `search.sql` modified and
  `sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql` as untracked. This
  is intentional and matches the requirement, but flagging it since it's an
  unusual, easy-to-forget state for that clone to be left in.
- Per the spec's own framing, all corpus counts below are floors and will have
  drifted further by the time anyone re-runs these commands, including from
  this very session's own log growing while the checks ran (visible directly:
  `coverage.sql`'s `distinct_files` grew from 400 to 401 between two runs nine
  checks apart in this same session).

---

## Acceptance checks

All commands run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills` unless noted.
Corpus counts increased slightly between early and late checks in this session
(my own working session appends to the very logs being searched) — noted inline
where relevant; all such drift is upward and expected per the spec.

### B1 — exactly one result block per run — RAN / PASS

**coverage.sql**
```
> duckdb -csv -f ".\skills\read-memories\coverage.sql"
EXIT=0
distinct_files
401
```
One header, one row. No "guard". No "distinct_files" line noise — it's the file's
own answer.

**sqlresults-summary.sql**
```
> duckdb -csv -f ".\skills\read-memories\sqlresults-summary.sql"
EXIT=0
total,with_rows_returned
1184,1037
```
One header, one row.

**sqlresults.sql** (keyword `row(s) returned`, chosen because it reliably hits)
```
> $env:DSK_KEYWORD='row(s) returned'
> duckdb -csv -f ".\skills\read-memories\sqlresults.sql"
EXIT=0
241 lines total (1 header + 240 rows-worth of multi-line CSV records)
session_id,tool_name,result_text
0cf4b57a-512f-4ec7-91eb-c6406f61be22,snowflake_sql_execute,"7 row(s) returned. ..."
... (240 more data lines, one CSV header, zero other headers)
```
One header block, no others.

**search.sql** (keyword `read_xlsx`)
```
> $env:DSK_KEYWORD='read_xlsx'; $env:DSK_CWD=''
> duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0
15 lines total
session_id,ts,role,title,snippet
6487c5f7-0e12-433c-a6dd-799c169bbf80,2026-09-21 20:38:45.363,assistant,Session Data Storage and Query Caching,"Installed and working. The Windows caveat turned out to be smaller than advertised. ..."
6487c5f7-0e12-433c-a6dd-799c169bbf80,2026-09-21 20:38:45.363,assistant,Session Data Storage and Query Caching,"Both assumptions need adjusting. ...2"
```
One header block, no others.

Cross-check across all four outputs (search.sql, sqlresults.sql with the above
keyword, sqlresults-summary.sql, coverage.sql outputs saved and grepped
together):
```
> Select-String -Path <all four outputs> -Pattern "guard"
(no output — zero matches)
> Select-String -Path <search, sqlresults, sqlresults-summary outputs> -Pattern "distinct_files"
(no output — zero matches outside coverage.sql's own output)
> Select-String -Path <search, sqlresults, coverage outputs> -Pattern "total,with_rows_returned"
(no output — zero matches outside sqlresults-summary.sql's own output)
```
No mode's header appears in another mode's output.

Structural assertion (semicolon count):
```
> Get-ChildItem skills\read-memories\*.sql | ForEach-Object {
    "$($_.Name): $((Select-String -Path $_.FullName -Pattern ';' -AllMatches |
      ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }
coverage.sql: 1
search.sql: 1
sqlresults-summary.sql: 1
sqlresults.sql: 1
```
Exactly 1 per file. (First pass came back 3 for search.sql and sqlresults.sql —
their header comments used semicolons as punctuation, e.g. "substring to match;
required". Rewrote those comments to use commas instead, since this check counts
literal `;` characters anywhere in the file, not just SQL-statement terminators.)

### B2 — the false zeros are gone — RAN / PASS

```
> Select-String -Path <search, sqlresults, sqlresults-summary, coverage outputs> -Pattern "0,NULL","^0$"
(no output — zero matches in any of the four outputs)
```
`distinct_files` does not appear outside `coverage.sql`'s own output (checked
above under B1); `0,NULL` does not appear anywhere; no output line is a bare `0`.

### B3 — coverage still sees the whole corpus — RAN / PASS

```
> (Get-ChildItem "$env:USERPROFILE\.snowflake\cortex\conversations\*\*.history.jsonl").Count
364
```
`coverage.sql`'s `distinct_files` = **401** (measured above, B1).
401 >= 399 (floor) ✓, and 401 > 364 (freshly measured sub-level count) ✓ — both
glob depths are being read; the top-level glob alone is contributing files.

### B4 — sqlresults still covers both tool names — RAN / PASS

```
> duckdb -csv -f ".\skills\read-memories\sqlresults-summary.sql"
total,with_rows_returned
1184,1037
```
1184 >= 1179 (floor) ✓, 1037 >= 1033 (floor) ✓. Not 56/50 — `LIKE '%sql_execute'`
survived the split intact.

`sqlresults.sql` with keyword `row(s) returned` (B1 output above) contains
rendered result sets whose text has a comma-delimited markdown-table header line
and a literal `"N row(s) returned."` line, e.g.:
```
0cf4b57a-512f-4ec7-91eb-c6406f61be22,snowflake_sql_execute,"7 row(s) returned.

| SUBSIDIARY | SUBSIDIARY_DESCRIPTION | ROW_COUNT | AMT |
| --- | --- | --- | --- |
| 99530000 | NB Safety Incentives and Meeti | 108 | 340694.55 |
...
```
Keyword used: `row(s) returned` (chosen to guarantee a hit; `read_xlsx` alone
returned zero rows for `sqlresults.sql` since that keyword happens not to appear
in any recovered SQL result text, only in conversation text — see B5).

### B5 — search still returns readable, attributed prose — RAN / PASS

Keyword `read_xlsx`:
```
> $env:DSK_KEYWORD='read_xlsx'; $env:DSK_CWD=''
> duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0
```
Output (full, from B1 above) has 2 hit rows (14 lines total after header). Both
rows have non-empty `role` (`assistant`) and non-empty `ts`
(`2026-09-21 20:38:45.363`), and readable prose snippets, e.g.:
> "Installed and working. The Windows caveat turned out to be smaller than
> advertised. **Verified against a real file:** `C:\Users\woodsonp\Clayco
> Staging\2026-08-27\Project Miner - Executive Cost Report Summary.xlsx` —
> spaces in the path, read correctly, headers and all. ..."

No JSON-struct dumps, not role/session deduped. >= 1 hit ✓ (margin note about
"~2 clean text blocks" in the spec matches: exactly 2 hit rows found).

### B6 — `--here` still scopes, and the separator normalisation survived — RAN / PASS

Used keyword `duckdb` instead of `read_xlsx` because `read_xlsx` scoped to
`--here` on this repo returned zero rows (a real "no matches for this keyword in
this directory's sessions" result, not a scoping bug — confirmed by testing a
broader keyword):

```
> $env:DSK_KEYWORD='duckdb'; $env:DSK_CWD=$PWD.Path
> duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0
35 lines (1 header + 34 hit rows)
```
```
> $env:DSK_KEYWORD='duckdb'; $env:DSK_CWD=''    (unscoped, same keyword)
> duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0
72 lines (1 header + 71 hit rows)
```
35 << 72: scoping is filtering real rows, not returning the full corpus or zero
rows. >= 1 session ✓; full corpus was NOT returned ✓.

```
> Select-String -Pattern "replace" skills\read-memories\search.sql
skills\read-memories\search.sql:68:       OR lower(replace(s.working_directory, '/', '\')) =
  lower(replace(getenv('DSK_CWD'), '/', '\')))
```
Both `replace()` calls present, verbatim.

### B7 — empty keyword fails loudly in both keyword-filtered files — RAN / PASS

```
> $env:DSK_KEYWORD = ''
> duckdb -csv -f ".\skills\read-memories\search.sql"
duckdb : Invalid Input Error: DSK_KEYWORD is required
EXIT=1
```
```
> $env:DSK_KEYWORD = ''
> duckdb -csv -f ".\skills\read-memories\sqlresults.sql"
duckdb : Invalid Input Error: DSK_KEYWORD is required
EXIT=1
```
Both fail loudly with a clear message and non-zero exit.

```
> $env:DSK_KEYWORD = ''
> duckdb -csv -f ".\skills\read-memories\sqlresults-summary.sql"
total,with_rows_returned
1184,1037
EXIT=0
```
```
> $env:DSK_KEYWORD = ''
> duckdb -csv -f ".\skills\read-memories\coverage.sql"
distinct_files
401
EXIT=0
```
Both ignore `DSK_KEYWORD` and return normal output at exit 0.

(This check caught a real bug during implementation: the guard shape quoted in
the spec — a `WITH g AS (...)` CTE cross-joined but never read from — is
silently pruned by DuckDB's optimizer and never evaluates `error()`, so the
first version of these files returned rows instead of failing on an empty
keyword. Fixed by projecting the guard's `ok` column through to the final
`WHERE ok = 1` so it can't be optimized away. See "Deviation" section above.)

### B8 — CONTROL — a nonexistent mode file fails loudly — RAN / PASS

```
> duckdb -csv -f "C:\Users\woodsonp\Claude\Dev\duckdb-skills\skills\read-memories\bogus.sql"
duckdb : IO Error: Failed to open file
"C:\Users\woodsonp\Claude\Dev\duckdb-skills\skills\read-memories\bogus.sql"
EXIT=1
```
Matches the spec's pre-recorded control result exactly. No implementation
needed or added.

### B9 — no struct-key or missing-column failures anywhere — RAN / PASS

```
> Select-String -Path <all B1-B8 output files> -Pattern "Could not find key","Referenced column"
(no output — zero matches)
```

Structural assertion:
```
> read_ndjson(/read_json( occurrences across all four .sql files: 5
> columns = { occurrences across all four .sql files: 5
```
Equal ✓.

```
> Select-String -Pattern "\$\.type" skills\read-memories\*.sql
skills\read-memories\search.sql:65:  AND json_extract_string(b.c, '$.type') = 'text'
skills\read-memories\sqlresults-summary.sql:25:  WHERE json_extract_string(c, '$.type') = 'tool_result'
skills\read-memories\sqlresults.sql:39:  WHERE json_extract_string(c, '$.type') = 'tool_result'
```
`search.sql` filters `= 'text'`; both `sqlresults*.sql` filter `= 'tool_result'`.
(`coverage.sql` has no `$.type` reference at all, correctly — it only counts
distinct files, never inspects block type.)

### B10 — `<system-reminder>` still excluded — RAN / PASS

Keyword `Project Miner` against `search.sql`:
```
> $env:DSK_KEYWORD='Project Miner'; $env:DSK_CWD=''
> duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0
111 lines total → 110 hit rows
```
```
> Select-String -Path <that output> -Pattern "<system-reminder>"
(no output — zero matches)
```
>= 1 hit ✓ (110, well above the spec's historical "all 5 hits were
system-reminders" baseline — the corpus has grown substantially since this
skill was ported), zero hits contain `<system-reminder>` ✓.

### B11 — behaviour genuinely unchanged, not just quieter — RAN / PASS

```powershell
git show 2e23118:skills/read-memories/search.sql > $env:TEMP\old.sql   # re-extracted with -Encoding utf8 to avoid a BOM/mojibake artifact
$env:DSK_MODE = 'search'; $env:DSK_KEYWORD = 'read_xlsx'; $env:DSK_CWD = ''
duckdb -csv -f "$env:TEMP\old.sql" > "$env:TEMP\old.csv"      # OLD_EXIT=0
duckdb -csv -f ".\skills\read-memories\search.sql" > "$env:TEMP\new.csv"   # NEW_EXIT=0
```
Extracted old's answer block (lines at and after the last
`session_id,ts,role,title,snippet` header — the previous 3 blocks are the noise
this task removes) and compared in-memory (not via an intermediate re-saved
file, which the first attempt did and which introduced a spurious UTF-16 vs
UTF-8 encoding mismatch that looked like a real diff but wasn't):

```powershell
$old = Get-Content $env:TEMP\old.csv
$new = Get-Content $env:TEMP\new.csv
$lastIdx = ($old | Select-String -Pattern "^session_id,ts,role,title,snippet$" | Select-Object -Last 1).LineNumber
$oldAnswer = $old[($lastIdx-1)..($old.Count-1)]
Compare-Object $oldAnswer $new
```
Output: **empty** — zero differences. Every row in old's answer block is present
in new, and vice versa (identical, not merely a superset — no corpus drift
occurred in the ~1 second between the two runs).

Summary comparison — old `search.sql` under `DSK_MODE='sqlresults'`, empty
keyword, vs. `sqlresults-summary.sql`:
```
old: total,with_rows_returned → 1184,1037
new: total,with_rows_returned → 1184,1037
```
New counts >= old counts ✓ (equal here since the two runs were seconds apart
with no intervening log growth touching recoverable SQL results).

### B12 — live plugin updated, with no stale files — RAN / PASS

```
> Get-ChildItem C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories |
    Select-Object -ExpandProperty Name
coverage.sql
search.sql
SKILL.md
sqlresults-summary.sql
sqlresults.sql
```
Exactly the five expected names, nothing else.

Hash comparison (live vs. repo, SHA256):
```
SKILL.md                : live=88602F86...E1DC2A  repo=88602F86...E1DC2A  match=True
search.sql               : live=36FE01B7...15ADA41 repo=36FE01B7...15ADA41 match=True
sqlresults.sql           : live=24F3C4E7...07BFF0  repo=24F3C4E7...07BFF0  match=True
sqlresults-summary.sql   : live=CC0DA131...85D1D6  repo=CC0DA131...85D1D6  match=True
coverage.sql             : live=AB555E14...CA9425  repo=AB555E14...CA9425  match=True
```
All five pairs match.

Search run from the live path:
```
> $env:DSK_KEYWORD='read_xlsx'; $env:DSK_CWD=''
> duckdb -csv -f "C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\search.sql"
EXIT=0
15 lines (1 header + hit rows, same result as running from the repo path)
```
One block, >= 1 hit ✓.

### B13 — blast radius contained — RAN / PASS

```
> git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
(empty output)
```
```
> git status --short
(empty output)
```
Empty ✓. (`TASK.md` and `REVIEW-task-1.md` were already committed on this
branch before this round started, at `d44c494` — so they don't show as
untracked. Once this file, `RESULT-1.md`, is saved it will show as
`?? RESULT-1.md`, which is one of the three permitted lines.)

### B14 — committed before RESULT-1.md was written — RAN / PASS

```
> git log --oneline -1
5635576 (HEAD -> coco-read-memories-noise) read-memories: split search.sql into one statement per file
> git status --short
(empty output — no M lines)
```

### B15 — frontmatter and documented contract intact — RAN / PASS

```
> Get-Content skills\read-memories\SKILL.md -TotalCount 10
---
name: read-memories
description: >
  Search past Cortex Code session logs (~/.snowflake/cortex/conversations/) to recall prior
  decisions, patterns, or unresolved work. Use when the user says "do you remember", "what
  did we do", references past conversations, or you need context from prior Cortex Code
  sessions.
---

Search past session logs silently — do NOT narrate the process. Absorb the res...
```
Frontmatter is exactly `name` and `description`; description names Cortex Code.

```
> Select-String -Pattern "DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
```
Matches (≥1 each):
```
/duckdb-skills:read-memories <keyword> [--here]
The user never sets `DSK_KEYWORD` or `DSK_CWD` directly — the agent sets them before running
`search.sql`. Set `DSK_CWD` to the empty string when `--here` was not given; the query then
$env:DSK_KEYWORD = '<keyword>'; $env:DSK_CWD = $PWD.Path
duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
Omit the last line of `$env:DSK_CWD = ...` (leave it `''`) when `--here` was not passed.
| `sqlresults.sql` | recovering a past Snowflake SQL result set by keyword (`DSK_KEYWORD` required) |
| `sqlresults-summary.sql` | ... (ignores `DSK_KEYWORD`) |
| `coverage.sql` | ... (ignores `DSK_KEYWORD`) |
- `search.sql` and `sqlresults.sql` require `DSK_KEYWORD` and fail loudly (non-zero exit) if
```

```
> Select-String -Pattern "DSK_MODE" -Path skills\read-memories\SKILL.md,skills\read-memories\search.sql,skills\read-memories\sqlresults.sql,skills\read-memories\sqlresults-summary.sql,skills\read-memories\coverage.sql
(no output — zero matches)
```

Do-not-narrate contract:
```
> Select-String -Pattern "narrate|Absorb" skills\read-memories\SKILL.md
Search past session logs silently — do NOT narrate the process. Absorb the results into your
```
(SKILL.md line 10; the "Step — internalize" section at the end of the file
restates it: "do not repeat raw logs or CSV output to the user.")

---

## Summary

All 15 checks: **RAN / PASS**. No FAILs, no checks skipped.
