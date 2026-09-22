# TASK — make `read-memories` search output honest and stable

Plan: none (single self-contained task; no multi-task plan exists)

Serves: **"do you remember what we decided about X?"** — the same feature shipped twice
already (`docs/tasks/2026-09-22-coco-read-memories/`, then
`docs/tasks/2026-09-22-read-memories-output-noise/`). It finds things and prints one clean
block. But a returned hit can show 500 characters of text that do not contain the keyword,
with no indication anything was cut; some hits are not matches at all; results are silently
capped at 40 with no count of what was dropped; the 40 you get are the **oldest** matches,
not the most recent; and two identical runs return different rows. After this task, a hit
shows you the match, tells you what it hid, and the same query twice gives the same answer.

After this task: nothing further is planned for `read-memories`.

---

## Context

`skills/read-memories/` holds four single-statement SQL files (`search.sql`,
`sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql`) plus `SKILL.md`. **All changes
are confined to `search.sql`, `sqlresults.sql`, and `SKILL.md`**; the other two `.sql` files
are untouched.

Repo: `C:\Users\woodsonp\Claude\Dev\duckdb-skills`, `main` at `4cb9814`, pushed to `origin`
(`woodsonpatclayco/duckdb-skills`). `upstream` = `duckdb/duckdb-skills`. Create a branch.

**Scope: `skills/read-memories/` only.** The other 8 skills must keep merging cleanly from
`upstream/main` — that property must not break. `README.md` may be touched **only** if a
requirement below makes a specific line wrong; name the line in `RESULT-1.md` first.

Environment: Windows, PowerShell 5.1. DuckDB CLI v1.5.5.

---

## The corpus grows while you work — read before quoting any count

Every Cortex Code session, including yours, appends to the logs being searched. Counts here
are **floors, not equalities**. Above a stated number is expected drift — quote the actual
figure and continue. Below it is a real failure.

Current floors: **403** log files, **1,184** recoverable SQL result blocks of which
**1,037** contain `row(s) returned`.

Two consequences, both of which have tripped checks on this skill before:

- A determinism check cannot demand byte-identical output across runs minutes apart. C6
  defines exactly what drift is permitted.
- Requirement 1 **changes which rows match**, so counts measured before this task are not
  comparable to counts after it. Do not treat a *lower* post-change count as a regression
  if the rows removed were wildcard false positives — C1b proves that distinction.

---

## The five defects, measured

### 1. `ILIKE` makes `_` and `%` silent wildcards, so some hits are not matches

`search.sql` matches with `ILIKE '%' || getenv('DSK_KEYWORD') || '%'`. In SQL `LIKE`
patterns, `_` matches **any single character**. So the keyword `sql_execute` also matches
text containing `sqlXexecute`, and the keyword `session_id` matches `sessionXid`:

```
('sessionXid ' || repeat('z',600)) ILIKE '%session_id%'   →  true
strpos(lower('sessionXid ' || ...), 'session_id')         →  0
```

Underscores are everywhere in this corpus — column names, tool names, environment
variables. Measured on keyword `sql_execute`: **1 of 5 returned rows does not contain the
keyword at all.** This is a correctness defect in its own right, and it also breaks
requirement 2 below, because a window computed from `strpos` on a wildcard-only match
returns position 0.

### 2. The snippet is the first 500 characters, not the match

`search.sql:61` is `left(json_extract_string(b.c, '$.text'), 500) AS snippet`.

Real observed hit for keyword `dangling blob` — the phrase appears nowhere in what the user
sees, because it sits past character 500:

```
341528cf-...,2026-08-20 18:54:46.472,assistant,Load and Order Plan Tasks,"Round 1 is
verified **SHIP**. Committed and pushed to both `origin` and `github`. **Prove it
yourself — the visual one, since this is a button:** ... py -3.12 -m
context_graph.serve_graph --db ...  Open `http://127.0.0.1:8788/`, click any file, and
you'll see **Pin to watchlist** / **Ignore** on the card. Click P
```

The match is real. The output looks like a false positive.

### 3. Truncation is invisible

`left()` cuts silently. A truncated 4,000-character message and a complete 480-character
message are indistinguishable.

### 4. The 40-row cap is silent, and shows the oldest matches

`search.sql:71` is `LIMIT 40`, under `ORDER BY ts` **ascending**. A common keyword returns
40 rows with no indication that thousands matched — measured: keyword `the` returns 40 rows
out of **6,965** — and the 40 you get are the oldest. For a "do you remember" tool, the most
useful hits are the ones most reliably hidden.

### 5. Both keyword files return different rows on identical runs

Measured, keyword `the`, two runs 300 ms apart from the same unmodified file: 126 vs 117
lines, 31 lines of `Compare-Object` difference. Line count going *down* rules out corpus
growth. Cause: `ORDER BY ts LIMIT 40` where many rows share a `ts` — one real session has
20+ rows at exactly `2026-07-30 18:26:51.022` — so which rows survive the `LIMIT` is
arbitrary. `sqlresults.sql` has the same defect via `ORDER BY session_id LIMIT 20`.

Do not try to reproduce those specific line counts. Line count is itself the unstable
quantity; a reviewer re-running the same command got 89 lines. What must reproduce is
*instability*, not a number.

---

## Verified expressions — use these, they were measured in place

Every expression below was run against DuckDB v1.5.5, and the two load-bearing ones were
re-verified **inside the real multi-CTE shape with the guard threaded**, not in isolation.
The previous task lost a round to an expression that worked standalone and was
dead-code-eliminated when embedded.

**Match position and the `WHERE` predicate must be the same test.** Use `strpos` for both,
which also fixes defect 1:

```sql
-- in the CTE that computes the window:
strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) AS p
-- in the final WHERE, instead of ILIKE:
p > 0
```

**Match-centred window with ASCII cut markers**, starting 120 characters before the match so
there is leading context:

```sql
-- s = greatest(1, p - 120)
(CASE WHEN s > 1 THEN '...' ELSE '' END)
  || substr(txt, s, 500)
  || (CASE WHEN length(txt) > s + 499 THEN '...' ELSE '' END)
```

Measured: a 1,249-char message with the match at 314 produced a window starting at 194 with
`...` at both ends; a 15-char message came back whole with no markers. Multiple occurrences
(window centres on the first), a match at position 1, and text shorter than the window all
behave as described. `strpos` and `substr` agree on non-ASCII text, so the window is not
byte/character-confused.

**Use ASCII `...`, not a Unicode ellipsis.** This console renders UTF-8 as cp1252, and a `…`
in output pasted into any artifact in this repo arrives as `â€¦`.

**Total-match count computed before the `LIMIT`.** Window functions evaluate before `LIMIT`:

```sql
count(*) OVER () AS matches
```

Verified **in the real shape** — four CTEs with the guard threaded into the final `WHERE`,
keyword `the`: 40 rows returned, `matches = 6965`, identical on every row.

**Deterministic tiebreak.** `md5()` of the row's text is stable and cheap:

```sql
ORDER BY <primary>, session_id, md5(txt)
```

Verified on the real corpus: byte-identical output on two consecutive runs.

**The guard survives extra CTE layers**, verified with the full
`blocks → extract txt → compute window → final SELECT` chain and `DSK_KEYWORD=''`:
`Invalid Input Error: DSK_KEYWORD is required`, exit 1 — **provided `ok` is carried through
every intermediate CTE and read in the outermost `WHERE`.**

---

## Requirements

1. **Match on a literal substring, not a `LIKE` pattern.** Replace the `ILIKE` keyword
   predicate in `search.sql` with `strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) > 0`, so
   the match test and the window position are the same computation by construction.

   This is a **deliberate behaviour change**: `_` and `%` in a keyword stop being wildcards.
   Fewer rows will match some keywords, and that is the fix, not a regression.

   Do the same in `sqlresults.sql` for its `result_text` predicate. The
   `NOT ILIKE '%<system-reminder>%'` exclusion is a fixed literal containing no `_` or `%`
   and may stay as it is.
2. **Match-centred snippet** in `search.sql`: replace `left(txt, 500)` with the verified
   window expression. A message shorter than the window returns whole with no markers; a cut
   at the start gets a leading `...`; a cut at the end a trailing `...`; both ends, both
   markers.
3. **Extract the text once.** `json_extract_string(b.c, '$.text')` is currently evaluated
   three times, and requirements 1–2 would add more. Extract it once as `txt` in the
   existing `blocks` CTE and reference it everywhere.

   This touches the `WHERE` clause carrying the `<system-reminder>` exclusion and the
   `$.type = 'text'` filter. **Those two filters are the highest-risk regression in this
   repo** — the original defect the skill was built to fix was that every returned hit was
   an injected `<system-reminder>`. C8 and C9 guard them.
4. **A `chars` column** in `search.sql` giving `length(txt)`, the full untruncated length.
   With the `...` markers this answers "how much did I not see" without arithmetic.
5. **A `matches` column** in both keyword files from `count(*) OVER ()` — the total row
   count **before** the `LIMIT`.
6. **Return the most recent matches**: `search.sql` orders `ts DESC`.

   A second **deliberate behaviour change**. The previous task's non-requirement "do not
   change what any mode returns" is knowingly reversed by this and by requirement 1;
   `docs/tasks/2026-09-22-read-memories-output-noise/SHIPPED.md` states ordering did not
   change, and that statement is now superseded. A verifier should not flag either as a
   violation.
7. **Deterministic ordering** in both keyword files:
   - `search.sql`: `ORDER BY ts DESC, session_id, md5(txt)`
   - `sqlresults.sql`: `ORDER BY session_id, md5(result_text)`

   The guarantee required is **byte-stable output**, not key uniqueness. Duplicate blocks
   genuinely exist — measured: 3 groups of 2 rows tie on `(session_id, md5(result_text))`
   for keyword `the` — but every tied group is identical in all selected columns, so output
   is byte-identical whichever order wins. Rows still tied must be identical in every
   selected column; that is the property to preserve.
8. **Preserve verbatim** — each was a hard-won finding of an earlier task, and a rewrite of
   this region is exactly how one gets silently dropped:
   - `content` read as `JSON`, never an auto-detected struct;
   - both glob depths (`conversations\*.history.jsonl` and
     `conversations\*\*.history.jsonl`) in every history read;
   - explicit `columns = {...}` on every `read_ndjson` / `read_json` call;
   - `tool_result.name LIKE '%sql_execute'` — this one is a **deliberate pattern match on
     the tool name**, not a keyword search, and must keep its `%`. Narrowing it to
     `= 'sql_execute'` recovers 4.8% of history while still returning data, so it fails
     silently;
   - the four-term `ts` coalesce: `user_sent_time`, `assistant_sent_time`, `created_at`,
     `epoch_ms(creationDate)` — the last two cover two different sidecar shapes;
   - the `--here` comparison with **both** `replace()` calls:
     `lower(replace(s.working_directory,'/','\')) = lower(replace(getenv('DSK_CWD'),'/','\'))`.
     Dropping them leaves a check that still passes, because `$PWD.Path` already uses
     backslashes;
   - `$.type = 'text'` plus the `<system-reminder>` exclusion in `search.sql`;
     `$.type = 'tool_result'` in `sqlresults.sql`;
   - `LIMIT 40` in `search.sql`, `LIMIT 20` in `sqlresults.sql` — unchanged. The caps are
     not the problem; the silence about them was.
9. **One statement per file, one terminating semicolon**, including in comment text. A
   `WITH` clause is part of that single statement. A second semicolon-terminated statement
   reintroduces the multi-block output the previous task removed.
10. **Do not weaken the empty-keyword guard.** Both keyword files must still `error()` with a
    non-zero exit on an empty `DSK_KEYWORD`. **DuckDB dead-code-eliminates an unreferenced
    `error()` CTE and it silently never fires** — that trap cost a round already. If
    requirement 3 introduces intermediate CTEs, `ok` must be carried through **every one of
    them** and still referenced in the outermost `WHERE`; a `SELECT t.*` that happens to
    carry it is fine, dropping it at any layer is not.

    Note that with an empty keyword `strpos(txt, '') = 1`, so the window would silently
    degrade to the old prefix behaviour. The guard is the only thing preventing that.
11. **Update `SKILL.md`**: the new `chars` and `matches` columns, the snippet being a
    match-centred window rather than a prefix, newest-first ordering, and that the keyword is
    a **literal** substring (case-insensitive, no wildcards). Frontmatter stays exactly
    `name` and `description`. Keep the behavioural contract: search silently, do not
    narrate, absorb results into the answer rather than dumping logs.
12. **Order of operations**, because getting it wrong fails C12: finish all repo edits →
    commit on your branch → copy to the live plugin → run the checks → write `RESULT-1.md`.
13. **Deploy** to
    `C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\`: copy
    `SKILL.md` and all four `.sql` files, then delete any other `.sql` there. It must end up
    containing exactly `SKILL.md`, `search.sql`, `sqlresults.sql`, `sqlresults-summary.sql`,
    `coverage.sql` — nothing else.

    That directory is a clone of `duckdb/duckdb-skills` which this work does not own. Copy
    files; do **not** commit, stage, or clean there. Its `git status` will show dirty
    afterwards — leave it so, and note in `RESULT-1.md` that the live plugin holds
    branch-only work.

## Non-requirements

- Do **not** touch `sqlresults-summary.sql` or `coverage.sql`. Neither filters on a keyword
  and neither has a `LIMIT`.
- Do **not** change the `LIMIT` values. Report the caps, do not raise them.
- Do **not** add a regex mode, a case-sensitive flag, a wildcard opt-in, or a configurable
  window size. The window is 500 characters starting 120 before the match, fixed.
- Do **not** diagnose the `tool_result.sqldata` mystery (47 raw-text occurrences, 0
  extractable rows). Out of scope for the third task running.
- Do **not** touch the other 8 skills, `.claude-plugin/`, or `.cortex-plugin/`.
- Do **not** create or use `state.sql`. `read-memories` stays outside that convention.
- Do **not** write any file into the repo working tree other than the changed skill files
  and `RESULT-1.md`. Check captures go to `$env:TEMP` (see C6) — a stray capture file in the
  repo root fails C13.
- Do **not** merge to `main` or push. The supervising session does that.
- Do **not** pin a DuckDB version in the skill.

---

## Acceptance checks

Run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills`. `RESULT-1.md` must quote the
**actual console output** of every check. A check not run is a FAIL, not a blank. State
RAN/PASS/FAIL per check.

Checks marked **CONTROL** pass on the untouched repo at `4cb9814`. They are regression
guards — run them, but do not treat passing as evidence of new work, and do not build
anything to satisfy them.

**C1 — every returned snippet contains the keyword**

Two keywords, and the second is the one that matters.

**C1a — `dangling blob`** (the hit that prompted this task):

```
Expected: >= 1 row, and for EVERY row the snippet contains "dangling blob"
case-insensitively. Paste the full output.
Previously session 341528cf-... returned 500 characters about a watchlist button
with the keyword nowhere in view.
```

**C1b — `sql_execute`** (contains `_`, so it exercises requirement 1):

Assert mechanically, not by eye. Report `rows_returned` and `snippet_missing_kw`, where
`snippet_missing_kw` counts rows whose snippet does not contain the keyword:

```
Expected: snippet_missing_kw = 0.
Measured on the OLD file today: 5 rows returned, 1 with snippet_missing_kw — the
wildcard false positive. A result of 0 here proves requirement 1 landed.
Paste the assertion query you used and its output.
A count of rows LOWER than the old file returned is expected and correct: wildcard
false positives are being removed.
```

**C2 — truncation is visible, and its size is knowable**

```
From C1a: at least one row's snippet must begin or end with `...`, and on those rows
`chars` must exceed the snippet length.

Then keyword `the`: at least one row must have NO `...` markers and chars <= 500,
proving short messages are not decorated. Measured today: 38 of 40 rows are
undecorated with chars <= 500, minimum chars 45. Show at least one with its `chars`.
```

**C3 — ASCII markers only**

```
Select-String -Pattern ([char]0x2026) skills\read-memories\*.sql skills\read-memories\SKILL.md
Expected: ZERO matches. This greps the SOURCE, which is authoritative — grepping
captured output can pass spuriously, because a cp1252 capture mangles the character
before the grep sees it.
Paste the command and result. A Unicode ellipsis → FAIL.
```

**C4 — the row cap is now reported**

**C4a — over the cap.** Keyword `the`:

```
Expected: `matches` present, identical on every row, and STRICTLY GREATER than the
number of rows returned. Paste the row count and the `matches` value.
Measured today: 40 rows, matches = 6965.
`matches` equal to the returned row count on this keyword means count(*) OVER () was
placed after the LIMIT → FAIL.
```

**C4b — under the cap.** Keyword `dangling blob`:

```
Expected: `matches` EQUALS the returned row count, and that count is >= 1.
Measured today: 6 rows, matches = 6.
A keyword returning zero rows does not satisfy this — it is vacuously true and
proves nothing.
```

**C5 — newest first**

```
Extract the `ts` column in row order (state how — the snippets contain embedded
newlines, so a naive line split is not row order; wrapping the query and selecting
only ts is the simplest honest method).
Expected: the ts values are non-increasing, and the first row's ts is the maximum of
all returned rows. Paste the first ts, the last ts, and the method.
Ascending → FAIL (requirement 6).
This reversal is intended; the previous task's SHIPPED.md says ordering did not
change and is superseded — do not report it as a violation.
```

**C6 — determinism, drift-tolerant**

Capture to `$env:TEMP\dsk-c6-*.txt`. **Nothing this check writes may land in the repo** —
a stray file fails C13.

Run each keyword file **three times back to back** in one shell.

```
search.sql with keyword `the`:
Expected: all three captures byte-identical after projecting the `matches` column out
(a uniform change to `matches` on every row, with row identity and order unchanged, is
corpus drift, not instability).

If rows differ, the ONLY acceptable difference is: N rows entering at the TOP with a
`ts` newer than the previous capture's first row, AND exactly N rows dropping off the
TAIL, AND no reordering of the rows in between. Under ts DESC with a fixed LIMIT those
two always happen together — a new row at the top necessarily pushes one off the tail,
so a tail deletion alone is not a failure. Quote the delta and continue.
Any other difference — a row appearing or vanishing in the MIDDLE, or the same rows in
a different order — is a FAIL. That is the tie-reshuffle requirement 7 removes.

Then sqlresults.sql the same way.
```

**Before-and-after evidence is required.** Use exactly this, because PowerShell 5.1's `>`
writes UTF-16LE with a BOM and DuckDB then fails with
`Parser Error: syntax error at or near " ■"`:

```powershell
git show 4cb9814:skills/read-memories/search.sql | Set-Content -Encoding ASCII $env:TEMP\dsk-c6-old.sql
```

```
Run the same three-run test against that old file (it needs DSK_KEYWORD and DSK_CWD;
DSK_MODE was removed at that commit, so it runs standalone).
Expected: the old file's three captures DIFFER from each other.
Do not try to match a specific line count — line count is itself the unstable
quantity being measured. Instability is the finding; a number is not.
A new file showing the same instability has fixed nothing.
```

**C7 — CONTROL — one statement per file**

```
Get-ChildItem skills\read-memories\*.sql | ForEach-Object {
  "$($_.Name): $((Select-String -Path $_.FullName -Pattern ';' -AllMatches |
    ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }
Expected: exactly 1 per file, all four. Semicolons in comments count.
Passes at 4cb9814 — this guards against requirement 3's refactor reintroducing a
second statement.
```

**C8 — CONTROL — `<system-reminder>` still excluded (highest-risk regression)**

Keyword `Project Miner`:

```
Expected: >= 1 hit, and ZERO snippets containing "<system-reminder>".
Paste the hit count and the Select-String result.
Before this skill was ported, all 5 hits for this keyword were system-reminders.
Requirement 3 rewrites the very WHERE clause that excludes them, which is why this
control matters more than its passing status suggests.
```

**C9 — the preserve-verbatim list survived, and the extraction happened once**

Paste the matching line(s) for each:

```
Select-String -Pattern "\$\.type"        skills\read-memories\*.sql
Select-String -Pattern "sql_execute"     skills\read-memories\*.sql
Select-String -Pattern "replace"         skills\read-memories\search.sql
Select-String -Pattern "coalesce"        skills\read-memories\search.sql
Select-String -Pattern "history.jsonl"   skills\read-memories\*.sql
Select-String -Pattern "columns = \{"    skills\read-memories\*.sql
Select-String -Pattern "LIMIT"           skills\read-memories\*.sql
```

```
Expected: search.sql filters $.type = 'text'; sqlresults.sql filters 'tool_result';
`LIKE '%sql_execute'` on the TOOL NAME still present and not narrowed; BOTH replace()
calls on the working_directory comparison; the ts coalesce showing ALL FOUR terms
(user_sent_time, assistant_sent_time, created_at, epoch_ms(creationDate)); both glob
depths in every history read; the count of read_ndjson/read_json calls equal to the
count of `columns = {`; LIMIT 40 and LIMIT 20 unchanged.
Any missing item → FAIL, whatever the row-level checks say.
```

Then requirement 3, which nothing else covers:

```
Select-String -Pattern "json_extract_string\(b\.c, '\$\.text'\)" skills\read-memories\search.sql
Expected: at most 1 match — the single extraction. More than one means the text is
still being re-extracted.

Select-String -Pattern "strpos" skills\read-memories\search.sql
Expected: exactly 1 — one position computation feeding both the predicate and the
window. Two means the match test and the window can disagree, which is defect 1.
```

**C10 — CONTROL — the empty-keyword guard still fires**

```
$env:DSK_KEYWORD = '' against search.sql, then sqlresults.sql.
Expected BOTH: clear error naming the missing keyword, non-zero $LASTEXITCODE.
Paste both messages and both exit codes.
Exit 0, or rows returned, → FAIL. The error() is dead-code-eliminated the moment its
`ok` column stops being referenced in the outermost WHERE, and requirement 3
restructures exactly that clause — so this control is load-bearing.

Then coverage.sql and sqlresults-summary.sql with DSK_KEYWORD = '':
Expected BOTH: normal output, exit 0. They must keep ignoring the variable.
```

**C11 — CONTROL — one result block per run, still**

```
For each of the four files, paste the complete unabridged output.
Expected: ONE header line per run. ZERO occurrences of "guard".
No mode's header may appear in another mode's output.
This is what the previous task bought; requirement 3's refactor must not spend it.
```

**C12 — live plugin updated, no stale files**

```
Get-ChildItem C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories |
  Select-Object -ExpandProperty Name
Expected EXACTLY: SKILL.md search.sql sqlresults.sql sqlresults-summary.sql coverage.sql
[CONTROL — the live directory already holds exactly these five; this half guards
against a stale file being added, not against a missing one.]

Then Get-FileHash each against its repo counterpart — all five pairs must match.
[NOT a control — the hashes change with this work. A mismatch means the copy preceded
the last edit, requirement 12.]
Paste the listing and both hashes per file.

Then run C1a's keyword from the LIVE path: one block, and every snippet contains the
keyword.
```

**C13 — blast radius contained**

```
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
Expected: EMPTY output.   [CONTROL]

git diff --stat 4cb9814 -- skills/read-memories
Expected: only search.sql, sqlresults.sql, and SKILL.md listed.
sqlresults-summary.sql or coverage.sql appearing → FAIL (non-requirement 1).

git status --short
Expected: every line is one of `?? TASK.md`, `?? RESULT-1.md`, `?? REVIEW-task-1.md`.
Any other path — especially a C6 capture file — and any M / A / D line, is a FAIL.
Paste the full output.   [CONTROL as to TASK.md; the rest is this round's work]
```

An emptiness expectation on `git status` would be wrong by construction: the task's own
artifacts are untracked. Expecting emptiness is how the equivalent check failed in both
previous tasks.

**C14 — committed before `RESULT-1.md` was written**

```
git log --oneline -1   → your implementation commit.
git status --short     → no M lines (requirement 12).
Paste both.
```

**C15 — `SKILL.md` documents what the skill now does**

```
Get-Content skills\read-memories\SKILL.md -TotalCount 10
Expected: frontmatter exactly `name` and `description`; description names Cortex Code.

Select-String -Pattern "chars","matches","DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
Expected: >= 1 match per pattern; paste the matched lines. The two new columns must be
documented, not merely implemented.

Select-String -Pattern "DSK_MODE" skills\read-memories\SKILL.md skills\read-memories\*.sql
Expected: ZERO matches — DSK_MODE was removed last task and must stay gone.

Plus quote the lines describing: the do-not-narrate contract, the snippet as a
match-centred window, newest-first ordering, and the keyword being a literal
substring with no wildcards (requirement 1 changes what users can expect).
```
