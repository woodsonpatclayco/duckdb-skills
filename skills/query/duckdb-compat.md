# Snowflake -> DuckDB dialect layer

Two mechanisms, and a rule for which to use. Neither is transparent: macros must be loaded
into the session (`skills/query/duckdb-compat.sql`), and `polyglot` must be called explicitly
through `polyglot_query('<sql>', 'snowflake')` — plain Snowflake SQL never runs unmodified
against raw DuckDB.

## Routing rule

1. **Write plain DuckDB SQL with the macros loaded.** They are value-correct for the 16
   functions and 1 conversion helper below, and they compose normally with the rest of the
   query.
2. **Reach for `polyglot_query('<sql>', 'snowflake')`** when a construct fails with a
   `Catalog Error` (a function or syntax macros cannot reach), or when lifting SQL verbatim
   from Snowflake. Single quotes inside the wrapped string must be doubled.
   `LOAD polyglot;` is required first — it does not autoload (`duckdb_extensions()` shows
   `installed=true, loaded=false` until then).
3. **`LOAD polyglot;` must come before `SET enable_external_access=false`.** Issued after the
   sandbox `SET` lines, it fails `Permission Error: Loading external extensions is disabled
   through configuration`.
4. **Macros compose inside `polyglot_query` — except for the handful of names `polyglot` also
   recognizes natively.** Verified: `TO_VARCHAR(123)` returns `123` through the wrapper, and
   fails without the macros loaded — that composition works as designed. But `polyglot`
   recognizes `DIV0`, `DIV0NULL`, `TO_NUMBER`, `TRY_TO_NUMBER`, and `REGEXP_SUBSTR` by name and
   **transpiles them to its own native expression, bypassing the macro entirely** — even with
   the compat file loaded. See "Measured wrong translations" below; this is the reason those
   five constructs pass in macro mode but not in polyglot mode.
5. **Always surface `polyglot_transpile('<sql>', 'snowflake')` output when polyglot runs.**
   It is a scalar function (not a table function — `SELECT * FROM polyglot_transpile(...)`
   raises `Catalog Error: Table Function ... does not exist`; call it as
   `SELECT polyglot_transpile('<sql>', 'snowflake') AS transpiled`). Polyglot has measured
   wrong translations (below), so the transpiled SQL is part of the answer, not debug detail.
6. **Macros arrive via `state.sql`, never a second `-init`.** `duckdb -init` takes exactly one
   file and a second `-init` silently replaces the first; every session-mode call already
   spends that slot on `state.sql`.

## Delivery

`tools\ensure-duckdb-compat.ps1` inserts `.read <forward-slash absolute path to
duckdb-compat.sql>` as the first line of `state.sql`, idempotently, BOM-free. Not a second
`-init`. Default target is project-local: `<repo root>\.duckdb-skills\state.sql`. Pass
`-StateFile <path>` to target a different file (e.g. a `$HOME\.duckdb-skills\<project>\`
location) — that resolution term is deliberately undefined here; see "Deferred decision"
below. The script's first output line is always the resolved absolute path it wrote to.

## The 17 macros, and why `DATEADD` is absent

`skills/query/duckdb-compat.sql` carries:

```
IFF, NVL, NVL2, ZEROIFNULL, NULLIFZERO, DIV0, DIV0NULL, TO_VARCHAR, TO_NUMBER,
TRY_TO_NUMBER, TRY_TO_DATE, EQUAL_NULL, REGEXP_SUBSTR, CHARINDEX, LEN, UUID_STRING,
xl_date
```

That is the seed's 16 macros (excluding `DATEADD`) plus `xl_date(serial)`, an Excel-serial to
`DATE` conversion added so the conversion is named once rather than retyped per column
(`(DATE '1899-12-30' + to_days(serial::BIGINT))::DATE` — the trailing `::DATE` cast is
load-bearing, otherwise `+ to_days()` yields `TIMESTAMP`).

**`DATEADD` is deliberately excluded.** A hand-written macro body
(`d + (n::VARCHAR || ' ' || p)::INTERVAL`) returns `TIMESTAMP` where Snowflake returns `DATE`
— exactly the kind of silent type drift this fixture exists to catch. Raw DuckDB has no
`DATEADD` at all (`Catalog Error: ... Did you mean "date_add"?`), and **`polyglot` reaches it
but gets the type wrong too** — its transpile is `CAST(...AS DATE) + INTERVAL 1 DAY`, which
DuckDB types as `TIMESTAMP`. So `DATEADD` currently has **no correct path in any mode** and is
a residual (below), not merely a macro gap.

### Round 2: five macro bodies corrected against measured Snowflake behaviour

Measured on CLAYCO-DATAHUB (see `TASK.md` C1/C6). Round 1 shipped two of these wrong and never
tested the other three at all — `VERIFY-1.md` returned **DO NOT SHIP** over the first two.

| Macro | Was | Now | Why |
|---|---|---|---|
| `TO_NUMBER`, `TRY_TO_NUMBER` | `CAST(a AS DECIMAL(38,6))` | `CAST(a AS DECIMAL(38,0))` | Snowflake's default scale is 0, not 6 — it rounds fractional digits away (`'12.3'` → `12`, half-away-from-zero). The old scale-6 body silently preserved decimals production rounds off. |
| `DIV0`, `DIV0NULL` | untyped `CASE` (DuckDB's `/` yields `DOUBLE`) | `CAST(CASE ... END AS DECIMAL(38,6))` | Value-correct at scale 6, verified against Snowflake's `NUMBER(7,6)`/`NUMBER(8,6)` answers. The precision digit varies with input and is not reproducible from a static macro — see "deviation", below. |
| `REGEXP_SUBSTR` | `regexp_extract(s, p)` | `CASE WHEN regexp_matches(s, p) THEN regexp_extract(s, p) END` | DuckDB's `regexp_extract` returns `''` on no match; Snowflake returns `NULL`. The old body silently changed the answer for every no-match case (`COUNT()`, `IS NULL`, `NVL` chains all see a different result). |
| `UUID_STRING` | `uuid()` | `CAST(uuid() AS VARCHAR)` | Snowflake's `UUID_STRING()` returns `VARCHAR(36)`; DuckDB's `uuid()` returns type `UUID`. Same disqualifying class as the `DATEADD` type drift. |

**`TRY_TO_DATE` was measured and deliberately left unfixed.** Snowflake's
`TRY_TO_DATE('46204')` returns `1970-01-01` — it reads an all-digit string as an epoch offset,
not an error and not NULL. DuckDB's `TRY_CAST('46204' AS DATE)` returns `NULL`. There is no
macro body that reproduces epoch-offset parsing without also breaking normal ISO-date strings,
so this is recorded as a **known divergence** (see Residuals) rather than patched. Practical
consequence: **`xl_date()` is the correct tool for Excel serials, and `TRY_TO_DATE` must not be
used for them** — on Snowflake, an Excel serial like `46204` silently becomes a 1970 date
rather than failing loudly.

## The type rule, and the `source` classification

`expected_type` in the fixture is the DuckDB type name that correctly *represents* Snowflake's
semantics, written exactly as `typeof()` renders it — never Snowflake's own type name (which
`typeof()` can never return). So `DECIMAL(38,6)` not `NUMBER`; `VARCHAR` not `VARCHAR(10)`.

A DuckDB type that is merely *named* differently is not a failure. A DuckDB type that is
*semantically wrong* — a date arriving as `TIMESTAMP` — is a failure. That is the whole reason
`DATEADD` is excluded, and it is also why **`DATE_TRUNC str` fails in all three modes** (see
"Raw-set reconciliation" below): DuckDB's `date_trunc()` always returns `TIMESTAMP`, even when
its input is a `DATE`, and no mode — not even `polyglot`'s pass-through — corrects it.

### Round 2: every row now declares where its expectation came from (`source`)

Round 1 shipped two rows (`TRY_TO_NUMBER`, `DIV0`) that asserted what the macro *produced* as
if it were Snowflake's answer — the exact defect this fixture exists to prevent. `VERIFY-1.md`
caught it and returned **DO NOT SHIP**. The fixture now carries a `source` column so that
distinction is never silent again:

- **`snowflake`** (41 rows) — the expectation is Snowflake's measured answer.
- **`deviation`** (8 rows) — **the value is equal**, but DuckDB's **type kind** differs and
  cannot be reproduced: fixed-point → floating, `ARRAY` → `INTEGER[]`, `OBJECT` → `STRUCT`,
  `VARIANT` → a concrete type, or a precision that varies with input (Snowflake picks a
  different scale per call; a static macro cannot follow it). Requires a non-empty `note`.
- **`duckdb-native`** (1 row, `xl_date`) — no Snowflake equivalent exists.

**The line `deviation` may not cross:** a length/precision difference *inside the same type
kind* is not a deviation — it is the canonical rendering the type rule above already covers
(`VARCHAR(10)` → `VARCHAR`), and stays `source=snowflake`. A row whose **value** differs, or
whose type difference would produce a wrong answer downstream, is **never** a deviation — it
keeps Snowflake's answer as its expectation and fails. `DATE_TRUNC str` is the worked
counter-example: both sides are temporal, so a loose reading would admit it as a deviation and
turn the single most valuable finding of round 1 into a pass. It stays `source=snowflake` and
stays failing (verified directly: relabelling it to `deviation`/`TIMESTAMP` still fails on
**value** — `2026-07-01` vs `2026-07-01 00:00:00` — so it cannot be gamed by a source change
alone).

The eight `deviation` rows, each with its reason: `DIV0`, `DIV0NULL` (precision varies with
input — value 0 is exact, but Snowflake's `NUMBER(7,6)` vs `NUMBER(8,6)` is not a static
macro's to reproduce), `ARRAY_AGG` (`ARRAY` → `INTEGER[]`), `OBJECT_CONSTRUCT` (`OBJECT` →
`STRUCT`), `MEDIAN`, `PERCENTILE_CONT` (Snowflake's `NUMBER(4,3)` fixed-point vs DuckDB's
`DOUBLE`), `RATIO_TO_REPORT` (same fixed-point-vs-floating class; also a residual — no DuckDB
window aggregate of this name exists), `FLATTEN` (`VARIANT` has no concrete DuckDB counterpart;
also a residual).

### Numeric values compare numerically

Snowflake's fixed-point scale renders some of these differently from DuckDB while being the
same number — `MEDIAN(1)` is `1.000` on Snowflake, `1.0` on DuckDB. When both the expected and
actual values parse as decimal, the runner compares them **numerically**; otherwise it compares
as exact strings. Type comparison is untouched by this and stays an exact string match.

## The fixture: 50 rows, seven columns

`skills/query/duckdb-compat-tests.csv` — columns `name, sql, expected_value, expected_type,
check_mode, source, note`. `check_mode` is a fifth column beyond PLAN-1's original four, added
because three constructs (`CURRENT_TIMESTAMP()`, `SEQ/UNIFORM`, `UUID_STRING`) are irreducibly
non-deterministic and must skip value comparison while still asserting type;
`check_mode=type_only` marks those three, every other row is `value_and_type`. `source` and
`note` are round-2 additions — see "The type rule", above.

Every row's `sql` is a complete statement returning exactly one row and exactly one column, so
value and type are assertable uniformly in all three modes. Three rows were rewritten off
`CURRENT_DATE` onto a fixed date literal (`DATEADD`, `DATE_TRUNC str`, `TO_CHAR fmt`) so the
expected value is pinned; this does not change which construct is under test. Nine rows were
added in round 2 to cover macros that shipped in round 1 with no fixture row at all —
`DIV0NULL`, `TO_NUMBER`, `TRY_TO_DATE` (both the serial-string and ISO-string cases), `CHARINDEX`,
`LEN`, `UUID_STRING`, a no-match case for `REGEXP_SUBSTR`, and `xl_date`.

## Pinned versions

- DuckDB **v1.5.5** (`d8cdaa33fd`).
- `polyglot` **`8f1666d`**, `install_mode=REPOSITORY`, `installed_from=community` — unlike
  `ducklake` and `excel` (`installed_from=core`). A community extension can be rebuilt and
  change transpilation silently, the same risk class as the `TRY_TO_NUMBER` flaw below.

`tools\run-compat-tests.ps1` asserts both pins before running any row and prints a `PIN DRIFT`
banner with a non-zero exit on mismatch. The remedy is operational: re-run the fixture and
update both the pin here and the before/after table below.

## Before/after table (50 rows)

Measured 2026-09-23 against DuckDB v1.5.5 / polyglot `8f1666d`, via
`tools\run-compat-tests.ps1 -Mode all`. `polyglot` column is `polyglot (macros loaded)` — see
"Composition", above; polyglot mode always loads the compat file too. `source` is the
classification described above — a `PASS` on a `deviation`/`duckdb-native` row is real, but on
a relaxed (type-kind) expectation, not Snowflake's own answer.

| name | raw | macro | polyglot (macros loaded) | source |
|---|---|---|---|---|
| IFF | FAIL | PASS | PASS | snowflake |
| NVL | FAIL | PASS | PASS | snowflake |
| NVL2 | FAIL | PASS | PASS | snowflake |
| IFNULL | PASS | PASS | PASS | snowflake |
| ZEROIFNULL | FAIL | PASS | PASS | snowflake |
| NULLIFZERO | FAIL | PASS | PASS | snowflake |
| DECODE | FAIL | FAIL | PASS | snowflake |
| DIV0 | FAIL | PASS | FAIL | deviation |
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
| DIV0NULL | FAIL | PASS | FAIL | deviation |
| TO_NUMBER | FAIL | PASS | FAIL | snowflake |
| TRY_TO_DATE serial | FAIL | FAIL | FAIL | snowflake |
| TRY_TO_DATE iso | FAIL | PASS | PASS | snowflake |
| CHARINDEX | FAIL | PASS | PASS | snowflake |
| LEN | PASS | PASS | PASS | snowflake |
| UUID_STRING | FAIL | PASS | PASS | snowflake |
| REGEXP_SUBSTR no match | FAIL | PASS | FAIL | snowflake |
| xl_date | FAIL | PASS | PASS | duckdb-native |

**Three-way counts (verified / deviation / fail, out of 50):**

| mode | pass | verified | deviation | fail |
|---|---|---|---|---|
| raw | 17 | 14 | 3 | 33 |
| macro | 34 | 28 | 6 | 16 |
| polyglot (macros loaded) | 37 | 32 | 5 | 13 |

"Verified" is a pass whose expectation is Snowflake's own answer (`source=snowflake`).
"Deviation" is a real pass, but on a relaxed type-kind expectation — round 1's single pass
count conflated the two, which is exactly how `TRY_TO_NUMBER` and `DIV0` shipped wrong.

## Raw-set reconciliation (against the original 17-name baseline)

The baseline (measured by the old error-only probe, `.duckdb-skills/dialect-probe.ps1`):
`IFNULL, QUALIFY, DATEDIFF, DATE_TRUNC str, TRY_CAST, LISTAGG, VARCHAR(n), ILIKE, GROUP BY
position, ARRAY_AGG, SPLIT_PART, POSITION IN, MEDIAN, PERCENTILE_CONT, QUALIFY+PARTITION,
CONCAT_WS, IS DISTINCT FROM` — 17 names.

Raw **pass** count is 16 of these 17 (unchanged since round 1) — **`DATE_TRUNC str`** is the
one that fails: DuckDB's `date_trunc('month', DATE '2026-07-15')` runs without error and
returns the numerically-correct instant, but as `2026-07-01 00:00:00` typed `TIMESTAMP` — not
`2026-07-01` typed `DATE`. Not macro-fixable (native function) and `polyglot`'s pass-through
transpile hits the identical function, so it fails in all three modes. See "Residuals", below.

Raw **verified** (Snowflake-sourced passes) is **13, not 16** — three of the sixteen raw passes
are `source=deviation`: `ARRAY_AGG`, `MEDIAN`, `PERCENTILE_CONT`. All three still pass raw
exactly as before (DuckDB's native behaviour did not change); they are reclassified, not
regressed. See AC11 in `RESULT-2.md` for the full row-by-row reconciliation against round 1.

## Residuals — constructs no mode currently reaches (8 of 50)

`DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT, FLATTEN, CURRENT_TIMESTAMP(), LATERAL
FLATTEN, TRY_TO_DATE serial`

- **`DATEADD`, `DATE_TRUNC str`** — DuckDB's date functions return `TIMESTAMP` even from a
  `DATE` input, in both the macro path and polyglot's pass-through transpile. No macro can fix
  `DATE_TRUNC str` (it is a native function, not a macro seam); fixing `DATEADD` would need a
  macro with an explicit trailing `::DATE`, deferred rather than added here to keep this file
  at exactly the 17 macros stated above — a future revision could ship a corrected `DATEADD`
  the way `xl_date` already demonstrates the pattern.
- **`TO_CHAR fmt`** — reaches `polyglot` without erroring, but is a **measured wrong
  translation**: `polyglot_transpile` turns `TO_CHAR(d,'YYYY-MM')` into
  `STRFTIME(d, 'YYYY-MM')` without converting Snowflake's format tokens to `strftime`'s, so it
  returns the literal string `YYYY-MM` instead of the formatted date. Same flaw class as
  `TRY_TO_NUMBER` below — the wrong answer is returned silently, not as an error.
- **`RATIO_TO_REPORT`** — no DuckDB aggregate/window function of this name exists, and macros
  cannot define custom window aggregates. `polyglot` passes the call through unchanged and it
  fails the same `Catalog Error` raw does. Classified `source=deviation` per its Snowflake
  measurement, but a residual regardless since it never passes.
- **`FLATTEN`, `LATERAL FLATTEN`** — `polyglot` transpiles `FLATTEN(input=>...)` to
  `UNNEST(input=>...)`, but the result does not carry a `value` column the way Snowflake's
  `FLATTEN` output does, so the adapted fixture SQL (`SELECT value AS v FROM ...`) fails to
  bind post-transpile. `FLATTEN` is classified `source=deviation` (same reasoning as
  `RATIO_TO_REPORT`); `LATERAL FLATTEN` is a distinct fixture row with the same root cause.
- **`CURRENT_TIMESTAMP()`** — DuckDB does not recognize the parenthesized call form as a
  function (`current_timestamp` alone is a keyword constant); `polyglot` passes the
  parenthesized form through unchanged and hits the identical bind error. Correct target type
  if a path is ever added: `TIMESTAMP WITH TIME ZONE` (Snowflake `TIMESTAMP_LTZ`).
- **`TRY_TO_DATE serial`** — round 2 addition. Measured: Snowflake reads an all-digit string as
  an epoch offset (`TRY_TO_DATE('46204')` = `1970-01-01`); DuckDB's `TRY_CAST(... AS DATE)`
  returns `NULL`. Deliberately left unfixed — see "Round 2: five macro bodies corrected",
  above. **Use `xl_date()` for Excel serials, never `TRY_TO_DATE`.**

## Measured wrong translations (value or type correct nowhere, but no error either)

Rows that run cleanly through `polyglot` — no error, exit 0 — and still return the wrong
answer. These are the reason macros are the value-correct path where they can reach at all,
per PLAN-1's original finding. Round 2 found four more: `polyglot` recognizes `DIV0`,
`DIV0NULL`, `TO_NUMBER`, and `REGEXP_SUBSTR` by name and **transpiles them to its own native
expression, bypassing the compat macro entirely** — the same pattern already known for
`TRY_TO_NUMBER`. This is why those four pass in macro mode (which uses the macro) but fail in
polyglot mode (which does not), even though the compat file is loaded in both.

| Construct | Input | polyglot returns | Correct answer |
|---|---|---|---|
| `TRY_TO_NUMBER` | `'12.3'` | `12.3` typed `DOUBLE` | `12` typed `DECIMAL(38,0)` |
| `TRY_TO_NUMBER` | `'abc'` | **errors** | `NULL` |
| `TO_CHAR fmt` | `'YYYY-MM'` format | literal string `YYYY-MM` | `2026-07` |
| `DIV0` | `(1,0)` | `0.0` typed `DOUBLE` | `0.000000` typed `DECIMAL(38,6)` |
| `DIV0NULL` | `(1,NULL)` | `0.0` typed `DOUBLE` | `0.000000` typed `DECIMAL(38,6)` |
| `TO_NUMBER` | `'12.3'` | `12.3` typed `DOUBLE` | `12` typed `DECIMAL(38,0)` |
| `REGEXP_SUBSTR` (no match) | `'abc'`,`'[0-9]+'` | `''` (empty, not NULL) | `NULL` |

Transpiled forms, confirmed via `polyglot_transpile`: `DIV0(1,0)` becomes
`CASE WHEN 0 = 0 AND NOT 1 IS NULL THEN 0 ELSE 1 / 0 END` (DuckDB's untyped `/` yields
`DOUBLE`); `TO_NUMBER('12.3')` becomes `CAST('12.3' AS DOUBLE)`; `REGEXP_SUBSTR('abc','[0-9]+')`
becomes `REGEXP_EXTRACT('abc', '[0-9]+')` (DuckDB's empty-string-on-no-match behaviour, exactly
the defect the macro fix removes). The macros themselves get every one of these cases right,
which is why they stay in the shipped set even though `polyglot` also "reaches" the names.

## `check_mode=type_only` rows

`CURRENT_TIMESTAMP()`, `SEQ/UNIFORM` (`UNIFORM(1,10,RANDOM())`), and `UUID_STRING()` return a
non-deterministic value, so the fixture skips value comparison for them and asserts type only.
`SEQ/UNIFORM` reaches `polyglot` correctly (returns `BIGINT`). `UUID_STRING` fails raw (no such
native function; `Catalog Error`), then passes macro and polyglot once the macro casts its
result to `VARCHAR`. `CURRENT_TIMESTAMP()` does not reach any mode — see Residuals.

## Deferred decision — `<project-id>`

`tools\ensure-duckdb-compat.ps1` resolves its default target as project-local only
(`<repo root>\.duckdb-skills\state.sql`). It deliberately does **not** implement
`~\.duckdb-skills\<project-id>\` resolution: `PLAN-1.md:308`'s pointer
(`skills/query/SKILL.md:24-27`'s `tr '/' '-'`) leaves the Windows drive colon in place, which is
not a legal directory name, so that term is not implementable as written. Item 2's spec must
settle `<project-id>` together with the plan revision that carries it, at which point
`SKILL.md:22-25`'s state-file precedence (home-side file wins when present) also needs
deciding against this spec's project-local-only default.

## Why the AC6-era 28/36 figures no longer apply, and what replaced them

PLAN-1 measured macro 28 and polyglot 36 as **error-free counts** against the *unadapted* probe
SQL. Round 1 replaced that with a *correctness* count (26, 33), and round 2 replaced the single
pass count with the three-way verified/deviation/fail split above, because a single pass number
cannot distinguish "Snowflake's real answer" from "a relaxed type-kind match" — the conflation
that let `TRY_TO_NUMBER` and `DIV0` ship wrong in round 1. `AC6` is superseded by `AC11`; the
full row-by-row reconciliation against round 1's per-row table lives in `RESULT-2.md`.

One genuine regression, found by this round's own three-mode run: **`DIV0` passes macro mode
but now fails polyglot mode** (round 1: pass both). Cause: `polyglot`'s native transpile of
`DIV0` bypasses the now-corrected macro and reverts to the old `DOUBLE`-typed answer — see
"Measured wrong translations", above. This is not a runner defect; it is the correction working
(round 1's `DIV0` expectation matched DuckDB's own wrong output, which is exactly what made it
a false positive).
