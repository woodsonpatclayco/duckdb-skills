# RESULT-2 — Round-2 corrections: honest fixture, five macros fixed

Branch: `item1-dialect-layer`. Spec: `TASK.md` body + `# CORRECTIONS — round 2`, as revised by
`REVIEW-task-2.md` (12 blocking items, all applied per that review before I started). Commit:
`6bc67ae` (parent `a572feb`). Nothing in the runner's tag-block parsing, stderr handling,
error-class matching, pin assertion, malformed-row rejection, `polyglot_transpile` emission,
`tools\ensure-duckdb-compat.ps1`, or `skills/query/SKILL.md` frontmatter was touched — confirmed
by `git diff --stat` showing only `duckdb-compat.sql`, `duckdb-compat-tests.csv`,
`duckdb-compat.md`, and `run-compat-tests.ps1`.

## What changed

1. **`skills/query/duckdb-compat.sql`** — five macro bodies fixed, verbatim from C1/C6:
   `TO_NUMBER`/`TRY_TO_NUMBER` to `DECIMAL(38,0)`; `DIV0`/`DIV0NULL` cast to `DECIMAL(38,6)`;
   `REGEXP_SUBSTR` returns NULL (not `''`) on no match; `UUID_STRING` cast to `VARCHAR`.
   `TRY_TO_DATE` deliberately left unfixed (documented divergence).
2. **`skills/query/duckdb-compat-tests.csv`** — 50 rows (41 + 9 new), two new columns
   (`source`, `note`). Five rows' `expected_value`/`expected_type` corrected against C7's
   measured table; `DATE_TRUNC str` kept its failing `DATE` expectation per C3.
3. **`tools\run-compat-tests.ps1`** — numeric value comparison (C2), three-way
   verified/deviation/fail split per mode (C4), `polyglot (macros loaded)` header label (C5).
4. **`skills/query/duckdb-compat.md`** — rewritten to match: 50-row table with `source`, the
   `source`/deviation rule, five-macro fix table, updated residuals (8, not 7), extended
   "measured wrong translations" (polyglot's native transpile bypasses the macro for `DIV0`,
   `DIV0NULL`, `TO_NUMBER`, `REGEXP_SUBSTR` — a round-2 finding, see below).

## The 50-row table (source column, measured 2026-09-23, DuckDB v1.5.5 / polyglot `8f1666d`)

| name | raw | macro | polyglot (macros loaded) | source |
|---|---|---|---|---|
| IFF | FAIL | PASS | PASS | snowflake |
| NVL | FAIL | PASS | PASS | snowflake |
| NVL2 | FAIL | PASS | PASS | snowflake |
| IFNULL | PASS | PASS | PASS | snowflake |
| ZEROIFNULL | FAIL | PASS | PASS | snowflake |
| NULLIFZERO | FAIL | PASS | PASS | snowflake |
| DECODE | FAIL | FAIL | PASS | snowflake |
| DIV0 | FAIL | PASS | **FAIL** | deviation |
| QUALIFY | PASS | PASS | PASS | snowflake |
| DATEADD | FAIL | FAIL | FAIL | snowflake |
| DATEDIFF | PASS | PASS | PASS | snowflake |
| DATE_TRUNC str | FAIL | FAIL | FAIL | snowflake |
| TO_VARCHAR | FAIL | PASS | PASS | snowflake |
| TO_CHAR fmt | FAIL | FAIL | FAIL | snowflake |
| TRY_CAST | PASS | PASS | PASS | snowflake |
| TRY_TO_NUMBER | FAIL | PASS | FAIL | snowflake |
| LISTAGG | PASS | PASS | PASS | snowflake |
| LISTAGG WITHIN GROUP | FAIL | FAIL | PASS | snowflake |
| EQUAL_NULL | FAIL | PASS | PASS | snowflake |
| cast ::NUMBER | FAIL | FAIL | PASS | snowflake |
| NUMBER(38,2) | FAIL | FAIL | PASS | snowflake |
| VARCHAR(n) | PASS | PASS | PASS | snowflake |
| ILIKE | PASS | PASS | PASS | snowflake |
| GROUP BY position | PASS | PASS | PASS | snowflake |
| RATIO_TO_REPORT | FAIL | FAIL | FAIL | deviation |
| ARRAY_AGG | PASS | PASS | PASS | deviation |
| OBJECT_CONSTRUCT | FAIL | FAIL | PASS | deviation |
| FLATTEN | FAIL | FAIL | FAIL | deviation |
| CURRENT_TIMESTAMP() | FAIL | FAIL | FAIL | snowflake |
| SPLIT_PART | PASS | PASS | PASS | snowflake |
| REGEXP_SUBSTR | FAIL | PASS | PASS | snowflake |
| POSITION IN | PASS | PASS | PASS | snowflake |
| MEDIAN | PASS | PASS | PASS | deviation |
| PERCENTILE_CONT | PASS | PASS | PASS | deviation |
| TOP n | FAIL | FAIL | PASS | snowflake |
| QUALIFY+PARTITION | PASS | PASS | PASS | snowflake |
| LATERAL FLATTEN | FAIL | FAIL | FAIL | snowflake |
| MINUS | FAIL | FAIL | PASS | snowflake |
| SEQ/UNIFORM | FAIL | FAIL | PASS | snowflake |
| CONCAT_WS | PASS | PASS | PASS | snowflake |
| IS DISTINCT FROM | PASS | PASS | PASS | snowflake |
| DIV0NULL *(new)* | FAIL | PASS | FAIL | deviation |
| TO_NUMBER *(new)* | FAIL | PASS | FAIL | snowflake |
| TRY_TO_DATE serial *(new)* | FAIL | FAIL | FAIL | snowflake |
| TRY_TO_DATE iso *(new)* | FAIL | PASS | PASS | snowflake |
| CHARINDEX *(new)* | FAIL | PASS | PASS | snowflake |
| LEN *(new)* | PASS | PASS | PASS | snowflake |
| UUID_STRING *(new)* | FAIL | PASS | PASS | snowflake |
| REGEXP_SUBSTR no match *(new)* | FAIL | PASS | FAIL | snowflake |
| xl_date *(new)* | FAIL | PASS | PASS | duckdb-native |

## Three-way verified/deviation/fail counts per mode (out of 50)

| mode | pass | verified | deviation | fail |
|---|---|---|---|---|
| raw | 17 | **14** | 3 | 33 |
| macro | 34 | **28** | 6 | 16 |
| polyglot (macros loaded) | 37 | **32** | 5 | 13 |

Residual (no mode reaches, 8 of 50): `DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT,
FLATTEN, CURRENT_TIMESTAMP(), LATERAL FLATTEN, TRY_TO_DATE serial`.

## AC11 — row-by-row reconciliation against `RESULT-1.md`

`RESULT-1.md` recorded, over the original 41 rows: raw pass 16/41, macro pass 26/41, polyglot
pass 33/41, with an explicit per-row PASS/FAIL table. I diffed round 2's per-row result against
that table, row by row, for all 41 original rows. **Exactly one row changed PASS/FAIL status.
Every other difference is a `source` reclassification, not a behaviour change.**

### Raw mode

Pass/fail identical to round 1 (still 16/41 pass; `DATE_TRUNC str` still the only fail among the
17-name baseline, per C3). Reclassified from **verified → deviation** (still passing, just not
counted as Snowflake-sourced): **`ARRAY_AGG`, `MEDIAN`, `PERCENTILE_CONT`** — all three are in
C2's explicit 8-row deviation set. Raw verified over the original 41 = 16 − 3 = **13**.

Adding the new-9 rows: only **`LEN`** passes raw (DuckDB has a native `LEN` alias that already
matches Snowflake, `source=snowflake`), contributing +1 verified. **Raw verified over all 50 =
13 + 1 = 14** — matches the measured total exactly.

### Macro mode

Pass/fail identical to round 1 (still 26/41 pass; same 26 names). Reclassified from
**verified → deviation**: **`DIV0`, `ARRAY_AGG`, `MEDIAN`, `PERCENTILE_CONT`** (4 rows — `DIV0`
newly deviation because its body was fixed this round; the other three per C2's set). Macro
verified over the original 41 = 26 − 4 = **22**.

New-9 rows in macro mode: 8 of 9 pass (`TRY_TO_DATE serial` is the one residual). Of those 8:
`TO_NUMBER`, `TRY_TO_DATE iso`, `CHARINDEX`, `LEN`, `UUID_STRING`, `REGEXP_SUBSTR no match` are
verified (6); `DIV0NULL` and `xl_date` are deviation/duckdb-native (2). **Macro verified over
all 50 = 22 + 6 = 28** — matches. **Macro deviation over all 50 = 4 + 2 = 6** — matches.
**Zero macro regressions**: no row that passed macro in round 1 fails macro in round 2.

### Polyglot mode — one genuine regression, fully attributed

**`DIV0` flips PASS → FAIL.** This is the only pass/fail change among the original 41 rows in
any mode. Root cause, confirmed via `polyglot_transpile`: `polyglot` recognizes `DIV0` by name
and transpiles it to its own native expression
(`CASE WHEN 0 = 0 AND NOT 1 IS NULL THEN 0 ELSE 1 / 0 END`), **bypassing the compat macro
entirely** — even with the macro file loaded. That native expression returns `0.0` typed
`DOUBLE`, which matched round 1's (wrong) expectation but no longer matches the corrected
`0.000000`/`DECIMAL(38,6)` expectation. This is not a runner defect: it is the same class of
flaw already documented for `TRY_TO_NUMBER`, newly exposed because `DIV0`'s expectation is now
honest. Polyglot pass over the original 41 = 33 − 1 = 32.

Reclassified from **verified → deviation** among the 32 remaining passes: `ARRAY_AGG`,
`OBJECT_CONSTRUCT`, `MEDIAN`, `PERCENTILE_CONT` (4 rows). Polyglot verified over the original 41
= 32 − 4 = **28**.

New-9 rows in polyglot mode: 5 of 9 pass (`DIV0NULL`, `TO_NUMBER`, `TRY_TO_DATE serial`,
`REGEXP_SUBSTR no match` fail — the first three because polyglot's native transpile bypasses
the fixed macro the same way it does for `DIV0`; `TRY_TO_DATE serial` is the documented
divergence). Of the 5 passes: `TRY_TO_DATE iso`, `CHARINDEX`, `LEN`, `UUID_STRING` are verified
(4); `xl_date` is duckdb-native (1). **Polyglot verified over all 50 = 28 + 4 = 32** — matches.
**Polyglot deviation over all 50 = 4 + 1 = 5** — matches.

### Every point of difference is attributed; nothing unexplained

| Movement | Rows | Cause |
|---|---|---|
| verified → deviation (raw) | ARRAY_AGG, MEDIAN, PERCENTILE_CONT | C2's explicit deviation set |
| verified → deviation (macro) | DIV0, ARRAY_AGG, MEDIAN, PERCENTILE_CONT | C2's explicit deviation set (DIV0 also newly fixed) |
| verified → deviation (polyglot) | ARRAY_AGG, OBJECT_CONSTRUCT, MEDIAN, PERCENTILE_CONT | C2's explicit deviation set |
| PASS → FAIL (polyglot only) | DIV0 | polyglot's native transpile bypasses the now-corrected macro (measured wrong translation, same class as `TRY_TO_NUMBER`) |
| new rows, verified | TO_NUMBER, TRY_TO_DATE iso, CHARINDEX, LEN, UUID_STRING, REGEXP_SUBSTR no match (macro); TRY_TO_DATE iso, CHARINDEX, LEN, UUID_STRING (polyglot); LEN (raw) | C6's nine new rows, each measured in C7 |
| new rows, deviation | DIV0NULL, xl_date | C2/C6 |
| new rows, residual | TRY_TO_DATE serial | C6's documented divergence, deliberately unfixed |

**Residue that could not be attributed to a named row: none.**

### The one discrepancy against AC11's stated figure — reported, not smoothed over

AC11 states "the one figure derivable in advance... raw verified over the original 41 rows =
**15**", reasoning only from `ARRAY_AGG`'s reclassification (16 − 1 = 15). **Measured actual is
13, not 15** (16 − 3, accounting for `ARRAY_AGG`, `MEDIAN`, **and** `PERCENTILE_CONT`). This is
not a runner or fixture defect: C2's deviation set explicitly names all eight rows —
"`DIV0, DIV0NULL, ARRAY_AGG, OBJECT_CONSTRUCT, MEDIAN, PERCENTILE_CONT, RATIO_TO_REPORT,
FLATTEN`" — and `MEDIAN`/`PERCENTILE_CONT` were both raw-passing in round 1 (they are in
`RESULT-1.md`'s 16-name pass list). AC11's own worked derivation accounted for `ARRAY_AGG` only
and omitted these two from its arithmetic, even though the same paragraph's deviation set
includes them. Per the instruction to report a discrepancy rather than adjust the expectation or
the classification: I implemented C2's deviation set exactly as enumerated (all eight rows,
verbatim), measured the actual result, and report **13** (over the original 41) / **14** (over
the full 50-row fixture) as the correct, internally-consistent figure — fully reconciled above,
with every point of movement named. I did not weaken C2's classification to force alignment
with AC11's pre-stated number.

AC11's qualitative claim — "macro and polyglot verified counts... will be lower than round 1's
26 and 33" — **does hold**, once compared like-for-like over the same 41 rows: macro verified
22 < 26, polyglot verified 28 < 33. (The full-50-row totals, 28 and 32, are higher than 26/33
only because six and four of the nine new rows respectively add verified passes — not a
regression, just a larger fixture.)

## Acceptance checks — verbatim output

**AC1 — macro inventory is 17, `DATEADD` absent.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS n FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name) IN (...)"
n
17
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS dateadd FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name)='DATEADD'"
dateadd
0
```
**PASS.**

**AC2 — `xl_date` returns DATE, not TIMESTAMP.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT xl_date(46204) AS v, typeof(xl_date(46204)) AS t"
v,t
2026-07-01,DATE
```
**PASS.**

**AC3-R2 (supersedes AC3) — TRY_TO_NUMBER/TO_NUMBER scale 0; DIV0/DIV0NULL/REGEXP_SUBSTR/UUID_STRING fixed.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT TRY_TO_NUMBER('12.3') AS v, typeof(TRY_TO_NUMBER('12.3')) AS t, TRY_TO_NUMBER('12.7') AS r, TRY_TO_NUMBER('-12.7') AS rn, TRY_TO_NUMBER('abc') IS NULL AS abc_null, TO_NUMBER('12.3') AS tn"
v,t,r,rn,abc_null,tn
12,"DECIMAL(38,0)",13,-13,true,12

> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT DIV0(1,0) AS a, DIV0(10,4) AS b, typeof(DIV0(10,4)) AS t, DIV0NULL(1,NULL) AS c, REGEXP_SUBSTR('abc123','[0-9]+') AS m, REGEXP_SUBSTR('abc','[0-9]+') IS NULL AS nomatch_null, typeof(UUID_STRING()) AS u, length(UUID_STRING()) AS ulen"
a,b,t,c,m,nomatch_null,u,ulen
0.000000,2.500000,"DECIMAL(38,6)",0.000000,123,true,VARCHAR,36
```
Every value matches its C7 measurement exactly. **PASS.**

**AC4 — delivery is idempotent, BOM-safe, points at the tracked file (4 cases, re-run unchanged).**
- Case 1 (fresh missing `state.sql`): first output line and file content both resolve to
  `skills/query/duckdb-compat.sql`; content is exactly one `.read` line. **PASS.**
- Case 2 (re-run on the same file): `readlines=1`, unchanged. **PASS.**
- Case 3 (existing `ATTACH` line): `.read` inserted first, `ATTACH` line intact, one `.read`.
  ```
  .read C:/Users/woodsonp/Claude/Dev/duckdb-skills/skills/query/duckdb-compat.sql
  ATTACH ':memory:' AS scratch;
  ```
  **PASS.**
- Case 4 (BOM-carrying `state.sql`): `bomBefore=239,187,191` → after run, first bytes
  `46,114,101` (`.re`, i.e. no BOM); `SELECT TO_VARCHAR(1) AS v` returns `1`. **PASS.**

**AC5 — macro resolves via `.read` + real `ATTACH` (AC4 case 3's scratch file).**
```
> duckdb -init .duckdb-skills\ac4\state3.sql -csv -c "SELECT TO_VARCHAR(123) AS v"
v
123
```
**PASS.**

**AC7 — malformed fixture row is rejected, not silently mis-compared.**
```
> tools\run-compat-tests.ps1 -Fixture .duckdb-skills\ac7\bad-fixture.csv -Mode raw
PIN: duckdb=v1.5.5 polyglot=8f1666d
MALFORMED ROW: BAD ROW (mode=raw): expected 1 column, got 2
...
raw pass count: 0 / 1  (verified: 0  deviation: 0  fail: 1)
EXITCODE=1
```
**PASS.**

**AC8 — the `Error`-matching trap is avoided; macro pass count ≥ 20.**
```
macro pass count: 34 / 50  (verified: 28  deviation: 6  fail: 16)
EXITCODE=0
```
34 ≥ 20. **PASS.** Grep of `tools\run-compat-tests.ps1` for the literal string `Error` finds
only: `$ErrorActionPreference` (line 14, unrelated), `Get-ErrorClass` (function name),
`^[A-Za-z ]+Error:` (line 60, the strict class pattern), `$errorClass`/`ErrorClass` (variable
and property names). **No bare-word `Error` match anywhere.** **PASS.**

**AC9 — pin drift fails loudly.**
```
> tools\run-compat-tests.ps1 -ExpectedPolyglotVersion deadbee
PIN: duckdb=v1.5.5 polyglot=8f1666d
PIN DRIFT: expected duckdb=v1.5.5 polyglot=deadbee; actual duckdb=v1.5.5 polyglot=8f1666d
Remedy: re-run the fixture and update the pin and the before/after table in skills/query/duckdb-compat.md.
EXITCODE=1
```
**PASS.**

**AC10 — no row carries an unmarked or unjustified expectation.**
```
> duckdb -csv -c "SELECT source, count(*) AS n FROM read_csv('skills/query/duckdb-compat-tests.csv') GROUP BY 1 ORDER BY 1"
source,n
deviation,8
duckdb-native,1
snowflake,41

> duckdb -csv -c "SELECT name, source, note FROM read_csv('skills/query/duckdb-compat-tests.csv') WHERE source <> 'snowflake' ORDER BY name"
name,source,note
ARRAY_AGG,deviation,"value equal ([1]); Snowflake ARRAY kind vs DuckDB INTEGER[] kind, pre-approved by the type rule"
DIV0,deviation,"value equal (0); Snowflake NUMBER(7,6) precision is input-dependent (e.g. NUMBER(8,6) for DIV0(10,4)) and cannot be reproduced by a static macro; DuckDB DECIMAL(38,6) is the fixed rendering"
DIV0NULL,deviation,"value equal (0); Snowflake NUMBER(7,6) precision is input-dependent and cannot be reproduced by a static macro; DuckDB DECIMAL(38,6) is the fixed rendering"
FLATTEN,deviation,"value equal (1); Snowflake VARIANT kind has no concrete DuckDB counterpart and resolves to the element's concrete type INTEGER; also a residual (Catalog Error) in every mode"
MEDIAN,deviation,"value equal (1); Snowflake NUMBER(4,3) fixed-point kind vs DuckDB DOUBLE floating kind"
OBJECT_CONSTRUCT,deviation,"value equal (the object a=1); Snowflake OBJECT kind vs DuckDB STRUCT kind, pre-approved by the type rule; expected_value uses DuckDB's own struct-literal quoting since the syntax differs by kind, not by content"
PERCENTILE_CONT,deviation,"value equal (1); Snowflake NUMBER(4,3) fixed-point kind vs DuckDB DOUBLE floating kind"
RATIO_TO_REPORT,deviation,"value equal (1); Snowflake NUMBER(7,6) fixed-point kind vs DuckDB DOUBLE floating kind; also a residual (Catalog Error, no DuckDB window aggregate of this name) in every mode"
xl_date,duckdb-native,NULL

> duckdb -csv -c "SELECT count(*) AS unclassified FROM read_csv('skills/query/duckdb-compat-tests.csv') WHERE source IS NULL OR source NOT IN ('snowflake','deviation','duckdb-native') OR (source='deviation' AND (note IS NULL OR note=''))"
unclassified
0
```
Exactly the 8 named deviation rows with non-empty notes, plus `xl_date` as `duckdb-native`;
`unclassified`=0; total 8+1+41=50. **PASS.**

`git diff skills/query/duckdb-compat-tests.csv` (against round 1) shows every row changed
textually (the two new columns were appended to all 41 original rows), but only **five** rows
changed `expected_value`/`expected_type` — verified programmatically by comparing each row's
old vs. new value/type field, not by eyeballing the diff:

| Row | Old → New | Justified by (C7) |
|---|---|---|
| `DIV0` | `0.0`/`DOUBLE` → `0.000000`/`DECIMAL(38,6)` | `DIV0(1,0) \| 0.000000 \| NUMBER(7,6) \| DECIMAL(38,6) (deviation)` |
| `TRY_TO_NUMBER` | `12.300000`/`DECIMAL(38,6)` → `12`/`DECIMAL(38,0)` | `TRY_TO_NUMBER('12.3') \| 12 \| NUMBER(38,0) \| DECIMAL(38,0)` |
| `RATIO_TO_REPORT` | `1.0`/`DOUBLE` → `1.000000`/`DOUBLE` | `RATIO_TO_REPORT(1) OVER () \| 1.000000 \| NUMBER(7,6) \| DOUBLE (deviation)` |
| `MEDIAN` | `1.0`/`DOUBLE` → `1.000`/`DOUBLE` | `MEDIAN(1) \| 1.000 \| NUMBER(4,3) \| DOUBLE (deviation)` |
| `PERCENTILE_CONT` | `1.0`/`DOUBLE` → `1.000`/`DOUBLE` | `PERCENTILE_CONT(0.5) … \| 1.000 \| NUMBER(4,3) \| DOUBLE (deviation)` |

All five are justified by C7 lines, verified by direct comparison (no other row's
`expected_value`/`expected_type` changed). **PASS.**

**AC11 — the three-way split, reconciled row by row.** See the full reconciliation section
above. Summary: three counts per mode sum to 50 (raw 14+3+33, macro 28+6+16, polyglot 32+5+13,
all confirmed by direct arithmetic and by the runner's own printed totals). Every point of
difference from `RESULT-1.md` is attributed to a named row (three `source` reclassifications on
raw, four on macro, four on polyglot, one genuine `DIV0`-polyglot regression, nine new rows each
individually accounted). **The one figure stated in advance (raw verified = 15) does not match
measured reality (13/41, 14/50) — reported above as a discrepancy in AC11's own derivation, not
smoothed over.** No residue is unattributed.

**AC12 — the fixture still catches a wrong answer (mutation test, on scratch copies, tracked
fixture never touched).**

`IFNULL` expected_value mutated to `999`:
```
IFNULL,FAIL
raw pass count: 16 / 50  (verified: 13  deviation: 3  fail: 34)
```
Flips PASS → FAIL. Verified over the 50-row fixture: **14 → 13** (baseline is 14, not the
spec's anticipated 15 — see the AC11 discrepancy above; the *movement* of exactly 1 is what
this check actually verifies, and it holds).

`QUALIFY` expected_type mutated to `VARCHAR`:
```
QUALIFY,FAIL
raw pass count: 16 / 50  (verified: 13  deviation: 3  fail: 34)
```
Also flips PASS → FAIL, same movement (14 → 13). **PASS** on the mechanical claim (mutation
flips the row and reduces verified by exactly 1); the absolute baseline differs from the spec's
anticipated 15/14 for the reason given under AC11. `git diff skills/query/duckdb-compat-tests.csv`
confirms the tracked fixture carries none of these mutations (both were made on
`.duckdb-skills\ac12\*.csv` scratch copies only).

**AC13 — a semantic failure cannot be relabelled into a pass.**

`DATE_TRUNC str` mutated to `source=deviation`, `expected_type=TIMESTAMP`, `note=x`, run
`-Mode all`:
```
DATE_TRUNC str,FAIL,FAIL,FAIL
...
RESIDUAL (no mode reaches, 8 of 50): DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT, FLATTEN, CURRENT_TIMESTAMP(), LATERAL FLATTEN, TRY_TO_DATE serial
```
Still fails in all three modes and still appears in the residual list. **Mechanism: the row
fails on value**, not an explicit runner rejection. Confirmed directly: actual output is
`2026-07-01 00:00:00` typed `TIMESTAMP`; the mutated `expected_value` stays `2026-07-01` (only
`source`/`expected_type`/`note` were mutated per the spec). Neither string parses as a decimal
number, so the comparison falls to an exact string match, and `2026-07-01` ≠
`2026-07-01 00:00:00` — the row fails on value regardless of its `source` label. Relabelling a
row cannot manufacture a pass; only a genuinely matching value can. **PASS.**

## Not done

Nothing in the corrections was skipped. `<project-id>`, the home-side state path, and porting
the bash skills remain out of scope exactly as the frozen body specifies.

## Deviations from the corrections

- **A new, previously-undocumented finding, surfaced by this round's own three-mode run:**
  `polyglot`'s native transpile bypasses the compat macro for `DIV0`, `DIV0NULL`, `TO_NUMBER`,
  and `REGEXP_SUBSTR` (the same class of flaw C7/round-1 already documented for
  `TRY_TO_NUMBER`), confirmed via `polyglot_transpile` and reported in "Measured wrong
  translations" in `duckdb-compat.md`. This was not named in the corrections (which supplied
  `TRY_TO_NUMBER` as the only known instance of this pattern) — I am reporting it rather than
  silently absorbing it into the residual list, since it explains the one genuine regression
  (`DIV0` polyglot PASS → FAIL) that the AC11 reconciliation would otherwise leave unattributed.
- **The AC11/AC12 discrepancy** (anticipated raw verified 15/14, measured 13/12 over the
  original 41, or 14/13 over the full 50-row fixture) is reported above, not corrected away. I
  did not adjust `MEDIAN`/`PERCENTILE_CONT`'s `source` to force alignment with the spec's
  pre-stated figure; C2's explicit deviation set is authoritative and I implemented it exactly
  as enumerated.
- No other deviations. All five macro bodies, the CSV structure, and the runner's counting logic
  match C1/C2/C4/C5/C6 verbatim.

## Concerns

- None new. `RESULT-1.md`'s concerns (BOM handling in scratch/report files, `$ErrorActionPreference`
  behaviour, `ConvertFrom-Csv` single-row bug, `polyglot_transpile`'s scalar calling convention)
  all remain correctly handled — none of that code was touched this round, and this round's own
  runs reproduced consistent output across three independent invocations (`run-all-output.txt`
  ≡ `final-run.txt`, byte-for-byte via `Compare-Object`).
- `TASK.md`, `REVIEW-task-2.md`, `RESULT-1.md`, `VERIFY-1.md`, `PLAN-2.md`, and this file are not
  gitignored (`.gitignore` still only covers `_plan.md`, `_data/`, `.duckdb-skills/`) — correct,
  nothing to flag.
