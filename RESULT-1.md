# RESULT-1 — Dialect layer: macro file, polyglot routing, correctness fixture

Branch: `item1-dialect-layer`. Spec: `TASK.md` (round 1, post-review). All eleven
`REVIEW-task-1.md` fixes were read and respected; none were reintroduced.

## What was built

1. **`skills/query/duckdb-compat.sql`** — 17 macros: the seed's 16 (excludes `DATEADD`) plus
   `xl_date(serial)`. BOM-free.
2. **`tools\ensure-duckdb-compat.ps1`** — idempotent `.read` delivery into `state.sql`.
   Project-local default (`<repo root>\.duckdb-skills\state.sql`), `-StateFile` override,
   BOM stripping, home-side `NOTE:` line, first-line-always-the-resolved-path.
3. **`skills/query/duckdb-compat-tests.csv`** — 41-row fixture, columns
   `name, sql, expected_value, expected_type, check_mode`, adapted from
   `.duckdb-skills/dialect-probe.ps1` to the one-row/one-column contract.
4. **`tools\run-compat-tests.ps1`** — three-mode (`raw|macro|polyglot|all`) runner: tag-block
   parsing via `ConvertFrom-Csv`, `2>$errFile` stderr capture, error-class matching
   (`^[A-Za-z ]+Error:`, never the bare word), pin assertion with `PIN DRIFT` exit, malformed-row
   rejection, `polyglot_transpile` output written for every polyglot-mode row.
5. **`skills/query/duckdb-compat.md`** — before/after table, raw-set reconciliation, residual
   list, pins, routing rule, type rule, deferred `<project-id>` note.
6. **`skills/query/SKILL.md`** — body-only edit adding a "Snowflake dialect compatibility"
   section. Frontmatter untouched (diff is 21 lines added, 0 removed, confined to the body).

## AC6 before/after table (41 rows) — inline per spec

| name | raw | macro | polyglot (macros loaded) |
|---|---|---|---|
| IFF | FAIL | PASS | PASS |
| NVL | FAIL | PASS | PASS |
| NVL2 | FAIL | PASS | PASS |
| IFNULL | PASS | PASS | PASS |
| ZEROIFNULL | FAIL | PASS | PASS |
| NULLIFZERO | FAIL | PASS | PASS |
| DECODE | FAIL | FAIL | PASS |
| DIV0 | FAIL | PASS | PASS |
| QUALIFY | PASS | PASS | PASS |
| DATEADD | FAIL | FAIL | FAIL |
| DATEDIFF | PASS | PASS | PASS |
| DATE_TRUNC str | FAIL | FAIL | FAIL |
| TO_VARCHAR | FAIL | PASS | PASS |
| TO_CHAR fmt | FAIL | FAIL | FAIL |
| TRY_CAST | PASS | PASS | PASS |
| TRY_TO_NUMBER | FAIL | PASS | FAIL |
| LISTAGG | PASS | PASS | PASS |
| LISTAGG WITHIN GROUP | FAIL | FAIL | PASS |
| EQUAL_NULL | FAIL | PASS | PASS |
| cast ::NUMBER | FAIL | FAIL | PASS |
| NUMBER(38,2) | FAIL | FAIL | PASS |
| VARCHAR(n) | PASS | PASS | PASS |
| ILIKE | PASS | PASS | PASS |
| GROUP BY position | PASS | PASS | PASS |
| RATIO_TO_REPORT | FAIL | FAIL | FAIL |
| ARRAY_AGG | PASS | PASS | PASS |
| OBJECT_CONSTRUCT | FAIL | FAIL | PASS |
| FLATTEN | FAIL | FAIL | FAIL |
| CURRENT_TIMESTAMP() | FAIL | FAIL | FAIL |
| SPLIT_PART | PASS | PASS | PASS |
| REGEXP_SUBSTR | FAIL | PASS | PASS |
| POSITION IN | PASS | PASS | PASS |
| MEDIAN | PASS | PASS | PASS |
| PERCENTILE_CONT | PASS | PASS | PASS |
| TOP n | FAIL | FAIL | PASS |
| QUALIFY+PARTITION | PASS | PASS | PASS |
| LATERAL FLATTEN | FAIL | FAIL | FAIL |
| MINUS | FAIL | FAIL | PASS |
| SEQ/UNIFORM | FAIL | FAIL | PASS |
| CONCAT_WS | PASS | PASS | PASS |
| IS DISTINCT FROM | PASS | PASS | PASS |

**Pass counts:** raw **16/41**, macro **26/41**, polyglot **33/41**.

## AC6 raw-set reconciliation by name (against the pasted 17-name baseline)

Baseline: `IFNULL, QUALIFY, DATEDIFF, DATE_TRUNC str, TRY_CAST, LISTAGG, VARCHAR(n), ILIKE,
GROUP BY position, ARRAY_AGG, SPLIT_PART, POSITION IN, MEDIAN, PERCENTILE_CONT,
QUALIFY+PARTITION, CONCAT_WS, IS DISTINCT FROM` (17 names).

Raw pass count under the new fixture is **16, not 17**. Checked every one of the 17 against
the table above:

PASS (16): IFNULL, QUALIFY, DATEDIFF, TRY_CAST, LISTAGG, VARCHAR(n), ILIKE, GROUP BY position,
ARRAY_AGG, SPLIT_PART, POSITION IN, MEDIAN, PERCENTILE_CONT, QUALIFY+PARTITION, CONCAT_WS,
IS DISTINCT FROM.

**Moved, FAIL (1): `DATE_TRUNC str`.** This is the one construct that moved, and it is fully
explained, not a runner defect:

- `SELECT DATE_TRUNC('month', DATE '2026-07-15') AS v` runs with **exit 0, no DuckDB error**
  — which is all the old probe's `-match 'Error|error:'` method checked, so it read as
  "passing" for as long as this project has measured it.
- It returns `2026-07-01 00:00:00` typed **`TIMESTAMP`**, not `2026-07-01` typed **`DATE`**.
  Snowflake's `DATE_TRUNC('month', <DATE>)` returns a `DATE`. DuckDB's `date_trunc()` always
  returns `TIMESTAMP` regardless of input type — this is a genuine, previously-invisible type
  drift, structurally identical to the reason `DATEADD` is excluded from the macro file, just
  never caught before because `date_trunc` is a native function nobody hand-wrote a macro for.
  `TYP,TIMESTAMP` verified directly: `duckdb -csv -c "SELECT typeof(DATE_TRUNC('month', DATE '2026-07-15'))"`.
- It is **not macro-fixable** (native function, not a macro seam) and **`polyglot` does not
  correct it either** — its pass-through transpile is
  `DATE_TRUNC('month', CAST('2026-07-15' AS DATE))`, hitting the identical DuckDB function and
  getting the identical wrong type. So it fails in raw, macro, **and** polyglot.

**Zero-regressions check:** the AC6 rule is "no construct that passes raw fails in both macro
and polyglot." `DATE_TRUNC str` does not pass raw under the new criteria (its own row above
is FAIL), so it is not a counter-example to that specific rule — the rule's premise ("passes
raw") is false for it. The regression is real and is fully reported here via the **count**
reconciliation (17 → 16, named and explained), which is the mechanism the spec provides for
catching exactly this. The runner's own "REGRESSION" line (which checks the narrower
raw-passes-but-macro-and-polyglot-fail condition) correctly prints "none", and that is not a
false negative — it is checking a different, narrower thing than the count reconciliation is.

**A bare number would have hidden this.** I did not adjust `expected_type` to `TIMESTAMP` to
make this row pass; that would have defeated the fixture's whole purpose (the spec is explicit
that a semantically-wrong type is a failure, using this exact date-vs-timestamp class as its
own example for `DATEADD`).

## Shortfall against the derived macro ≥28 / polyglot ≥36 figures

AC6 flags this as *derived* and expects a per-construct explanation if the fixture lands lower.
It did: macro 26 (not ≥28), polyglot 33 (not ≥36).

**Macro (28 → 26, gap of 2), fully attributed:**
- **`DATEADD`** removed from the macro set by deliberate spec decision (its old macro version
  had the TIMESTAMP-vs-DATE drift). This one is not a new discovery; it is documented policy.
- **`DATE_TRUNC str`** newly fails under type assertion — see reconciliation above. This
  accounts for the second point of the gap.

**Polyglot (36 → 33, gap of 3), attributed as far as this fixture can attribute it:**
Four polyglot-mode rows run error-free but fail value/type assertion:
`DATEADD` (TIMESTAMP not DATE), `DATE_TRUNC str` (TIMESTAMP not DATE), `TO_CHAR fmt` (returns
the literal string `YYYY-MM` instead of `2026-07` — `polyglot_transpile` shows it becomes
`STRFTIME(d, 'YYYY-MM')` without converting Snowflake's format tokens to `strftime`'s), and
`TRY_TO_NUMBER` (returns `12.3` typed `DOUBLE` instead of `12.300000` typed `DECIMAL(38,6)` for
the *valid* input — a second, previously undocumented facet of the flaw PLAN-1 recorded only
for the `'abc'`-errors-instead-of-NULL case). That is 4 newly-attributed failures against an
expected reduction of only 3 (36 − 33). I cannot reconcile the exact remaining 1 without the
original probe's raw per-construct pass/fail list, which was never recorded — PLAN-1 recorded
only the totals (17/28/36), and the original probe used unadapted SQL text (e.g. `TOP 1 *`
rather than this fixture's `TOP 1 v FROM (SELECT 1 AS v)`), so a byte-for-byte replay of the
old measurement is not possible. I am reporting this discrepancy rather than forcing a false
precise match, per the instruction to surface what does not reconcile rather than paper over
it. `skills/query/duckdb-compat.md` records the same finding for future sessions.

## Residual list (7 of 41 — no mode reaches)

`DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT, FLATTEN, CURRENT_TIMESTAMP(),
LATERAL FLATTEN`

Root cause for each is in `skills/query/duckdb-compat.md` ("Residuals" section). Two
(`DATEADD`, `DATE_TRUNC str`) are DuckDB always returning `TIMESTAMP` from date functions;
`TO_CHAR fmt` is a measured wrong translation (format-token mismatch); `RATIO_TO_REPORT`,
`FLATTEN`, `LATERAL FLATTEN`, `CURRENT_TIMESTAMP()` are genuine bind/parse failures in every
mode including polyglot's pass-through.

## Verbatim acceptance-check output

**AC1 — macro inventory is 17, `DATEADD` absent.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS n FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name) IN ('IFF','NVL','NVL2','ZEROIFNULL','NULLIFZERO','DIV0','DIV0NULL','TO_VARCHAR','TO_NUMBER','TRY_TO_NUMBER','TRY_TO_DATE','EQUAL_NULL','REGEXP_SUBSTR','CHARINDEX','LEN','UUID_STRING','XL_DATE')"
n
17

> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS dateadd FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name)='DATEADD'"
dateadd
0
```
**PASS.** (The `-init` banner appears on stderr in some invocations of this command via the
tooling used to run it in this session, and is correctly not treated as an error — consistent
with the spec's own note that the banner is not an error.)

**AC2 — `xl_date` returns DATE, not TIMESTAMP.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT xl_date(46204) AS v, typeof(xl_date(46204)) AS t"
v,t
2026-07-01,DATE
```
**PASS.**

**AC3 — `TRY_TO_NUMBER`.**
```
> duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT TRY_TO_NUMBER('12.3') AS v, typeof(TRY_TO_NUMBER('12.3')) AS t, TRY_TO_NUMBER('abc') IS NULL AS abc_null"
v,t,abc_null
12.300000,"DECIMAL(38,6)",true
```
**PASS.**

**AC4 — delivery is idempotent, BOM-safe, points at the tracked file.**

Case 1 (fresh missing `state.sql`), first output line and file content:
```
C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\ac4\state.sql
--- content ---
.read C:/Users/woodsonp/Claude/Dev/duckdb-skills/skills/query/duckdb-compat.sql
```
Resolves to `skills/query/duckdb-compat.sql`, not `.duckdb-skills/sf-compat.sql`. First output
line is the resolved absolute state path. **PASS.**

Case 2 (same file again):
```
identical=True readlines=1
```
Byte-identical, exactly one `.read` line. **PASS.**

Case 3 (`state.sql` whose only line is an `ATTACH`):
```
readlines=1 attachlines=1
--- content ---
.read C:/Users/woodsonp/Claude/Dev/duckdb-skills/skills/query/duckdb-compat.sql
ATTACH ':memory:' AS scratch;
```
`.read` first, `ATTACH` line intact, one `.read`. **PASS.**

Case 4 (`state.sql` written with `Set-Content -Encoding UTF8`, carrying a BOM):
```
bomBefore=239,187,191 bomAfter=46,114,101
> duckdb -init .duckdb-skills\ac4\state.sql -csv -c "SELECT TO_VARCHAR(1) AS v"
v
1
```
BOM present before (`239,187,191`), gone after (first bytes `.re` = 46,114,101). Query returns
`1`, not `Parser Error: syntax error at or near "."`. **PASS.**

**AC5 — macro resolves through `-init` against `.read` + real `ATTACH`.**
```
> duckdb -init .duckdb-skills\ac4\state.sql -csv -c "SELECT TO_VARCHAR(123) AS v"
v
123
```
**PASS.**

**AC6 — see the before/after table, reconciliation, and residual list above.**
```
PIN: duckdb=v1.5.5 polyglot=8f1666d
raw pass count: 16 / 41
macro pass count: 26 / 41
polyglot pass count: 33 / 41
RESIDUAL (no mode reaches, 7 of 41): DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT, FLATTEN, CURRENT_TIMESTAMP(), LATERAL FLATTEN
REGRESSION: none (zero regressions holds)
EXITCODE=0
```
**PARTIAL — see analysis.** Exit code 0 as expected. Raw is 16, not the exact expected 17 —
named and explained above (this is a genuine finding, not a defect I am hiding). Macro (26) and
polyglot (33) are below the *derived, "may land lower"* ≥28/≥36 figures — explained per
construct above, with one polyglot-mode point of the gap I could not attribute exactly (see
"Shortfall" section). Residual list and PIN line present as required.

**AC7 — malformed fixture row is rejected, not silently mis-compared.**
```
> tools\run-compat-tests.ps1 -Fixture .duckdb-skills\ac7\bad-fixture.csv -Mode raw
PIN: duckdb=v1.5.5 polyglot=8f1666d
MALFORMED ROW: BAD ROW (mode=raw): expected 1 column, got 2
...
raw pass count: 0 / 1
EXITCODE=1
```
Names the row (`BAD ROW`), non-zero exit. **PASS.**

**AC8 — the `Error`-matching trap is avoided; macro pass count ≥ 20.**
```
> tools\run-compat-tests.ps1 -Mode macro
...
macro pass count: 26 / 41
EXITCODE=0
```
26 ≥ 20. **PASS.** Confirmed via `grep` that the only `-match` against the string `Error` in
`tools\run-compat-tests.ps1` is the strict class pattern `^[A-Za-z ]+Error:` (lines 59/one
usage); there is no bare-word `Error` match anywhere in the file. **PASS.**

**AC9 — pin drift fails loudly.**
```
> tools\run-compat-tests.ps1 -ExpectedPolyglotVersion deadbee
PIN: duckdb=v1.5.5 polyglot=8f1666d
PIN DRIFT: expected duckdb=v1.5.5 polyglot=deadbee; actual duckdb=v1.5.5 polyglot=8f1666d
Remedy: re-run the fixture and update the pin and the before/after table in skills/query/duckdb-compat.md.
EXITCODE=1
```
**PASS.**

## Not done

Nothing in the spec's six deliverables was skipped. Deferred items are deferred **by the
spec's own design**, not by omission on my part: `<project-id>` resolution (explicitly out of
scope, item 2's to settle), a corrected `DATEADD` macro (explicitly excluded pending a
type-asserted fix), and porting the eight bash skills (explicitly out of scope).

The one thing I could not complete to full precision: an exact construct-by-construct
reconciliation of the polyglot shortfall (36 → 33) — I attributed 4 causes against an expected
gap of 3 and reported the 1-point discrepancy rather than force a false match, since the
original 36 figure was never recorded per-construct and the original probe used different
(unadapted) SQL text for at least one construct (`TOP n`).

## Deviations from the spec

- **`$ErrorActionPreference` bug, discovered and fixed during implementation.** Setting
  `$ErrorActionPreference = 'Stop'` at script scope in `tools\run-compat-tests.ps1`, combined
  with `2>$errFile` on the per-row `duckdb` invocations, caused PowerShell to raise a
  terminating `NativeCommandError` on the **first** row that legitimately exits non-zero (i.e.
  the first expected dialect failure) — even though stderr was correctly redirected to a file,
  not merged with `2>&1`. This is a distinct trap from the one the spec names (`2>&1` merging
  the `-init` banner into `NativeCommandError`): here the terminating behavior comes from
  `$ErrorActionPreference='Stop'` itself, independent of how stderr is redirected. Fixed by
  changing it to `'Continue'`, since this runner's whole design depends on native `duckdb`
  invocations that are *expected* to fail and be inspected, not to terminate the script.
  Recorded here because it is exactly the class of "cost a full debugging cycle" trap the spec
  warns about elsewhere, just one layer further in.
- **`ConvertFrom-Csv` single-row bug, discovered and fixed during implementation.** PowerShell
  5.1's `ConvertFrom-Csv` (and `Import-Csv`) return a bare object, not a one-element array, when
  the input has exactly one data row. `$obj.Count` on a bare object is `$null`, and
  `$null -ge 1` evaluates `False` — so a guard written as `if ($rows.Count -ge 1)` silently
  fails exactly when there is exactly one row, which is the common case for the `META` block
  (always one row) and for a single-row fixture (AC7's scratch fixture). This produced a
  first-draft runner that reported **every** row as FAIL in **every** mode, including
  `IFNULL`/`QUALIFY` which need no macro at all — a systemic false-negative bug, not a partial
  one. Fixed by wrapping every `ConvertFrom-Csv`/`Import-Csv`/`Where-Object` result that is
  later `.Count`-checked in `@(...)`. Caught by manual verification against known-good rows
  before trusting any AC6 number; had this shipped unnoticed, every acceptance check depending
  on the runner (AC6, AC7, AC8) would have reported false failures.
- **`polyglot_transpile` is a scalar function, not a table function.** The spec's phrase
  "emit `polyglot_transpile` output" does not specify calling convention. I initially assumed
  (incorrectly) it was a table function like `polyglot_query`/`polyglot_dialects`; the actual
  signature, confirmed via `duckdb_functions()`, is
  `polyglot_transpile(sql, dialect) -> VARCHAR` (`function_type = 'scalar'`). The runner and
  the `.md` file both use the correct scalar-call form
  (`SELECT polyglot_transpile('<sql>', 'snowflake') AS transpiled`). Noting this because the
  wrong assumption produces a *different* wrong error (`Catalog Error: Table Function ... does
  not exist`) that could easily be mistaken for "transpile isn't available."
- **`DIV0(1,0)` expected value/type is my own reasoned judgment, not a documented Snowflake
  fact.** The macro (`CASE WHEN b=0 THEN 0 ELSE a/b END`, inherited verbatim from the existing
  seed) returns `0.0` typed `DOUBLE` in DuckDB, because DuckDB's `/` operator between two
  integers returns `DOUBLE`, which the `CASE` unifies with the `0` branch. I recorded the
  fixture's `expected_value`/`expected_type` as exactly what the macro verifiably produces
  (`0.0`/`DOUBLE`) rather than guessing at Snowflake's exact NUMBER precision/scale rules for
  integer division, which cannot be checked without a live Snowflake connection (explicitly out
  of scope). This is flagged in `duckdb-compat.md` implicitly by omission — I am flagging it
  explicitly here instead, since it is a judgment call rather than a verified fact like the
  rest of the fixture.
- **`ARRAY_AGG` and `OBJECT_CONSTRUCT` `expected_value` uses DuckDB's own rendering, not a
  literal Snowflake JSON/array representation.** Per the spec's type rule (expected_type is
  DuckDB's rendering of Snowflake's semantics, not Snowflake's own name), I applied the same
  principle to `expected_value` for these two structurally-different-by-design rows:
  `[1]` for `ARRAY_AGG(1)` and `{'a': 1}` for `OBJECT_CONSTRUCT('a',1)` are DuckDB's own CSV
  rendering of the correct value, not Snowflake's `[1]`/`{"a":1}` JSON syntax. This is
  consistent with how the runner's `VAL` block will always render these types, but I am
  flagging the reasoning since the spec's "Compare as an exact string" instruction is stated
  for the type column specifically.

## Concerns

- `TASK.md` and `RESULT-1.md` are not gitignored — confirmed by reading `.gitignore` (three
  lines only: `_plan.md`, `_data/`, `.duckdb-skills/`). Correct as-is; nothing to flag.
- The `-Encoding utf8` default used by `Out-File`/`ConvertTo-Csv` in PowerShell 5.1 writes a
  UTF-8 BOM (distinct from `-Encoding UTF8` on `Set-Content`, but the same underlying issue).
  This did not affect any shipped deliverable (all four files that must be BOM-free were
  written with `write`/`[IO.File]::WriteAllText` and verified byte-for-byte with
  `[IO.File]::ReadAllBytes`), but it is worth remembering for anyone extending
  `tools\run-compat-tests.ps1`: its own scratch/report files under `.duckdb-skills\` are not
  BOM-sensitive (nothing reads them back with `.read`), so this was not a defect, just a trap
  to stay clear of if that scratch output is ever repurposed as `.read` input.
