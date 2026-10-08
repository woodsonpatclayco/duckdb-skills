"""xlsx_meta.py -- read Excel table (ListObject) and named-range locations out of a workbook.

DuckDB's read_xlsx cannot address a table or a named range by name (duckdb-excel#7), and a
sheet-only read silently stops early or runs past the end of a table. This script reads the
locations straight out of the workbook zip and emits SQL macros, so a query can say
read_xlsx_table(path, 'Tbl') and get exactly that table's rows (PLAN-6 item 1).

Subcommands:
  tables <workbook>            one row per table: name, sheet, ref, data range, header/totals rows, columns
  names  <workbook>            one row per defined name, plus one 'ambiguous' row per bare name that
                               is defined more than once; hidden _xlnm.* built-ins excluded
  macros <workbook>... [-o F]  SQL defining xlsx_table_sheet/_range, read_xlsx_table,
                               xlsx_name_sheet/_range, read_xlsx_name for the given workbooks

Standard library only (py -3.12). The workbook is opened read-only as a zip and never written.
The generated SQL is regenerated on every run and never committed -- nothing in it can go stale.
Refuses rather than guesses: an unknown table, an ambiguous bare name, a broken or
formula-defined name, or a table with no header row all raise a named error when used.
"""
import argparse
import csv
import io
import os
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

REL_TABLE = "/table"
_CELL = re.compile(r"^\$?([A-Z]{1,3})\$?(\d+)$")


def local(tag):
    return tag.rsplit("}", 1)[-1]


def attr(el, name):
    """Attribute by local name, ignoring any namespace prefix (r:id etc.)."""
    for k, v in el.attrib.items():
        if local(k) == name:
            return v
    return None


def col_to_num(col):
    n = 0
    for ch in col:
        n = n * 26 + ord(ch) - 64
    return n


def num_to_col(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def parse_area(ref):
    """'A2:AO124' or 'B3' -> (c1, r1, c2, r2) as numbers, or None if not a plain rectangle."""
    parts = ref.split(":")
    if len(parts) not in (1, 2):
        return None
    cells = [_CELL.match(p) for p in parts]
    if not all(cells):
        return None
    (c1, r1), (c2, r2) = [(col_to_num(m.group(1)), int(m.group(2))) for m in (cells[0], cells[-1])]
    return min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)


def area_text(c1, r1, c2, r2):
    a, b = f"{num_to_col(c1)}{r1}", f"{num_to_col(c2)}{r2}"
    return a if a == b else f"{a}:{b}"


def quote_sheet(sheet):
    """Excel's way of writing a sheet name in front of '!'."""
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", sheet) and not _CELL.match(sheet.upper()):
        return sheet
    return "'" + sheet.replace("'", "''") + "'"


def resolve(base_dir, target):
    if target.startswith("/"):
        return target.lstrip("/")
    return posixpath.normpath(posixpath.join(base_dir, target))


def rels_path(part):
    d, f = posixpath.split(part)
    return posixpath.join(d, "_rels", f + ".rels")


def read_rels(z, part):
    p = rels_path(part)
    if p not in z.namelist():
        return []
    root = ET.fromstring(z.read(p))
    base = posixpath.dirname(part)
    out = []
    for r in root:
        if r.get("TargetMode") == "External":
            continue
        out.append((r.get("Id"), r.get("Type", ""), resolve(base, r.get("Target", ""))))
    return out


class Workbook:
    def __init__(self, path):
        if not os.path.isfile(path):
            raise SystemExit(f"ERROR: workbook not found: {path}")
        self.path = os.path.abspath(path)
        try:
            self.z = zipfile.ZipFile(self.path, "r")
        except zipfile.BadZipFile:
            raise SystemExit(f"ERROR: not an .xlsx/.xlsm zip (an .xls or .xlsb?): {self.path}")
        if "xl/workbook.xml" not in self.z.namelist():
            raise SystemExit(f"ERROR: no xl/workbook.xml in {self.path}")
        self._load()

    def close(self):
        self.z.close()

    def _load(self):
        wb = ET.fromstring(self.z.read("xl/workbook.xml"))
        rid_target = {rid: tgt for rid, _t, tgt in read_rels(self.z, "xl/workbook.xml")}
        self.sheets = []            # [(name, part)] in tab order; index == localSheetId
        self.defined = []           # [(name, localSheetId or None, text, hidden)]
        for el in wb.iter():
            tag = local(el.tag)
            if tag == "sheet":
                self.sheets.append((el.get("name"), rid_target.get(attr(el, "id"))))
            elif tag == "definedName":
                lsid = el.get("localSheetId")
                self.defined.append((el.get("name"), int(lsid) if lsid is not None else None,
                                     (el.text or "").strip(), el.get("hidden") in ("1", "true")))

        self.tables = []
        for sheet, part in self.sheets:
            if not part:
                continue
            for _rid, rtype, tgt in read_rels(self.z, part):
                if not rtype.endswith(REL_TABLE) or tgt not in self.z.namelist():
                    continue
                self.tables.append(self._table(sheet, tgt))

    def _table(self, sheet, part):
        # Only the <table> tag's own attributes: its <autoFilter> child has a different ref.
        for _ev, el in ET.iterparse(io.BytesIO(self.z.read(part)), events=("start",)):
            if local(el.tag) == "table":
                root = el
                break
        ncols = None
        for el in root.iter():
            if local(el.tag) == "tableColumns":
                ncols = int(el.get("count") or len(list(el)))
                break
        ref = root.get("ref")
        header = int(root.get("headerRowCount", "1"))
        totals = int(root.get("totalsRowCount", "0"))
        area = parse_area(ref)
        c1, r1, c2, r2 = area
        data_first, data_last = r1 + header, r2 - totals
        return {
            "table": root.get("displayName") or root.get("name"),
            "sheet": sheet,
            "ref": ref,
            "read_range": area_text(c1, r1, c2, data_last),   # header row .. last data row
            "data_range": area_text(c1, data_first, c2, data_last),
            "header_rows": header,
            "totals_rows": totals,
            "data_rows": data_last - data_first + 1,
            "columns": ncols if ncols is not None else c2 - c1 + 1,
            "part": part,
        }

    def names(self):
        """Per definition: dict(address, name, scope, sheet, range, rows, status, detail).
        Plus one 'ambiguous' row for each bare name defined more than once."""
        rows = []
        for name, lsid, text, hidden in self.defined:
            if name.startswith("_xlnm."):
                continue
            scope_sheet = self.sheets[lsid][0] if lsid is not None and lsid < len(self.sheets) else None
            row = {"name": name, "scope": "sheet" if scope_sheet else "workbook",
                   "scope_sheet": scope_sheet or "",
                   "address": (quote_sheet(scope_sheet) + "!" + name) if scope_sheet else name,
                   "sheet": "", "range": "", "rows": "", "status": "", "detail": text}
            row.update(self._classify(text))
            rows.append(row)

        by_name = {}
        for r in rows:
            by_name.setdefault(r["name"].lower(), []).append(r)
        for key, defs in by_name.items():
            if len(defs) > 1:
                where = ", ".join(d["address"] for d in defs)
                rows.append({"name": defs[0]["name"], "scope": "-", "scope_sheet": "",
                             "address": defs[0]["name"], "sheet": "", "range": "", "rows": "",
                             "status": "ambiguous",
                             "detail": f"defined {len(defs)} times: {where}"})
        return rows

    def _classify(self, text):
        if "#REF!" in text.upper():
            return {"status": "broken"}
        m = re.fullmatch(r"(?:'((?:[^']|'')+)'|([^'!\[\]]+))!([$A-Z0-9:]+)", text)
        if m:
            sheet = (m.group(1) or "").replace("''", "'") or m.group(2)
            area = parse_area(m.group(3).replace("$", ""))
            if area and sheet in [s for s, _p in self.sheets]:
                c1, r1, c2, r2 = area
                return {"status": "ok", "sheet": sheet, "range": area_text(*area),
                        "rows": r2 - r1 + 1}
        return {"status": "formula"}


# ---------------------------------------------------------------- output

def emit(rows, cols, fmt):
    if fmt == "csv":
        w = csv.writer(sys.stdout, lineterminator="\n")
        w.writerow(cols)
        for r in rows:
            w.writerow([r[c] for c in cols])
        return
    widths = {c: max([len(c)] + [len(str(r[c])) for r in rows]) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols).rstrip())
    for r in rows:
        print("  ".join(str(r[c]).ljust(widths[c]) for c in cols).rstrip())


def cmd_tables(a):
    wb = Workbook(a.workbook)
    try:
        rows = sorted(wb.tables, key=lambda t: ([s for s, _ in wb.sheets].index(t["sheet"]), t["ref"]))
        emit(rows, ["table", "sheet", "ref", "data_range", "data_rows", "header_rows", "totals_rows",
                    "columns"], a.format)
        if a.format == "text":
            print(f"total_tables={len(rows)}")
    finally:
        wb.close()


def cmd_names(a):
    wb = Workbook(a.workbook)
    try:
        rows = wb.names()
        emit(rows, ["address", "scope", "sheet", "range", "rows", "status", "detail"], a.format)
        counts = {}
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        if a.format == "text":
            print("total_names=" + str(len(rows)) + " "
                  + " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    finally:
        wb.close()


# ---------------------------------------------------------------- macro generation

def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def norm_path(p):
    return os.path.abspath(p).replace("\\", "/").lower()


def name_keys(row):
    """Every spelling that addresses this definition, lowercased."""
    if row["status"] == "ambiguous" or not row["scope_sheet"]:
        return [row["name"].lower()]
    keys = {row["address"].lower(), (row["scope_sheet"] + "!" + row["name"]).lower()}
    return sorted(keys)


def case_macro(name, params, whens, fallback):
    lines = [f"CREATE OR REPLACE MACRO {name}({params}) AS CASE"]
    lines += [f"    WHEN {cond} THEN {val}" for cond, val in whens]
    lines.append(f"    ELSE {fallback}")
    lines.append("END;")
    return "\n".join(lines)


def cmd_macros(a):
    t_sheet, t_range = [], []
    n_sheet, n_range, n_header = [], [], []
    loaded = []
    for path in a.workbooks:
        wb = Workbook(path)
        try:
            p = norm_path(wb.path)
            loaded.append(wb.path)
            pc = f"xlsx__norm(p) = {sql_str(p)}"
            for t in wb.tables:
                cond = f"{pc} AND lower(t) = {sql_str(t['table'].lower())}"
                t_sheet.append((cond, sql_str(t["sheet"])))
                if t["header_rows"] == 0:
                    msg = (f"read_xlsx_table: table {t['table']} on sheet {t['sheet']} has no header row "
                           f"(headerRowCount=0); refusing to guess column names")
                    t_range.append((cond, f"error({sql_str(msg)})"))
                elif t["data_rows"] < 1:
                    msg = f"read_xlsx_table: table {t['table']} has no data rows (ref {t['ref']})"
                    t_range.append((cond, f"error({sql_str(msg)})"))
                else:
                    t_range.append((cond, sql_str(t["read_range"])))
            # Unambiguous bare names also answer to their bare spelling.
            rows = wb.names()
            counts = {}
            for r in rows:
                if r["status"] != "ambiguous":
                    counts[r["name"].lower()] = counts.get(r["name"].lower(), 0) + 1
            for r in rows:
                keys = name_keys(r)
                if r["status"] != "ambiguous" and r["scope_sheet"] and counts[r["name"].lower()] == 1:
                    keys.append(r["name"].lower())
                cond = f"{pc} AND lower(n) IN ({', '.join(sql_str(k) for k in keys)})"
                if r["status"] == "ok":
                    n_sheet.append((cond, sql_str(r["sheet"])))
                    n_range.append((cond, sql_str(r["range"])))
                    n_header.append((cond, "true" if r["rows"] > 1 else "false"))
                else:
                    if r["status"] == "ambiguous":
                        msg = (f"read_xlsx_name: {r['name']} is ambiguous -- {r['detail']}; "
                               f"address it as Sheet!Name")
                    elif r["status"] == "broken":
                        msg = f"read_xlsx_name: {r['address']} is broken: {r['detail']}"
                    else:
                        msg = (f"read_xlsx_name: {r['address']} is not a plain cell range "
                               f"(it is {r['detail']}); formula-defined names are not resolved")
                    err = f"error({sql_str(msg)})"
                    n_sheet.append((cond, err))
                    n_range.append((cond, err))
                    n_header.append((cond, err))
        finally:
            wb.close()

    t_unknown = f"error('no table ''' || t || ''' in ' || p || ' (or that workbook was not passed to tools/xlsx_meta.py macros) -- list them with tools/xlsx_meta.py tables')"
    n_unknown = f"error('no defined name ''' || n || ''' in ' || p || ' (or that workbook was not passed to tools/xlsx_meta.py macros) -- list them with tools/xlsx_meta.py names')"
    out = [
        "-- Generated by tools/xlsx_meta.py macros -- regenerated every run, never committed or hand-edited.",
        "-- Workbooks: " + "; ".join(loaded),
        "CREATE OR REPLACE MACRO xlsx__norm(p) AS lower(replace(p, '\\', '/'));",
        "CREATE OR REPLACE MACRO xlsx__q(s) AS '''' || replace(s, '''', '''''') || '''';",
        case_macro("xlsx_table_sheet", "p, t", t_sheet, t_unknown) if t_sheet
        else f"CREATE OR REPLACE MACRO xlsx_table_sheet(p, t) AS {t_unknown};",
        case_macro("xlsx_table_range", "p, t", t_range, t_unknown) if t_range
        else f"CREATE OR REPLACE MACRO xlsx_table_range(p, t) AS {t_unknown};",
        case_macro("xlsx_name_sheet", "p, n", n_sheet, n_unknown) if n_sheet
        else f"CREATE OR REPLACE MACRO xlsx_name_sheet(p, n) AS {n_unknown};",
        case_macro("xlsx_name_range", "p, n", n_range, n_unknown) if n_range
        else f"CREATE OR REPLACE MACRO xlsx_name_range(p, n) AS {n_unknown};",
        case_macro("xlsx__name_header", "p, n", n_header, n_unknown) if n_header
        else f"CREATE OR REPLACE MACRO xlsx__name_header(p, n) AS {n_unknown};",
        # range= is sheet-relative and switches stop_at_empty off, so the read is exactly the
        # table's rectangle: header row through the last data row (totals row trimmed).
        "CREATE OR REPLACE MACRO read_xlsx_table(p, t) AS TABLE FROM query("
        "'SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_table_sheet(p, t))"
        " || ', range = ' || xlsx__q(xlsx_table_range(p, t)) || ', header = true, all_varchar = true)');",
        # header defaults from geometry: a one-row range has nothing below a header to read.
        "CREATE OR REPLACE MACRO read_xlsx_name(p, n, header := NULL) AS TABLE FROM query("
        "'SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_name_sheet(p, n))"
        " || ', range = ' || xlsx__q(xlsx_name_range(p, n)) || ', header = '"
        " || coalesce(header, xlsx__name_header(p, n))::VARCHAR || ', all_varchar = true)');",
    ]
    text = "\n".join(out) + "\n"
    if a.output:
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"wrote {a.output}: {len(t_sheet)} tables, {len(n_sheet)} names, "
              f"{len(loaded)} workbook(s)")
    else:
        sys.stdout.write(text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("tables", cmd_tables), ("names", cmd_names)):
        s = sub.add_parser(name)
        s.add_argument("workbook")
        s.add_argument("--format", choices=("text", "csv"), default="text")
        s.set_defaults(fn=fn)
    s = sub.add_parser("macros")
    s.add_argument("workbooks", nargs="+")
    s.add_argument("-o", "--output", help="write the SQL here instead of stdout")
    s.set_defaults(fn=cmd_macros)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
