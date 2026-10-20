# PLAN-7: Ship the xlsx_meta extension on Windows

## The feature

The skills read an Excel table or named range by name (`read_xlsx_table` / `read_xlsx_name`)
through the C++ `xlsx_meta` extension instead of regenerating SQL macros with
`tools/xlsx_meta.py` on every call. Today the extension exists (`extension/xlsx_meta/`) but has
only been built on Linux, and a Linux build cannot load in the Windows DuckDB the skills use.

Two facts shape everything below:

- **An extension binary loads only in the exact DuckDB version it was built for.** Ours is built
  for v1.5.5, the version on this laptop. A `winget upgrade` of DuckDB breaks `LOAD` until the
  extension is rebuilt, so the skills must keep the Python route as a fallback.
- **Our build is unsigned.** DuckDB loads it only with `duckdb -unsigned` (or
  `SET allow_unsigned_extensions = true` at startup). Publishing as a signed community extension
  is out of scope.

## The pieces, in order

### 1. Windows build in GitHub Actions

A workflow, `.github/workflows/xlsx-meta-windows.yml`, builds the extension on a GitHub Windows
runner (MSVC) against DuckDB v1.5.5, runs `test/sql/xlsx_meta.test` there, and uploads
`xlsx_meta.duckdb_extension` as a run artifact. It runs on pushes that touch
`extension/xlsx_meta/**` or the workflow, and by hand. It follows the Windows job in DuckDB's
own `extension-ci-tools` workflow, which can't be used directly because it expects the
extension at the repo root.

**Proof:** the run's test step reports the SQL tests passing on Windows; then, on this laptop,
the downloaded artifact loads and answers:

    duckdb -unsigned -c "LOAD '<artifact>/xlsx_meta.duckdb_extension'; SELECT table_name, sheet_name, read_range, data_rows FROM xlsx_tables('extension/xlsx_meta/test/data/tables.xlsx')"

returning the fixture's tables with their ranges and row counts.

### 2. Ship the binary with the plugin

Commit the built file at `extension/bin/v1.5.5/windows_amd64/xlsx_meta.duckdb_extension`
(DuckDB's own version/platform layout), so it reaches the installed plugin with everything else.
A small script, `tools/fetch-xlsx-meta.ps1`, downloads the newest successful CI artifact into
that path, so a rebuild never means hand-copying files.

**Proof:** the same `LOAD ... FROM xlsx_tables(...)` command, pointed at the committed path,
returns the same rows.

### 3. Parity on Windows against real workbooks

Run the extension and `tools/xlsx_meta.py` side by side on real workbooks (staged copies of
Data Extracts.xlsm and others), from Windows: both listings, and every lookup's value and error
text. `test/parity.sh` does this on Linux; it gets a Windows mode or a PowerShell twin.

**Proof:** the parity run prints per-workbook counts of tables and names compared, and
`0 differences`.

### 4. Switch the skills to the extension, with the Python fallback

`skills/query/SKILL.md` and the lakehouse contract path (`tools/contract-xlsx.ps1`) load the
extension and define the two macros once; because the macros take the path as an argument, they
no longer need regenerating per workbook. If the running DuckDB isn't the version the binary was
built for, or `LOAD` fails, they fall back to `xlsx_meta.py` exactly as today. Formula
extraction (`read_xlsx_formulas`, the `@formula_*` checks) stays on Python; it was never ported.

**Proof:** `tests/prove-xlsx-names.ps1` and the lakehouse proof pass on the extension route; a
run with the extension made unloadable shows the fallback taking over with the same rows.

### 5. Release

Bump the plugin to 0.6.0 (`.claude-plugin/plugin.json` and `marketplace.json`), drop "in
progress" from the README section, add the `docs/SHIPPED.md` entry, reinstall the plugin, and
give Phil one command to run against a real workbook.

**Proof:** from the installed plugin, a `read_xlsx_table` read of a real workbook returns rows,
and `duckdb_extensions()` in that process shows `xlsx_meta` loaded.
