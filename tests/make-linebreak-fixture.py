"""make-linebreak-fixture.py <out.xlsx>

Builds the workbook tests/prove-linebreak-headers.ps1 checks: Excel tables whose header cells
hold a line break (Alt+Enter), the way Excel itself stores them -- the header cell's text holds
the line break, and the table's own column list writes it as _x000a_ (_x000d_ for a CR), as in
Project Profit's Risk_Reserve_Summary table.

  Breaks (sheet Data, A1:E5)   Job<LF>Number | Cost "Code",<LF>Type | Amount | Note<CR><LF>Text | Calc
                               Calc is a calculated column whose formula holds a line break;
                               E4 holds a typed 99 instead of the formula. D2 holds a value with
                               a line break.
  Plain  (sheet Plain, A1:B3)  Code | Qty -- no line breaks anywhere
  Accents (sheet Accents, A1:B3)  Café | Plain -- non-ASCII header and values

Written straight as XML (standard library only), like tests/make-formula-fixture.py, with
cached values in every cell so read_xlsx returns data.
"""
import sys
import zipfile
from xml.sax.saxutils import escape

NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
     'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
CT = "application/vnd.openxmlformats-officedocument.spreadsheetml"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

# Header text as Excel holds it in the cell, and the name Excel writes into the table's column list.
BREAKS_HEADERS = ["Job\nNumber", 'Cost "Code",\nType', "Amount", "Note\r\nText", "Calc"]
CALC = "IF(Breaks[[#This Row],[Amount]]>0,\nBreaks[[#This Row],[Amount]]*2,0)"


def xml_text(s):
    # escape() leaves CR alone, and an XML parser turns a raw CR (or CRLF) into LF -- so a CR
    # must be written as a character reference to survive, exactly as Excel does.
    return escape(s, {'"': "&quot;"}).replace("\r", "&#13;")


def table_col_name(s):
    return s.replace("\r", "_x000d_").replace("\n", "_x000a_")


def inline(ref, text):
    return f'<c r="{ref}" t="inlineStr"><is><t xml:space="preserve">{xml_text(text)}</t></is></c>'


def num(ref, v):
    return f'<c r="{ref}"><v>{v}</v></c>'


def sheet_xml(cells, extra=""):
    rows = "".join(f'<row r="{r}">{"".join(cells[r])}</row>' for r in sorted(cells))
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet {NS}><sheetData>{rows}</sheetData>{extra}</worksheet>'


def table_xml(tid, name, ref, cols, calc=None):
    parts = []
    for i, c in enumerate(cols, 1):
        f = calc.get(c) if calc else None
        body = f"<calculatedColumnFormula>{xml_text(f)}</calculatedColumnFormula>" if f else ""
        parts.append(f'<tableColumn id="{i}" name="{xml_text(table_col_name(c))}">{body}</tableColumn>')
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            f'<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="{tid}" name="{name}" '
            f'displayName="{name}" ref="{ref}" totalsRowShown="0"><autoFilter ref="{ref}"/>'
            f'<tableColumns count="{len(cols)}">{"".join(parts)}</tableColumns>'
            '<tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" '
            'showRowStripes="1" showColumnStripes="0"/></table>')


def main(out):
    # --- Breaks: header row with line breaks, a calculated column with one typed value ---
    data = {1: [inline(f"{c}1", h) for c, h in zip("ABCDE", BREAKS_HEADERS)]}
    notes = {2: "line one\nline two", 3: "ok", 4: "ok", 5: "ok"}
    for r in range(2, 6):
        amount = (r - 1) * 100
        data[r] = [inline(f"A{r}", str(10000 + r - 1)), inline(f"B{r}", f"CC-{r - 1}"),
                   num(f"C{r}", amount), inline(f"D{r}", notes[r])]
        if r == 4:
            data[r].append(num(f"E{r}", 99))                                  # typed over the formula
        else:
            data[r].append(f'<c r="E{r}"><f>{xml_text(CALC)}</f><v>{amount * 2}</v></c>')

    plain = {1: [inline("A1", "Code"), inline("B1", "Qty")],
             2: [inline("A2", "P-1"), num("B2", 5)],
             3: [inline("A3", "P-2"), num("B3", 7)]}
    accents = {1: [inline("A1", "Café"), inline("B1", "Plain")],
               2: [inline("A2", "crème"), num("B2", 1)],
               3: [inline("A3", "naïve"), num("B3", 2)]}

    sheets = [("Data", data, "table1.xml"), ("Plain", plain, "table2.xml"), ("Accents", accents, "table3.xml")]
    tables = {
        "table1.xml": table_xml(1, "Breaks", "A1:E5", BREAKS_HEADERS, {"Calc": CALC}),
        "table2.xml": table_xml(2, "Plain", "A1:B3", ["Code", "Qty"]),
        "table3.xml": table_xml(3, "Accents", "A1:B3", ["Café", "Plain"]),
    }

    parts = {
        "[Content_Types].xml":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            f'<Override PartName="/xl/workbook.xml" ContentType="{CT}.sheet.main+xml"/>'
            f'<Override PartName="/xl/styles.xml" ContentType="{CT}.styles+xml"/>'
            + "".join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="{CT}.worksheet+xml"/>'
                      for i in range(1, len(sheets) + 1))
            + "".join(f'<Override PartName="/xl/tables/{t}" ContentType="{CT}.table+xml"/>' for t in tables)
            + '</Types>',
        "_rels/.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{REL}/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>',
        "xl/workbook.xml":
            f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook {NS}><sheets>'
            + "".join(f'<sheet name="{n}" sheetId="{i}" r:id="rId{i}"/>' for i, (n, _, _) in enumerate(sheets, 1))
            + '</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>',
        "xl/_rels/workbook.xml.rels":
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i}" Type="{REL}/worksheet" Target="worksheets/sheet{i}.xml"/>'
                      for i in range(1, len(sheets) + 1))
            + f'<Relationship Id="rId{len(sheets) + 1}" Type="{REL}/styles" Target="styles.xml"/>'
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
    }
    for i, (_, cells, table) in enumerate(sheets, 1):
        parts[f"xl/worksheets/sheet{i}.xml"] = sheet_xml(cells, '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>')
        parts[f"xl/worksheets/_rels/sheet{i}.xml.rels"] = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{REL}/table" Target="../tables/{table}"/></Relationships>')
        parts[f"xl/tables/{table}"] = tables[table]

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in parts.items():
            z.writestr(name, text.encode("utf-8"))
    print(f"wrote {out}: tables Breaks (Data!A1:E5), Plain (Plain!A1:B3), Accents (Accents!A1:B3)")


if __name__ == "__main__":
    main(sys.argv[1])
