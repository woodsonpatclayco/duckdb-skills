# Shipped

Newest first. Earlier work is recorded under `docs/tasks/<date>-<slug>/SHIPPED.md`.

## 2026-11-05 — Contracts read Excel headers with line breaks (v0.6.2)

**The feature:** a contract can use a table whose header cells hold a line break (Alt+Enter)
as its data source, and multi-line check details arrive whole. Found by the Project Profit
data quality checks (risk-reserve repo), whose Risk_Reserve_Summary has 19 such headers.

**Before / after:** on a frozen copy of Project Profit 26-10 October with the contract's
`@table` switched to `Risk_Reserve_Summary`, v0.6.1 printed
`ERROR,...,Binder Error: Referenced column ""Current Revenue JDE" not found` and skipped every
formula check. v0.6.2 prints no ERROR line and runs all 120 checks: 112 PASS, 8 FAIL, which are
the workbook's own findings (typed-over Summary cells, B6 blank, C244/C245 `#REF!`). Details that
used to stop at a line break (a DuckDB error's `LINE 1:` context, a two-line formula) now print
whole on one line, joined with ` | `.

**Prove it:**

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\prove-linebreak-headers.ps1

Expect `RESULT: PASS`, preceded by the old code's Binder Error and the new code's
`FINGERPRINT,MATCH` and `calc_consistent` FAIL naming only E4.

**What deliberately did not change:**
- **Output is byte-identical for every contract without line-break headers.** The proof
  compares old and new on all 5 contracts in `contracts\`, and on NULL, empty and non-ASCII
  values.
- **A line break is written as `\n`** in `@fingerprint`, `@snapshot_committed` and `@anchor`.
  The lake table keeps the real names.
- **The risk-reserve contract still uses `Combined_Project_Details`.** Switching it is a change
  in that repo.
- **`xlsx_meta.py`'s two gaps are not fixed here:** it counts empty spill placeholders as
  formulas, and it drops an array formula's range.
- **`prove-contract-tables.ps1` still calls plain `tar`.** It fails when run from Git Bash
  (GNU tar reads `C:` as a host) but works from PowerShell. The new proof calls Windows' tar.exe.

## 2026-10-20 — SDI Calculator contract with formula checks (v0.6.1)

**The feature:** the first real contract with formula checks, `contracts/SDI_Combined_SDI_Data.sql`.
It guards the SDI Calculator's Combined_SDI_Data table, the source of the month's SDI journal
entry: the posting and earnings columns keep one formula on every row, the posting formula is
still the committed one, and error cells don't grow.

**Before / after:** before, no contract in `contracts/` checked formulas, and `xlsx_meta.py`
failed with `PermissionError` on the live SDI workbook whenever Excel or OneDrive held it open
(DuckDB could read it). After, `run-assertions` on the contract prints 11 checks, all `PASS`:
81 rows, six columns with one formula each, `errors 5 (max 5)` in the table, and
`errors 722 (max 722)` in the workbook.

**Prove it:**

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-assertions.ps1 -Contract contracts\SDI_Combined_SDI_Data.sql

The last line should read `SUMMARY,contracts=1,assertions=11,failures=0`.

**What deliberately did not change:**
- **Insurance_Basis's bonds column is not checked yet.** It mixes formulas, typed values and
  blanks, and that waits on Phil's decision. The contract says what to add afterwards.
- **No checks on Not_to_Exceed_SDI or Final_Pay_App_Adjs.** They are hand-entered override
  tables, not formula columns.
- **The view stays all VARCHAR.** Casts belong in queries for now.
- **A line like `--   @formula_consistent ...` is live even inside a comment block.** The
  runners match `-- @` at any indentation. Write a parked check without the at-sign.

## 2026-10-20 — Excel tables and named ranges through the xlsx_meta extension (v0.6.0)

**The feature:** reading an Excel table or named range by name (`read_xlsx_table` /
`read_xlsx_name`) now goes through the C++ `xlsx_meta` DuckDB extension, built for Windows,
instead of generating macros with Python on every call. When the extension can't load, the
Python route takes over automatically. Plan: `docs/plans/2026-10-20-xlsx-meta-windows/`.

**Before / after:** before, every by-name read first ran `py -3.12 tools\xlsx_meta.py macros`
to generate SQL for that one workbook. After, the plugin ships
`extension\bin\v1.5.5\windows_amd64\xlsx_meta.duckdb_extension`, built by GitHub Actions, and
the skills `LOAD` it with one fixed macros file (`tools\xlsx_meta_macros.sql`) that works for
any workbook path. On `Job_Rate_Tiers` in Data Extracts.xlsm, both routes return the same 105
rows with the same content hash. `run-assertions`/`check-contract` output is identical line for
line. On seven real workbooks, the extension and the generator agree on every table and name
listing and on 3,127 lookups.

**Prove it:**

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\prove-xlsx-meta-route.ps1

It prints which route each mode took (the extension path vs `python generator`), the two
contract-check comparisons (`identical`), the scratch-lake row counts (105 both ways), and
`RESULT: PASS`.

**What deliberately did not change:**
- **Formulas stay on Python.** `read_xlsx_formulas` and the `@formula_*` checks always run
  `xlsx_meta.py macros --formulas`; formula extraction was never ported to the extension.
- **The Python generator stays, unchanged.** It is the fallback for any DuckDB other than
  v1.5.5, and `DSK_XLSX_META=python` forces it. Don't delete it.
- **Sheet contracts are untouched.** They never load the extension, and their freshness key
  is the same (`tests\prove-contract-tables.ps1` still passes).
- **By-name contracts re-materialize once** the first time they run on 0.6.0. The extension
  binary's SHA-256 is now part of their freshness key, on purpose.
- **Unsigned, and only for Windows x64 / DuckDB v1.5.5.** There is no signing, no community-
  extension publishing, and no Linux or macOS binary in the plugin. After a DuckDB upgrade,
  run the workflow for the new version and `tools\fetch-xlsx-meta.ps1`; until then the Python
  route serves.
- **`-unsigned` is passed only to the duckdb calls that read the macros file**, and only once
  the extension route is taken.

## 2026-10-16 — Excel-ready CSV export with a types file (v0.5.0)

**The feature:** export any DuckDB data (a file, a `.sql` file, or SQL text) as a CSV that
Excel's Power Query reads from SharePoint with the right column types, without anyone
typing a column list into the query.

**Before / after:** before, a CSV loaded in Power Query came in as text, and every column's
type had to be set by hand in the query. After, `tools\export-excel-csv.ps1` writes
`<name>.csv`, `<name>.types.csv` (DuckDB's `DESCRIBE`) and `<name>.pq.m`. Run in Excel,
that query types the 100,000-row proof table as `id=Int64.Type, amount=Number.Type,
gl_date=Date.Type, posted_at=DateTime.Type, is_even=Logical.Type, job=Text.Type, ...`,
with 0 error rows.

**Prove it:**

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\prove-excel-csv.ps1

It prints the column list from the export, the hidden-Excel `probe-m` result, then
expected-vs-got rows, error rows and types, and finally `PASS`.

**What deliberately did not change:**
- **No Parquet for Excel.** Excel's Power Query has no `Parquet.Document` (tested on build
  16.0.20430). Don't add a Parquet route for Excel consumers.
- **convert-file's plain `.csv` row is unchanged.** The types file and `.pq.m` are written
  only by the Excel export.
- **The proof doesn't touch SharePoint.** It runs `-Local`, which swaps only the
  `SharePoint.Files` source step for `File.Contents`; everything after it is the shipped
  template. The SharePoint source needs a real site and a sign-in, so it hasn't been tested.
- **Types are simplified on purpose.** `DECIMAL` maps to `type number`, not
  `Currency.Type`, which keeps only 4 decimal places. `HUGEINT` and unmapped types (UUID,
  INTERVAL, LIST, ...) stay text rather than risk an Int64 overflow or a failed conversion.
- **CSV limits are left as they are.** A NULL text value arrives in Excel as an empty
  string, and `TIMESTAMP WITH TIME ZONE` is written in the exporting machine's time zone.
