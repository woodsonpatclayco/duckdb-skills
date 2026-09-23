# VERIFY-1 — independent verification of RESULT-1.md

Verifier: `verifier`, run in a disposable `git worktree` at
`C:\Users\woodsonp\Claude\Dev\_verify-item1`, commit `b0df642`. Live tree confirmed unchanged
afterwards (`HEAD` = `b0df642`, `git status` empty), worktree removed. The two mutation tests were
performed on copies under `$env:TEMP`, not on the worktree fixture.

## Verdict: DO NOT SHIP

Not for craftsmanship — every mechanical claim in `RESULT-1.md` reproduced exactly. For fixture
**content**: two rows assert what the macro produces as if it were Snowflake's answer, which is the
one thing this deliverable exists to stop.

## Acceptance checks, re-run independently

| Check | Observed | Verdict |
|---|---|---|
| AC1 | `n`=17, `dateadd`=0 | PASS |
| AC2 | `2026-07-01,DATE` | PASS |
| AC3 | `12.300000,"DECIMAL(38,6)",true` | PASS mechanically — **expectation itself wrong**, see below |
| AC4 ×4 | created / `identical=True readlines=1` / `.read` first with `ATTACH` intact / `bomBefore=239,187,191` → `bomAfter=46,114,101`, query returns `1` | PASS |
| AC5 | `123` | PASS |
| AC6 | raw 16, macro 26, polyglot 33, exit 0, PIN correct, residuals match, `REGRESSION: none` | PARTIAL — table **row-for-row identical** to the claim; no number inflated |
| AC7 | `MALFORMED ROW: BAD ROW (mode=raw): expected 1 column, got 2`, exit 1 | PASS |
| AC8 | macro 26 ≥ 20; only `^[A-Za-z ]+Error:` present | PASS |
| AC9 | `PIN DRIFT: expected ... polyglot=deadbee; actual ... 8f1666d`, exit 1 | PASS |

## Fixture integrity audit — the finding that blocks the ship

37 of 41 rows carry independently defensible Snowflake semantics. Four are reverse-engineered from
DuckDB's observed output:

| Row | Assessment |
|---|---|
| **`TRY_TO_NUMBER`** | **Real defect.** Expectation `12.300000` / `DECIMAL(38,6)` is the macro's own hard-coded cast asserted as ground truth. Snowflake's default is `NUMBER(38,0)`. False PASS in macro mode. Also baked into `TASK.md`'s own AC3, so it is a spec defect, not only an implementation one. |
| **`DIV0`** | **Real defect.** Expectation `0.0` / `DOUBLE` is DuckDB's `/` behaviour on two integers, not Snowflake's fixed-point result. False PASS in macro and polyglot. The implementer flagged this one honestly in its Deviations section. |
| **`ARRAY_AGG`** | Harmless. Type mismatch pre-approved by the spec; `[1]` is unambiguous. |
| **`OBJECT_CONSTRUCT`** | Harmless. Type mismatch pre-approved; differs from Snowflake only in quote style. |

Net effect: at least 2 of 26 macro passes and 1 of 33 polyglot passes are false positives.

## Confirmed against a live Snowflake connection (main session, after the verifier reported)

The verifier argued both defects from knowledge of Snowflake. Both were then checked on
CLAYCO-DATAHUB, and both are correct:

| Expression | Snowflake value | Snowflake type |
|---|---|---|
| `TRY_TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` |
| `TRY_TO_NUMBER('abc')` | `NULL` | — |
| `TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` |
| `DIV0(1,0)` | `0.000000` | `NUMBER(7,6)` |
| `DIV0(10,4)` | `2.500000` | `NUMBER(8,6)` |
| `DATE_TRUNC('month', DATE '2026-07-15')` | `2026-07-01` | `DATE` |

Rounding is half-away-from-zero: `12.3`→`12`, `12.7`→`13`, `-12.7`→`-13`, `12.5`→`13`, `''`→`NULL`,
`'1e3'`→`1000`.

**The fix for `TO_NUMBER`/`TRY_TO_NUMBER` is a scale change from 6 to 0**, and DuckDB then matches
Snowflake on all seven cases exactly — verified: `TRY_CAST(x AS DECIMAL(38,0))` returns
`12, 13, -13, 13, NULL, NULL, 1000` with `typeof` = `DECIMAL(38,0)`.

**`DIV0`'s exact type is not reproducible** — Snowflake's result precision varies with input
precision (`NUMBER(7,6)` vs `NUMBER(8,6)`), which a DuckDB macro cannot see. Value correctness at
scale 6 is reachable; the precision digit is not.

## The nine targeted checks

1. **`DATE_TRUNC str` finding — all four claims true.** DuckDB returns `TIMESTAMP` from a `DATE`
   input for `month`, `year`, `day` and `week`; polyglot's transpile is a literal pass-through hitting
   the same function; not macro-fixable. Snowflake returns `DATE` — independently confirmed above. The
   finding is real and correctly diagnosed.
2. **Mutation test — comparison is live.** A wrong `expected_value` on `IFNULL` and a wrong
   `expected_type` on `QUALIFY` each flipped PASS→FAIL, raw 16→15.
3. **No bare-word `Error` match** (only `^[A-Za-z ]+Error:`, line 60); `2>$errFile` at lines 33, 114,
   208, no `2>&1` anywhere.
4. **`LOAD polyglot;` issued first in polyglot mode** (line 94) and the macro file loaded in polyglot
   mode too (lines 107-110).
5. **`SKILL.md` frontmatter untouched** — diff is 21 lines added, 0 removed, entirely after the
   closing `---`.
6. **No BOM** — `duckdb-compat.sql` starts `45,45,32`; `duckdb-compat-tests.csv` starts `34,110,97`.
7. **17 macros, `DATEADD` absent, `xl_date` → DATE.**
8. **Residuals spot-checked 4 of 7** (`FLATTEN`, `DATEADD`, `TO_CHAR fmt`, `CURRENT_TIMESTAMP()`) —
   all match the claimed root causes. `CURRENT_TIMESTAMP()` fails because DuckDB treats it as a
   keyword, not a callable function.
9. **One overstatement:** the implementer caveated `DIV0` as reasoned judgment but applied no such
   caveat to `TRY_TO_NUMBER`, the same class of issue and the larger practical error.

## Non-blocking

The runner's console header prints `polyglot`, not `polyglot (macros loaded)` as the spec asks. The
required label is present in `duckdb-compat.md` and `RESULT-1.md`. Cosmetic.

## Blocking reason, restated

`TASK.md` exists to replace an error-only probe with one that compares values and types. Two rows do
the opposite. Correct `TO_NUMBER`/`TRY_TO_NUMBER` to scale 0, and either make `DIV0` value-correct at
scale 6 or mark it — as `ARRAY_AGG` and `OBJECT_CONSTRUCT` already are — as a deliberate,
documented deviation rather than a silent pass.
