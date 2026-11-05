"""raw-cell.py <workbook> <sheet> <cell> [<cell> ...]

Prints each cell's <c> element exactly as stored in the sheet XML, one per line as
cell,xml (CSV; xml is empty when the sheet has no <c> for that cell; a line break inside it is
written as its XML character reference, &#10; or &#13;, so one cell stays on one line). Finds the sheet's part
through xl/workbook.xml and its .rels with plain regular expressions -- deliberately sharing no
code with tools/xlsx_meta.py, so tests/prove-xlsx-arrays.ps1 can compare what the formula view
reports for a cell with what the file itself holds.
"""
import csv
import html
import re
import sys
import zipfile

path, sheet, cells = sys.argv[1], sys.argv[2], sys.argv[3:]
with zipfile.ZipFile(path) as z:
    wb = z.read("xl/workbook.xml").decode("utf-8")
    rid = None
    for m in re.finditer(r"<(?:\w+:)?sheet\b([^>]*)/?>", wb):
        name = re.search(r'\bname="([^"]*)"', m.group(1))
        if name and html.unescape(name.group(1)) == sheet:
            rid = re.search(r'\br:id="([^"]*)"', m.group(1)).group(1)
    if rid is None:
        sys.exit(f"no sheet named {sheet!r} in {path}")
    rels = z.read("xl/_rels/workbook.xml.rels").decode("utf-8")
    rel = next(m.group(0) for m in re.finditer(r"<Relationship\b[^>]*>", rels) if f'Id="{rid}"' in m.group(0))
    target = re.search(r'\bTarget="([^"]*)"', rel).group(1)
    part = target.lstrip("/") if target.startswith("/") else "xl/" + target
    xml = z.read(part).decode("utf-8")
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(["cell", "xml"])
for cell in cells:
    m = re.search(rf'<c r="{cell}"(?:\s[^>]*?)?(?:/>|>.*?</c>)', xml, re.S)
    w.writerow([cell, m.group(0).replace("\r", "&#13;").replace("\n", "&#10;") if m else ""])
