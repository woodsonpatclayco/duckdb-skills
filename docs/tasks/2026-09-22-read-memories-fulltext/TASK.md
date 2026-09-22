# TASK — retrieve the part of a message the snippet cut off

Plan: none (single self-contained task; no multi-task plan exists)

Serves: **"do you remember what we decided about X?"** — the fourth and final task on this
skill. Search now tells you honestly that it hid something: a hit reports `chars: 4200`
beside a 500-character snippet. But there is no way to read the other 3,700 characters, so
`chars` currently means *"there is text you cannot reach."* After this task, any hit can be
opened in full.

After this task: nothing further is planned for `read-memories`.

---

## Context

`skills/read-memories/` holds four single-statement SQL files (`search.sql`,
`sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql`) plus `SKILL.md`.

This task **adds a fifth SQL file** and adds **one column** to `search.sql`. Changes are
confined to `search.sql`, the new `message.sql`, and `SKILL.md`.

Repo: `C:\Users\woodsonp\Claude\Dev\duckdb-skills`, `main` at **`8634580`**, pushed to
`origin` (`woodsonpatclayco/duckdb-skills`). `upstream` = `duckdb/duckdb-skills`. Create a
branch.

**Scope: `skills/read-memories/` only.** The other 8 skills must keep merging cleanly from
`upstream/main`. `README.md` may be touched **only** if a requirement makes a specific line
wrong; name the line in `RESULT-1.md` first.

Environment: Windows, PowerShell 5.1. DuckDB CLI v1.5.5.

---

## The corpus grows while you work — read before quoting any count

Every Cortex Code session, including yours, appends to these logs. Counts here are **floors,
not equalities**. Above a stated number is drift — quote the actual figure and continue.
Below it is a real failure. The one exception is D2, which asserts an exact length on an
existing immutable block.

Current floors: **8,506** clean text blocks, **403** log files.

---

## The gap

`search.sql` returns a 500-character match-centred window plus `chars`, the full length. For
a long message you can see that text was cut and how much — but not what it said. No file in
the skill returns untruncated conversation text: `sqlresults.sql` returns tool results, and
the other two return counts. Reading a full message today means hand-writing a DuckDB query
against the log path, which is the thing the skill exists to avoid.

---

## The retrieval key — measured, do not re-litigate

### `(session_id, ts)` is NOT a key

The obvious choice fails badly. Measured over clean text blocks under `search.sql`'s exact
block filters:

| Key | Distinct values | Over 8,506 blocks |
|---|---|---|
| `session_id` + `user_sent_time` | **451** | useless |
| `md5(txt)` | 8,472 | 34 exact-duplicate texts |
| `left(md5(txt), 8)` | **8,472** | **zero prefix collisions** |
| `session_id` + `left(md5(txt), 8)` | 8,497 | 9 duplicates |

`(session_id, ts)` collapses to 451 values because roughly half of all rows carry no
timestamp, and the display `ts` is then derived from a session-level sidecar field shared by
every row in that session.

### The key is `left(md5(txt), 8)`, optionally scoped by session

`md5(txt)` is **already computed** — `search.sql`'s deterministic tiebreak is
`ORDER BY ts DESC, w.session_id, md5(w.txt)`, which the previous task requires be preserved.

An 8-hex-character prefix had **zero collisions** across 8,472 distinct texts, so it is short
enough to read and paste.

**The residual duplicates are harmless by construction, and this was tested directly:** the
count of `left(md5(txt),8)` keys mapping to more than one *distinct text* is **0**, globally
and per session. 8 duplicate groups exist, at most 3 rows each, and every row in a group has
identical text. This is the same argument that makes the ordering tiebreak byte-stable.

### One id can legitimately span several sessions

**19 keys occur in more than one session** — worst case `8bbc2d2f`, 5 rows across 4 sessions.
The `txt` is identical; `session_id`, `ts`, and `title` differ. That is real, intended output,
not a bug to collapse — see requirement 4.

### The id space of the two files must be identical

`message.sql` must apply **exactly the same block filters** as `search.sql`
(`$.type = 'text'`, `<system-reminder>` excluded). If they disagree, an id minted by search
can resolve to a different message — a silent wrong answer, worse than no answer.

### Worst case is 40,396 characters, and `-csv` carries it losslessly

Measured largest clean text block: **exactly 40,396 characters, 427 newlines, 196 double
quotes** (`id = c443c766`, session `3b5ff798-b435-4c1c-8159-254ecaddde27`). Captured with
`cmd /c ... >` and re-read with `read_csv`, it round-trips at `chars = 40396`,
`length(txt) = 40396`, `newlines = 427`. **`-csv` is lossless on this field**, so requirement
7's "no paging" is correct.

**The capture method matters — see the warning below the Requirements.**

---

## Requirements

1. **Add an `id` column to `search.sql`** as the **first** column, ahead of `session_id`:

   ```sql
   left(md5(w.txt), 8) AS id
   ```

   Leave `ORDER BY ts DESC, w.session_id, md5(w.txt)` **byte-identical**. Two textual
   occurrences of `md5(w.txt)` are expected and correct — "the same expression" means the
   same function on the same argument, not a single call site.

   Do **not** restructure the CTE chain to hoist `md5` into an earlier CTE, and do **not**
   change the `ORDER BY` to reference the `id` alias (a prefix and a full hash order
   differently, and requirement 10 freezes that line).
2. **Ship `skills/read-memories/message.sql`**, returning the **complete untruncated text** of
   the addressed message(s). No window, no `left()`, no ellipsis markers, no `LIMIT`.

   Columns, in exactly this order:

   ```
   id, session_id, ts, role, title, chars, txt
   ```

   `ts`, `role`, and `title` are derived exactly as `search.sql` derives them — including the
   four-term `ts` coalesce and a **`LEFT JOIN`** to the sidecar, so a message in a session
   with no sidecar still returns with a NULL `title`.

   `ORDER BY ts DESC, session_id`. An `ORDER BY` is not a `LIMIT`; requirement 7 does not
   forbid it. Deterministic ordering matters for the same reason it did in the previous task —
   unordered multi-row output is the defect that file deliberately left alone in
   `sqlresults.sql`, and shipping it again in a new file would be a regression by repetition.
   `md5(txt)` is not a useful tiebreak here, since every returned row has identical text.
3. **Address by two environment variables:**
   - `DSK_MSG` — the 8-character id. **Required**; `error()` with a non-zero exit if empty.
   - `DSK_SESSION` — the session id. **Optional**; empty means "every session".

   `DSK_KEYWORD` and `DSK_CWD` are **not** used by `message.sql` and must be ignored by it.

   **Match the id as `lower(trim(getenv('DSK_MSG')))` against `left(md5(txt), 8)`** —
   case-insensitive, surrounding whitespace ignored. `md5()` emits lowercase hex, so an id
   pasted from a terminal that upper-cased it would otherwise silently return "no such
   message" for a message that exists (verified: `DSK_MSG='C443C766'` returns zero rows
   today). A value that is not 8 hex characters simply matches nothing — do **not** add
   format validation.
4. **With `DSK_SESSION` empty, return every row sharing the id**, one per occurrence, in the
   order requirement 2 specifies. Their `txt` is identical by construction; `session_id`,
   `ts`, and `title` will differ, and that attribution is the useful part. Do **not**
   `DISTINCT` them away.
5. **Identical block filters to `search.sql`**: `$.type = 'text'`, `<system-reminder>`
   excluded. This is a correctness requirement, not tidiness — see the id-space section.
6. **An unknown id returns zero rows and exits 0.** Not an error: an id that has aged out or
   was mistyped is an ordinary empty result, and a non-zero exit there would be
   indistinguishable from a real failure.
7. **No paging, no truncation, no character cap.** A `(session_id, id)` pair addresses at most
   a handful of identical rows, and the measured worst case is one 40 KB field — large but
   bounded, and `-csv` carries it losslessly. Do not add an offset, a page size, or a cap.
8. **One statement per file, one terminating semicolon** — in `message.sql` too, including in
   comment text. A `WITH` clause is part of the single statement.
9. **The `error()` guard must actually fire.** DuckDB dead-code-eliminates an unreferenced
   `error()` CTE and the guard then silently never runs — this cost a round on an earlier
   task. The guard's `ok` column must be carried through **every** intermediate CTE and read
   in the outermost `WHERE`.
10. **Preserve everything else in `search.sql`.** Requirement 1 touches its `SELECT` list,
    which sits beside filters hardened across three tasks. Preserve:
    - `strpos` computed **exactly once**, serving both the keyword predicate (`> 0`) and the
      window position — two calls, or an `ILIKE` predicate, reintroduces the wildcard bug
      where `sql_execute` matched text lacking the keyword;
    - the match-centred 500-char window with ASCII `...` markers, and `chars`;
    - `matches` from `count(*) OVER ()` — the pre-`LIMIT` total;
    - `ORDER BY ts DESC, w.session_id, md5(w.txt)`, and `LIMIT 40`;
    - `$.type = 'text'` and the `<system-reminder>` exclusion;
    - both glob depths, explicit `columns = {...}` on every read, the four-term `ts` coalesce
      (`user_sent_time`, `assistant_sent_time`, `created_at`, `epoch_ms(creationDate)`), and
      both `replace()` calls in the `--here` comparison;
    - the empty-`DSK_KEYWORD` guard.
11. **Update `SKILL.md`:** the new `id` column and how it is derived, `message.sql` in the
    file table, the `DSK_MSG` / `DSK_SESSION` contract including case-insensitive matching,
    the multi-session output shape, and the user-facing invocation.

    Also state the measured worst case concretely — **40,396 characters, roughly 10,000
    tokens** — so the size is a number rather than an adjective.

    Frontmatter stays exactly `name` and `description`.
12. **Carry the behavioural instruction in `SKILL.md` prose**: when a snippet is truncated and
    the cut portion matters, retrieve the full message and **summarise it — never print a
    40 KB message back to the user.** This is the existing do-not-dump-logs contract applied
    to a file built to return bulk text.

    This requirement is **documentation, not enforceable behaviour**. No check can prove a
    future agent obeys it; the only verification is D13 quoting the line. Stated here so that
    limit is explicit rather than assumed.
13. **User-facing invocation.** Extend the documented form, in the style already used:
    ```
    /duckdb-skills:read-memories <keyword> [--here]
    /duckdb-skills:read-memories --full <id>
    ```
    `<id>` is the 8-character value from the `id` column of a previous search.
14. **Order of operations**, because getting it wrong fails D11: finish all repo edits →
    commit on your branch → copy to the live plugin → run the checks → write `RESULT-1.md`.
15. **Deploy** to
    `C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\`: copy
    `SKILL.md` and all **five** `.sql` files, then delete any other `.sql` there. It must end
    up containing exactly `SKILL.md`, `search.sql`, `message.sql`, `sqlresults.sql`,
    `sqlresults-summary.sql`, `coverage.sql`.

    That directory is a clone of `duckdb/duckdb-skills` which this work does not own. Copy
    files; do **not** commit, stage, or clean there. Its `git status` will show dirty — leave
    it so, and note in `RESULT-1.md` that the live plugin holds branch-only work.

## Non-requirements

- Do **not** touch `sqlresults.sql`, `sqlresults-summary.sql`, or `coverage.sql`.
- Do **not** add paging, an offset, or a character cap to `message.sql` (requirement 7).
- Do **not** make `message.sql` searchable — it addresses by id. Keyword search exists.
- Do **not** lengthen or shorten the 8-character id. Zero collisions across 8,472 texts.
- Do **not** change `search.sql`'s window size, `LIMIT`, ordering, or predicate. Only the
  `SELECT` list gains a column.
- Do **not** diagnose the `tool_result.sqldata` mystery (47 raw-text occurrences, 0
  extractable rows). Out of scope for the fourth task running.
- Do **not** touch the other 8 skills, `.claude-plugin/`, or `.cortex-plugin/`.
- Do **not** create or use `state.sql`.
- Do **not** write any file into the repo working tree other than the changed skill files and
  `RESULT-1.md`. Captures go to `$env:TEMP` — a stray file in the repo fails D10.
- Do **not** merge to `main` or push. The supervising session does that.
- Do **not** pin a DuckDB version in the skill.

---

## How to capture output — read this before running any check

Several checks compare a captured field against an exact length. **Do not pipe DuckDB output
through PowerShell into a file.** PowerShell 5.1 rewrites LF as CRLF, which inflates
`length(txt)` by one per newline: measured on `c443c766`, a true 40,396-character field
re-reads as **41,046** after a PowerShell capture — a 650-character phantom difference that
looks exactly like a truncation bug in reverse.

Use `cmd` redirection:

```powershell
cmd /c "duckdb -csv -f ""<abs path>\skills\read-memories\message.sql"" > ""%TEMP%\cap.csv"""
```

Then assert **inside DuckDB** by re-reading the capture with `read_csv(..., header = true)`,
not by measuring strings in PowerShell. This is the same class of defect as the UTF-16 BOM
trap recorded in the previous task's process notes; a `Select-String` or `.Contains()`
comparison on captured CSV fails for encoding reasons rather than correctness ones.

**A `Select-String` that throws an error is a FAIL, not zero matches.** Pass multiple paths
comma-joined to `-Path`, never as positional arguments:

```powershell
Select-String -Pattern "X" -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql
```

---

## Acceptance checks

Run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills`. `RESULT-1.md` must quote the **actual
console output** of every check. A check not run is a FAIL, not a blank. State RAN/PASS/FAIL
per check.

Checks marked **CONTROL** pass on the untouched repo at `8634580` — regression guards, not
evidence of new work. Run them; build nothing to satisfy them.

**D1 — the round trip works, end to end (the whole point)**

The check that proves the gap is closed. Assert in SQL, not by eye.

```
1. Run search.sql with keyword `dangling blob`. Pick a row whose snippet carries a
   `...` marker — one that WAS truncated. Record its id, session_id, chars, ts, role,
   title.
2. Run message.sql with DSK_MSG = that id, DSK_SESSION = that session_id.
   Capture both runs with the cmd /c form above.
3. Re-read both captures in DuckDB and assert:
   - exactly one row returned, or if more, count(DISTINCT txt) = 1;
   - message.sql's `chars` EQUALS the `chars` search reported;
   - length(txt) EQUALS that same `chars` — no truncation anywhere;
   - the snippet, with its markers stripped, appears in txt:
       SELECT position(
         regexp_replace(regexp_replace(s.snippet,'^\.\.\.',''),'\.\.\.$','') IN m.txt
       ) AS pos
     Expect pos > 0. Paste the value.
   - txt contains the keyword.
Paste the id, both chars values, and every assertion result.
A returned txt of length 500, or equal to the snippet length, means the window leaked
into message.sql → FAIL.
```

**D2 — the largest message retrieves whole**

The measured worst case, where a truncation or encoding limit would surface:

```
DSK_MSG = 'c443c766', DSK_SESSION = '3b5ff798-b435-4c1c-8159-254ecaddde27'
Expected: one row; chars = 40396 EXACTLY; length(txt) = 40396; newline count = 427;
exit 0.
This is an exact assertion, not a floor — the corpus cannot lengthen an existing block.
Capture with cmd /c and measure inside DuckDB (see the capture warning). A PowerShell
capture reports 41046 and will read as a failure on correct work.
Paste chars, length(txt), the newline count, and the first and last 100 characters of
txt — the tail is what a truncation bug silently drops.
If this id has aged out, say so, then repeat against the current longest clean text
block and show how you found it.
```

**D3 — the id is stable, and derived from the ordering expression**

```
Run search.sql with keyword `dangling blob` three times (capture to $env:TEMP).
Expected: the id column is identical across all three runs for the same rows.
An id that changes between runs cannot be a handle → FAIL.

Select-String -Pattern "md5" -Path skills\read-memories\search.sql
Expected: EXACTLY two matching lines — one `left(md5(w.txt), 8) AS id` in the SELECT
list, one `md5(w.txt)` in the ORDER BY, both on `w.txt`. Paste both lines.
Fewer than two, or an md5 on a different argument, → FAIL (requirement 1).
```

**D4 — the two files agree on the id space**

Not a pair of hand-written queries — that would prove only that their author is
self-consistent. Exercise the shipped code paths.

```
1. Run search.sql with keyword `the` (40 rows). Feed EVERY returned (id, session_id)
   pair to message.sql. Each must return >= 1 row whose `chars` equals the `chars`
   search reported for that pair.
   Report `pairs_tested` and `pairs_unresolved`. Expect pairs_unresolved = 0.
   Any unresolved pair means the filters disagree → FAIL.
2. Paste the $.type and <system-reminder> filter lines from BOTH files side by side and
   state that they are character-identical apart from the table alias.
3. Separately report distinct (session_id, left(md5(txt),8)) over clean blocks; expect
   >= 8497. Label this a corpus measurement, not an equality test.
```

**D5 — lookup edge cases**

```
a. Unknown id: DSK_MSG = 'zzzzzzzz', DSK_SESSION = ''
   Expected: ZERO rows, $LASTEXITCODE = 0, no binder error, no stack trace.
   A non-zero exit → FAIL (requirement 6) — indistinguishable from a real failure.

b. Uppercase id: DSK_MSG = 'C443C766', DSK_SESSION = ''
   Expected: the same row D2 returns. Zero rows → FAIL (requirement 3's case-folding).

c. Multi-session id: DSK_MSG = '8bbc2d2f', DSK_SESSION = ''
   Expected: >= 2 rows spanning >= 2 distinct session_id, all with identical txt and
   equal chars. Report count(*), count(DISTINCT session_id), count(DISTINCT txt).
   count(DISTINCT txt) must be 1. One row only → the rows were DISTINCTed away → FAIL
   (requirement 4).
```

**D6 — the guard fires on an empty id**

```
DSK_MSG = '' against message.sql.
Expected: a clear error naming the missing variable, non-zero $LASTEXITCODE.
Paste the message and the exit code.
Exit 0, or rows returned, → FAIL. The error() is dead-code-eliminated the moment its
`ok` column stops being referenced in the outermost WHERE (requirement 9), so this is
load-bearing.

Then message.sql with DSK_MSG set and DSK_KEYWORD / DSK_CWD set to junk values:
Expected: normal output, exit 0 — message.sql must ignore both (requirement 3).
```

**D7 — one statement per file, all five**

```
Get-ChildItem skills\read-memories\*.sql | ForEach-Object {
  "$($_.Name): $((Select-String -Path $_.FullName -Pattern ';' -AllMatches |
    ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)" }
Expected: exactly 1 per file, five files. Semicolons in comments count.
```

**D8 — CONTROL — `search.sql` did not regress**

Requirement 1 edits its `SELECT` list, beside filters hardened over three tasks.

```
a. Keyword `Project Miner`: >= 1 hit, ZERO snippets containing "<system-reminder>".
b. Keyword `sql_execute`: every snippet contains the keyword. Report
   `snippet_missing_kw`; expect 0. (`_` is a LIKE wildcard, so an ILIKE predicate
   returns rows lacking the keyword.)
c. Keyword `the`: `matches` present, uniform on every row, strictly greater than rows
   returned.
d. `ts` non-increasing down the output (state your extraction method).
e. Select-String -Pattern "strpos" -Path skills\read-memories\search.sql → exactly 1.
f. Select-String -Pattern "coalesce" -Path skills\read-memories\search.sql → the ts
   coalesce showing ALL FOUR terms.
g. Select-String -Pattern "replace" -Path skills\read-memories\search.sql → BOTH
   replace() calls on the working_directory comparison.
h. Select-String -Pattern "LIMIT" -Path skills\read-memories\*.sql → LIMIT 40 and
   LIMIT 20 unchanged; message.sql has NO LIMIT.
Paste each. Any failure → FAIL regardless of D1.
```

**D9 — one result block per run, all five files**

```
Paste the complete unabridged output of each of the five files (for message.sql use
D1's id; you may truncate only the txt field in what you paste — say that you did).
Expected: ONE header line per run. ZERO occurrences of "guard".
No file's header may appear in another file's output.
```

**D10 — blast radius contained**

```
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
Expected: EMPTY output.   [CONTROL]

git diff --stat 8634580 -- skills/read-memories
Expected: only search.sql, message.sql, and SKILL.md listed.
sqlresults.sql, sqlresults-summary.sql, or coverage.sql appearing → FAIL.

git status --short
Expected: every line is one of `?? TASK.md`, `?? RESULT-1.md`, `?? REVIEW-task-1.md`.
Any other path — especially a stray capture file — and any M / A / D line, is a FAIL.
```

An emptiness expectation on `git status` would be wrong by construction: the task's own
artifacts are untracked. Expecting emptiness is how the equivalent check failed in the two
earliest tasks on this skill.

**D11 — committed before `RESULT-1.md` was written**

```
git log --oneline -1   → your implementation commit.
git status --short     → no M lines (requirement 14).
```

**D12 — live plugin updated, no stale files**

```
Get-ChildItem C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories |
  Select-Object -ExpandProperty Name
Expected EXACTLY six names: SKILL.md search.sql message.sql sqlresults.sql
sqlresults-summary.sql coverage.sql

Then Get-FileHash each against its repo counterpart — all six pairs must match.
A mismatch means the copy preceded the last edit (requirement 14).

Then run D1's round trip entirely from the LIVE path and paste it.
```

**D13 — ASCII only, and `SKILL.md` documents the new capability**

Note the comma-joined `-Path` form. Passing two paths positionally **throws**, and a throwing
`Select-String` produces no matching lines — which reads as "ZERO matches → PASS" from a
command that never grepped anything.

```
Select-String -Pattern ([char]0x2026) -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql
Expected: ZERO matches, and no error. Grep the SOURCE — a cp1252 capture mangles the
character before a grep of captured output can see it.

Select-String -Pattern "DSK_MODE" -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql
Expected: ZERO matches, and no error — DSK_MODE was removed two tasks ago.

Get-Content skills\read-memories\SKILL.md -TotalCount 10
Expected: frontmatter exactly `name` and `description`; description names Cortex Code.

Select-String -Pattern "DSK_MSG","DSK_SESSION","message.sql","--full","left\(md5","40,396" skills\read-memories\SKILL.md
Expected: >= 1 match per pattern; paste the matched lines.
Do NOT use a bare `\bid\b` pattern to prove the id column is documented — it already
matches `<session-id>.json` on the untouched file and therefore cannot fail.
Instead quote: the line naming the `id` column and its `left(md5(txt), 8)` derivation,
and the line stating that `--full` takes that id.

Plus quote the lines carrying: the do-not-narrate contract, and requirement 12's
instruction to summarise a retrieved message rather than print it.
```

**D14 — `message.sql`'s column contract**

Requirement 2's columns are otherwise unguarded: a `message.sql` that omits `title`, or
derives `ts` from a two-term coalesce, passes every other check.

```
Header line must read EXACTLY: id,session_id,ts,role,title,chars,txt

For D1's row, message.sql's `ts`, `role`, and `title` must equal the values search.sql
reported for the same row. Paste both sets.

Select-String -Pattern "coalesce" -Path skills\read-memories\message.sql
Expected: the same four-term ts coalesce as search.sql — user_sent_time,
assistant_sent_time, created_at, epoch_ms(creationDate). Paste the line.

Select-String -Pattern "LEFT JOIN" -Path skills\read-memories\message.sql
Expected: >= 1 match — the sidecar join must be a LEFT JOIN so a message in a session
with no sidecar still returns, with a NULL title. An inner join silently drops those
messages.
```
