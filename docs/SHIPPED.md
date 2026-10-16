# Shipped

Newest first. Earlier work is recorded under `docs/tasks/<date>-<slug>/SHIPPED.md`.

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
