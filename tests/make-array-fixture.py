"""make-array-fixture.py <out.xlsx>

Builds the 0.6.3 fixture for the formula view's array handling (tests/prove-xlsx-arrays.ps1):

  Arrays  B2:B4  legacy CSE array      <f t="array" ref="B2:B4">, children hold values only
          D2:D6  VOLATILE dynamic array  anchor <c cm="1"><f t="array" aca="1" ref="D2:D6" ca="1">;
                 Excel writes an empty <f ca="1"/> into each spilled child D3:D6 -- the spill
                 placeholders. D4's cached value is #DIV/0!.
          F2:F4  non-volatile dynamic array: children hold values only, no <f>
          H2:H4  shared formula: master H2, dependents H3:H4 store only <f t="shared" si="0"/>
          J2     one-cell dynamic array <f t="array" ref="J2"> (the shape of Project Profit's
                 '10002556'!I128 in the clean file)
  Tab     table Tbl (A1:C8) whose Calc column holds a calculated formula in C2:C5, a typed 99
          in C6, a blank C7, and a placeholder in C8 (Excel never spills into a table; it is
          planted to show a placeholder in a table column is read as a typed value)
  Edge    A1   an EMPTY array master <f t="array" ref="A1:A2"/> -- kept as an array formula
          C5   a placeholder outside every array rectangle on its sheet -- read as a value
          E2   a data table <f t="dataTable" .../>, empty text by design -- kept

Also writes <out.xlsx>.expected.csv (every row the 0.6.3 formula view must produce for this
workbook, no more) and <out.xlsx>.placeholders.csv (the six placeholder cells). Written straight
as XML with the standard library, so every <f> is exactly the text below.
"""
import csv
import sys
import zipfile
from xml.sax.saxutils import escape

NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
     'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
CT = "application/vnd.openxmlformats-officedocument.spreadsheetml"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
SHEETS = ["Arrays", "Tab", "Edge"]
CALC = "Tbl[[#This Row],[Col1]]*2"
VOLATILE = "A2:A6/(A2:A6-3)+RAND()*0"
# Columns: sheet, cell, kind, formula_a1, formula_r1c1, cached_value, error, array_ref
EXPECTED = [
    ("Arrays", "B2", "array", "A2:A4*2", "RC[-1]:R[2]C[-1]*2", "2", "", "B2:B4"),
    ("Arrays", "D2", "array", VOLATILE, "RC[-3]:R[4]C[-3]/(RC[-3]:R[4]C[-3]-3)+RAND()*0", "-0.5", "", "D2:D6"),
    ("Arrays", "D4", "none", "", "", "#DIV/0!", "#DIV/0!", ""),
    ("Arrays", "F2", "array", "_xlfn.SEQUENCE(3)", "_xlfn.SEQUENCE(3)", "1", "", "F2:F4"),
    ("Arrays", "H2", "shared", "A2+1", "RC[-7]+1", "2", "", ""),
    ("Arrays", "H3", "shared", "A3+1", "RC[-7]+1", "3", "", ""),
    ("Arrays", "H4", "shared", "A4+1", "RC[-7]+1", "4", "", ""),
    ("Arrays", "J2", "array", "SUM(A2:A6*2)", "SUM(RC[-9]:R[4]C[-9]*2)", "30", "", "J2"),
    ("Tab", "C2", "normal", CALC, CALC, "2", "", ""),
    ("Tab", "C3", "normal", CALC, CALC, "4", "", ""),
    ("Tab", "C4", "normal", CALC, CALC, "6", "", ""),
    ("Tab", "C5", "normal", CALC, CALC, "8", "", ""),
    ("Tab", "C6", "none", "", "", "99", "", ""),
    ("Tab", "C7", "none", "", "", "", "", ""),
    ("Tab", "C8", "none", "", "", "14", "", ""),
    ("Edge", "A1", "array", "", "", "1", "", "A1:A2"),
    ("Edge", "E2", "data-table", "", "", "5", "", ""),
]
# Columns: sheet, cell, cached_value, error, where
PLACEHOLDERS = [
    ("Arrays", "D3", "-2", "", "spilled child of the volatile array D2:D6"),
    ("Arrays", "D4", "#DIV/0!", "#DIV/0!", "spilled child of D2:D6, showing an error"),
    ("Arrays", "D5", "4", "", "spilled child of D2:D6"),
    ("Arrays", "D6", "2.5", "", "spilled child of D2:D6"),
    ("Tab", "C8", "14", "", "planted in table Tbl's Calc column"),
    ("Edge", "C5", "7", "", "outside every array rectangle on its sheet"),
]


def v(ref, value, t=None, f="", cm=False):
    attrs = f' r="{ref}"' + (f' t="{t}"' if t else "") + (' cm="1"' if cm else "")
    return f"<c{attrs}>{f}<v>{escape(value)}</v></c>"


def inline(ref, text):
    return f'<c r="{ref}" t="inlineStr"><is><t>{escape(text)}</t></is></c>'


def sheet_xml(cells, extra=""):
    rows = "".join(f'<row r="{r}">{"".join(cells[r])}</row>' for r in sorted(cells))
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet {NS}>'
            f'<sheetData>{rows}</sheetData>{extra}</worksheet>')


def main(out):
    ph = '<f ca="1"/>'
    arrays = {r: [v(f"A{r}", str(r - 1))] for r in range(2, 7)}
    arrays[2] += [v("B2", "2", f='<f t="array" ref="B2:B4">A2:A4*2</f>'),
                  v("D2", "-0.5", cm=True, f=f'<f t="array" aca="1" ref="D2:D6" ca="1">{escape(VOLATILE)}</f>'),
                  v("F2", "1", cm=True, f='<f t="array" ref="F2:F4">_xlfn.SEQUENCE(3)</f>'),
                  v("H2", "2", f='<f t="shared" ref="H2:H4" si="0">A2+1</f>'),
                  v("J2", "30", cm=True, f='<f t="array" ref="J2">SUM(A2:A6*2)</f>')]
    arrays[3] += [v("B3", "4"), v("D3", "-2", f=ph), v("F3", "2"), v("H3", "3", f='<f t="shared" si="0"/>')]
    arrays[4] += [v("B4", "6"), v("D4", "#DIV/0!", t="e", f=ph), v("F4", "3"), v("H4", "4", f='<f t="shared" si="0"/>')]
    arrays[5] += [v("D5", "4", f=ph)]
    arrays[6] += [v("D6", "2.5", f=ph)]

    tab = {1: [inline("A1", "Col1"), inline("B1", "Col2"), inline("C1", "Calc")]}
    for r in range(2, 9):
        tab[r] = [v(f"A{r}", str(r - 1)), v(f"B{r}", str((r - 1) * 10))]
    for r in range(2, 6):
        tab[r].append(v(f"C{r}", str((r - 1) * 2), f=f"<f>{escape(CALC)}</f>"))
    tab[6].append(v("C6", "99"))
    tab[8].append(v("C8", "14", f=ph))

    edge = {1: [v("A1", "1", f='<f t="array" ref="A1:A2"/>')],
            2: [v("A2", "2"), v("E2", "5", f='<f t="dataTable" ref="E2:E3" dt2D="0" dtr="0" r1="A1"/>')],
            3: [v("E3", "6")],
            5: [v("C5", "7", f=ph)]}

    parts = {
        "[Content_Types].xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            f'<Override PartName="/xl/workbook.xml" ContentType="{CT}.sheet.main+xml"/>'
            f'<Override PartName="/xl/styles.xml" ContentType="{CT}.styles+xml"/>'
            f'<Override PartName="/xl/metadata.xml" ContentType="{CT}.sheetMetadata+xml"/>'
            + "".join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="{CT}.worksheet+xml"/>'
                      for i in range(1, len(SHEETS) + 1))
            + f'<Override PartName="/xl/tables/table1.xml" ContentType="{CT}.table+xml"/></Types>',
        "_rels/.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{REL}/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>',
        "xl/workbook.xml":
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook {NS}><sheets>'
            + "".join(f'<sheet name="{n}" sheetId="{i}" r:id="rId{i}"/>' for i, n in enumerate(SHEETS, 1))
            + '</sheets><calcPr calcId="191029"/></workbook>',
        "xl/_rels/workbook.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i}" Type="{REL}/worksheet" Target="worksheets/sheet{i}.xml"/>'
                      for i in range(1, len(SHEETS) + 1))
            + f'<Relationship Id="rId{len(SHEETS) + 1}" Type="{REL}/styles" Target="styles.xml"/>'
            f'<Relationship Id="rId{len(SHEETS) + 2}" Type="{REL}/sheetMetadata" Target="metadata.xml"/>'
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
        # The dynamic-array flag cm="1" points here (as in Project Profit's own xl/metadata.xml).
        "xl/metadata.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<metadata xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:xda="http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray">'
            '<metadataTypes count="1"><metadataType name="XLDAPR" minSupportedVersion="120000" copy="1" '
            'pasteAll="1" pasteValues="1" merge="1" splitFirst="1" rowColShift="1" clearFormats="1" '
            'clearComments="1" assign="1" coerce="1" cellMeta="1"/></metadataTypes>'
            '<futureMetadata name="XLDAPR" count="1"><bk><extLst><ext uri="{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}">'
            '<xda:dynamicArrayProperties fDynamic="1" fCollapsed="0"/></ext></extLst></bk></futureMetadata>'
            '<cellMetadata count="1"><bk><rc t="1" v="0"/></bk></cellMetadata></metadata>',
        "xl/worksheets/sheet1.xml": sheet_xml(arrays),
        "xl/worksheets/sheet2.xml": sheet_xml(tab, '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>'),
        "xl/worksheets/sheet3.xml": sheet_xml(edge),
        "xl/worksheets/_rels/sheet2.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{REL}/table" Target="../tables/table1.xml"/>'
            '</Relationships>',
        "xl/tables/table1.xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="Tbl" '
            'displayName="Tbl" ref="A1:C8" totalsRowShown="0"><autoFilter ref="A1:C8"/>'
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
        w.writerow(["sheet", "cell", "kind", "formula_a1", "formula_r1c1", "cached_value", "error", "array_ref"])
        w.writerows(EXPECTED)
    with open(out + ".placeholders.csv", "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["sheet", "cell", "cached_value", "error", "where"])
        w.writerows(PLACEHOLDERS)
    print(f"wrote {out}: {len(EXPECTED)} expected rows, {len(PLACEHOLDERS)} placeholders")


if __name__ == "__main__":
    main(sys.argv[1])
