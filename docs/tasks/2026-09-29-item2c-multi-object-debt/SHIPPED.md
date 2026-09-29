# SHIPPED — Clear item 2b's multi-object debt, and two defects found doing it (item 2c)

Shipped 2026-09-29. **Reopens PLAN-4 item 2**, which item 2b's `SHIPPED.md:4` declared closed. Verified
SHIP on round 1: 14 of 14 acceptance checks, 5 of 5 mutation proofs, and all 14 of item 2b's recorded
verdict rows reproduced independently.

Commits: `43e2c40` (fixes + SKILL.md), `4d41739` (header doc), `ff445c0` (RESULT-1), merged as `49290a5`.

## Why this item existed

`docs\tasks\2026-09-24-item2b-snowflake-extract\SHIPPED.md:110` deferred it in as many words:

> **Multi-object extracts are unverified.** Every `extract-decide.ps1` fixture has exactly one
> `source_objects` entry … the first multi-object extract should be treated as untested ground.

Building the first multi-object fixture found the **rule was correct** — nine combinations, all right.
The debt was a testing gap, not a broken rule. But testing it surfaced three problems, two of them in
shipped, verified code.

## What was actually wrong

**D1 — an extract with no source metadata was served indefinitely stale.** When every object returned a
null row count, the tool printed `SKIPPED (source unchanged)`. It had no evidence at all; "I don't know"
was being reported as "nothing changed" — the exact thing `SIDECAR.md:20` and the tool's own header exist
to prevent. Worse, the age ceiling that exists precisely to bound *"we cannot tell"* is tested only inside
the ambiguous branch, so it never fired. Measured on a shipped fixture at **7,811 minutes** against a
1,440 ceiling: still skipped.

`SIDECAR.md:20` names "the object is a view" as a reason a row count is unavailable, so this was reachable
on real data, not a theoretical case.

Now `SKIPPED (no evidence) age=<n>` under the ceiling and `REFRESH (no evidence past ceiling)` beyond it.
`SKIPPED (source unchanged)` keeps its meaning and stays unbounded, because it reflects real evidence.
Verdict list 11 → 13.

**D2 — the documented invocation wrote a PowerShell error to stderr.** `Cannot index into a null array`,
on the ordinary two-call protocol. Non-terminating, so the verdict and exit code were right — which is
exactly why item 2b's fixtures missed it: they checked the verdict and the exit code, and nothing looked
at stderr. Measured **1,408 bytes before, 0 after.**

**D3 — multi-object probes could not be passed at all through the documented path.** PowerShell 5.1
cannot bind more than one value to an array parameter through `powershell -File`: `-CurrentRows 100,200`
arrives as the single string `"100,200"`, and `-CurrentRows 100 200` silently drops the second token.
Single-object worked by accident — one value, one object, the count matched. Elements are now comma-split,
so the array form, the comma-joined form, and the `-File` form all work.

## What deliberately did NOT change

- **`SKIPPED (source unchanged)` stays unbounded.** It means genuinely unaltered, and the tool's header
  argues for that asymmetry explicitly. Only *abstain* became bounded.
- **All 14 of item 2b's recorded verdicts.** Reproduced byte-for-byte, with **no carve-out**. The first
  draft of the spec claimed two rows would legitimately change; review proved otherwise — `g_null_baseline`
  and `m_null_current` both supply a comparable `-CurrentLastAltered`, so stage 2 returns `unchanged` and
  neither reaches the new branch.
- **`tools\make-extract-fixtures.ps1`.** Byte-identical; item 2a's AC10 asserts it.
- **The contracts, the assertion harness, the lakehouse tools, `duckdb-compat.sql`.** Untouched, and items
  3–6 were re-run unregressed: `run-assertions.ps1` still `failures=0`, `gl-facts.sql` still clean,
  `materialize.ps1` still materializes both contracts.
- **No Snowflake.** Entirely fixture-driven, so the verifier certified all 14 checks.

## The mistake this item recorded, because it happened three times running

The spec's first draft reported the stale fixture as *"age 1500 against a ceiling of 1440."* That number
was read from the fixture's **name**, not its output. It was at **7,811** — fixtures are time-stamped at
generation and the shipped tree was days old.

That was the third consecutive spec in which a confident "measured" figure came from a setup nobody
re-checked, after a constant-folded delay (item 6) and a one-row inlining fixture (item 6 again). The
finding survived each time, but the number was invented.

So the spec now opens with a hard convention: **regenerate the fixtures first, state the absolute root,
pass `-ExtractRoot` explicitly on every call, and pin verdict tokens rather than `age=` digits.** That one
rule resolved five of the review's nine blocking defects.

## The fix that would have reproduced the bug

For D2 the first draft authorised "or pass a correctly-typed array of nulls." Review tested it:
`[string[]]::new(1)` passed through an `if` statement **becomes `$null`** — PowerShell enumerates a
single-element array to its element. That fix reproduces the defect exactly.

The shipped fix wraps the whole `if` in `@(...)`, forcing array semantics. Mutation 4 exists solely to
prove it: retyping instead of wrapping brings the stderr back. Note the bug only fires at **one** source
object — at two or more the placeholder survives, so any test using the two-object fixture passes on
broken code.

## Two write-up inaccuracies in `RESULT-1.md`, found by verification

Recorded because they are the kind of thing that erodes trust in a log if left unremarked:

1. The stderr byte counts (1,424 / 1,380) do not reproduce verbatim — 1,408 via native redirection, 333–357
   via `Start-Process`. A capture-method artifact; both agree on non-zero → zero, which is the fact that
   matters.
2. `RESULT-1.md` cites the `2>$null` occurrence at line 205, but on the final tree it is line **216** —
   205 + the 11 lines commit `4d41739` added. So that citation was captured *before* the header fix,
   which contradicts the same file's claim that every check was re-run afterwards. The fact checked
   (count = 1) is correct on the shipped tree.

## Bookkeeping this item invalidates

`PLAN-4:301-303` enumerates **eight** specs, and item 2b's `SHIPPED.md:4` says "Item 2 is now complete and
Track A is done". Both are now wrong: the count is **nine** and item 2 reopened. Recorded here rather than
edited into either file, so the plan chain stays a record of what was believed when.

## Debt carried forward

- **Direction-aware row tolerance** — split out of item 5, still unbuilt.
- **Floors store pass/fail, not the observed ratio** — item 5's harness emits none.
- **A per-object evidence gap, accepted as bounded.** With `source_rows` `[100,null]` and object B's
  `last_altered` moved, the verdict reads `SKIPPED (ambiguous: last_altered moved, rows unchanged)` — where
  "rows unchanged" is true for A and never evaluated for B. Covered by the `two_object_w6` fixture and
  ceiling-bounded, so not indefinite, but the wording overstates its evidence.
- **A view-backed extract with no `last_altered` now refreshes once per ceiling period** instead of never.
  The intended direction, but a real recurring warehouse cost — one refresh per day per affected extract at
  the default ceiling — that nobody has priced.
