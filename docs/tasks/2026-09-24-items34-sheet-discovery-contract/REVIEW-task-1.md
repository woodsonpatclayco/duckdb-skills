# REVIEW — TASK.md (items 3 + 4), round 1

Reviewer: `task-reviewer`. Round 1, on the spec only — no implementer had run.
Verdict at the time: **NOT READY**, six blocking items.

This file records the review because the reviewer reported inline and did not write it. The same
omission was caught in item 2b round 1; recording it here keeps the round-1 record complete.

`PLAN-4.md` was confirmed frozen (named by `docs\tasks\2026-09-24-item2b-snowflake-extract\TASK.md`)
and clean against HEAD — no plan was edited in place.

## What the reviewer independently re-measured

Every headline figure in the draft spec was re-measured against the live workbook and **all were
correct**: the pinned path and byte size, 62,110 rows, the 13 columns in order, the 51,928 / 18,764 /
62,110 non-null floors, both sums, `MAX` cast and lexicographic, the three PLAN-4 corrections, the
26-sheet structure, and `Project_Profit`'s 123 columns / 123 distinct normalized names / 230
non-null newline-header count. Read cost measured 0.86 s against the spec's 0.78 s — ordinary drift.

The reviewer also measured two safety facts the draft had not stated, now recorded in the spec:
`GL_PERIOD` is all-digits in 18,764 of 18,764 non-null rows, and `JOB_COSTS` is castable in 62,110 of
62,110 — which is *why* `::BIGINT` and `::DECIMAL(18,2)` cannot throw.

## Blocking defects, and the fixes applied

**R1 — AC8, the only check with an independent oracle, passed on a wrong answer.** The reviewer
sabotaged the decoder so every `46235` became `46266` — both values already present — leaving min,
max, and non-null count identical while **6,654 of 18,764 dates (35 %) were wrong**. AC8 reported
agreement. Fixed: AC8 now compares row-wise via `EXCEPT ALL` in both directions, both required 0,
with the explicit statement that aggregate agreement is *not* sufficient.

**R2 — Decision 1 could not be executed as written.** The view was never named anywhere in the spec;
"`SELECT <expr>` against the created view" admitted two incompatible readings (scalar subquery vs
`FROM` appended); and "exactly one row" collided with the obvious phrasing of AC7, which returns
62,110 rows un-aggregated. Fixed: the view is `contract_view`, expressions are evaluated verbatim as
`SELECT <expr>;` with no `FROM` appended, assertions carry their own scalar subqueries, NULL is a
FAIL not an error, and the directive grammar is pinned down to leading whitespace and `--@assert`.

**R3 — AC12 was the self-grading check, not AC8.** Its `\.0$` test returned 0 under `all_varchar`
before any contract existed — passing by construction — and under the obvious honest cast it was a
`Binder Error: No function matches ... 'regexp_matches(BIGINT, STRING_LITERAL)'`. Fixed: the
contract must cast `VENDOR_NUMBER` to `BIGINT`, and AC12 became two parts — the declared type is
`BIGINT` (a), and `VENDOR_NUMBER::VARCHAR LIKE '%.0'` is 0 (b) — with (a) named as the part that
actually proves the cast happened.

**R4 — eight of fifteen checks contained no command.** AC5–AC12 stated facts about "the view" with
no view name, no query, and no invocation, so the verifier would have authored its own SQL and
produced numbers not comparable to the implementer's. Fixed: added `checks\gl-facts.sql` as a fourth
deliverable emitting one labelled line per check, and pinned the `duckdb -f` invocation form.

**R5 — the compat macros were unreachable in a clean worktree.** `.gitignore:3` excludes
`.duckdb-skills/`, so the `state.sql` that carries the macros does not exist in a fresh
`git worktree` and every assertion would fail as a `Catalog Error` for reasons unrelated to the work.
Fixed: `check-contract.ps1` must resolve `duckdb-compat.sql` relative to `$PSScriptRoot`, never a
hardcoded absolute path, and **AC0** was added as the check that proves the verifier can run anything
at all.

**R6 — both required headers were missing.** `Plan:` and `Serves:` were absent. Added.

## Non-blocking issues fixed in the same revision

- `-0.000088` is a rounded rendering of `-8.7738037109375e-05` and is **not** reproducible by
  subtracting the two printed decimals. Now stated, with an explicit ban on asserting it by equality.
- Two of the four mutations reached outside scope into shipped `duckdb-compat.sql`. AC7's mutation
  now targets the contract (`GL_PERIOD::TIMESTAMP`).
- The filename-refusal rule had no check and could be omitted while passing 15 of 15. Added **AC16**
  against a purpose-built zip declaring `Q1 Sales (draft)`.
- The newline-header capability works **only** via `duckdb -f`; through `-c` PowerShell truncates the
  argument at the newline and DuckDB reports a parser error. Recorded, since Decision 2 rests on it.
- A fingerprint mismatch was a hard gate, conflicting with the drift policy — and annotation #42
  records two columns being *removed* from a sheet in this same workbook, so append-only is a
  convention, not an invariant. Now drift to report.
- The view re-reads the 68 MB workbook per query: a view plus six aggregates measured 4.29 s, so the
  full run is minutes. Now budgeted, with a `TEMP TABLE` permitted but AC6/AC7 still required against
  the view.
- Guard ordering (parse before creating the view), throwaway-fixture location, the
  `[IO.File]::WriteAllText` rule, and AC15's interpretation as a control were all unstated. Added.
- "Several within 5 %" of the live file's size was an overstatement — measured, one other name.
  Corrected.

## Drift from PLAN-4, now stated in the spec

PLAN-4 §4 framed Decision 2 as `normalize_names = true` *versus* positional selection. The spec
chooses **neither**: exact quoting is a third option, adopted because it is the only one keeping the
header fingerprint byte-traceable to the workbook. The reviewer judged the choice right but the
silent departure wrong; the spec now labels it as a third option explicitly.

`tools\check-contract.ps1` corresponds to no PLAN-4 step — PLAN-4 §5 owns the harness. Kept, because
shipping assertions that have never run is the self-grading failure in a new costume, but now
labelled as deliberate expansion.

## The finding that outlives this item

**PLAN-4 §5's entire acceptance section rests on the two claims this spec disproves.** Its mutation 1
expects a `51,571 → 0` collapse under `ignore_errors=true` (measured: **51,928**, no collapse) and
its mutation 2 expects the `'City of DeKalb'` parse error (measured: **exit 0**). Item 5's stated
reason to exist does not reproduce and needs a new one before it is specced. Now recorded in the
spec's "Out of scope" so the next spec does not burn a round rediscovering it.

## Main-session verification of the review

Because agent reports are not taken at face value, four load-bearing claims were re-checked directly
before the revision was written:

| claim | result |
|---|---|
| `.duckdb-skills/` is gitignored | confirmed — `.gitignore:3` |
| `regexp_matches(BIGINT, ...)` errors | confirmed — Binder Error, candidates are VARCHAR only |
| `all_varchar` already renders `VENDOR_NUMBER` without `.0` | confirmed — `0`, `1`, `10`; `%.0` count = 0 |
| row-wise `EXCEPT ALL` returns 0/0 on the honest decode | confirmed — 0, 0 |
| `GL_PERIOD` all-digits / `JOB_COSTS` castable | confirmed — 18,764/18,764 and 62,110/62,110 |

All five held. The revision was written against them.
