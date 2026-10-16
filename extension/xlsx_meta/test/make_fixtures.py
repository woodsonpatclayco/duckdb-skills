"""Generate the test workbooks in test/data/. Standard library only; rerun after editing.

Each fixture plants a trap from duckdb-skills PLAN-6 / the Cortex ListObject notes:
  tables.xlsx    blank row inside a table (sheet-only reads stop early), data below a table
                 (stop_at_empty=false runs past it), a totals row with a different <autoFilter>
                 ref, two tables side by side on one sheet, table part numbers that don't match
                 sheet numbers, an absolute rel target, a sheet name with a space and an
                 apostrophe (with a readable table on it), and one defined name per kind
                 (workbook/sheet scope, one cell, ambiguous, broken, formula, missing sheet,
                 whole column, same name at both scopes, hidden built-in), headerRowCount="0", a header-only table, a hidden sheet.
  prefixed.xlsx  every SpreadsheetML element written with an x: prefix, and a table whose
                 displayName differs from its name.
  not_a_zip.xlsx plain text with an .xlsx name.
"""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data")

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
REL_SHEET = NS_R + "/worksheet"
REL_TABLE = NS_R + "/table"
REL_STYLES = NS_R + "/styles"
REL_DOC = NS_R + "/officeDocument"


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def content_types(sheets, tables):
    parts = ['<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
             '<Default Extension="xml" ContentType="application/xml"/>',
             '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
             '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>']
    parts += [f'<Override PartName="/xl/worksheets/{s}" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for s in sheets]
    parts += [f'<Override PartName="/xl/tables/{t}" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>' for t in tables]
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' + "".join(parts) + "</Types>")


def rels(entries):
    body = "".join(f'<Relationship Id="{i}" Type="{t}" Target="{esc(g)}"/>' for i, t, g in entries)
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{NS_PKG}">{body}</Relationships>'


STYLES = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="{NS}">'
          '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
          '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
          '<borders count="1"><border/></borders>'
          '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
          '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
          '</styleSheet>')


def col_letter(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def sheet_xml(cells, p=""):
    """cells: {(row, col): value}; strings as inline strings, numbers as numbers."""
    rows = {}
    for (r, c), v in cells.items():
        rows.setdefault(r, []).append((c, v))
    out = []
    for r in sorted(rows):
        cs = []
        for c, v in sorted(rows[r]):
            ref = f"{col_letter(c)}{r}"
            if isinstance(v, str):
                cs.append(f'<{p}c r="{ref}" t="inlineStr"><{p}is><{p}t>{esc(v)}</{p}t></{p}is></{p}c>')
            else:
                cs.append(f'<{p}c r="{ref}"><{p}v>{v}</{p}v></{p}c>')
        out.append(f'<{p}row r="{r}">{"".join(cs)}</{p}row>')
    xmlns = f'xmlns:x="{NS}"' if p else f'xmlns="{NS}"'
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><{p}worksheet {xmlns} xmlns:r="{NS_R}">'
            f'<{p}sheetData>{"".join(out)}</{p}sheetData></{p}worksheet>')


def table_xml(tid, name, ref, columns, display=None, header=None, totals=None, autofilter=None, p=""):
    attrs = f'id="{tid}" name="{esc(name)}" displayName="{esc(display or name)}" ref="{ref}"'
    if header is not None:
        attrs += f' headerRowCount="{header}"'
    if totals is not None:
        attrs += f' totalsRowCount="{totals}"'
    af = f'<{p}autoFilter ref="{autofilter}"/>' if autofilter else ""
    cols = "".join(f'<{p}tableColumn id="{i + 1}" name="{esc(c)}"/>' for i, c in enumerate(columns))
    xmlns = f'xmlns:x="{NS}"' if p else f'xmlns="{NS}"'
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><{p}table {xmlns} {attrs}>{af}'
            f'<{p}tableColumns count="{len(columns)}">{cols}</{p}tableColumns></{p}table>')


def workbook_xml(sheets, p="", names=()):
    """sheets: [(name, rid, state or None)]; names: [(name, localSheetId or None, text, hidden)]"""
    body = "".join(f'<{p}sheet name="{esc(n)}" sheetId="{i + 1}" r:id="{rid}"'
                   + (f' state="{st}"' if st else "") + "/>" for i, (n, rid, st) in enumerate(sheets))
    defined = "".join(f'<{p}definedName name="{esc(n)}"'
                      + (f' localSheetId="{lsid}"' if lsid is not None else "")
                      + (' hidden="1"' if hidden else "") + f">{esc(text)}</{p}definedName>"
                      for n, lsid, text, hidden in names)
    defined = f"<{p}definedNames>{defined}</{p}definedNames>" if names else ""
    xmlns = f'xmlns:x="{NS}"' if p else f'xmlns="{NS}"'
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><{p}workbook {xmlns} xmlns:r="{NS_R}">'
            f'<{p}sheets>{body}</{p}sheets>{defined}</{p}workbook>')


# Defined names in tables.xlsx, one per case xlsx_meta.py classifies (localSheetId 1 = Rates,
# 2 = Bob's Data). Shapes taken from the SDI Calculator's 32 names (PLAN-6).
TABLES_NAMES = [
    ("Rate_Block", None, "Rates!$A$2:$C$5", False),               # workbook scope, multi-row
    ("Title_Cell", None, "Rates!$A$1", False),                    # one cell: header defaults false
    ("Items", 2, "'Bob''s Data'!$G$1:$H$3", False),               # sheet scope, unique: bare works
    ("ExternalData_1", 1, "Rates!$E$2:$F$5", False),              # same name on two sheets
    ("ExternalData_1", 2, "'Bob''s Data'!$A$1:$B$3", False),      #   -> bare name is ambiguous
    ("Excluded_Vendors", None, "_xlfn.ANCHORARRAY(#REF!)", False),  # broken
    ("Dyn_Range", None, "OFFSET(Rates!$A$1,0,0,5,1)", False),     # formula-defined
    ("Ghost", None, "Gone!$A$1", False),                          # sheet doesn't exist
    ("Whole_Col", None, "Rates!$A:$A", False),                    # not a plain rectangle
    ("Dup", None, "Rates!$A$3", False),                           # workbook AND sheet scope: not
    ("dup", 1, "Rates!$B$3", False),                              #   ambiguous; bare -> workbook
    ("_xlnm._FilterDatabase", 1, "Rates!$A$2:$C$5", True),       # hidden built-in: excluded
]


def write_zip(path, parts):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in parts.items():
            z.writestr(name, text)


def tables_xlsx():
    # Sheet "Rates" (sheet2.xml): Base_Rate A2:C5 with a blank row 4 inside, and a stray value at
    # A8 below it; Rate_Tiers E2:F6 with a totals row 6, side by side. Part numbers are swapped
    # against sheet order (table3 is Base_Rate, table1 is Rate_Tiers).
    rates = {(1, 1): "Rates sheet title",
             (2, 1): "Code", (2, 2): "Rate", (2, 3): "Unit",
             (3, 1): "A100", (3, 2): 12.5, (3, 3): "hr",
             (5, 1): "A300", (5, 2): 40, (5, 3): "day",
             (8, 1): "not part of any table",
             (2, 5): "Tier", (2, 6): "Floor",
             (3, 5): "Bronze", (3, 6): 0,
             (4, 5): "Silver", (4, 6): 1000,
             (5, 5): "Gold", (5, 6): 5000,
             (6, 5): "Total", (6, 6): 6000}
    # Sheet "Bob's Data" (sheet3.xml): NoHeader A1:B3 (headerRowCount=0), Empty_Tbl D1:E1, and
    # Bobs_Items G1:H3, a normal table on a sheet whose name needs quoting.
    bobs = {(1, 1): 1, (1, 2): 2, (2, 1): 3, (2, 2): 4, (3, 1): 5, (3, 2): 6,
            (1, 4): "Only", (1, 5): "Header",
            (1, 7): "Item", (1, 8): "Qty", (2, 7): "washer", (2, 8): 7, (3, 7): "rivet", (3, 8): 9}
    parts = {
        "[Content_Types].xml": content_types(["sheet1.xml", "sheet2.xml", "sheet3.xml", "sheet4.xml"],
                                             ["table1.xml", "table2.xml", "table3.xml", "table4.xml", "table5.xml"]),
        "_rels/.rels": rels([("rId1", REL_DOC, "xl/workbook.xml")]),
        "xl/workbook.xml": workbook_xml([("Summary", "rId1", None), ("Rates", "rId2", None),
                                         ("Bob's Data", "rId3", None), ("Hidden", "rId4", "hidden")],
                                        names=TABLES_NAMES),
        "xl/_rels/workbook.xml.rels": rels([("rId1", REL_SHEET, "worksheets/sheet1.xml"),
                                            ("rId2", REL_SHEET, "worksheets/sheet2.xml"),
                                            ("rId3", REL_SHEET, "/xl/worksheets/sheet3.xml"),
                                            ("rId4", REL_SHEET, "worksheets/sheet4.xml"),
                                            ("rId9", REL_STYLES, "styles.xml")]),
        "xl/styles.xml": STYLES,
        "xl/worksheets/sheet1.xml": sheet_xml({(1, 1): "nothing here"}),
        "xl/worksheets/sheet2.xml": sheet_xml(rates),
        "xl/worksheets/_rels/sheet2.xml.rels": rels([("rId1", REL_TABLE, "../tables/table3.xml"),
                                                     ("rId2", REL_TABLE, "/xl/tables/table1.xml")]),
        "xl/worksheets/sheet3.xml": sheet_xml(bobs),
        "xl/worksheets/_rels/sheet3.xml.rels": rels([("rId1", REL_TABLE, "../tables/table2.xml"),
                                                     ("rId2", REL_TABLE, "../tables/table4.xml"),
                                                     ("rId3", REL_TABLE, "../tables/table5.xml")]),
        "xl/worksheets/sheet4.xml": sheet_xml({}),
        "xl/tables/table3.xml": table_xml(1, "Base_Rate", "A2:C5", ["Code", "Rate", "Unit"],
                                          autofilter="A2:C5"),
        "xl/tables/table1.xml": table_xml(2, "Rate_Tiers", "E2:F6", ["Tier", "Floor"], totals=1,
                                          autofilter="E2:F5"),
        "xl/tables/table2.xml": table_xml(3, "NoHeader", "A1:B3", ["Column1", "Column2"], header=0),
        "xl/tables/table4.xml": table_xml(4, "Empty_Tbl", "D1:E1", ["Only", "Header"]),
        "xl/tables/table5.xml": table_xml(5, "Bobs_Items", "G1:H3", ["Item", "Qty"]),
    }
    write_zip(os.path.join(OUT, "tables.xlsx"), parts)


def prefixed_xlsx():
    p = "x:"
    cells = {(1, 2): "Name", (1, 3): "Qty", (2, 2): "bolt", (2, 3): 10, (3, 2): "nut", (3, 3): 20}
    parts = {
        "[Content_Types].xml": content_types(["sheet1.xml"], ["table1.xml"]),
        "_rels/.rels": rels([("rId1", REL_DOC, "xl/workbook.xml")]),
        "xl/workbook.xml": workbook_xml([("Parts List", "rId1", None)], p=p,
                                        names=[("Parts_Block", None, "'Parts List'!$B$1:$C$3", False)]),
        "xl/_rels/workbook.xml.rels": rels([("rId1", REL_SHEET, "worksheets/sheet1.xml"),
                                            ("rId9", REL_STYLES, "styles.xml")]),
        "xl/styles.xml": STYLES,
        "xl/worksheets/sheet1.xml": sheet_xml(cells, p=p),
        "xl/worksheets/_rels/sheet1.xml.rels": rels([("rId1", REL_TABLE, "../tables/table1.xml")]),
        "xl/tables/table1.xml": table_xml(1, "Table1", "B1:C3", ["Name", "Qty"], display="Parts_Tbl", p=p),
    }
    write_zip(os.path.join(OUT, "prefixed.xlsx"), parts)


def main():
    os.makedirs(OUT, exist_ok=True)
    tables_xlsx()
    prefixed_xlsx()
    with open(os.path.join(OUT, "not_a_zip.xlsx"), "w", encoding="utf-8") as f:
        f.write("this is not a workbook\n")
    print("wrote", ", ".join(sorted(os.listdir(OUT))))


if __name__ == "__main__":
    main()
