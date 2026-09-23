# PLAN-2 — Local lakehouse over Excel workbooks and Snowflake extracts

> **DRAFT.** Reviewed once by `plan-reviewer`; eight blocking issues found and folded in. Three
> open questions at the bottom still need Phil. Not frozen — no `TASK.md` names it, so edit in
> place.

> **PLAN-2 is a second, distinct plan, not a revision of `PLAN-1.md`.** Both are current.
> PLAN-1 stays in force and this one depends on it. Under the versioning convention a bumped
> number normally means "the instructions changed"; that is *not* what this is, which is why the
> relationship is stated explicitly below. See open question 1 if the numbering should differ.

**Serves:** One SQL surface where an Excel workbook sheet and a Snowflake extract are both just
tables, so joining them is ordinary SQL — and the joined result is saved and re-queryable
without re-reading either source.

## Relationship to `PLAN-1.md` — read this first

PLAN-1 (2026-09-22, not frozen) already owns Snowflake extraction and extract freshness.
**This plan does not re-decide any of it.** It inherits:

- Transport is `COPY INTO` Parquet → `GET` → `REMOVE` through the app's built-in connection. The
  `snow` CLI was **rejected** (not installed, CSV-only output forcing a type-losing hop).
- **One directory per extract**, not one file, because `COPY INTO` splits output. Queried as
  `<dir>\*.parquet`.
- Extract freshness is an **age-against-a-window judgment** recorded in a `<dir>\_extract.json`
  sidecar, parameterized by `DSK_WINDOW_MINUTES`, reader's mode governing. **Not** an mtime
  comparison.
- Extracts live at one absolute, gitignored location — production data, never committable.

This plan therefore owns only the **workbook read layer** and the **lakehouse**. It consumes
extract directories and reads their sidecar for age. Anything about pulling from Snowflake
belongs to PLAN-1 item 2.

## Measured facts this plan rests on

All verified in-session on this machine, 2026-09-22.

- `ducklake` and `excel` are **core** extensions (`installed_from = core`), not community.
- DuckLake runs on a purely local catalog: `ATTACH 'ducklake:catalog.ducklake' AS lake (DATA_PATH '...')`.
  **No PostgreSQL.** ducksync's Postgres requirement is ducksync's, not DuckLake's.
- Proven end to end: wrote a real `.xlsx` and `.parquet`, joined them, materialized into
  DuckLake, then in a **separate process** read the result back without touching sources,
  chained it to a CSV, and materialized a second-generation table. Exits 0.64s and 0.3s.
- `.xlsm` reads fine and fast: 64 MB workbook, a 123-column sheet plus a 61,741-row sheet, 1.4s.
  Macros irrelevant — DuckDB reads sheet values only and never touches `vbaProject.bin` or the
  Power Query DataMashup blob. **Workbooks are read-only sources; the entire
  `xlsx-connected-data` failure mode is out of scope by construction.**
- **Type inference is unsafe.** `VENDOR_NAME` inferred DOUBLE; with `ignore_errors=true`,
  `COUNT(VENDOR_NAME)` = **0 of 61,741**. With `all_varchar=true` it is **51,571**. Silently
  nulled, query "succeeded".
- Without `ignore_errors` it fails loudly: `Invalid Input Error: read_xlsx: Failed to parse cell
  'I3': Could not convert string 'City of DeKalb' to DOUBLE`.
- **`all_varchar` alone also destroys dates** — the same bug class. `GL_PERIOD` comes back
  VARCHAR holding Excel serials (min `46204`, max `46296`), and `TRY_CAST('46204' AS DATE)` →
  **NULL**, silently. Correct form: `(DATE '1899-12-30' + to_days(GL_PERIOD::BIGINT))::DATE` →
  2026-07-01 to 2026-10-01. The trailing `::DATE` is required; `+ to_days()` yields TIMESTAMP.
- Money survives exactly: `SUM(JOB_COSTS::DOUBLE)` = 22,390,953,840.92989 vs `::DECIMAL(18,2)` =
  **22,390,953,840.93** — exact at the cent.
- **Lexicographic trap:** on `all_varchar` columns `MAX(JOB_COSTS)` = `'99999.72'`; cast first
  and it is **256,178,387.75**.
- Null rates differ wildly per column: `JOB_COSTS` 0%, `VENDOR_NAME` 83.5% non-null, `GL_PERIOD`
  **70.2% NULL**. Floors must be measured per column.
- No sheet-listing function exists. Sheet names read from `xl/workbook.xml` in the zip,
  read-only, no Excel. `Data Extracts.xlsm` has **26 sheets**; the first is a 2-row `MetaData`
  sheet, not data.
- Column names are hostile: embedded newline in `Projected\nCompletion Date`; duplicate headers
  auto-suffixed **positionally** — `Job Cost to Date` / `...to Date3`, and the same pattern for
  `Job Revenue`, `Job Cost Profit`, `Job Billed`, plus all four `Segment` equivalents.
- **DuckLake keeps history through `CREATE OR REPLACE`**: `FROM lake.snapshots()` lists every
  change and `AT (VERSION => 1)` still returns pre-replace data. Materializing does not destroy
  its own evidence.
- DuckLake **inlines** small tables into the catalog file (`file_count = 0`); Parquet appears
  only past a size threshold. `DATA_PATH` creates no directory until then.
- `read_xlsx` params are exactly: `col0, header, all_varchar, stop_at_empty, ignore_errors,
  range, sheet, empty_as_varchar, normalize_names`.

## Non-goals — deliberate, do not add

- **No `.xls` support.** Excluded by Phil, 2026-09-22. No Excel COM, no conversion stage.
- **No ducksync, no Quack listener, no PostgreSQL.**
- **The `snowflake` DuckDB extension is never loaded by anything here.** Its ADBC teardown
  defect leaves an unkillable process holding a driver lock, needing a reboot — reproduced on
  driver v1.11.0 and v1.14.0. Note the scope precisely: this forbids the **DuckDB extension**,
  not programmatic Snowflake access. PLAN-1's transport is fine.
- **No source workbook is ever written to.** Read-only always, including in tests.
- **No long-lived service.** Every invocation is a short-lived DuckDB process that exits.
- **No re-planning of extraction or extract freshness.** See the relationship section.

## Items

Sequence **1 → 2 → 3 → 4 → (5 || 6) → 7 → 8**. Items 3, 4 and 7 can land on the GL sheet alone,
so item 6 does not block shipping.

### 1 — Contract format and shared helpers

The foundational decision; everything else depends on its shape.

A **contract** is one `.sql` file per sheet containing a `CREATE OR REPLACE VIEW` over
`read_xlsx`, with `all_varchar = true`, **never** `ignore_errors`, and an explicit cast per
column. A `CREATE VIEW` cannot hold assertions, so the format must state concretely where they
live — either `-- @assert` directives parsed by item 4, or a companion `<name>__assert` view.
Pick one here; leaving it open costs a correction round.

Ship an `xl_date()` macro for serial→date so the conversion is named once rather than retyped
per column, delivered by appending a `.read C:/forward/slash/path` line to `state.sql` — **not**
a second `-init`, which silently replaces the first (verified in PLAN-1).

Decide and record: `normalize_names = true` versus positional selection, for headers containing
literal newlines under CRLF.

**Acceptance:** `xl_date(46204)` returns `2026-07-01` **and** `typeof()` returns `DATE`.
Asserting type as well as value is required — PLAN-1's `DATEADD` macro silently drifted to
TIMESTAMP.

### 2 — Sheet discovery tool

`tools\list-sheets.ps1 <absolute-workbook-path>` reads `xl/workbook.xml` from the zip.
Read-only, no Excel, never opens the workbook. Must handle Excel's 31-character sheet-name
truncation (`Subcontract_Totals_and_Invoicin`) and a contract-filename convention that survives
spaces and multiple dots.

**Acceptance:** against the pinned absolute path to `Data Extracts.xlsm`, prints **26** sheets,
first is `MetaData`, and both `Project_Profit` and `Clayco_Job_Costs_from_GL` appear.

### 3 — First hand-built contract: `Clayco_Job_Costs_from_GL`

13 columns — tractable by hand, and the sheet all the measurements above come from. Pin the
absolute workbook path; there are ~30 files named `Data Extracts*.xlsm` on this machine and the
numbers are meaningless without it.

**Acceptance**, every value measured:

- **61,741** rows
- `COUNT(VENDOR_NAME)` = **51,571**
- `GL_PERIOD` `typeof()` = `DATE`, min **2026-07-01**, max **2026-10-01**, **18,395** non-null
- `SUM(JOB_COSTS)` = **22,390,953,840.93**, type `DECIMAL(18,2)` — a figure Phil can tie to a
  report
- `MAX(JOB_COSTS)` = **256,178,387.75**, proving the cast-before-compare rule
- the ordered header list matches a committed fingerprint

### 4 — Assertion harness

Runs each contract's assertions and reports pass/fail per column. Must cover: per-column
non-null floors (**measured individually** — `VENDOR_NAME` at 83.5% is a misleading template
when `GL_PERIOD` is 70.2% NULL), **direction-aware** row-count tolerance so a growing GL sheet
doesn't cry wolf monthly, casts applied before any range comparison, and the header fingerprint
from item 3.

Must **not** decide pass/fail by matching the bare word `Error`: DuckDB writes its `-init`
banner to stderr and PowerShell surfaces that as `NativeCommandError`, which cost a full
debugging cycle during PLAN-1. Match DuckDB's error classes only (`Catalog Error`,
`Parser Error`, `Binder Error`, `Conversion Error`); the exit code is trustworthy.

**Acceptance — two mutation tests:**

1. Drop `all_varchar` **and** add `ignore_errors = true` → harness FAILS naming `VENDOR_NAME`
   and the **51,571 → 0** collapse. This is the silent-nulling detector and the harness's whole
   reason to exist.
2. Drop `all_varchar` only → harness FAILS reporting the `'City of DeKalb'` parse error and a
   non-zero exit. Mutation 2 alone cannot prove the detector works, because the read dies before
   any row exists.

### 5 — Contract scaffolder

Generates a reviewable draft contract for a workbook + sheet: normalized column name with the
raw name in a comment, a cast guess, and a TODO on every column needing a human decision. Never
emits `ignore_errors`.

Serial-date columns **cannot** be found by comparing inferred type to content — `46204` agrees
perfectly with DOUBLE. A stated heuristic is required: name matches date/period, or
integer-valued in roughly 20000–60000.

**Acceptance:** scaffold `Project_Profit` → the generated contract **runs** and returns **123
columns** and the real row count; it flags all **four** date columns (`Sales Start Date`,
`Sales End Date`, `Projected Completion Date`, `Last Update`) and the ~90 DOUBLE money columns.
"Output compiles" is not an acceptable check — Phil cannot observe it.

### 6 — Decode the positionally-suffixed columns

Research, and a genuine blocker on any trustworthy `Project_Profit` contract. Four
`...to Date`/`...To Date` pairs plus four `Segment` equivalents differ only by an integer suffix
DuckDB assigned by position. Nobody can alias or cast `Job Cost to Date3` without knowing what
it means, and an upstream column insertion silently changes it.

Establish meaning by reading the workbook's Power Query through the `xlsx-power-query` skill
(M code is base64 in `customXml`; grep and openpyxl never find it). Deliver a committed mapping
table.

**Acceptance:** every suffixed column has a stated meaning and an upstream source, in a table
Phil can read without opening the workbook.

### 7 — Materialize into the lakehouse, with workbook freshness

`CREATE OR REPLACE TABLE lake.<name> AS SELECT * FROM <contract>`. A `lake.manifest` table
records source path, mtime, row count, and contract hash — DuckLake's own `snapshots()` records
changes but not provenance, so the manifest is still justified.

Workbook **mtime is a valid signal**. Extract freshness is **not** mtime — every `GET` rewrites
the Parquet, so mtime always advances and every run would report REFRESHED for exactly the data
most likely to be stale. Extract age comes from PLAN-1's `_extract.json` sidecar.

**Acceptance:** run refresh twice → second reports SKIPPED for all; touch a **scratch copy** of
the workbook → next run reports REFRESHED with a row count. Never touch the live 67 MB
`Data Extracts.xlsm` — it is SharePoint-synced, so writing triggers a full re-upload and version
churn, and it violates this plan's own read-only non-goal. Also assert `FROM lake.snapshots()`
lists the replace and `AT (VERSION => 1)` still returns pre-replace data.

### 8 — End-to-end proof and skill layer

The **`Serves:` test**, which nothing in the first draft checked: point the contract at a
nonexistent path, query the materialized table, get the identical row count — proving results
really are re-queryable without re-reading sources.

Then a cross-source join: a landed extract directory (`<dir>\*.parquet`) joined to a
materialized workbook table in one statement, process exiting under 2s.

Then the non-goal, asserted behaviourally rather than by grep:
`SELECT extension_name FROM duckdb_extensions() WHERE loaded` returns **no** `snowflake` row,
and every entrypoint exits 0 within budget. A grep for `LOAD snowflake` is a fake check — it
already matches `docs\duckdb-snowflake-findings.md` lines 59–70, and it would miss
`INSTALL snowflake` and `ATTACH ... (TYPE snowflake)`.

The skill layer must say whether it extends `skills\read-file\SKILL.md` (which already routes
`.xlsx` to `read_xlsx`) or adds a new skill, and respect PLAN-1's standing-context budget of
<= 4 description lines.

**Acceptance:** Phil follows the doc from a clean shell and reaches a specific joined row count.
Documentation with nothing to run leaves the plan's last step unverifiable.

## Risks

- **Positional column drift.** Mitigated by the item 3 header fingerprint plus the item 6
  mapping — both now assigned to items rather than left in prose.
- **Casting money `DOUBLE -> DECIMAL` freezes what Excel already stored.** It makes values exact
  going forward; it does **not** retroactively recover precision Excel lost. The measured
  cent-exact SUM shows nothing has been lost *here*, but that is a fact about this sheet, not a
  guarantee.
- **Catalog inlining** means materialized tables are not readable as Parquet by other tools
  until flushed. See open question 2.

## Open questions — these block specific items

1. **Is `PLAN-2.md` the right filename?** The repo question is now settled — this plan lives
   here, `duckdb-skills` is a git repo on `main` with a clean tree and no root `TASK.md`, so the
   delegation loop is ready. What remains is the convention: under the versioning rule a bumped
   number means "the instructions changed", but this is a *second distinct plan*, not a revision
   of PLAN-1. A future `TASK.md` carrying `Plan: PLAN-2.md` would read as pointing at a
   superseded PLAN-1. The banner at the top of this file is the stopgap. If a different scheme
   is preferred, it is cheaper to rename now than after the first spec.
2. **Must materialized tables be readable by other tools**, forcing a Parquet flush, or is
   catalog-inlined fine? Blocks item 7.
3. **Is `Project_Profit` worth item 6's decoding work now**, or ship on
   `Clayco_Job_Costs_from_GL` alone first? Items 3, 4 and 7 are complete without it.
