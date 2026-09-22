# SHIPPED — search output that tells the truth

Date: 2026-09-22 · Branch: `coco-read-memories-snippets` · Implementation commit: `79eaf05`
Verified at `79eaf05` in a disposable worktree. Verdict: **SHIP**, all 15 checks PASS.

Third task against this skill. Predecessors: `docs/tasks/2026-09-22-coco-read-memories/`
(built it), `docs/tasks/2026-09-22-read-memories-output-noise/` (one result block per run).

## The point of it

**Before:** a hit could show 500 characters that did not contain the keyword — and some hits
were not matches at all. Results were capped at 40 with no count of what was dropped, the 40
shown were the **oldest**, and two identical runs returned different rows.

**After:** the snippet is centred on the match, `...` marks either end that was cut, `chars`
gives the true length, `matches` gives the pre-cap total, results are newest-first, and the
same query twice returns the same rows.

Observed in verification: keyword `worktree` → 40 rows, every snippet containing the keyword,
`matches = 204`, correctly signalling 164 hidden.

## What shipped

Changes confined to `search.sql`, `sqlresults.sql`, `SKILL.md`.

| Change | Effect |
|---|---|
| `strpos(...) > 0` replaces `ILIKE` as the keyword predicate | Fixes a correctness bug — see below |
| Match-centred 500-char window, 120 chars of leading context | The keyword is visible in the snippet |
| ASCII `...` markers on any cut end | Truncation is no longer silent |
| `chars` column | Full untruncated length |
| `matches` column via `count(*) OVER ()` | Total matches before the `LIMIT` |
| `ORDER BY ts DESC, session_id, md5(txt)` | Newest first, and deterministic |
| `ORDER BY session_id, md5(result_text)` in `sqlresults.sql` | Deterministic |

## The correctness bug found during spec review

**Underscores in a keyword were silently wildcards.** The predicate was `ILIKE`, where `_`
matches any single character, so keyword `sql_execute` also matched text containing
`sqlXexecute`:

```
('sessionXid ' || repeat('z',600)) ILIKE '%session_id%'   →  true
strpos(lower(...), 'session_id')                          →  0
```

Measured on the old file: **1 of 5 returned rows for `sql_execute` contained no match at
all.** And because the window was positioned with `strpos`, a wildcard-only match returned
position 0 and the snippet fell back to the first 500 characters — the very defect being
fixed.

The first draft of the spec would have **certified this as fixed**, because its only check
used `dangling blob`, a keyword with no underscore. One `strpos` call now serves as both the
predicate and the window position, so they cannot disagree. The verifier confirmed this
structurally and attacked it with five adversarial keyword classes (`_`, `%`, position-1,
end-of-message, real corpus) — all clean.

## Known limitation, deliberately not fixed

**A keyword longer than roughly 380-500 characters can have its own tail truncated out of the
snippet**, even though the match is real. Found by the verifier with synthetic data; no real
keyword in this corpus is that long. Named here rather than left silent. Fixing it would mean
a variable window size, which a non-requirement rules out.

## What deliberately DID change — superseding the previous SHIPPED.md

`docs/tasks/2026-09-22-read-memories-output-noise/SHIPPED.md` states that ordering and
returned rows did not change. **That statement is superseded on two counts**, both intended:

1. **Keywords are now literal substrings.** `_` and `%` no longer act as wildcards. Some
   keywords return fewer rows than before, and those removed rows were false positives.
2. **Results are newest-first.** Previously ascending, which combined with `LIMIT 40` hid
   recent work behind 2026-07 hits.

## What deliberately did NOT change

- **`LIMIT 40` and `LIMIT 20`.** The caps are not the problem; the silence about them was.
  They are now reported via `matches`, not raised.
- **`sqlresults-summary.sql` and `coverage.sql`.** Untouched — neither filters on a keyword
  nor has a `LIMIT`. Verified by `git diff --stat`.
- **`LIKE '%sql_execute'` on the tool name.** That one is a deliberate pattern match, not a
  keyword search, and keeps its `%` so both the legacy and current tool names match.
- **The `<system-reminder>` exclusion and `$.type` filters.** Preserved through a rewrite of
  the exact `WHERE` clause that holds them — the highest-risk regression in this repo.
- **The `tool_result.sqldata` mystery.** 47 raw-text occurrences, 0 extractable rows. Out of
  scope for the third task running.
- **The other 8 skills, `README.md`, `.claude-plugin/`, `.cortex-plugin/`.** Untouched, so
  the fork keeps merging cleanly from `upstream/main`.

## Process notes

- The spec review caught three blockers, two of which would have made an honest implementer
  report FAIL on correct work: a determinism check whose drift rule contradicted its own
  mechanism (under `ts DESC` with a fixed cap, a new row at the top *always* pushes one off
  the tail), and a before/after comparison that could not run at all because PowerShell 5.1's
  `>` writes UTF-16LE with a BOM and DuckDB fails with `Parser Error: syntax error at or
  near " ■"`.
- The requirement the spec itself called highest-risk had **no acceptance check** in the first
  draft. Five other checks already passed before any work began and are now labelled CONTROL.
- The implementer reworded a code comment so it would not inflate a grep-based check. The
  verifier was asked to scrutinise that specifically — editing code to satisfy the measuring
  instrument — and confirmed `strpos` is genuinely called once and the comment is still
  accurate.
