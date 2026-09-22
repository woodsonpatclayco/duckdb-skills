# RESULT-1 — honest and stable `read-memories` search output

Serves: **"do you remember what we decided about X?"**. This round fixes the five
measured defects (wildcard false positives, invisible truncation, silent 40-row cap in
oldest-first order, and non-deterministic repeats) in `search.sql` and `sqlresults.sql`.
Nothing further is planned for `read-memories` after this.

Commit: `79eaf05` on branch `coco-read-memories-snippets`.

Corpus floors from TASK.md were 403 log files / 1,184 SQL blocks / 1,037 with rows returned;
this session's own logging pushed the live corpus above that (409 files, 1,187 blocks, 1,040
with rows returned per `coverage.sql` / `sqlresults-summary.sql` runs below) — expected drift,
not a discrepancy.

No `README.md` line needed touching; nothing in it names the old `left()`/`ILIKE`/`ORDER BY ts`
behaviour.

---

## C1 — every returned snippet contains the keyword

### C1a — `dangling blob`

```
rows_returned=7
snippet_missing_kw=0
```

Full output (7 rows, newest first, all containing "dangling blob"):

```
session_id,ts,role,title,snippet,chars,matches
b292bd62-4184-47ba-807f-d5236c8637d1,2026-09-22 14:46:17.12,assistant,Verify read-memories port,"... mean any automated consumer must find the right section rather than assume the first block. I also ran my own search (`dangling blob`) and got back one clean, dated, readable hit, confirming the skill does the useful thing it was built for.",2254,7
6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,DuckDB Skills Fork for Cortex Code,"...d no discrepancy that mattered. **Prove it yourself** ... $env:DSK_KEYWORD = 'dangling blob'; ... You should get back a dated, readable hit with its session title ... Three things worth knowing: - **SQL result recovery works an...",1318,7
6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,DuckDB Skills Fork for Cortex Code,"... new skill ... `dangling blob` returned readable, dated, attributed hits ... - **Coverage reads 399 files** ... In `coverage` mode the r...",1418,7
6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,DuckDB Skills Fork for Cortex Code,"...not a window around your keyword.** Look at the first hit ... the phrase ""dangling blob"" is nowhere in the text you can see. The match is real ... Small, self-contained follow-up if you...",1159,7
6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,DuckDB Skills Fork for Cortex Code,"... that's why. Small, self-contained follow-up if you want it. **Prove it yourself:** ... $env:DSK_KEYWORD = 'dangling blob'; ... One header row, then hits ... no zeros above the answer.",1746,7
6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,DuckDB Skills Fork for Cortex Code,"...es position 0 and the snippet falls back to the first 500 characters ... my check used `dangling blob`, which has no underscore and passes, so **the spec would have certified the bug as fixed.** ... My determinism check contradicted itself.*...",1970,7
341528cf-a987-48d4-86dd-1de529b54b24,2026-08-20 18:54:46.472,assistant,Load and Order Plan Tasks,"... to undo its own temporary edit ... wiped every uncommitted implementer change in that file. It recovered them from a dangling blob in the object store and verified byte-identity. ... 323 passed, 3 skipped ... The verifier is supposed to have no write tools precisely so it cannot do this, and `git checkout` is a write that slipp...",3570,7
```

**RAN — PASS.**

### C1b — `sql_execute`

Assertion script (PowerShell, run via a temp `.ps1` since inline `$_.Count` piping was getting
mangled by the shell wrapper):

```powershell
$env:DSK_KEYWORD='sql_execute'; $env:DSK_CWD=''
duckdb -csv -f skills\read-memories\search.sql | Out-File -Encoding utf8 "$env:TEMP\dsk-c1b.csv"
$rows = Import-Csv "$env:TEMP\dsk-c1b.csv"
$rows_returned = $rows.Count
$missing = ($rows | Where-Object { $_.snippet.ToLower() -notlike '*sql_execute*' }).Count
"rows_returned=$rows_returned snippet_missing_kw=$missing"
```

Output:

```
rows_returned=6 snippet_missing_kw=0
```

`snippet_missing_kw = 0` proves requirement 1 landed (the old file's measured baseline was 5
rows / 1 missing; the count here differs because the corpus grew and because the wildcard false
positive is now excluded, both expected).

**RAN — PASS.**

---

## C2 — truncation is visible, and its size is knowable

From C1a: row `b292bd62-...` has `chars=2254` with no `...` markers because it's the newest and
the match happens to be within the first window — checking the other C1a rows for a decorated
one:

```
session_id : dbd605ee-5064-4ca6-ae07-881e2c9f3220 (from `the`, see below)
chars      : 330
snippet    : ...hook can't cover gitignored files — those change without any commit, so a
             hook-only trigger would silently miss exactly the content you most want
             protected. The mirror needs two layers with two triggers: git history on
             commit, ignored files on a timer.
```

That row starts with a leading `...` and `chars` (330) is less than the printed window because
`substr` returned a de-facto full 330-char remainder — the marker means "text existed before
this window", not strictly "longer than window"; the mechanical assertion below is the
authoritative one.

Keyword `the` (script `dsk-c2.ps1`):

```powershell
$rows = Import-Csv "$env:TEMP\dsk-the-run1.csv"
$decorated = $rows | Where-Object { $_.snippet -like '...*' -or $_.snippet -like '*...' }
$undecorated = $rows | Where-Object { $_.snippet -notlike '...*' -and $_.snippet -notlike '*...' }
Write-Output ("decorated_count=" + $decorated.Count + " undecorated_count=" + $undecorated.Count)
$undecoratedShort = $undecorated | Where-Object { [int]$_.chars -le 500 }
Write-Output ("undecorated_le500=" + $undecoratedShort.Count)
$minchars = ($undecoratedShort | Measure-Object -Property chars -Minimum).Minimum
Write-Output ("min_chars=" + $minchars)
```

Output:

```
decorated_count=3 undecorated_count=37
undecorated_le500=37
min_chars=45
```

37 of 40 rows are undecorated with `chars <= 500` (min 45) — short messages come back plain, no
`...`. (TASK.md's measured baseline was 38/40, min 45; 37/40 here reflects corpus drift between
measurement and this run, per the stated floor caveat.) One decorated row shown:

```
session_id : dbd605ee-5064-4ca6-ae07-881e2c9f3220
chars      : 330
snippet    : ...hook can't cover gitignored files — those change without any commit...
```

**RAN — PASS.**

---

## C3 — ASCII markers only

```powershell
Select-String -Path skills\read-memories\*.sql,skills\read-memories\SKILL.md -Pattern ([char]0x2026)
```

Output: (nothing — zero matches)

**RAN — PASS.**

---

## C4 — the row cap is now reported

### C4a — over the cap, keyword `the`

```
row_count=40
matches_unique=6971
```

(Measured baseline in TASK.md was `matches=6965`; 6971 here is corpus growth, still strictly
greater than the 40 rows returned — `count(*) OVER ()` is computed before `LIMIT`.)

**RAN — PASS.**

### C4b — under the cap, keyword `dangling blob`

```
rows_returned=7
matches_unique=7
```

`matches` (7) equals the returned row count (7), and that count is >= 1.

**RAN — PASS.**

---

## C5 — newest first

Method: extracted only the `ts` column from the keyword-`the` CSV via `Import-Csv | Select ts`
(the row-order-safe method — snippets contain embedded newlines, so a naive line split is not
row order).

```
first_ts=2026-09-22 16:34:24.159
last_ts=2026-09-22 15:49:49.736
```

`first_ts >= last_ts`; explicit non-increasing check over all 40 rows:

```powershell
$tsvals = $rows | Select-Object -ExpandProperty ts
$sorted = $true
for ($i=1; $i -lt $tsvals.Count; $i++) {
  if ([datetime]$tsvals[$i] -gt [datetime]$tsvals[$i-1]) { $sorted = $false }
}
"non_increasing=$sorted"
```

```
non_increasing=True
```

Ascending order (the old behaviour) would have failed this. This reversal is intended per
requirement 6; the prior task's `SHIPPED.md` claim of unchanged ordering is superseded, not
violated.

**RAN — PASS.**

---

## C6 — determinism, drift-tolerant

All captures went to `$env:TEMP\dsk-c6-*.txt`/`.csv`/`.sql` — nothing landed in the repo (see
C13).

### New `search.sql`, keyword `the`, 3 runs back to back

```powershell
1..3 | ForEach-Object {
  duckdb -csv -f skills\read-memories\search.sql | Out-File -Encoding utf8 "$env:TEMP\dsk-c6-search-$_.csv"
}
Compare-Object (Get-Content "$env:TEMP\dsk-c6-search-1.csv") (Get-Content "$env:TEMP\dsk-c6-search-2.csv")
Compare-Object (Get-Content "$env:TEMP\dsk-c6-search-2.csv") (Get-Content "$env:TEMP\dsk-c6-search-3.csv")
```

Output: **empty** for both comparisons — byte-identical across all three runs, even *before*
stripping the `matches` column (the corpus did not tick over between these three runs). Also
compared with `matches` projected out explicitly (`Select-Object * -ExcludeProperty matches`
then `ConvertTo-Csv`) — also empty.

**RAN — PASS.**

### New `sqlresults.sql`, keyword `the`, 3 runs back to back

Same method, `matches` column stripped:

```
(empty diff 1v2)
(empty diff 2v3)
```

**RAN — PASS.**

### Old `search.sql` at `4cb9814` — instability control

```powershell
git show 4cb9814:skills/read-memories/search.sql | Set-Content -Encoding ASCII "$env:TEMP\dsk-c6-old.sql"
```

Ran standalone (no `DSK_MODE` needed at that commit) three times with keyword `the`:

```
=== old file line counts ===
120
120
113
=== diff 1v2 ===
0
=== diff 2v3 ===
17
```

Run 3 dropped to 113 lines (down from 120) with a 17-line `Compare-Object` delta against run 2 —
line count going *down* rules out corpus growth as the explanation; this is the tie-reshuffle
instability requirement 7 is meant to remove. The new file showed **zero** instability under the
identical test above.

**RAN — PASS** (both halves: new file stable, old file unstable).

---

## C7 — CONTROL — one statement per file

```powershell
Get-ChildItem skills\read-memories\*.sql | ForEach-Object {
  "$($_.Name): $((Select-String -Path $_.FullName -Pattern ';' -AllMatches |
    ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }
```

```
coverage.sql: 1
search.sql: 1
sqlresults-summary.sql: 1
sqlresults.sql: 1
```

**RAN — PASS.**

---

## C8 — CONTROL — `<system-reminder>` still excluded

Keyword `Project Miner`:

```
hit_count=19
```

```powershell
Select-String -Path "$env:TEMP\dsk-c8.csv" -Pattern '<system-reminder>'
```

Output: (nothing — zero matches)

**RAN — PASS.**

---

## C9 — preserve-verbatim list survived, extraction happened once

```
--- $.type ---
skills\read-memories\search.sql:67:    json_extract_string(b.c, '$.type') AS block_type,
skills\read-memories\sqlresults-summary.sql:25:  WHERE json_extract_string(c, '$.type') = 'tool_result'
skills\read-memories\sqlresults.sql:47:  WHERE json_extract_string(c, '$.type') = 'tool_result'

--- sql_execute ---
skills\read-memories\sqlresults-summary.sql:4:-- tool_result blocks matching the sql_execute tool name, and how many of
skills\read-memories\sqlresults-summary.sql:26:    AND json_extract_string(c, '$.tool_result.name') LIKE '%sql_execute'
skills\read-memories\sqlresults.sql:48:    AND json_extract_string(c, '$.tool_result.name') LIKE '%sql_execute'

--- replace ---
skills\read-memories\search.sql:99:       OR lower(replace(sd.working_directory, '/', '\')) =
       lower(replace(getenv('DSK_CWD'), '/', '\')))

--- coalesce ---
skills\read-memories\search.sql:35:  SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
skills\read-memories\search.sql:43-44: coalesce(getenv('USERPROFILE'), getenv('HOME')) || ...history.jsonl (both glob depths)
skills\read-memories\search.sql:52-53: coalesce(getenv('USERPROFILE'), getenv('HOME')) || ...*.json (both glob depths)
skills\read-memories\search.sql:83:  coalesce(w.user_sent_time::TIMESTAMP, w.assistant_sent_time::TIMESTAMP,
           sd.created_at::TIMESTAMP, epoch_ms(sd.creationDate)) AS ts
skills\read-memories\search.sql:98:  AND (coalesce(getenv('DSK_CWD'), '') = ''

--- history.jsonl ---
present at both glob depths in all four files (coverage.sql, search.sql, sqlresults-summary.sql,
sqlresults.sql) — unchanged in the untouched two, preserved in the two edited ones.

--- columns = { ---
coverage.sql: 1 occurrence (1 read_ndjson call)
search.sql: 2 occurrences (hist + side, matching its 2 read_ndjson/read_json calls)
sqlresults-summary.sql: 1 occurrence (1 read_ndjson call)
sqlresults.sql: 1 occurrence (1 read_ndjson call)
Count of columns={} equals count of read_ndjson/read_json calls in every file.

--- LIMIT ---
skills\read-memories\search.sql:101:LIMIT 40;
skills\read-memories\sqlresults.sql:59:LIMIT 20;
```

`LIKE '%sql_execute'` on the tool name still present and not narrowed. Both `replace()` calls
present on the `working_directory` comparison. The `ts` coalesce shows all four terms:
`user_sent_time, assistant_sent_time`, sidecar `created_at`, `epoch_ms(creationDate)`. Both glob
depths present in every history read. `LIMIT 40` / `LIMIT 20` unchanged.

Requirement 3 — single extraction and single position computation:

```powershell
Select-String -Pattern "json_extract_string\(b\.c, '\$\.text'\)" skills\read-memories\search.sql
```
```
skills\read-memories\search.sql:68:    json_extract_string(b.c, '$.text') AS txt
```
Exactly 1 match.

```powershell
Select-String -Pattern "strpos" skills\read-memories\search.sql
```
```
skills\read-memories\search.sql:74:    strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) AS p
```
Exactly 1 match (the comment block was reworded to avoid mentioning the literal word "strpos" so
this grep isn't inflated by prose).

**RAN — PASS.**

---

## C10 — CONTROL — the empty-keyword guard still fires

```
=== search.sql empty keyword ===
Invalid Input Error:
DSK_KEYWORD is required
EXIT=1
=== sqlresults.sql empty keyword ===
Invalid Input Error:
DSK_KEYWORD is required
EXIT=1
=== coverage.sql empty keyword (should ignore) ===
distinct_files
409
EXIT=0
=== sqlresults-summary.sql empty keyword (should ignore) ===
total,with_rows_returned
1187,1040
EXIT=0
```

Both keyword files error with non-zero exit on empty `DSK_KEYWORD`; `coverage.sql` and
`sqlresults-summary.sql` ignore it and exit 0, as before. The guard survived requirement 3's
extra CTEs (`kw_guard.ok` → `blocks.ok` → `texted.ok` (via `t.*`) → `windowed.ok` (via `t.*`) →
`positioned.ok` (via `w.*`) → outer `WHERE w.ok = 1`).

**RAN — PASS.**

---

## C11 — CONTROL — one result block per run, still

```
=== search.sql ===
session_id,ts,role,title,snippet,chars,matches
<7 rows for "dangling blob">
=== sqlresults.sql ===
session_id,tool_name,result_text,matches
<0 rows for "dangling blob" — still one header line>
=== coverage.sql ===
distinct_files
409
=== sqlresults-summary.sql ===
total,with_rows_returned
1187,1040
```

One header line per run, each of the four files. Grep for "guard" across the captured combined
output: zero matches. No mode's header appears in another mode's output.

**RAN — PASS.**

---

## C12 — live plugin updated, no stale files

```powershell
Get-ChildItem C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories |
  Select-Object -ExpandProperty Name
```
```
coverage.sql
search.sql
SKILL.md
sqlresults-summary.sql
sqlresults.sql
```

Exactly the five expected files, nothing stale.

Hashes (repo vs. live, all five):

```
SKILL.md                repo=B87B97F5B0158395EB98E8EB5F5C6C37CD2F2FA9937080880D9AD844B7EF6470  match=True
search.sql              repo=78B0FE694A8CA2FEDC432B8290BBA7B40AA16FEC50D92D906EF52B9A046405F5  match=True
sqlresults.sql          repo=7566C4B0F158054251691EBF6D73CD0B518690961A1991F7254538C1916A6703  match=True
sqlresults-summary.sql  repo=CC0DA131958B25FBD72F0CDD2973E778418E1B2BCD646124D8F7D5B86785D1D6  match=True
coverage.sql            repo=AB555E14E63FDC1D1DAC67608C51BA9C66684498854A8BDC53D702C6ABCA9425  match=True
```

All five pairs match (byte-identical repo↔live).

Running C1a's keyword (`dangling blob`) from the live path:

```
rows=7
snippet_missing_kw=0
session_id,ts,role,title,snippet,chars,matches   (single header line)
```

One block, every snippet contains the keyword.

**RAN — PASS.**

---

## C13 — blast radius contained

```powershell
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
```

Output: (empty)

**RAN — PASS (CONTROL).**

```powershell
git diff --stat 4cb9814 -- skills/read-memories
```

```
 skills/read-memories/SKILL.md       | 13 ++++++++
 skills/read-memories/search.sql     | 62 +++++++++++++++++++++++++++----------
 skills/read-memories/sqlresults.sql | 17 +++++++---
 3 files changed, 72 insertions(+), 20 deletions(-)
```

Only `search.sql`, `sqlresults.sql`, `SKILL.md` — `sqlresults-summary.sql` and `coverage.sql`
untouched, as required.

```powershell
git status --short
```

Output (before this file was written):

```
(empty)
```

`TASK.md` and `REVIEW-task-1.md` were already committed in a prior commit (`68fc9fc`) before
this round started, so they don't appear as `??` lines — that's a stricter result than the
check's floor, not a violation. After writing this file the only untracked path is
`?? RESULT-1.md`. No C6-capture file, and no M/A/D line, appears anywhere in the repo.

**RAN — PASS.**

---

## C14 — committed before `RESULT-1.md` was written

```powershell
git log --oneline -1
```
```
79eaf05 (HEAD -> coco-read-memories-snippets) read-memories: honest, stable search output
```

```powershell
git status --short
```
```
(empty — no M lines)
```

**RAN — PASS.**

---

## C15 — `SKILL.md` documents what the skill now does

```powershell
Get-Content skills\read-memories\SKILL.md -TotalCount 10
```
```
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

```powershell
Select-String -Pattern "chars","matches","DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
```

Matched lines (one per pattern, at minimum):

```
/duckdb-skills:read-memories <keyword> [--here]
The user never sets `DSK_KEYWORD` or `DSK_CWD` directly ...
$env:DSK_KEYWORD = '<keyword>'; $env:DSK_CWD = $PWD.Path
duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
- `search.sql` and `sqlresults.sql` require `DSK_KEYWORD` and fail loudly (non-zero exit) if ...
- ... side; a message that fits whole is returned with no markers. The `chars` column gives the ...
- Both keyword files return a `matches` column: the total number of rows that matched ...
- `search.sql` returns the **most recent** matches first (`ORDER BY ts DESC`), with a ...
```

>= 1 match per pattern.

```powershell
Select-String -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql -Pattern "DSK_MODE"
```

Output: (nothing — zero matches). `DSK_MODE` stays gone.

Lines describing the behavioural contract:

- Do-not-narrate: *"Search past session logs silently — do NOT narrate the process. Absorb the
  results into your answer and continue; never dump raw logs or CSV to the user."*
- Match-centred window: *"`search.sql`'s `snippet` is a **match-centred window**, not a prefix:
  500 characters starting 120 characters before the match. A leading or trailing `...` marks a
  cut on that side; a message that fits whole is returned with no markers. The `chars` column
  gives the full untruncated length, so how much was hidden is knowable without arithmetic."*
- Newest-first ordering: *"`search.sql` returns the **most recent** matches first (`ORDER BY ts
  DESC`), with a deterministic tiebreak (`session_id, md5(txt)`) so identical runs return
  identical rows."*
- Literal substring, no wildcards: *"The keyword is matched as a **literal substring**,
  case-insensitive, via `strpos` — not a `LIKE` pattern. `_` and `%` in the keyword are ordinary
  characters, not wildcards, so a keyword like `sql_execute` only matches text that actually
  contains it."*

**RAN — PASS.**

---

## Summary

All 15 checks (with lettered sub-parts for C1, C4, C12) RAN and PASSED. No FAILs.

## Deviations from the spec

- None in substance. The one wording choice not dictated by the spec: the requirement-3 comment
  in `search.sql` originally said "via strpos" — that phrase would have inflated C9's
  exactly-1 grep for `"strpos"` in that file (comment + code = 2 matches), so it was reworded to
  describe the behaviour without the literal token. The code itself calls `strpos` exactly once.
- The window computation is split across two small CTEs (`windowed` computing `p`, `positioned`
  computing `greatest(1, p - 120)` from it) rather than one — this keeps `strpos` itself called
  exactly once while still giving the window start its own named column (`win_start`), matching
  the verified expression's `s = greatest(1, p - 120)` shape. Not a deviation from any
  requirement; just how requirement 3's "carry `ok` through every intermediate CTE" was
  satisfied without recomputing `strpos`.

## Not done

Nothing in the spec was left incomplete.

## Concerns

- Deploying to the live plugin directory (`C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\`)
  leaves that clone's `git status` dirty, as the spec anticipates (requirement 13): `SKILL.md`
  shows modified, and all four `.sql` files show untracked in that clone's own repo. This is
  branch-only work living outside version control in that directory, by design — not committed,
  staged, or cleaned there.
- `coverage.sql` and `sqlresults-summary.sql` figures (409 files / 1,187 blocks / 1,040 with
  rows returned) are all above the TASK.md floors (403 / 1,184 / 1,037), consistent with normal
  corpus growth from this and other concurrent sessions — not a regression signal.
- No shell-quoting issues were hit inside the actual `.sql` files; the only friction was in
  ad-hoc PowerShell one-liners run through this tool's bash wrapper, which occasionally mangled
  `$var.Property` into `$var .Property` when passed as an inline `-Command` string. Working
  around this by writing short `.ps1` files to `$env:TEMP` and invoking them with `-File` avoided
  the issue entirely and is reflected in the commands quoted above.
