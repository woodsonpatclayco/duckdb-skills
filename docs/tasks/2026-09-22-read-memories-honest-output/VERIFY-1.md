# VERIFY-1 — independent verification of RESULT-1.md

Verified `RESULT-1.md` (round 1), commit `79eaf05`, from a disposable git worktree at
`C:\Users\woodsonp\Claude\Dev\_verify-snip` (detached HEAD, no branch). Never touched
`C:\Users\woodsonp\Claude\Dev\duckdb-skills`. No destructive git command was run anywhere.
All scratch files went to `$env:TEMP\v-*`. `git status --short` at the end of this session
is unchanged from the start: `?? RESULT-1.md` only.

## Overall verdict: SHIP, with one disclosed limitation that should be named, not hidden

The core fix (requirement 1 — one `strpos` call feeding both the predicate and the window)
is real and structurally sound for every keyword length that occurs in practice. I found one
genuine, mechanically-reproduced edge case where the fixed 500-char/120-before window can
truncate an unusually long keyword out of the visible snippet even though the match is real
(see Finding 1 below). It does not affect any acceptance-check keyword and is not a regression
of anything the previous file did (the old file had the same structural exposure, just hidden
behind a bug that made it irrelevant). I recommend shipping and naming this as a known
limitation in `SKILL.md` or a follow-up note, not blocking on it.

---

## Per-check results

| Check | Expected | My result | PASS/FAIL |
|---|---|---|---|
| C1a `dangling blob` | ≥1 row, every snippet contains keyword | 9 rows, missing=0 | PASS |
| C1b `sql_execute` | snippet_missing_kw = 0 | 7 rows, missing=0 | PASS |
| C2 truncation visible | ≥1 decorated row (chars > shown), ≥1 undecorated ≤500 | 8 decorated (chars up to 1870 vs snippet ~510-514 chars shown), 32 undecorated ≤500, min 61 | PASS |
| C3 ASCII markers only | zero U+2026 in source | zero matches | PASS |
| C4a keyword `the`, over cap | matches strictly > row count | 40 rows, matches=7027 | PASS |
| C4b keyword `dangling blob`, under cap | matches == row count, ≥1 | 9 rows, matches=9; independently recomputed count = 9 | PASS |
| C5 newest first | ts non-increasing, first=max | first=2026-09-22 16:53:29.008, last=2026-09-22 16:35:27.266, non_increasing=True | PASS |
| C6 new-file determinism, search.sql | 3 runs byte-identical | 0 diff (1v2), 0 diff (2v3) | PASS |
| C6 new-file determinism, sqlresults.sql | 3 runs byte-identical | 0 diff (1v2), 0 diff (2v3) | PASS |
| C6 old-file instability control (4cb9814) | 3 runs differ | line counts 117/118/117; diffs 21/19/6 lines | PASS |
| C7 one statement per file | exactly 1 `;` per file, all 4 | coverage=1, search=1, sqlresults-summary=1, sqlresults=1 | PASS |
| C8 `<system-reminder>` excluded | ≥1 hit, zero `<system-reminder>` in output | 19 hits, 0 matches | PASS |
| C9 preserve-verbatim list | all listed items present, unchanged | all present (see detail below) | PASS |
| C9 single-extraction / single-strpos | `$.text` extracted exactly once; `strpos` exactly once in search.sql | 1 and 1 | PASS |
| C10 empty-keyword guard | search.sql & sqlresults.sql error, exit 1; coverage.sql & sqlresults-summary.sql ignore it, exit 0 | both error with `DSK_KEYWORD is required`, exit 1; both others ran normally, exit 0 | PASS |
| C11 one block per run, no leaked mode markers | one header per file; no structural "guard" leak | one header each; the single "guard" hit found is real matched conversation text about this very task, not a structural leak (see note below) | PASS |
| C12 live plugin — file listing | exactly 5 named files | exactly 5 | PASS |
| C12 live plugin — hashes | all 5 match repo | all 5 SHA-256 match | PASS |
| C12 live plugin — live search | 1 block, snippet contains keyword | 9 rows, missing=0 | PASS |
| C13 blast radius — upstream control | empty diff | empty | PASS |
| C13 blast radius — since 4cb9814 | only search.sql/sqlresults.sql/SKILL.md | exactly those 3, `sqlresults-summary.sql`/`coverage.sql` untouched | PASS |
| C13 git status | only task artifacts untracked, no M/A/D | `?? RESULT-1.md` only (TASK.md/REVIEW-task-1.md already committed at 68fc9fc) | PASS |
| C14 committed before RESULT-1.md | HEAD = implementation commit, no M lines | `79eaf05`, clean | PASS |
| C15 SKILL.md documentation | frontmatter, all 6 patterns ≥1, DSK_MODE = 0, behavioural-contract lines present | frontmatter exact; chars=1, matches=4, DSK_KEYWORD=6, DSK_CWD=4, `duckdb -csv -f`=1, invocation string=1; DSK_MODE=0; all 4 contract lines present verbatim | PASS |

**All 15 checks (with sub-parts) PASS**, matching RESULT-1.md's claim of all-PASS with no FAILs.

---

## Finding 1 — the core fix (requirement 1) is structurally sound; one adversarial edge case in the window, not the predicate

Read `search.sql` directly: `strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) AS p` appears
exactly once, in the `windowed` CTE (line 74). `positioned` derives `win_start` from that same
`w.p` (line 78), and the final `WHERE w.p > 0` (line 96) reads the same `p` again through the
CTE chain. There is only one position computed, so the match predicate and the window start
cannot mathematically disagree about *whether* something matched — requirement 1 is satisfied
by construction, not just by convention.

I then attacked it with the five adversarial keyword classes requested:

| Case | Keyword | Result |
|---|---|---|
| Underscore, real substring only | `foo_bar` in text also containing `fooXbar` | p correctly finds only the real `foo_bar`; snippet contains it |
| Literal `%` | `50%off` | matched literally, no wildcard expansion; snippet contains it |
| Keyword at position 1 | `needle` at start of a 74-char message | win_start=1, snippet contains it, no leading `...` |
| Keyword appearing once at the very end of a 600-char message | `zzzendmarker` at position 589 | win_start=469, snippet=`...xxx...zzzendmarker`, contains it |
| Real corpus: `sql_execute`, `session_id`-shaped keywords | via C1b | 7/7 rows contain keyword, 0 missing |

All five passed — the keyword always appears in the snippet for realistic keyword lengths.

**But** I went further than the five classes and tested the literal instruction "a keyword
longer than the 500-char window," using a synthetic DuckDB query with the file's exact
formula (not the corpus, since no real keyword is that long):

```sql
-- E: 520-char keyword, matches at position 1
kw = repeat('Q',520), txt = repeat('Q',520) || ' trailing context...'
p=1, win_start=1, snippet = substr(txt,1,500) + '...'   -- only 500 of the 520 Q's
kw_pos_in_snippet = strpos(lower(snippet), lower(kw)) = 0   -- keyword NOT in snippet
```

and a more realistic variant — a 400-character keyword (still unusually long, but not
absurd — a searched sentence or exact quote) matched **away from the start** of the message:

```sql
-- F: 400-char keyword matched at position 200 (win_start = 200-120 = 80)
kw = repeat('K',400), txt = repeat('a',199) || repeat('K',400) || repeat('b',50)
p=200, win_start=80, chars=649
kw_pos_in_snippet = strpos(lower(snippet), lower(kw)) = 0   -- last part of keyword cut off
```

Both mechanically confirmed: `kw_pos_in_snippet=0` — the snippet does **not** contain the
full keyword. The general shape of the exposure: the window is fixed at 500 chars with only
120 chars of leading context, so it can show at most `500 - min(p-1, 120)` characters of
anything starting at the match — any keyword longer than that (which for `p > 120` is a fixed
380 characters) will have its tail truncated out of the visible snippet, even though `chars`
and `matches` remain correct and the row is a genuine hit.

This is a real, spec-anticipated edge case, not a false alarm — the task brief explicitly
asked me to test this exact scenario for a reason. It does **not** fail any numbered
acceptance check: C1a and C1b both use short, realistic keywords and both pass cleanly, and
nothing in TASK.md's five defects or eleven requirements specifies behavior for
keywords longer than the window. It is a genuine gap in the "every snippet contains the
keyword" guarantee for an unrealistic-but-not-impossible input (a 400+ character search
string), not a defect in the predicate/window agreement requirement 1 was written to fix.
Recommend noting it as a known limitation rather than treating it as a blocking regression.

## Finding 2 — the disclosed rewording is genuine and not misleading

(a) `strpos` appears **exactly once** in `search.sql` (line 74, in the `windowed` CTE) —
confirmed by direct grep, and by reading the full 101-line file myself. There is no hidden
second call; the CTE that reads `w.p` in `positioned` and the final `WHERE` both reference
the *same* computed column, they do not recompute `strpos`.

(b) The reworded comment (search.sql lines 29-33):

> "The snippet is a match-centred window, not a prefix: it starts 120 chars before the match
> and covers 500 chars, with a leading/trailing "..." when text was cut on that side. `chars`
> reports the full untruncated length so "how much did I not see" needs no arithmetic.
> `matches` reports the total row count before LIMIT, so the 40-row cap is visible rather
> than silent."

This is accurate and complete as a description of the code's behavior — it just avoids
naming the implementation function `strpos`. It does not overstate, omit, or misrepresent
anything a future reader would need (window size, leading offset, cut markers, `chars`,
`matches`). Judgment: **not misleading**. Editing prose to avoid inflating a token-count grep
is a defensible, disclosed choice as long as the prose stays true — which it does here. I'd
flag it if the comment had, say, dropped mention of `chars`/`matches` to dodge some other
grep; it didn't.

## Finding 3 — the guard survives both new CTE layers

Verified by reading the CTE chain (`kw_guard.ok` → `blocks.ok` → `texted.ok` via explicit
select → `windowed` via `t.*` → `positioned` via `w.*` → outer `WHERE w.ok = 1`, line 94) and
by direct test: empty `DSK_KEYWORD` against **both** `search.sql` and `sqlresults.sql` errors
with `Invalid Input Error: DSK_KEYWORD is required` and exit code 1 for both. `coverage.sql`
and `sqlresults-summary.sql` ignore the empty variable and exit 0 as required. Matches
RESULT-1's claim exactly.

## Finding 4 — C6 determinism reproduces exactly as claimed

New `search.sql`: 3 runs, keyword `the`, byte-identical (`Compare-Object` empty both times).
New `sqlresults.sql`: same, byte-identical. Old file at `4cb9814`: line counts 117/118/117
across 3 runs (RESULT-1 reported 120/120/113 — different numbers, same phenomenon: unstable,
non-monotonic line counts under an unmodified file with a fixed keyword, which is the drift
signature the check is designed to catch). `Compare-Object` deltas of 21/19/6 lines confirm
real reshuffling, not corpus growth (line count went up then down, ruling out simple
append-only drift). New file showed **zero** instability under the identical test.

## Finding 5 — C4's `matches` value independently cross-checked, not trusted on the report's word

For `dangling blob`, I ran a separate hand-written query replicating the file's filter logic
(guard, `$.type='text'`, `strpos>0`, `NOT ILIKE '%<system-reminder>%'`) but without the
window/ORDER/LIMIT machinery, and got `independent_count=9` — exactly equal to the `matches`
column value reported by `search.sql` itself. `matches` is genuinely computed before `LIMIT`.

## Finding 6 — the one "guard" grep hit in C11 is real content, not a leak

`Select-String -Pattern "guard"` over the C11 capture files returns exactly one hit, inside a
`search.sql` row for keyword `dangling blob` whose *matched text* literally quotes a past
session discussing "empty-keyword guard" (this very task's own subject matter, now itself
logged and searchable). It is not the internal `kw_guard` CTE name leaking into the CSV
header or format — the header lines themselves (`session_id,ts,role,...` etc.) contain no
such string in any of the four files' first lines. Not a violation of what C11 is actually
guarding against.

---

## Discrepancies between RESULT-1.md and my own run

None that matter. All numeric differences (row counts, `matches` values, corpus totals,
timestamps) are consistent with the stated corpus-growth floor rule — every one of my numbers
is ≥ RESULT-1's, as expected for a corpus that keeps growing while both sessions worked in it
(RESULT-1 measured 409/1187/1040 log/blocks/with-rows; I measured coverage.sql=413 and
sqlresults-summary.sql=1187/1040 — the extra 4 files are exactly the kind of drift the
spec anticipates, likely from this verification session's own logging plus RESULT-1's).
No check that RESULT-1 claimed PASS failed for me, and no check I ran found a regression
RESULT-1 missed — the one thing I found beyond RESULT-1's own checks (Finding 1, the
long-keyword window truncation) is outside the literal acceptance checks and was found by
going further than C1a/C1b's specific keywords, exactly as the verification brief asked.

---

## Honest-output assessment (beyond the checks)

Ran keyword `worktree` — a term I'd genuinely want session recall on:

```
rows=40
missing=0
matches_value=204
```

Every one of the 40 returned rows mechanically contains "worktree" (case-insensitive) in its
snippet. The raw output is dated (`ts` newest-first, e.g. `2026-09-22 16:35:27.266` at top),
attributed (`session_id`, `title` per row), and honest about scale: `matches=204` on every
row tells the reader immediately that 164 hits were not shown, without needing arithmetic on
`chars`. Several rows show visible `...` truncation with a `chars` value far exceeding the
displayed excerpt (e.g. a `chars=11734` row truncated to its first ~500-character window)
so it's clear text was cut versus complete. A reader — including a non-programmer — can look
at any row and answer "did I see the whole thing" from the `chars` column and the `...`
markers alone, and can answer "did I see everything that matched" from `matches` alone.

That is the point of this task, and it is achieved. The one thing that could still mislead:
if `chars` for a matched row happens to be well over 500 but the match itself falls inside
the shown window, the snippet still looks "cut" (leading/trailing `...`) even though the
*relevant* part is fully visible — that's expected and documented ("the marker means text
existed before this window, not strictly longer than window", per RESULT-1's own C2 note),
not a defect, but worth knowing so a reader doesn't assume `...` always means "more of the
match is hidden."
