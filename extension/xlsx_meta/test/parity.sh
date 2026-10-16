#!/usr/bin/env bash
# test/parity.sh -- prove the extension and tools/xlsx_meta.py agree, on any workbooks.
#
#   test/parity.sh <workbook>...
#
# Run from extension/xlsx_meta after `make release`. Read-only: works on copies in a temp dir,
# and checks every source's SHA-256 is unchanged at the end. Compares:
#   1. listings: xlsx_tables / xlsx_names vs xlsx_meta.py tables / names --format csv
#   2. lookups: every table and name, under every spelling (as listed, bare, Sheet!Name,
#      'Sheet'!Name, upper-cased) plus unknowns, through the extension's scalars and the Python-generated
#      macros -- values and error text. The two "unknown" messages differ by design (they point
#      at different listing tools) and are normalised before comparing.
set -euo pipefail
cd "$(dirname "$0")/.."
DUCKDB=build/release/duckdb
META=${XLSX_META_PY:-../../tools/xlsx_meta.py}   # override to check another version
[ -x "$DUCKDB" ] || { echo "ERROR: build first (make release)"; exit 2; }
[ $# -gt 0 ] || { echo "usage: $0 <workbook>..."; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
copies=()
for src in "$@"; do
    sha256sum "$src" >> "$WORK/before.sha256"
    copy="$WORK/$(basename "$src")"
    cp "$src" "$copy"
    copies+=("$copy")
done

echo "Listings"
for f in "${copies[@]}"; do
    python3 -I "$META" tables "$f" --format csv > "$WORK/t.py"
    "$DUCKDB" -csv -c "SELECT table_name AS \"table\", sheet_name AS sheet, ref, data_range, data_rows,
        header_rows, totals_rows, column_count AS columns FROM xlsx_tables('$f')" > "$WORK/t.ext"
    python3 -I "$META" names "$f" --format csv > "$WORK/n.py"
    "$DUCKDB" -csv -c "SELECT address, scope, coalesce(sheet_name, '') AS sheet, coalesce(cell_range, '') AS range,
        coalesce(row_count::VARCHAR, '') AS rows, status, detail FROM xlsx_names('$f')" > "$WORK/n.ext"
    for k in t n; do
        # csv quoting differs between the two writers; compare parsed rows
        if python3 -I -c 'import csv,sys; sys.exit(list(csv.reader(open(sys.argv[1]))) != list(csv.reader(open(sys.argv[2]))))' \
                "$WORK/$k.py" "$WORK/$k.ext"; then
            echo "  PASS  $(basename "$f") $([ $k = t ] && echo tables || echo names): $(($(python3 -I -c 'import csv,sys; print(len(list(csv.reader(open(sys.argv[1])))))' "$WORK/$k.py") - 1)) rows identical"
        else
            echo "  FAIL  $(basename "$f") $([ $k = t ] && echo tables || echo names) differ:"; { diff "$WORK/$k.py" "$WORK/$k.ext" || true; } | head -10; fail=1
        fi
    done
done

echo "Lookups"
python3 -I "$META" macros "${copies[@]}" -o "$WORK/py_macros.sql" > /dev/null
# The generated macros share the extension's function names; rename them to sit side by side.
sed -e 's/\bxlsx_name_sheet(/py_name_sheet(/g; s/\bxlsx_name_range(/py_name_range(/g;
        s/\bxlsx__name_header(/py_name_header(/g; s/\bxlsx_table_sheet(/py_table_sheet(/g;
        s/\bxlsx_table_range(/py_table_range(/g' "$WORK/py_macros.sql" > "$WORK/py_lookups.sql"
N=""; T=""
for f in "${copies[@]}"; do
    N="$N${N:+ UNION ALL }SELECT '$f' AS f, * FROM xlsx_names('$f')"
    T="$T${T:+ UNION ALL }SELECT '$f' AS f, * FROM xlsx_tables('$f')"
done
"$DUCKDB" -csv -noheader -c "SELECT DISTINCT 'n', f, k FROM (
      SELECT f, address AS k FROM ($N) UNION ALL SELECT f, defined_name FROM ($N)
      UNION ALL SELECT f, scope_sheet || '!' || defined_name FROM ($N) WHERE scope_sheet IS NOT NULL
      UNION ALL SELECT f, '''' || replace(scope_sheet, '''', '''''') || '''!' || defined_name FROM ($N) WHERE scope_sheet IS NOT NULL
      UNION ALL SELECT f, upper(address) FROM ($N) UNION ALL SELECT DISTINCT f, 'No_Such_Name' FROM ($N))
    UNION ALL SELECT DISTINCT 't', f, k FROM (
      SELECT f, table_name AS k FROM ($T) UNION ALL SELECT f, upper(table_name) FROM ($T)
      UNION ALL SELECT DISTINCT f, 'No_Such_Table' FROM ($T))
    ORDER BY ALL" > "$WORK/keys.csv"
# One statement per lookup, so an error in one doesn't hide the rest (and try() can't wrap
# the generated macros: they call error(), which DuckDB treats as volatile).
python3 -I - "$WORK" <<'EOF'
import csv, sys
work = sys.argv[1]
q = lambda s: "'" + s.replace("'", "''") + "'"
sets = {"ext": ("xlsx_name_sheet", "xlsx_name_range", "xlsx__name_header", "xlsx_table_sheet", "xlsx_table_range"),
        "py": ("py_name_sheet", "py_name_range", "py_name_header", "py_table_sheet", "py_table_range")}
for side, fns in sets.items():
    with open(f"{work}/{side}.sql", "w") as w:
        if side == "py":
            w.write(f".read {work}/py_lookups.sql\n")
        for kind, f, k in csv.reader(open(f"{work}/keys.csv")):
            for i, fn in enumerate(fns[:3] if kind == "n" else fns[3:]):
                w.write(f"SELECT {q(k)}, {i}, {fn}({q(f)}, {q(k)})::VARCHAR;\n")
EOF
"$DUCKDB" -csv -noheader < "$WORK/ext.sql" > "$WORK/ext.out" 2>&1 || true
"$DUCKDB" -csv -noheader < "$WORK/py.sql" > "$WORK/py.out" 2>&1 || true
norm() { sed -E "s/no (defined name|table) '([^']*)' in .*/no \1 '\2' (unknown)/" "$1" | grep -v '^LINE\|^ *^$'; }
norm "$WORK/ext.out" > "$WORK/ext.norm"; norm "$WORK/py.out" > "$WORK/py.norm"
lookups=$(wc -l < "$WORK/ext.norm")
if diff -q "$WORK/ext.norm" "$WORK/py.norm" > /dev/null; then
    echo "  PASS  $lookups lookups identical ($(grep -c 'Error' "$WORK/ext.norm" || true) of them refusals)"
else
    echo "  FAIL  lookups differ:"; { diff "$WORK/ext.norm" "$WORK/py.norm" || true; } | head -20; fail=1
fi

if sha256sum --quiet -c "$WORK/before.sha256"; then
    echo "PASS  sources unchanged (SHA-256 before = after)"
else
    echo "FAIL  a source workbook changed"; fail=1
fi
[ $fail = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
