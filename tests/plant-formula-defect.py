"""plant-formula-defect.py <clean.xlsx> <out.xlsx> <sheet> <cells> typed <value>
                                                               formula <new A1 formula>
                                                               error <#CODE!>

Writes a copy of <clean.xlsx> with the defect a PLAN-6 item 4 formula check must catch
(tests/prove-formula-checks.ps1). <cells> is one cell (A20) or a one-column range (A10:A90);
"{row}" in the value is replaced by each cell's row number.
  typed    the formula is removed and a plain value typed over it
  formula  the formula text is replaced (the cell keeps its kind: array / normal)
  error    the formula stays, but the cell now shows an error value
Every other byte of every other part is copied unchanged. <clean.xlsx> is only read.
"""
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import xlsx_meta  # noqa: E402


def main(clean, out, sheet, cells, mode, arg):
    m = re.fullmatch(r"([A-Z]+)(\d+)(?::\1(\d+))?", cells)
    if not m:
        raise SystemExit(f"ERROR: {cells!r} is not one cell or a one-column range like A10:A90")
    targets = [f"{m.group(1)}{r}" for r in range(int(m.group(2)), int(m.group(3) or m.group(2)) + 1)]
    wb = xlsx_meta.Workbook(clean)
    part = dict(wb.sheets).get(sheet)
    wb.close()
    if not part:
        raise SystemExit(f"ERROR: no sheet {sheet!r} in {clean}")
    with zipfile.ZipFile(clean) as zi, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
        for item in zi.infolist():
            data = zi.read(item.filename)
            if item.filename == part:
                xml = data.decode("utf-8")
                for cell in targets:
                    xml = plant(xml, sheet, cell, mode, arg.replace("{row}", cell.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ")))
                data = xml.encode("utf-8")
            zo.writestr(item, data)
    print(f"planted {mode} in {sheet}!{cells} ({len(targets)} cell(s))")


def plant(xml, sheet, cell, mode, arg):
    m = re.search(r'<c r="%s"(?P<attrs>[^>]*)>(?P<body>.*?)</c>' % re.escape(cell), xml, re.S)
    if not m:
        raise SystemExit(f"ERROR: cell {sheet}!{cell} has no <c> element to change")
    attrs, body = m.group("attrs"), m.group("body")
    style = re.search(r'\ss="\d+"', attrs)
    style = style.group(0) if style else ""
    if mode == "typed":
        new = f'<c r="{cell}"{style}><v>{escape(arg)}</v></c>'
    elif mode == "formula":
        f = re.search(r"<f\b[^>]*>.*?</f>|<f\b[^>]*/>", body, re.S)
        if not f:
            raise SystemExit(f"ERROR: {sheet}!{cell} holds no formula to change")
        new_f = re.sub(r">.*?</f>$", f">{escape(arg)}</f>", f.group(0), flags=re.S)
        new = f'<c r="{cell}"{attrs}>{body.replace(f.group(0), new_f)}</c>'
    elif mode == "error":
        f = re.search(r"<f\b[^>]*>.*?</f>", body, re.S)
        attrs2 = re.sub(r'\st="\w+"', "", attrs) + ' t="e"'
        new = f'<c r="{cell}"{attrs2}>{f.group(0) if f else ""}<v>{escape(arg)}</v></c>'
    else:
        raise SystemExit(f"ERROR: unknown defect {mode!r} (typed / formula / error)")
    return xml[:m.start()] + new + xml[m.end():]


if __name__ == "__main__":
    if len(sys.argv) != 7:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
