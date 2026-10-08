"""recount-formulas.py <workbook>

An independent recount for tests/prove-xlsx-formulas.ps1: counts formula cells (by kind) and
error cells (by code; in a formula or a plain value) with plain regular expressions over the
raw sheet XML -- deliberately sharing no code with tools/xlsx_meta.py, which streams the XML
with a parser. Prints metric,value lines.
"""
import collections
import re
import sys
import zipfile

kinds, errors = collections.Counter(), collections.Counter()
in_formula = as_value = 0
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        if not re.fullmatch(r"xl/worksheets/sheet\d+\.xml", name):
            continue
        xml = z.read(name).decode("utf-8")
        for m in re.finditer(r"<c\b([^>]*?)(?:/>|>(.*?)</c>)", xml, re.S):
            attrs, body = m.group(1), m.group(2) or ""
            f = re.search(r"<f\b([^>]*)", body)
            if f:
                t = re.search(r'\bt="(\w+)"', f.group(1))
                kinds[{"dataTable": "data-table"}.get(t.group(1), t.group(1)) if t else "normal"] += 1
            if re.search(r'\bt="e"', attrs):
                v = re.search(r"<v>([^<]*)</v>", body)
                errors[v.group(1) if v else "?"] += 1
                if f:
                    in_formula += 1
                else:
                    as_value += 1

print("metric,value")
print(f"formula_cells,{sum(kinds.values())}")
for k in ("normal", "shared", "array", "data-table"):
    print(f"kind_{k},{kinds[k]}")
print(f"error_cells,{sum(errors.values())}")
print(f"error_in_formula,{in_formula}")
print(f"error_as_value,{as_value}")
for code, n in sorted(errors.items()):
    print(f"error_{code},{n}")
