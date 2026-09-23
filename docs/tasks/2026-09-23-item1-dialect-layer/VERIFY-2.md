# VERIFY-2 — independent verification of RESULT-2.md

Verifier: `verifier`, in a disposable `git worktree` at
`C:\Users\woodsonp\Claude\Dev\_verify-item1-r2`, commit `b345298`. Live tree confirmed unchanged
(`HEAD` = `b345298`, `git status` clean before and after); worktree removed. Mutation tests were run
on copies under `.duckdb-skills\` and `$env:TEMP`; the tracked fixture was confirmed untouched after
each (`git diff --stat` empty every time).

## Verdict: SHIP

All thirteen acceptance-check groups pass with output byte-identical to `RESULT-2.md`'s claims.

| Check | Observed | Verdict |
|---|---|---|
| AC1 | `n`=17, `dateadd`=0 | PASS |
| AC2 | `2026-07-01,DATE` | PASS |
| AC3-R2 | `12,"DECIMAL(38,0)",13,-13,true,12` then `0.000000,2.500000,"DECIMAL(38,6)",0.000000,123,true,VARCHAR,36` | PASS |
| AC4 ×4 | created / `identical=True readlines=1` / `.read` first with `ATTACH` intact / BOM `239,187,191`→`46,114,101`, query returns `1` | PASS |
| AC5 | `123` | PASS |
| AC7 | `MALFORMED ROW: BAD ROW (mode=raw): expected 1 column, got 2`, exit 1 | PASS |
| AC8 | macro 34/50 (verified 28); only `^[A-Za-z ]+Error:` | PASS |
| AC9 | `PIN DRIFT ... polyglot=deadbee; actual ... 8f1666d`, exit 1 | PASS |
| AC10 | `deviation`=8, `duckdb-native`=1, `snowflake`=41, total 50, `unclassified`=0 | PASS |
| AC11 | raw 14/3/33, macro 28/6/16, polyglot 32/5/13 — table row-for-row identical to the claim | PASS |
| AC12 | `IFNULL` value mutation and `QUALIFY` type mutation each flip PASS→FAIL, verified 14→13 | PASS |
| AC13 | `DATE_TRUNC str` still `FAIL,FAIL,FAIL` and still in the residual list after relabelling to `deviation`/`TIMESTAMP` | PASS |

## The round's central integrity risk did not materialise

`deviation` as an escape hatch: **all 8 deviation rows plus the 1 `duckdb-native` row meet C2's
rule** — value equal, only type kind differing, each justified by a C7 measurement. And it is not
merely prose: `run-compat-tests.ps1:223-226` sets `Category='fail'` unconditionally unless the row
passes, so a `deviation`-labelled row that fails is counted as **fail**, never as deviation.
`RATIO_TO_REPORT` and `FLATTEN` are the live proof — both labelled `deviation`, both `FAIL,FAIL,FAIL`,
neither inflating a count.

**The converse also checks out.** All 41 `source=snowflake` rows were walked by hand against C7:
**zero mismatches.** `DATE_TRUNC str` kept `2026-07-01`/`DATE` per C3. `TRY_TO_DATE serial` kept
`1970-01-01`/`DATE` per C6 — the genuine divergence was not weakened. Exactly five rows changed their
expectation from round 1 (`DIV0`, `TRY_TO_NUMBER`, `RATIO_TO_REPORT`, `MEDIAN`, `PERCENTILE_CONT`),
each reconciled against C7 by direct CSV diff.

## The polyglot bypass — confirmed, and larger than the spec knew

`RESULT-2.md`'s claim is correct and the verifier reproduced it: polyglot rewrites four macro names
natively and bypasses the compat macros. Measured again in the main session with
`polyglot_transpile`, which pins the mechanism exactly:

| wrapped call | polyglot's rewrite | wrong how |
|---|---|---|
| `TO_VARCHAR(123)` | *unchanged* | not affected — this is why "macros compose" looked true |
| `TO_NUMBER('12.3')` | `CAST('12.3' AS DOUBLE)` | `12.3`, not `12` |
| `TRY_TO_NUMBER('12.3')` | `CAST('12.3' AS DOUBLE)` | same, and `'abc'` errors instead of NULL |
| `DIV0(1,0)` | native `CASE ... 1 / 0 ...` | `DOUBLE`, not fixed-point |
| `DIV0NULL(1,NULL)` | native `CASE ...` | same |
| `REGEXP_SUBSTR('abc','[0-9]+')` | `REGEXP_EXTRACT(...)` | `''` on no match, not NULL |

So a macro composes inside `polyglot_query` **only** for a name polyglot does not itself translate.
That is a materially different rule from the one round 1 shipped.

**The verifier flagged the consequence as a documentation gap**: `duckdb-compat.md` documented it but
`SKILL.md` still named only two wrong translations and still claimed macros compose inside the
wrapper. Fixed in the main session after the verdict, since it is the file future sessions read:
`SKILL.md` now carries the bypass table, the instruction not to route those five through polyglot, and
what polyglot *should* be used for. Frontmatter still untouched (21 lines added, 5 removed, body
only); fixture counts re-run unchanged afterwards.

## The AC11 arithmetic — the spec was wrong, the implementer was right

The corrections anticipated raw verified = 15. Actual is 13 over the original 41, 14 over 50. The
verifier reconciled independently against `RESULT-1.md`'s per-row table: that 16-name raw-pass list
contains `MEDIAN` and `PERCENTILE_CONT` as well as `ARRAY_AGG`, and C2's deviation set names all
three, so `16 − 3 = 13`. `REVIEW-task-2.md`'s own B3 fix corrected only `ARRAY_AGG` and inherited the
same omission. The implementer implemented C2 as enumerated rather than adjusting a classification to
hit the anticipated number — the correct call, and exactly the behaviour the round was designed to
produce.

## "What must not change" held

`git diff a572feb b345298 -- tools\ensure-duckdb-compat.ps1` is **empty**. The runner diff
(`b0df642 → 6bc67ae`) contains exactly `Get-ModeLabel`, `Test-ValueMatch` and the categorisation —
tag-block parsing, `2>$errFile`, the strict error-class pattern, pin assertion, malformed-row
rejection and `polyglot_transpile` emission are byte-identical. `SKILL.md` frontmatter untouched
against `e0f6194`. No `<project-id>` derivation and no home-side branch: `ensure-duckdb-compat.ps1`
still resolves project-local only, with an informational `$HOME` note.

## Numeric comparison is bounded, not a loophole

`Test-ValueMatch` extracted and run standalone: `1.000` vs `1.0` → True; `1.0` vs `2.0` → **False**;
`abc` vs `ABC` → False; `2026-07-01` vs `2026-07-01 00:00:00` → **False** (neither parses as decimal,
so exact string compare holds — which is precisely why AC13 fails on value). Type comparison uses
`-ceq` and is untouched by any numeric logic.

## Other checks

No BOM: `duckdb-compat.sql` starts `45,45,32`; `duckdb-compat-tests.csv` starts `34,110,97`. Fixture
is 50 rows. Residual list is 8 of 50: `DATEADD`, `DATE_TRUNC str`, `TO_CHAR fmt`, `RATIO_TO_REPORT`,
`FLATTEN`, `CURRENT_TIMESTAMP()`, `LATERAL FLATTEN`, `TRY_TO_DATE serial`.

## Nothing unreproducible, no round-1 defect reintroduced

Every verbatim output block in `RESULT-2.md` reproduced exactly, including the AC11 reconciliation
arithmetic, checked against `RESULT-1.md` rather than taken on trust.
