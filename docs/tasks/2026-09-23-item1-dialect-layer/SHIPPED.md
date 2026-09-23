# SHIPPED — Item 1, the dialect layer

Plan: `PLAN-2.md` item 1 (specced against `PLAN-1.md`, re-pointed mid-flight when round 1 proved the
plan itself wrong). Branch `item1-dialect-layer`. Verified SHIP by `VERIFY-2.md`, round 2.

## What shipped

| Path | What it is |
|---|---|
| `skills/query/duckdb-compat.sql` | 17 macros, BOM-free |
| `skills/query/duckdb-compat-tests.csv` | 50-row correctness fixture, `source`-classified |
| `tools\ensure-duckdb-compat.ps1` | idempotent `.read` delivery into `state.sql` |
| `tools\run-compat-tests.ps1` | three-mode runner, verified/deviation/fail split |
| `skills/query/duckdb-compat.md` | before/after table, residuals, pins, routing rule |
| `skills/query/SKILL.md` | routing section, body only — frontmatter untouched |

## The point of it, in one before/after

Before: `SELECT IFF(1>0,'y','n')` failed on DuckDB with a `Catalog Error`, and so did `NVL`, `DIV0`,
`TO_VARCHAR` and `TRY_TO_NUMBER` — every one a retry round mid-analysis.

After, one command:

```powershell
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT IFF(1>0,'y','n') AS a, NVL(NULL,'x') AS b, TRY_TO_NUMBER('12.3') AS c, DIV0(10,4) AS d, xl_date(46204) AS e"
```

→ `y,x,12,2.500000,2026-07-01`

Every one of those five matches what Snowflake returns, measured on CLAYCO-DATAHUB rather than assumed.

## What this round actually bought, beyond the macros

**Five of the seventeen seeded macros were wrong against real Snowflake.** None of it was visible to
the old error-only probe, because every one of them ran without raising an error:

| macro | was | Snowflake |
|---|---|---|
| `TO_NUMBER` / `TRY_TO_NUMBER` | `12.300000` / `DECIMAL(38,6)` | `12` / `NUMBER(38,0)` |
| `DIV0` / `DIV0NULL` | `0.0` / `DOUBLE` | `0.000000` / fixed-point |
| `REGEXP_SUBSTR` (no match) | `''` | `NULL` |
| `UUID_STRING` | type `UUID` | `VARCHAR(36)` |

The `TO_NUMBER` one mattered most: the macro *preserved* decimals Snowflake rounds away, so a query
ported from Snowflake returned `12.3` locally where production returns `12`.

**Two findings that outlive this item:**

- **`TRY_TO_DATE` disagrees with Snowflake on all-digit strings.** Snowflake reads `'46204'` as an
  epoch offset and returns `1970-01-01`; DuckDB returns NULL. Not reconcilable in a macro. `46204` is
  the Excel serial items 3–6 are built on, so `xl_date()` is the tool for serials and `TRY_TO_DATE`
  must not be used for them. Recorded as a permanent residual, not papered over.
- **polyglot bypasses the macros for five names.** It rewrites `TO_NUMBER`, `TRY_TO_NUMBER`, `DIV0`,
  `DIV0NULL` and `REGEXP_SUBSTR` to native DuckDB, so the macro never sees them and polyglot's wrong
  answer stands. `TO_VARCHAR` passes through untouched, which is why "macros compose inside
  `polyglot_query`" looked true in round 1. `SKILL.md` now says which five to keep out of polyglot.

## What deliberately did NOT change

- **`DATEADD` is still excluded from the macro file.** Its TIMESTAMP-vs-DATE drift is unfixed. Do not
  add it back without a type assertion.
- **`DATE_TRUNC str` still fails in all three modes, on purpose.** DuckDB's `date_trunc()` returns
  TIMESTAMP from a DATE input; Snowflake returns DATE. It is unfixable by macro and uncorrected by
  polyglot. It read as passing for as long as this project measured by absence of errors, and
  round 2 explicitly refused to relabel it into a pass — `AC13` exists to stop a future session doing
  so. **If you find it passing, something was weakened.**
- **`<project-id>` and the `$HOME\.duckdb-skills\` state path are not implemented.** `PLAN-2.md`
  defines the term; item 1 writes only to the project-local `state.sql` and prints the path it
  resolved. Item 2 settles the precedence, which `skills/query/SKILL.md:22-25` currently has
  preferring the home-side file.
- **The eight upstream bash skills are untouched.** They remain POSIX and do not run on this machine.
  Delivery deliberately bypasses `skills/attach-db/SKILL.md:111-137` rather than fixing it.
- **`.duckdb-skills/sf-compat.sql` and `dialect-probe.ps1` are still gitignored and still present**
  as local evidence. Nothing loads them any more. `.gitignore` unchanged.
- **No second `-init`.** Macros arrive via a `.read` line at line 1 of `state.sql`. `duckdb -init`
  takes exactly one file and a second silently replaces the first.
- **The runner's internals were frozen in round 2** — tag-block parsing, `2>$errFile`, error-class
  matching, pin assertion, malformed-row rejection, `polyglot_transpile` emission all verified in
  round 1 and diffed byte-identical afterwards. Only the counting split and numeric value comparison
  changed.

## Numbers as shipped

Fixture 50 rows: 41 `snowflake`, 8 `deviation`, 1 `duckdb-native`. Per mode, verified / deviation /
fail: **raw 14/3/33, macro 28/6/16, polyglot 32/5/13.**

These are *correctness* counts. PLAN-1's raw 17 / macro 28 / polyglot 36 were error-free counts and
are retired — do not compare against them. Residuals, 8: `DATEADD`, `DATE_TRUNC str`, `TO_CHAR fmt`,
`RATIO_TO_REPORT`, `FLATTEN`, `CURRENT_TIMESTAMP()`, `LATERAL FLATTEN`, `TRY_TO_DATE serial`.

Pinned: DuckDB **v1.5.5**, polyglot **`8f1666d`** (community, so it can change under you — the runner
exits non-zero on drift).

## Process note worth keeping

Round 1 passed every acceptance check and was still rejected, because the fixture graded itself: two
expectations had been copied from what the macro produced. The fix that mattered was not a code
change but a rule — **expectations come from Snowflake, and the session that measures them pastes the
values into the spec** so the implementer receives a fact rather than an errand. That rule is now in
`PLAN-2.md`'s shared conventions. It is what turned up the other three macro defects.
