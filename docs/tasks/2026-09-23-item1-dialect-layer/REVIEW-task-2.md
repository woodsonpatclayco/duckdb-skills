# REVIEW ? TASK.md round-2 corrections and the PLAN-1 to PLAN-2 delta

Reviewer: `task-reviewer`. Verdict: **NOT READY** ? twelve blocking items. All applied.

Four were unpassable-as-written checks; the rest were design holes or stale figures.

## Blocking issues found (all fixed)

| # | Issue | Fix applied |
|---|---|---|
| B1 | AC10 required a `DIV0NULL` deviation row that does not exist in the fixture, while pinning the total at 41 ? which forbids adding it. Both halves unsatisfiable. | Nine new fixture rows added (C6), total restated as **50** and used in AC10 and AC11. |
| B2 | **The `deviation` loophole.** `deviation` was defined as ""Snowflake's answer is known but DuckDB cannot reproduce it"" ? which describes `DATE_TRUNC str` exactly. The one row C3 insists must keep failing was, by C2's own definition, eligible to be relabelled into a pass. Same looseness made every `NUMBER(p,0)`-to-`INTEGER` row arguable, so two honest implementers would report verified counts a dozen rows apart. | `deviation` now requires the **value to be equal** and only the type **kind** to differ. Length/precision differences inside one kind stay `snowflake`. A value difference or a semantically wrong type is **never** a deviation. `DATE_TRUNC str` named as the worked counter-example, and **AC13** added as the observable guard. |
| B3 | AC11's ""raw verified = 16"" is arithmetically wrong under C2: `ARRAY_AGG` is one of the 16 raw passes and is now a deviation row, so verified is 15. | Corrected to 15, with the pass-vs-verified distinction stated. |
| B4 | AC11 asked for counts ""lower than 26 and 33"" ? satisfied by 25 or by 4. Not checkable by Phil or by a verifier. | Replaced with a row-by-row reconciliation against RESULT-1's per-row verdicts; every point of difference must be attributable to a named row, residue reported as an unexplained gap. |
| B5 | AC10 was an instruction to an agent, not a runnable command. | Three literal `duckdb -csv -c` commands with literal expected output, plus a fixture-diff requirement tying every changed expectation to a measurement. |
| B6 | C2 ordered a live 41-row Snowflake audit while the frozen body lists ""any Snowflake connection"" as out of scope ? and never said who holds the connection. The implementer's Snowflake access is unverified, so the instruction was potentially unexecutable, in the round whose entire cause was a bad inherited expectation. | **C7 added: the main session measured all 41 constructs on CLAYCO-DATAHUB with `SYSTEM()` and pasted the table into the spec.** The implementer reconciles against facts rather than obtaining them. The out-of-scope bullet is explicitly superseded for expectations only. |
| B7 | AC6 left dangling with its retired `macro >= 28` / `polyglot >= 36` figures, guaranteeing a second PARTIAL against a baseline the corrections themselves invalidate. | AC6 explicitly superseded by AC11; the derived figures retired by name. |
| B8 | ""Reach value correctness at scale 6 **if you can**"" is not an instruction, and silently implied a macro rewrite. | Concrete verified macro bodies for `DIV0`/`DIV0NULL` given, with the measured reason the outer cast is required (DuckDB's `/` always yields DOUBLE). |
| B9 | `note` was required but never declared as a column; the column count was stated three different ways. | Both `source` and `note` declared, full header given, `duckdb-compat.md` note corrected to three extra columns. |
| B10 | **C2 audits the fixture, not the macros ? and seven of 17 shipped macros have no fixture row.** Three carried real defects: `REGEXP_SUBSTR` returns `''` where Snowflake returns NULL; `UUID_STRING` returns type `UUID` not VARCHAR; `TRY_TO_DATE` diverges on all-digit strings. | C6 added. All three confirmed on Snowflake and all three fixes verified in DuckDB. Nine fixture rows added so no shipped macro is untested. |
| B11 | PLAN-2's item 1 acceptance still read ""pass count rises from 17, zero regressions among the original 17"" ? contradicting PLAN-2's own newly added `date_trunc` fact, the same plan-figure-propagation that caused round 2. | Corrected to a baseline of 16 with by-name reconciliation. The 17/28/36 facts now carry the corrected 16/26/33 beside them. |
| B12 | `<project-id>` is closed and correct, but `git rev-parse --show-toplevel` returns the **worktree** root in a linked worktree ? and verification runs in a worktree. Any check pinning the literal string passes for the implementer and fails for the verifier. | Worktree behaviour stated, pinning the literal forbidden, UNC edge closed, and an item 2 acceptance bullet added since the definition had nothing checking it. |

## Non-blocking (applied)

Runner ""parsing"" disambiguated to ""tag-block parsing"" since C4 does change what the runner reads;
AC12 now names the same rows VERIFY-1 used and the expected movement; PLAN-2's Risks section gained
the seeded-macro risk and the `TRY_TO_DATE` divergence; the new Shared-conventions rule scoped to
Snowflake semantics so it does not reach item 4's workbook figures; `MEDIAN`, `PERCENTILE_CONT`,
`SEQ/UNIFORM` and `CURRENT_TIMESTAMP()` pre-classified so the implementer does not have to guess.

Also added beyond the review: **numeric value comparison.** Snowflake's `MEDIAN(1)` renders
`1.000` against DuckDB's `1.0` ? the same number. Under a strict string compare the only way to
pass would be to copy DuckDB's rendering, which is the defect this round removes. Values that parse as
decimal on both sides now compare numerically; types stay an exact string match.

## What the review said to keep

C1's scale-0 change (it independently verified the rounding risk: DuckDB is half-away-from-zero on both
the string and DOUBLE paths, matching Snowflake); AC3-R2 as the model check; **C3's refusal to weaken
`DATE_TRUNC str`**, called the most important judgment in the section; keeping the runner, delivery
script and loading mechanics untouched; C4's three-way split as the right mechanism; naming C1 a spec
defect rather than an implementation defect; and the PLAN-2 banner format.

It also confirmed VERIFY-1 coverage is complete ? every finding addressed or declined with a reason.

## Scope

The reviewer warned round 2 was near its limit and recommended deferring most of C6. I kept it whole
because the expensive part was the Snowflake measurement, which is now done and pasted in C7 ? adding
nine CSV rows against a measured table is mechanical, and leaving seven macros untested is the exact
defect class this round exists to close.

## One caveat carried forward

The reviewer flagged `TRY_TO_DATE`'s Snowflake behaviour as recalled rather than measured. It was then
measured: `TRY_TO_DATE('46204')` returns `1970-01-01` on Snowflake. The reviewer was right.
