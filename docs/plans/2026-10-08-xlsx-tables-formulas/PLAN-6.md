# PLAN-6 — Read Excel tables and named ranges by name, and check workbook formulas in contracts

> **Version 1.** Numbered on from PLAN-5 at Phil's request (same convention PLAN-5 used); a new plan,
> not a revision of PLAN-4 or PLAN-5. Continues the Cortex Code session "Query ListObject Tables in
> Workbooks" (2026-10-06), whose findings are now in shared memory (`origin:cortex-session`).
> Revised in place after `REVIEW-plan-6.md` (no task had spawned): error check counts value errors
> too; directive forms fixed to the existing grammar; generator and formula view run only when a
> contract uses them; query skill generates per call; lake manifest schema untouched; proof
> contracts' home stated.

**Serves:** Phil can point a query or a contract at an Excel **table (ListObject) or named range by
its name** — `FROM read_xlsx_table('…Data Extracts.xlsm', 'Job_Rate_Tiers')` — and get exactly that
table's rows, never a sheet-guess that silently stops early or runs past the end. And a contract can
**check a workbook's formulas**: that a table column's formula is the same on every row with no typed
values over it, that error cells (`#REF!`, `#N/A`, …) haven't grown, and that key formulas haven't
changed since they were committed.

## Decisions Phil made (2026-10-07)

1. **No C++.** The Cortex session designed a DuckDB community extension; this laptop has no C++
   toolchain and an extension needs a rebuild per DuckDB release. Instead a script reads the table and
   named-range locations out of the workbook **on every run** and hands them to DuckDB as generated
   SQL macros. Nothing is baked into a contract, so nothing can go stale. Accepted limitation: the
   functions exist only where the plugin's tools load them (contract runners, the query skill's
   session state), not in a bare `duckdb` prompt.
2. **Formula checks wanted:** consistent column formulas; no growth in error results; formula
   fingerprint. **Not** wanted now: external-link checks.
3. **Formula proof workbook:** the SDI Calculator (`…\Analytics\SDI Calculator\SDI Calculator Data
   thru Current Month.xlsx`), read from a **staged copy only** — it is a live working file.

## Measured facts — verified on this machine, 2026-10-06/07

### Table and named-range reads

- `read_xlsx` (excel extension, DuckDB v1.5.5) cannot address a table or a named range: 8 parameters,
  never opens `xl/tables/*.xml`. Upstream issue duckdb/duckdb-excel#7 open, no timeline.
- `sheet=` + `range=<table ref>` reads a table correctly; sheet-only reads do not. `Executive_Reviews.xlsx`,
  table `Exec_Review_Details` (`A2:AO124`): sheet default **121** rows, `stop_at_empty=false` **130**,
  sheet+range **122** (correct). Both wrong answers exit 0.
- **The no-C++ mechanism works** (tested 2026-10-07 on a generated fixture): scalar macros whose body
  is a literal `CASE` (as a generator would emit) fold into `query()`, and a table macro
  `read_xlsx_table(p, t) AS TABLE FROM query('SELECT * FROM read_xlsx(''' || p || ''', sheet=''' ||
  xlsx_table_sheet(p,t) || ''', range=''' || xlsx_table_range(p,t) || ''', …)')` returned the expected
  5 rows, also through a `CREATE VIEW`. A subquery in a table function argument is rejected outright,
  so the macro route is the only pure-SQL route.
- Locating a table in the zip: `xl/tables/tableN.xml` `<table>` tag has `name`, `ref`, optional
  `headerRowCount`, `totalsRowCount`. `ref` has no sheet and includes the header row and any totals
  row. The `<autoFilter>` child has its own `ref` (excludes totals) — scope parsing to the `<table>` tag.
  The table→sheet link is only `xl/worksheets/_rels/sheetN.xml.rels`; numbering doesn't align
  (`table10` on `sheet11`). One sheet can hold several tables: `Data Extracts.xlsm` sheet
  `Job_Internal_Rates` has `Job_Base_Rate` A2:D37, `Job_Rate_Tiers` G2:J107, `Project_Rate_Tiers`
  L2:N112 — **no sheet-level read can produce any of the three**. `Data Extracts.xlsm` has 28 tables
  on 26 sheets.
- Named ranges in the SDI Calculator (staged copy, 2026-10-07): 32 `definedName`s — 6 hidden built-ins
  (`_xlnm._FilterDatabase`), 25 **sheet-scoped** static ranges (the same name, e.g. `ExternalData_1`,
  appears on 5 different sheets, distinguished only by `localSheetId`), and **1 broken**:
  `Excluded_Vendors = _xlfn.ANCHORARRAY(#REF!)`. So a bare name can be ambiguous, and some names
  can't be resolved to a rectangle at all (broken, or a formula such as `OFFSET(...)`).

### Formulas (SDI Calculator staged copy, 2026-10-07)

- DuckDB's excel extension returns cached values only, never formula text. Formula text is in
  `<f>` elements of each sheet XML.
- **7,142** formula cells across 20 of 43 sheets; **1,720** of them dynamic-array (`t="array"`) on
  `Combined` alone; shared formulas (`t="shared"`, dependents carry only `si=`) — 1,752 on
  `SDI_Costcodes`. 62 tables, 61 `calculatedColumnFormula` entries. No `externalLink` parts.
- **691** cells currently show an error: `#N/A` 604, `#REF!` 65, `#VALUE!` 22. So an error check
  must be "not more than the committed count", not "zero". **Only 115 of the 691 are formula
  cells**; 576 are plain error *values* written by queries (`Project_Phases` 297, `SDI_Costcodes` 234,
  `Journal Entry Helpers` 39, 6 elsewhere) — found by the plan review. An error check that looked at
  formula cells only would miss 83% of them.
- **Formula text differs row to row for one logical formula**: `INDEX(_xlfn.ANCHORARRAY(AI$10),$AG10)`
  on row 10, `…$AG11)` on row 11. Consistency must compare a position-independent form (R1C1), not
  the A1 text.
- **`calculatedColumnFormula` is often stale.** Across the 61 calculated columns' data cells: 608
  match it textually, 2,659 differ (mostly the row-relative shift above, some genuinely different),
  2,708 hold **no formula at all** — e.g. `SDI_Costcodes` table columns A–H claim formulas but rows
  3–221 are plain values (query output). The table XML is advisory; the cells are the truth.

## Shared conventions and verified traps

- **Never write to a workbook.** Every tool opens the zip read-only. The SDI Calculator and
  `Data Extracts.xlsm` are read from staged copies in proofs; the SHA-256 of each source is captured
  before and after, as in items 3+4.
- **Python stdlib only** for the new reader (`py -3.12`, `zipfile` + `xml.etree.ElementTree.iterparse`),
  matching `tools\sf.py`'s "standard library only" rule (it adds only the Snowflake connector). Streams
  sheet XML; never loads a 68 MB workbook's sheets into memory at once.
- **Generated SQL is regenerated every run** into the project's `.duckdb-skills\` state (gitignored,
  per PLAN-5 item 2), never committed, never hand-edited.
- **Refuse, don't guess.** An ambiguous bare name, a broken or formula-defined named range, an unknown
  table → a named `REFUSED`/`ERROR` line and non-zero exit, never a fallback to sheet reads.
- **Positive tests for every check** (Phil's standing rule): each formula check is made to fire on a
  throwaway copy with a planted defect, then shown to pass again on the clean copy. A check that only
  ever passes proves nothing.
- Acceptance checks name real values (row counts, error counts, specific cells), and stay few —
  aimed at the actual risk.

## Non-goals — deliberate, do not add

- No C++ / community extension (Decision 1). The function names are chosen so an extension could
  replace the generator later without contracts changing — but building it is not in this plan.
- No external-link check (Decision 2).
- No formula evaluation. We read what Excel stored; we never recompute.
- No resolving formula-defined (dynamic) named ranges — they are refused with their formula shown.
- `tools\list-sheets.ps1` stays as is (zero-dependency bootstrap; the Cortex session's conclusion).
- No `.xlsb` support.
- No change to the existing contracts' behaviour: `Clayco_Job_Costs_from_GL.sql` and
  `All_Sales_Data.sql` must produce the same check output before and after.

## Items

### 1 — Workbook catalog and the by-name read functions

Deliverable: `tools\xlsx_meta.py` with subcommands:

- `tables <workbook>` and `names <workbook>` — discovery, one row per table / named range:
  table name, sheet, ref, data range (header and totals trimmed), header rows, totals rows, column
  count; for names: name, scope (workbook or sheet), sheet, range, and a `status` of `ok`,
  `ambiguous` (bare name exists on several sheets), `formula` or `broken`. Hidden `_xlnm.*`
  built-ins excluded.
- `macros <workbook>...` — emits a SQL file defining `xlsx_table_sheet`, `xlsx_table_range`,
  `read_xlsx_table(path, table)`, `xlsx_name_sheet`, `xlsx_name_range`, `read_xlsx_name(path, name)`
  for the given workbooks. Names are addressed as `Name` or `Sheet!Name`; an ambiguous bare name
  resolves to an error, not to one of the candidates. A sheet-scoped name whose sheet has spaces is
  written Excel's way: `'Journal Entry Helpers'!ExternalData_1`. `read_xlsx_table` passes
  `all_varchar = true` (contracts cast explicitly, per items 3+4). The macros escape `'` in paths
  inside the `query()` string, match paths after normalizing slashes and case, and refuse a table
  with `headerRowCount="0"` rather than guess column names.

Proof: `read_xlsx_table` returns 122 rows for `Exec_Review_Details`, and each of the three
`Job_Internal_Rates` tables returns its own ref's row count (35, 105, 110 data rows from the refs
above, re-measured at spec time). `names` on the SDI copy reports the 25 sheet-scoped ranges as
`ok` when addressed `Sheet!Name`, bare `ExternalData_1` as `ambiguous`, and `Excluded_Vendors` as
`broken`. (`Executive_Reviews.xlsx` lives at `…\Profit Plans - General\Analytics\Executive_Review_Automation\`.)

### 2 — Contracts can read by table or named range

- New one-value directives `-- @table: <name>` and `-- @name: <name>` (same colon grammar as
  `-- @sheet: X`), as alternatives to `@sheet` — exactly one of the three per contract.
- **Sheet-only contracts execute exactly as today.** The runners (`check-contract.ps1`,
  `run-assertions.ps1`, `materialize.ps1`, `prove-requery.ps1`) run the generator **only** when the
  contract has `@table`/`@name` or calls `read_xlsx_table(`/`read_xlsx_name(`, and then `.read` its
  output before the contract, the same way they `.read` `duckdb-compat.sql`. A generator or Python
  failure therefore cannot reach the two existing contracts.
- **The query skill generates per invocation, never via `state.sql`.** A permanent `.read` line
  would serve whatever was generated last, for whichever workbook — exactly the staleness Decision 1
  rules out. The skill runs `xlsx_meta.py macros <workbook>` into the session's scratch and `.read`s
  that file in the same `duckdb` call.
- The truncation/consistency checks (`run-assertions.ps1:443,506`) read the **resolved** sheet+range
  for a table or name contract, instead of the whole sheet.
- The workbook-path regex (`run-assertions.ps1:370`, `materialize.ps1:276`) accepts
  `read_xlsx_table(` / `read_xlsx_name(` as well as `read_xlsx(`.
- `materialize.ps1`'s freshness key covers the generator script **by folding its SHA into the
  existing `compat_sha256` value, and only for contracts that use the generator.** No new manifest
  column (`lake.manifest` has a fixed 12-column schema with positional inserts, `materialize.ps1:333,
  479, 530` — a 13th value would fail on every existing lake), and the existing contracts' key is
  unchanged, so they do not even refresh once.
- **The directive keyword list moves to one shared file** read by both `check-contract.ps1:101` and
  `run-assertions.ps1:257`. It is duplicated today; this plan adds keywords twice (items 2 and 4), so
  a third and fourth drift chance is worth closing now.

Proof: a new contract `contracts\Job_Rate_Tiers.sql` over `Data Extracts.xlsm` table
`Job_Rate_Tiers` — committed, on the same live path the existing contracts already read (read-only)
— passes all checks and materializes. The two existing contracts' `run-assertions.ps1` output **and**
a `materialize.ps1` run on an existing lake are unchanged (before/after diff empty apart from
timings; both report SKIPPED-fresh, not a refresh).

### 3 — Read a workbook's formulas

`tools\xlsx_meta.py formulas <workbook>` writes one row per formula cell, loaded as a DuckDB view
`xlsx_formulas` / macro `read_xlsx_formulas(path)`: sheet, cell, row, column, table and table column
(if the cell is in a table's data body), formula kind (normal / shared / array / data-table),
formula as stored (A1), formula in **R1C1** (position-independent), cached value, error code if the
cell shows an error. Shared-formula dependents get their master's R1C1 (identical by definition) and
their A1 text translated from the master.

Two more kinds of row, both with formula kind `none`:

- **Every error-valued cell** (`t="e"`), formula or not — so the error check sees the 576 query-written
  `#N/A` values as well as the 115 formula errors.
- **Every non-formula data cell** (typed value *or* blank) inside a table column that has formulas in
  at least one of its **cells** — decided from the cells, never from `calculatedColumnFormula`, which
  is often stale (otherwise `SDI_Costcodes` A–H alone would produce ~2,700 false rows). This makes
  "a value typed over a formula column" queryable.

The R1C1 converter is the riskiest code in the plan. It must leave alone: strings in quotes; any
identifier followed by `(` (functions — covers `LOG10`, `ATAN2`, `DAYS360`); `_xlfn.`/`_xlws.`
prefixes; error literals (`#REF!`); structured references (`Table[[#This Row],[Col]]`); the
implicit-intersection `@`; scientific notation (`1E3`). It must convert: sheet-qualified refs,
including quoted sheet names and one that looks like a cell (`'Q1'!A1`), whole-column (`A:A`),
whole-row (`1:1`) and range (`A1:B5`) refs, with `$` absolute parts kept absolute. A small fixture
workbook with one formula per trap is a deliverable.

Proof on the SDI copy: 7,142 formula rows; 691 error cells by code (604 / 65 / 22), split 115
formula / 576 value; and the two `Combined` cells above (`…$AG10)`, `…$AG11)`) share one R1C1 form.

### 4 — Formula checks in contracts

Three new **named** directives, in the existing `-- @kw <name>: <value>` grammar (`<name>` matches
`[A-Za-z0-9_]+`, unique in the file — same rules as `@assert`). Scope is written as in item 1:
`*` (whole workbook), a sheet (`'Journal Entry Helpers'!`), a table (`Tbl`), a table column
(`Tbl[Col]`), or a cell / single-cell named range.

- `-- @formula_consistent <name>: <Tbl>[<Col>]` — every data row in the column holds a formula, all
  with one R1C1 form. A blank data cell counts as a violation, like a typed value. Reports rows,
  distinct forms, typed-value/blank rows. Fails if forms > 1 or violations > 0.
- `-- @formula_errors_max <name>: <scope> <= <n>` — fails if error cells in scope exceed `n`;
  always reports the count by error code and split formula / value, so a fall is visible too.
- `-- @formula_fingerprint <name>: <scope> == <R1C1 text>` — scope is a table column (its single
  R1C1 form; a column with more than one form fails and says to use `@formula_consistent`) or a
  single cell. Fails on any difference.
- **Separators:** the value is split at the **first** ` <= ` or ` == ` (spaces required), because
  `:` is already the name separator and R1C1 text itself contains `:`. A scope containing the
  separator is refused.
- **Failures print A1 beside R1C1** (with a sample cell address) — Phil reads A1.
- **Who evaluates them:** `run-assertions.ps1`, which emits `ASSERT,<name>,PASS|FAIL,<detail>`
  lines, so `materialize.ps1:421` records them in check history as `invariant` with no new parsing.
  `check-contract.ps1` (which only evaluates `@assert`) accepts the keywords and prints
  `SKIPPED <name> (evaluated by run-assertions.ps1)` for each — visible, not silent.
- **The formula view is built only when needed:** a formula directive is present, or an `@assert`
  mentions `xlsx_formulas`. Then free-form `-- @assert` over it is the escape hatch for anything the
  three don't cover. Contracts without either never pay the full-workbook stream.
- Docs note: `@formula_fingerprint` (formula text) is unrelated to the existing `@fingerprint`
  (column-header list).

Proof: a proof contract over one SDI Calculator table — a column that is genuinely consistent today,
chosen at spec time from the measured data — passes on the staged copy. Then, on throwaway copies,
each check is made to fire once (a typed value planted in the column, one formula changed, one extra
`#REF!`) and the clean copy passes again.

**Where proof contracts live:** the SDI proof contract points at a staged copy, so it is committed
under `tests\contracts\` (not `contracts\`, which the default runners glob) and run with
`-Contract`, alongside a small script that stages the copy and plants the three defects. Only
contracts on a stable path, like item 2's `Job_Rate_Tiers.sql`, go in `contracts\`.

### 5 — Documentation and release

Query skill, lakehouse skill and README describe `read_xlsx_table`, `read_xlsx_name`,
`read_xlsx_formulas` and the new directives, with one worked example each. Version bump to 0.4.0 in
`plugin.json` and `marketplace.json` after the last item ships (per the PLAN-5 rule, changes reach
the install only on a bump).

## Intended spec boundaries

Four specs, in order: **1**, **2**, **3**, **4**. Item 5's docs ride with the item they describe;
the version bump happens after item 4 ships. Items 1→2 deliver the table/name reads on their own;
3→4 the formula checks. If item 1 or 3 turns up a measured fact that changes a later item, that is a
PLAN-7, not an edit here.

## Risks

- **R1C1 conversion bugs give silent wrong answers** (two different formulas look identical, or one
  formula looks like two). Mitigation: the trap fixture in item 3, plus item 4's planted-defect proofs.
- **The functions only exist inside the plugin's tools** (Decision 1). A contract run through a bare
  `duckdb -f` fails with "macro does not exist" — loud, not silent. Documented.
- **Generated macros per run add a zip scan.** Expected small (catalog reads only `workbook.xml`,
  rels and `tables/*.xml`), but measured on the 68 MB `Data Extracts.xlsm` in item 1; formula
  extraction streams every sheet and is only run when a contract needs it.
- **A live workbook may be locked by Excel** when a runner reads it. Existing behaviour; the same
  staged-copy rule applies.
- **Stale `calculatedColumnFormula`** could tempt a later change to "check against the table's
  formula". Recorded here so it isn't: the cells are the truth.

## Follow-on work — not in this plan

- A C++ community extension with the same function names, if a toolchain or CI build becomes
  worthwhile.
- External-link checks.
- Formula checks spanning several workbooks.
