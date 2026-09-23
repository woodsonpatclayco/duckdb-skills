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
4. **Macros compose inside `polyglot_query`** — verified: `TO_VARCHAR(123)` returns `123`
   through the wrapper, and fails without the macros loaded. The compat file is loaded via
   `state.sql` in both cases (see delivery, below), so this composition is automatic once a
   session has run `tools\ensure-duckdb-compat.ps1` once.
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

## The type rule

`expected_type` in the fixture is the DuckDB type name that correctly *represents* Snowflake's
semantics, written exactly as `typeof()` renders it — never Snowflake's own type name (which
`typeof()` can never return). So `DECIMAL(38,6)` not `NUMBER`; `VARCHAR` not `VARCHAR(10)`.

A DuckDB type that is merely *named* differently is not a failure. Two rows are expected-by-design
mismatches for this reason and are not regressions:

- **`ARRAY_AGG`** — Snowflake `ARRAY`, DuckDB `INTEGER[]`.
- **`OBJECT_CONSTRUCT`** — Snowflake `OBJECT`, DuckDB `STRUCT(a INTEGER)` (reached only via
  `polyglot`; raw and macro both raise `Catalog Error`).

A DuckDB type that is *semantically wrong* — a date arriving as `TIMESTAMP` — is a failure.
That is the whole reason `DATEADD` is excluded, and it is also, newly, why **`DATE_TRUNC str`
now fails in all three modes** (see "Raw-set reconciliation" below): DuckDB's `date_trunc()`
always returns `TIMESTAMP`, even when its input is a `DATE`, and no mode — not even
`polyglot`'s pass-through — corrects it.

## The fixture: 41 rows, five columns

`skills/query/duckdb-compat-tests.csv` — columns `name, sql, expected_value, expected_type,
check_mode`. `check_mode` is a fifth column beyond PLAN-1's original four, added because two
constructs (`CURRENT_TIMESTAMP()`, `SEQ/UNIFORM`) are irreducibly non-deterministic and must
skip value comparison while still asserting type; `check_mode=type_only` marks those two, every
other row is `value_and_type`.

Every row's `sql` is a complete statement returning exactly one row and exactly one column, so
value and type are assertable uniformly in all three modes. Three rows were rewritten off
`CURRENT_DATE` onto a fixed date literal (`DATEADD`, `DATE_TRUNC str`, `TO_CHAR fmt`) so the
expected value is pinned; this does not change which construct is under test.

## Pinned versions

- DuckDB **v1.5.5** (`d8cdaa33fd`).
- `polyglot` **`8f1666d`**, `install_mode=REPOSITORY`, `installed_from=community` — unlike
  `ducklake` and `excel` (`installed_from=core`). A community extension can be rebuilt and
  change transpilation silently, the same risk class as the `TRY_TO_NUMBER` flaw below.

`tools\run-compat-tests.ps1` asserts both pins before running any row and prints a `PIN DRIFT`
banner with a non-zero exit on mismatch. The remedy is operational: re-run the fixture and
update both the pin here and the before/after table below.

## Before/after table (41 rows)

Measured 2026-09-23 against DuckDB v1.5.5 / polyglot `8f1666d`, via
`tools\run-compat-tests.ps1 -Mode all`. `polyglot` column is `polyglot (macros loaded)` — see
"Composition", above; polyglot mode always loads the compat file too.

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

**Pass counts:** raw 16/41, macro 26/41, polyglot 33/41.

## Raw-set reconciliation (against the original 17-name baseline)

The baseline (measured by the old error-only probe, `.duckdb-skills/dialect-probe.ps1`):
`IFNULL, QUALIFY, DATEDIFF, DATE_TRUNC str, TRY_CAST, LISTAGG, VARCHAR(n), ILIKE, GROUP BY
position, ARRAY_AGG, SPLIT_PART, POSITION IN, MEDIAN, PERCENTILE_CONT, QUALIFY+PARTITION,
CONCAT_WS, IS DISTINCT FROM` — 17 names.

Under the new value-and-type fixture, raw scores **16, not 17**. Sixteen of the seventeen
still pass unchanged. **`DATE_TRUNC str` moved from pass to fail**, and it is the only one that
moved. Root cause: DuckDB's `date_trunc('month', DATE '2026-07-15')` runs without error and
returns the numerically-correct instant, but as `2026-07-01 00:00:00` typed `TIMESTAMP` — not
`2026-07-01` typed `DATE`. The old probe only checked for the absence of an error, so this
construct read as "passing" under that method for as long as the project has measured it; the
type assertion this fixture adds is the first thing to actually catch it. It is not a runner
defect — `polyglot`'s pass-through transpile (`DATE_TRUNC('month', CAST(...AS DATE))`) hits the
identical DuckDB function and is wrong the same way, so no mode currently corrects it. See
"Residuals" below.

## Residuals — constructs no mode currently reaches (7 of 41)

`DATEADD, DATE_TRUNC str, TO_CHAR fmt, RATIO_TO_REPORT, FLATTEN, CURRENT_TIMESTAMP(), LATERAL
FLATTEN`

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
  fails the same `Catalog Error` raw does.
- **`FLATTEN`, `LATERAL FLATTEN`** — `polyglot` transpiles `FLATTEN(input=>...)` to
  `UNNEST(input=>...)`, but the result does not carry a `value` column the way Snowflake's
  `FLATTEN` output does, so the adapted fixture SQL (`SELECT value AS v FROM ...`) fails to
  bind post-transpile. A different adaptation might bind against `polyglot`'s literal unnest
  shape, but that would test the transpile's actual output shape rather than the Snowflake
  construct itself.
- **`CURRENT_TIMESTAMP()`** — DuckDB does not recognize the parenthesized call form as a
  function (`current_timestamp` alone is a keyword constant); `polyglot` passes the
  parenthesized form through unchanged and hits the identical bind error. Correct target type
  if a path is ever added: `TIMESTAMP WITH TIME ZONE` (Snowflake `TIMESTAMP_LTZ`).

## Measured wrong translations (value or type correct nowhere, but no error either)

Two rows run cleanly through `polyglot` — no error, exit 0 — and still return the wrong
answer. These are the reason macros are the value-correct path where they can reach at all,
per PLAN-1's original finding:

| Construct | Input | polyglot returns | Correct answer |
|---|---|---|---|
| `TRY_TO_NUMBER` | `'12.3'` | `12.3` typed `DOUBLE` | `12.300000` typed `DECIMAL(38,6)` |
| `TRY_TO_NUMBER` | `'abc'` | **errors** | `NULL` |
| `TO_CHAR fmt` | `'YYYY-MM'` format | literal string `YYYY-MM` | `2026-07` |

The macro (`TRY_TO_NUMBER(a) AS TRY_CAST(a AS DECIMAL(38,6))`) gets both `TRY_TO_NUMBER` cases
right, which is why it stays in the shipped macro set even though `polyglot` also "reaches" the
name.

## `check_mode=type_only` rows

`CURRENT_TIMESTAMP()` and `SEQ/UNIFORM` (`UNIFORM(1,10,RANDOM())`) return a non-deterministic
value, so the fixture skips value comparison for them and asserts type only.
`SEQ/UNIFORM` reaches `polyglot` correctly (returns `BIGINT`, a reasonable rendering of
Snowflake's integer `UNIFORM`); `CURRENT_TIMESTAMP()` does not reach any mode — see Residuals.

## Deferred decision — `<project-id>`

`tools\ensure-duckdb-compat.ps1` resolves its default target as project-local only
(`<repo root>\.duckdb-skills\state.sql`). It deliberately does **not** implement
`~\.duckdb-skills\<project-id>\` resolution: `PLAN-1.md:308`'s pointer
(`skills/query/SKILL.md:24-27`'s `tr '/' '-'`) leaves the Windows drive colon in place, which is
not a legal directory name, so that term is not implementable as written. Item 2's spec must
settle `<project-id>` together with the plan revision that carries it, at which point
`SKILL.md:22-25`'s state-file precedence (home-side file wins when present) also needs
deciding against this spec's project-local-only default.

## Why the shortfall against the 28 / 36 "prior" figures

PLAN-1 measured macro 28 and polyglot 36 as **error-free counts** against the *unadapted*
probe SQL, using a macro set that still included the type-wrong `DATEADD`. This fixture's
counts (26, 33) are **correctness counts** against the *adapted*, one-row-one-column SQL, using
a macro set with `DATEADD` removed. The two counting methods are not directly comparable
construct-for-construct, but the largest identifiable drivers of the gap are:

- Removing `DATEADD` from the macro set costs exactly one macro-mode pass (deliberate).
- Type assertion newly fails `DATE_TRUNC str` in both macro and polyglot mode (not a runner
  regression — see reconciliation above).
- Type assertion newly fails `TRY_TO_NUMBER` and `DATEADD` in polyglot mode specifically
  (both silently wrong, not erroring — see "Measured wrong translations").
- `TO_CHAR fmt`'s wrong translation was not previously distinguishable from a pass under the
  error-only method.

A construct-for-construct reconciliation to the exact prior 28/36 figures is not possible from
this fixture alone, because the prior figures were never recorded per-construct — only as
totals. Everything this fixture *can* attribute is attributed above.
