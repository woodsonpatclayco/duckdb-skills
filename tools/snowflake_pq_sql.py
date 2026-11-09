"""snowflake_pq_sql.py -- the <table>.snowflake.sql file for a Snowflake-only CSV lake table.

A lake table that comes only from Snowflake gets, next to <table>.csv, a file holding the query
the lake pull runs, ready to paste into Power Query (Excel: From ODBC > Snowflake DSN > Advanced
options > SQL statement). It is plain SQL: a short header, the query, and -- when the table has a
project column -- a commented-out WHERE line at the end that a person switches on to pull only
some projects.

  write --query Q --table T --dest DIR [--project-column COL] [--source-label TEXT]
        Writes DIR\\T.snowflake.sql from the query file Q. Rewrites it only when the text
        changes, and prints "wrote" or "unchanged". Exit 2 when Q cannot run in Power Query
        as one statement (SET/USE first, two statements, a $session variable).
  check --file F [--projects P1,P2] [--query Q] [--connection DATAHUB]
        Runs F in Snowflake as written and prints its row and column counts. --query also runs
        the source query and says whether F returns exactly the same rows. --projects switches
        the project filter on the way the file's comment tells a person to (delete /* and */,
        list the projects) and checks that it returns exactly the full result's rows for them.
        Exit 1 when a comparison does not match.

write uses the standard library only; check needs snowflake-connector-python (through sf.py).
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUFFIX = ".snowflake.sql"
ALIAS = "lake_table"
PLACEHOLDER = "'<project>', '<project>'"
# The project filter line exactly as write() emits it.
FILTER_RE = re.compile(r"^/\* (WHERE " + ALIAS + r"\.(\S+) IN \((.*)\)) \*/$", re.MULTILINE)


class Refused(Exception):
    pass


def mask(sql):
    """Return sql with every string literal, quoted identifier and comment blanked to spaces
    (same length, newlines kept), so ; $ and keywords can be found in the code alone."""
    out = list(sql)
    i, n = 0, len(sql)

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c, two = sql[i], sql[i:i + 2]
        if two in ("--", "//"):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif two == "/*":
            j = sql.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif two == "$$":
            j = sql.find("$$", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "\\":
                    j += 2
                elif sql[j] == "'":
                    if sql[j + 1:j + 2] == "'":
                        j += 2
                    else:
                        break
                else:
                    j += 1
            blank(i, j + 1)
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n:
                if sql[j] == '"':
                    if sql[j + 1:j + 2] == '"':
                        j += 2
                    else:
                        break
                else:
                    j += 1
            blank(i, j + 1)
            i = j + 1
        else:
            i += 1
    return "".join(out)


def query_body(text):
    """The statement itself: the leading comment header and a trailing ; (and anything after the
    last code) removed. Raises Refused when Power Query could not run it as one statement."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    m = mask(text)
    code = [k for k, ch in enumerate(m) if not ch.isspace()]
    if not code:
        raise Refused("the query file has no SQL in it")
    start, end = code[0], code[-1] + 1
    if m[end - 1] == ";":
        end -= 1
        while end > start and m[end - 1].isspace():
            end -= 1
    body, bm = text[start:end], m[start:end]
    first = re.match(r"[A-Za-z]+", bm)
    if not first or first.group(0).upper() not in ("SELECT", "WITH"):
        raise Refused("the query must be one SELECT or WITH statement; it starts with %r. "
                      "Power Query runs nothing before it, so no SET or USE."
                      % (first.group(0) if first else bm[:20]))
    if ";" in bm:
        line = body[:bm.index(";")].count("\n") + 1
        raise Refused("the query holds more than one statement (a ; on line %d of the statement); "
                      "Power Query runs one" % line)
    var = re.search(r"(?<![\w$])\$\w+", bm)
    if var:
        raise Refused("the query uses %s, a session variable or positional reference; Power Query "
                      "cannot SET one first, so put the value in the query" % var.group(0))
    return body


def git_label(path):
    path = os.path.abspath(path)
    d = os.path.dirname(path)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return os.path.basename(d) + "\\" + os.path.relpath(path, d).replace("/", "\\")
        parent = os.path.dirname(d)
        if parent == d:
            return path
        d = parent


def render(body, table, source, project_column=None):
    lines = [
        "-- %s: the Snowflake query behind %s.csv, ready to paste into Power Query." % (table, table),
        "--",
        "-- Excel: Data > Get Data > From Other Sources > From ODBC, choose the Snowflake DSN, open Advanced",
        "--   options and paste this whole file into \"SQL statement\". (Excel has no built-in Snowflake",
        "--   connector; Power BI's Snowflake connector takes the same text under Advanced options.)",
        "-- It returns live data with your own Snowflake sign-in. %s.csv is the copy that passed the" % table,
        "--   lake contract's checks when it was exported; rows from this query have not been checked.",
        "-- Column names come back as Snowflake writes them, usually upper case.",
    ]
    if project_column:
        lines.append("-- Project filter: see PROJECT FILTER at the end. As written, it returns every project.")
    lines += [
        "--",
        "-- Written from %s by duckdb-skills tools\\snowflake_pq_sql.py." % source,
        "--   The next export overwrites this file; change the source query instead.",
    ]
    if project_column:
        lines += ["SELECT *", "FROM ("]
        lines += body.split("\n")
        lines += [
            ") AS %s" % ALIAS,
            "-- PROJECT FILTER (optional). To return only some projects, delete the /* and the */ on the",
            "-- next line and put your project numbers in the list, each in single quotes, separated by commas.",
            "/* WHERE %s.%s IN (%s) */" % (ALIAS, project_column, PLACEHOLDER),
        ]
    else:
        lines += body.split("\n")
    return "\r\n".join(lines) + "\r\n"


def do_write(a):
    with open(a.query, encoding="utf-8-sig") as f:
        text = f.read()
    try:
        body = query_body(text)
    except Refused as e:
        print("ERROR: %s: %s" % (a.query, e), file=sys.stderr)
        return 2
    if a.project_column and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", a.project_column):
        print("ERROR: --project-column must be a plain column name, got %r" % a.project_column,
              file=sys.stderr)
        return 2
    out = render(body, a.table, a.source_label or git_label(a.query), a.project_column)
    data = out.encode("utf-8")
    path = os.path.join(a.dest, a.table + SUFFIX)
    if os.path.exists(path):
        with open(path, "rb") as f:
            if f.read() == data:
                print("unchanged %s" % path)
                return 0
    os.makedirs(a.dest, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    print("wrote %s (%d lines)" % (path, out.count("\r\n")))
    return 0


def run(cur, sql):
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    return cols, cur.fetchall()


def key(row):
    return tuple("" if v is None else str(v) for v in row)


def do_check(a):
    with open(a.file, encoding="utf-8-sig") as f:
        text = f.read()
    sys.path.insert(0, HERE)
    import sf
    conn = sf.connect(a.connection)
    ok = True
    try:
        cur = conn.cursor()
        cols, rows = run(cur, text)
        print("as written: %d rows, %d columns" % (len(rows), len(cols)))
        print("columns: %s" % ", ".join(cols))

        if a.query:
            with open(a.query, encoding="utf-8-sig") as f:
                qcols, qrows = run(cur, f.read())
            same = qcols == cols and sorted(map(key, qrows)) == sorted(map(key, rows))
            print("source query: %d rows, %d columns -> %s" % (
                len(qrows), len(qcols), "SAME rows and columns" if same else "DIFFERENT"))
            ok = ok and same

        if a.projects:
            m = FILTER_RE.search(text.replace("\r\n", "\n"))
            if not m:
                print("ERROR: %s has no PROJECT FILTER line" % a.file, file=sys.stderr)
                return 2
            projects = [p.strip() for p in a.projects.split(",") if p.strip()]
            listed = ", ".join("'%s'" % p.replace("'", "''") for p in projects)
            where = m.group(1).replace(m.group(3), listed)
            print("filter line switched on: %s" % where)
            switched = text.replace(m.group(0), where)
            fcols, frows = run(cur, switched)
            upper = [c.upper() for c in cols]
            col = m.group(2).upper()
            if col not in upper:
                print("ERROR: the result has no column %s" % m.group(2), file=sys.stderr)
                return 2
            k = upper.index(col)
            got = sorted({"" if r[k] is None else str(r[k]) for r in frows})
            expected = [r for r in rows if ("" if r[k] is None else str(r[k])) in projects]
            same = sorted(map(key, frows)) == sorted(map(key, expected))
            print("filter on: %d rows; %s values: %s" % (len(frows), m.group(2), ", ".join(got) or "(none)"))
            print("as written, rows for those projects: %d -> %s" % (
                len(expected), "SAME rows" if same else "DIFFERENT"))
            ok = ok and same
    finally:
        conn.close()
    print("RESULT: %s" % ("MATCH" if ok else "MISMATCH"))
    return 0 if ok else 1


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("--query", required=True, help="the Snowflake query file the lake pull runs")
    w.add_argument("--table", required=True, help="the lake table name (the CSV's stem)")
    w.add_argument("--dest", required=True, help="the CSV lake folder holding <table>.csv")
    w.add_argument("--project-column", help="output column the project filter tests, e.g. PROJECT_NUMBER")
    w.add_argument("--source-label", help="how the header names the query (default: <repo>\\<path>)")
    c = sub.add_parser("check")
    c.add_argument("--file", required=True, help="a <table>.snowflake.sql file")
    c.add_argument("--projects", help="comma-separated project numbers to switch the filter on with")
    c.add_argument("--query", help="the source query, to compare rows with")
    c.add_argument("--connection", default="DATAHUB")
    a = p.parse_args()
    return do_write(a) if a.cmd == "write" else do_check(a)


if __name__ == "__main__":
    sys.exit(main())
