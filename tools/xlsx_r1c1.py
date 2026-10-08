"""xlsx_r1c1.py -- convert Excel's stored A1 formula text to R1C1, and shift it, without Excel.

The same logical formula is stored with different A1 text on every row:
INDEX(_xlfn.ANCHORARRAY(AI$10),$AG10) on row 10, ...$AG11) on row 11. R1C1 writes references
relative to the formula's own cell (RC[-3] = "same row, three columns left"), so one logical
formula has ONE R1C1 form wherever it sits -- which is what a consistency check must compare.

Used by xlsx_meta.py (PLAN-6 item 3). Standard library only. The converter only rewrites cell,
range, whole-column and whole-row references; everything else is copied through untouched:

  left alone   "strings"  FUNC(  _xlfn.FUNC(  LOG10( ATAN2( DAYS360(  #REF! #N/A ...
               Table[[#This Row],[Col]]  [@Col]  @ (implicit intersection)  1E3  2.5E-7
               names that are not references (TRUE, Excluded_Vendors, TAX)
  converted    A1  $A$1  A$1  A1:B5  A:A  $A:$C  1:1  $3:$5  Sheet1!A1  'My Sheet'!A1
               'Q1'!A1 (a sheet whose name looks like a cell)  Sheet1!#REF! keeps #REF!

R1C1 rendering follows Excel: an absolute part is R<n>/C<n>, a relative one R[<d>]/C[<d>],
and a zero offset is a bare R or C (so the formula's own cell is RC).
"""
import re

MAX_COL = 16384
MAX_ROW = 1048576

_ERR = re.compile(r"#(?:NULL!|DIV/0!|VALUE!|REF!|NAME\?|NUM!|N/A|GETTING_DATA|SPILL!|CALC!|FIELD!|"
                  r"BLOCKED!|CONNECT!|BUSY!|UNKNOWN!|PYTHON!)", re.IGNORECASE)
# What may NOT follow a reference: another identifier character, a call, a table bracket,
# or a sheet bang (then the "reference" was really a sheet or name prefix).
_END = r"(?![A-Za-z0-9_.\\?(\[!])"
_AREA = re.compile(r"(\$?)([A-Z]{1,3})(\$?)(\d+)(?::(\$?)([A-Z]{1,3})(\$?)(\d+))?" + _END)
_COLS = re.compile(r"(\$?)([A-Z]{1,3}):(\$?)([A-Z]{1,3})" + _END)
_ROWS = re.compile(r"(\$?)(\d+):(\$?)(\d+)" + _END)
_NUM = re.compile(r"(?:\d+\.?\d*|\.\d+)(?:[Ee][+-]?\d+)?")
_IDENT = re.compile(r"[A-Za-z_\\\u0080-￿][A-Za-z0-9_.\\?\u0080-￿]*")


def col_num(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def col_letters(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


class Ref:
    """One reference. kind: 'cell' (a single cell or an A1:B5 area), 'cols', 'rows'.
    parts: list of (col, col_abs, row, row_abs); col or row is None where it does not apply."""
    __slots__ = ("kind", "parts")

    def __init__(self, kind, parts):
        self.kind, self.parts = kind, parts


def tokenize(formula):
    """Split stored formula text into a list of str (copied through) and Ref (rewritten)."""
    out, i, n = [], 0, len(formula)

    def emit(text):
        if out and isinstance(out[-1], str):
            out[-1] += text
        else:
            out.append(text)

    prev_ident = False   # was the previous token an identifier/number (so a digit here continues it)?
    while i < n:
        ch = formula[i]
        if ch == '"':                                   # string literal, "" is an escaped quote
            j = i + 1
            while j < n:
                if formula[j] == '"':
                    if j + 1 < n and formula[j + 1] == '"':
                        j += 2
                        continue
                    break
                j += 1
            emit(formula[i:j + 1]); i = j + 1; prev_ident = False; continue
        if ch == "'":                                   # quoted sheet name, '' is an escaped quote
            j = i + 1
            while j < n:
                if formula[j] == "'":
                    if j + 1 < n and formula[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            emit(formula[i:j + 1]); i = j + 1; prev_ident = False; continue
        if ch == "[":                                   # structured ref / external book: skip, nested
            depth, j = 0, i
            while j < n:
                c = formula[j]
                if c == "'" and j + 1 < n:              # ' escapes the next char inside brackets
                    j += 2
                    continue
                if c == "[":
                    depth += 1
                elif c == "]":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            emit(formula[i:j + 1]); i = j + 1; prev_ident = True; continue
        if ch == "#":
            m = _ERR.match(formula, i)
            if m:
                emit(m.group(0)); i = m.end(); prev_ident = False; continue
            emit(ch); i += 1; prev_ident = False; continue
        if not prev_ident and (ch == "$" or ch.isdigit()):
            m = _ROWS.match(formula, i)
            if m and _rows_ok(m):
                out.append(Ref("rows", [(None, False, int(m.group(2)), bool(m.group(1))),
                                        (None, False, int(m.group(4)), bool(m.group(3)))]))
                i = m.end(); prev_ident = False; continue
        if not prev_ident and (ch == "$" or "A" <= ch <= "Z"):
            m = _AREA.match(formula, i)
            if m and _area_ok(m):
                parts = [(col_num(m.group(2)), bool(m.group(1)), int(m.group(4)), bool(m.group(3)))]
                if m.group(6):
                    parts.append((col_num(m.group(6)), bool(m.group(5)), int(m.group(8)), bool(m.group(7))))
                out.append(Ref("cell", parts)); i = m.end(); prev_ident = False; continue
            m = _COLS.match(formula, i)
            if m and col_num(m.group(2)) <= MAX_COL and col_num(m.group(4)) <= MAX_COL:
                out.append(Ref("cols", [(col_num(m.group(2)), bool(m.group(1)), None, False),
                                        (col_num(m.group(4)), bool(m.group(3)), None, False)]))
                i = m.end(); prev_ident = False; continue
        if ch.isdigit() or (ch == "." and i + 1 < n and formula[i + 1].isdigit()):
            m = _NUM.match(formula, i)                  # 1E3 is a number, not cell E3
            emit(m.group(0)); i = m.end(); prev_ident = True; continue
        m = _IDENT.match(formula, i)
        if m:                                           # function, name, table, sheet prefix
            emit(m.group(0)); i = m.end(); prev_ident = True; continue
        emit(ch); i += 1
        prev_ident = False
    return out


def _area_ok(m):
    if col_num(m.group(2)) > MAX_COL or not 1 <= int(m.group(4)) <= MAX_ROW:
        return False
    if m.group(6) and (col_num(m.group(6)) > MAX_COL or not 1 <= int(m.group(8)) <= MAX_ROW):
        return False
    return True


def _rows_ok(m):
    return 1 <= int(m.group(2)) <= MAX_ROW and 1 <= int(m.group(4)) <= MAX_ROW


def _r1c1_part(axis, value, absolute, origin):
    if absolute:
        return f"{axis}{value}"
    d = value - origin
    return axis if d == 0 else f"{axis}[{d}]"


def render_r1c1(tokens, row, col):
    """R1C1 text for tokens, as seen from the cell at (row, col)."""
    s = []
    for t in tokens:
        if isinstance(t, str):
            s.append(t)
            continue
        if t.kind == "cell":
            bits = [_r1c1_part("R", r, ra, row) + _r1c1_part("C", c, ca, col) for c, ca, r, ra in t.parts]
        elif t.kind == "cols":
            bits = [_r1c1_part("C", c, ca, col) for c, ca, _r, _ra in t.parts]
        else:
            bits = [_r1c1_part("R", r, ra, row) for _c, _ca, r, ra in t.parts]
        # Excel writes B:B as C[1], not C[1]:C[1] -- a range whose two ends are the same is one.
        s.append(bits[0] if len(bits) == 2 and bits[0] == bits[1] else ":".join(bits))
    return "".join(s)


def render_a1(tokens, drow=0, dcol=0):
    """A1 text for tokens, with every relative part moved by (drow, dcol) -- how Excel fills a
    shared formula from its master cell into a dependent cell."""
    s = []
    for t in tokens:
        if isinstance(t, str):
            s.append(t)
            continue
        bits = []
        for c, ca, r, ra in t.parts:
            b = ""
            if c is not None:
                b += ("$" if ca else "") + col_letters(c if ca else c + dcol)
            if r is not None:
                b += ("$" if ra else "") + str(r if ra else r + drow)
            bits.append(b)
        s.append(":".join(bits))
    return "".join(s)


def to_r1c1(formula, row, col):
    return render_r1c1(tokenize(formula), row, col)
