"""make-formula-fixture.py <out.xlsx>

Builds the PLAN-6 item 3 trap workbook: one stored formula per trap the A1 -> R1C1 converter
(tools/xlsx_r1c1.py) must get right, plus a shared-formula block, an Excel table whose
calculated column has a typed value and a blank in it, and two error cells. Also writes
<out.xlsx>.expected.csv: every row the formula view must produce for this workbook, no more.

The workbook is written straight as XML (standard library only), so the formula text in it is
exactly the text below -- what Excel itself stores, without the leading '='.
"""
import csv
import sys
import zipfile
from xml.sax.saxutils import escape

# (row, A1 formula in Traps!A<row>, expected R1C1, trap)
TRAPS = [
    (10, '_xlfn.CONCAT("B5 and $C$3",B5)', '_xlfn.CONCAT("B5 and $C$3",R[-5]C[1])', "string literal left alone"),
    (11, "LOG10(B11)+ATAN2(1,2)+DAYS360(B11,C11)", "LOG10(RC[1])+ATAN2(1,2)+DAYS360(RC[1],RC[2])",
     "functions whose names look like cells"),
    (12, "_xlfn.XLOOKUP(B12,Data!C:C,Data!D:D)", "_xlfn.XLOOKUP(RC[1],Data!C[2],Data!C[3])",
     "_xlfn. prefix; whole columns"),
    (13, "IF(ISERROR(B13),NA(),#REF!)", "IF(ISERROR(RC[1]),NA(),#REF!)", "error literal"),
    (14, "SUM(Tbl[Col1])+COUNTA(Tbl[[#Headers],[Col1]:[Col2]])",
     "SUM(Tbl[Col1])+COUNTA(Tbl[[#Headers],[Col1]:[Col2]])", "structured references"),
    (15, "_xlfn.SINGLE(Data!B15:B20)", "_xlfn.SINGLE(Data!RC[1]:R[5]C[1])",
     "implicit intersection (@ is stored as _xlfn.SINGLE)"),
    (16, "1E3+2.5E-7*B16", "1E3+2.5E-7*RC[1]", "scientific notation is not cell E3"),
    (17, "Data!B2+'My Sheet'!$C$3+'Q1'!A1", "Data!R[-15]C[1]+'My Sheet'!R3C3+'Q1'!R[-16]C",
     "sheet-qualified; quoted; a sheet named like a cell"),
    (18, "SUM(Data!B:B)+SUM(Data!$C:$D)+SUM(Data!2:2)+SUM(Data!$3:$5)",
     "SUM(Data!C[1])+SUM(Data!C3:C4)+SUM(Data!R[-16])+SUM(Data!R3:R5)", "whole columns and rows"),
    (19, "B$4*$C5+$D$6", "R4C[1]*R[-14]C3+R6C4", "mixed absolute parts stay absolute"),
    (20, "SUM(B2:C5)", "SUM(R[-18]C[1]:R[-15]C[2])", "range"),
    (21, "TaxRate*B21", "TaxRate*RC[1]", "defined name left alone"),
    (22, "'O''Brien'!B2", "'O''Brien'!R[-20]C[1]", "quote inside a quoted sheet name"),
    (23, '"say ""B2"""&B23', '"say ""B2"""&RC[1]', "doubled quote inside a string"),
    (24, "ROWS(Tbl[#Data])", "ROWS(Tbl[#Data])", "structured reference special item"),
    (25, "Data!$XFD$1048576", "Data!R1048576C16384", "last cell of the sheet"),
    (26, "COUNTA(Data!A:A)+COUNTA(Data!26:26)", "COUNTA(Data!C)+COUNTA(Data!R)",
     "zero offset is a bare R / C"),
]
# Shared formula: master Traps!E2, dependents E3:E6 store only si="0".
SHARED_MASTER = "B2*2+$C$2"
SHARED_R1C1 = "RC[-3]*2+R2C3"
SHARED_ROWS = range(2, 7)
CALC = "Tbl[[#This Row],[Col1]]*2"

NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
     'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
CT = "application/vnd.openxmlformats-officedocument.spreadsheetml"
SHEETS = ["Traps", "Data", "My Sheet", "Q1", "O'Brien", "Tab"]


def inline(ref, text):
    return f'<c r="{ref}" t="inlineStr"><is><t>{escape(text)}</t></is></c>'


def sheet_xml(cells, extra=""):
    """cells: {row: [cell xml, ...]} -- written in row order."""
    rows = "".join(f'<row r="{r}">{"".join(cells[r])}</row>' for r in sorted(cells))
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet {NS}><sheetData>{rows}</sheetData>{extra}</worksheet>'


def main(out):
    expected = []   # sheet, cell, kind, formula_a1, formula_r1c1, cached_value, error

    traps = {}
    for r, a1, r1c1, why in TRAPS:
        traps.setdefault(r, []).append(f'<c r="A{r}"><f>{escape(a1)}</f></c>')
        traps[r].append(inline(f"C{r}", why))
        expected.append(("Traps", f"A{r}", "normal", a1, r1c1, "", ""))
    for r in SHARED_ROWS:
        if r == SHARED_ROWS[0]:
            f = f'<f t="shared" ref="E{r}:E{SHARED_ROWS[-1]}" si="0">{escape(SHARED_MASTER)}</f>'
        else:
            f = '<f t="shared" si="0"/>'
        traps.setdefault(r, []).append(f'<c r="E{r}">{f}</c>')
        expected.append(("Traps", f"E{r}", "shared", f"B{r}*2+$C$2", SHARED_R1C1, "", ""))

    # Tab: table Tbl at A1:C6. Calc has formulas in rows 2, 3, 6; a typed 99 in row 4; row 5 blank.
    tab = {1: [inline("A1", "Col1"), inline("B1", "Col2"), inline("C1", "Calc")]}
    for r in range(2, 7):
        tab[r] = [f'<c r="A{r}"><v>{r - 1}</v></c>', f'<c r="B{r}"><v>{(r - 1) * 10}</v></c>']
        if r in (2, 3, 6):
            tab[r].append(f'<c r="C{r}"><f>{escape(CALC)}</f><v>{(r - 1) * 2}</v></c>')
            expected.append(("Tab", f"C{r}", "normal", CALC, CALC, str((r - 1) * 2), ""))
        elif r == 4:
            tab[r].append(f'<c r="C{r}"><v>99</v></c>')
            expected.append(("Tab", f"C{r}", "none", "", "", "99", ""))
        else:
            expected.append(("Tab", f"C{r}", "none", "", "", "", ""))
    tab[2].append('<c r="E2" t="e"><v>#N/A</v></c>')                       # an error VALUE
    expected.append(("Tab", "E2", "none", "", "", "#N/A", "#N/A"))
    tab[3].append('<c r="E3" t="e"><f>1/0</f><v>#DIV/0!</v></c>')          # an error FORMULA
    expected.append(("Tab", "E3", "normal", "1/0", "1/0", "#DIV/0!", "#DIV/0!"))

    data = {2: ['<c r="B2"><v>0.08</v></c>']}
    parts = {
        "[Content_Types].xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            f'<Override PartName="/xl/workbook.xml" ContentType="{CT}.sheet.main+xml"/>'
            f'<Override PartName="/xl/styles.xml" ContentType="{CT}.styles+xml"/>'
            + "".join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="{CT}.worksheet+xml"/>'
                      for i in range(1, len(SHEETS) + 1))
            + f'<Override PartName="/xl/tables/table1.xml" ContentType="{CT}.table+xml"/></Types>',
        "_rels/.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>',
        "xl/workbook.xml":
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook {NS}><sheets>'
            + "".join(f'<sheet name="{escape(n, {chr(39): "&apos;"})}" sheetId="{i}" r:id="rId{i}"/>'
                      for i, n in enumerate(SHEETS, 1))
            + '</sheets><definedNames><definedName name="TaxRate">Data!$B$2</definedName></definedNames>'
            '<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>',
        "xl/_rels/workbook.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>'
                      for i in range(1, len(SHEETS) + 1))
            + f'<Relationship Id="rId{len(SHEETS) + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            '</Relationships>',
        "xl/styles.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
            '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
            '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
            '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
        "xl/worksheets/sheet1.xml": sheet_xml(traps),
        "xl/worksheets/sheet2.xml": sheet_xml(data),
        "xl/worksheets/sheet3.xml": sheet_xml({}),
        "xl/worksheets/sheet4.xml": sheet_xml({}),
        "xl/worksheets/sheet5.xml": sheet_xml({}),
        "xl/worksheets/sheet6.xml": sheet_xml(tab, '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>'),
        "xl/worksheets/_rels/sheet6.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table1.xml"/>'
            '</Relationships>',
        "xl/tables/table1.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="Tbl" '
            'displayName="Tbl" ref="A1:C6" totalsRowShown="0"><autoFilter ref="A1:C6"/>'
            '<tableColumns count="3"><tableColumn id="1" name="Col1"/><tableColumn id="2" name="Col2"/>'
            f'<tableColumn id="3" name="Calc"><calculatedColumnFormula>{escape(CALC)}</calculatedColumnFormula>'
            '</tableColumn></tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" '
            'showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>',
    }
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in parts.items():
            z.writestr(name, text)
    with open(out + ".expected.csv", "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["sheet", "cell", "kind", "formula_a1", "formula_r1c1", "cached_value", "error"])
        w.writerows(expected)
    print(f"wrote {out}: {len(TRAPS)} traps, {len(expected)} expected rows")


if __name__ == "__main__":
    main(sys.argv[1])
