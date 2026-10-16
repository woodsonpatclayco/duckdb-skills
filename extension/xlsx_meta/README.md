# xlsx_meta

A DuckDB extension that reports where Excel **tables (ListObjects)** and **named ranges** are inside
an `.xlsx` / `.xlsm` workbook, so a query can read either by name and get exactly its rows.

DuckDB's `read_xlsx` cannot address a table by name (duckdb/duckdb-excel#7), and a sheet-only read
silently stops at a blank row inside a table or runs past its end. This extension is the C++ form of
the `tables` / `names` / `macros` lookups in duckdb-skills `tools/xlsx_meta.py` (PLAN-6 item 1);
formula extraction (item 3) is not ported. The function names are the same, so contracts don't
change.

The design keeps three layers apart:

1. **This extension: facts only.** Where each table and named range is. It never reads cell values.
2. **`read_xlsx_table(path, table)` / `read_xlsx_name(path, name)`: plain-SQL macros** that build a
   `read_xlsx` call from those facts. They stay in duckdb-skills, not here. Copies are in
   `test/sql/xlsx_meta.test`.
3. **Core `read_xlsx`** (excel extension) does all the actual reading.

## Functions

| function | returns |
|---|---|
| `xlsx_tables(path)` | one row per table: `table_name, sheet_name, ref, read_range, data_range, data_rows, header_rows, totals_rows, column_count, column_names` |
| `xlsx_sheets(path)` | one row per sheet in tab order: `sheet_index, sheet_name, state, part, table_count` |
| `xlsx_table_sheet(path, table)` | the sheet the table is on |
| `xlsx_table_range(path, table)` | header row through the last data row, with any totals row trimmed. This is what `read_xlsx(range=)` needs |
| `xlsx_names(path)` | one row per defined name, plus one `ambiguous` row per name defined on several sheets: `defined_name, address, scope, scope_sheet, status, sheet_name, cell_range, row_count, detail`. `status` is `ok`, `ambiguous`, `broken` (`#REF!`) or `formula` (anything but `Sheet!rectangle` on an existing sheet). Hidden `_xlnm.*` built-ins are left out |
| `xlsx_name_sheet(path, name)` / `xlsx_name_range(path, name)` | where an `ok` name points. A one-cell name gives `A1`, not `A1:A1` |
| `xlsx__name_header(path, name)` | `read_xlsx_name`'s header default: true when the range has more than one row |

```sql
CREATE MACRO xlsx__q(s) AS '''' || replace(s, '''', '''''') || '''';
CREATE MACRO read_xlsx_table(p, t) AS TABLE FROM query(
    'SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_table_sheet(p, t))
    || ', range = ' || xlsx__q(xlsx_table_range(p, t)) || ', header = true, all_varchar = true)');

FROM read_xlsx_table('Data Extracts.xlsm', 'Job_Rate_Tiers');
```

`read_xlsx_name` is built the same way, and widens a one-cell range to `A1:A1` because `read_xlsx`
rejects `range='A1'`:

```sql
CREATE MACRO xlsx__read_range(r) AS CASE WHEN contains(r, ':') THEN r ELSE r || ':' || r END;
CREATE MACRO read_xlsx_name(p, n, header := NULL) AS TABLE FROM query(
    'SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_name_sheet(p, n))
    || ', range = ' || xlsx__q(xlsx__read_range(xlsx_name_range(p, n))) || ', header = '
    || coalesce(header, xlsx__name_header(p, n))::VARCHAR || ', all_varchar = true)');
```

The macros work only because the scalars are **not volatile**: with constant arguments they
fold at bind time, so `query()` receives a constant string. Table function arguments can't contain
subqueries, so this is the only pure-SQL route. **Never register them volatile.**

Behaviour matches `tools/xlsx_meta.py`:

- **Names are addressed as** `Name`, `Sheet!Name` or `'Quoted Sheet'!Name`, all case-insensitive.
  A sheet-scoped name answers to its bare name only if no other definition shares it. A name
  defined on several sheets is ambiguous bare, unless it also has a workbook-scoped definition:
  then the bare name means that one (as in Excel), and the sheet-scoped ones are `Sheet!Name`.
- **Table names:** compared case-insensitively. `displayName` is the name; the `name` attribute is
  only a fallback.
- **Refuses rather than guesses:**
  - an unknown table, `headerRowCount="0"`, or a header-only table → a named error
  - an unknown, ambiguous, broken or formula-defined name → a named error (same text as the
    generated macros)
  - a file that isn't a zip → an error
- **Workbook XML quirks it handles:**
  - only the `<table>` tag's `ref` is used, never `<autoFilter>`'s
  - a table is linked to its sheet through `sheetN.xml.rels`
  - absolute rel targets
  - `x:`-prefixed XML
- **Read-only:** the workbook is opened through DuckDB's FileSystem and never written.

## Building (Ubuntu / WSL)

The tests also build the excel extension (for `read_xlsx`), and it needs vcpkg packages. One-time
setup:

```sh
sudo apt-get install -y build-essential cmake ninja-build ccache git pkg-config python3-venv curl zip unzip tar
git clone https://github.com/microsoft/vcpkg.git ~/vcpkg && ~/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

Build in a **Linux-side clone** of duckdb-skills (e.g. `~/src/duckdb-skills`), not under
`/mnt/c`: DuckDB's build writes thousands of files, and Windows git and WSL git disagree about
line endings in a shared checkout. From the repo root, once per clone:

```sh
git submodule update --init --depth 1 extension/xlsx_meta/duckdb extension/xlsx_meta/extension-ci-tools
git -C extension/xlsx_meta/duckdb fetch --depth 1 origin tag v1.5.5   # else DuckDB reports a v0.0.x version
```

Then build and test from `extension/xlsx_meta`:

```sh
export VCPKG_TOOLCHAIN_PATH=$HOME/vcpkg/scripts/buildsystems/vcpkg.cmake
GEN=ninja make release
make test_release
test/parity.sh '/mnt/c/path/to/Data Extracts.xlsm' ...   # agrees with tools/xlsx_meta.py?
```

- The first build compiles all of DuckDB, which takes several minutes. Later builds use ccache.
- Outputs:
  - `build/release/duckdb`: a shell with both extensions built in
  - `build/release/extension/xlsx_meta/xlsx_meta.duckdb_extension`: the loadable extension
- The `duckdb` submodule is pinned to **v1.5.5**, and `excel` to the commit v1.5.5 ships.
- A Linux build loads only in Linux DuckDB. Windows binaries need MSVC or a CI build. The
  template's GitHub workflow is not included: DuckDB's reusable extension workflow expects the
  extension at the repository root, so publishing (e.g. as a community extension) needs that
  solved first.

## Tests

- `test/sql/xlsx_meta.test` covers each function and each refusal. It also runs `read_xlsx_table`
  end to end and shows the two silent wrong answers it replaces.
- The fixtures in `test/data/` are generated by `test/make_fixtures.py` (standard library only).
  Rerun it after editing the script. `tests/prove-xlsx-names.ps1` (repo root) reads the same
  fixture through the Python generator's macros on Windows.
- `test/parity.sh <workbook>...` compares the extension with `tools/xlsx_meta.py` on real
  workbooks (staged copies): both listings, and every lookup's value and error text.
