"""sf.py -- run Snowflake SQL through the Python connector for the snowflake-extract skill.

Modes:
  query  --sql-file <f>   one read-only statement (SELECT/WITH/SHOW/DESC[RIBE]) -> CSV on stdout
  unload --name N --project-id P --database DB --sql-file <f> --dest <dir>
                          COPY INTO @~ (Parquet) + GET + timing lookup + REMOVE -> JSON on stdout

Standard library plus snowflake-connector-python only. SQL always comes from a file.
The read-only guard is a guardrail against mistakes, not a security boundary: the
role's privileges are the real limit, and cursor.execute() runs one statement only.
"""
import argparse
import contextlib
import csv
import datetime
import json
import os
import re
import sys
import time
import uuid

REFUSAL = ("ERROR: sf.py query only runs SELECT/WITH/SHOW/DESCRIBE; "
           "use the unload mode for COPY/GET/REMOVE")
_ALLOWED = re.compile(r"(select|with|show|desc|describe)\b", re.IGNORECASE)


def read_sql(path):
    with open(path, encoding="utf-8-sig") as f:
        return f.read()


def is_read_only(sql):
    s = sql
    while True:
        s = s.lstrip()
        if s.startswith("--"):
            nl = s.find("\n")
            s = "" if nl < 0 else s[nl + 1:]
        else:
            break
    return bool(_ALLOWED.match(s))


def connect(name):
    import snowflake.connector
    with contextlib.redirect_stdout(sys.stderr):
        return snowflake.connector.connect(connection_name=name)


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, datetime.datetime):
        if v.tzinfo is not None:
            v = v.astimezone(datetime.timezone.utc).replace(tzinfo=None)
            return v.isoformat() + "Z"
        return v.isoformat()
    if isinstance(v, (datetime.date, datetime.time)):
        return v.isoformat()
    return str(v)


def do_query(args):
    sql = read_sql(args.sql_file)
    if not is_read_only(sql):
        print(REFUSAL, file=sys.stderr)
        return 2
    conn = connect(args.connection)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        w = csv.writer(sys.stdout, lineterminator="\n")
        w.writerow([d[0] for d in cur.description])
        for row in cur.fetchall():
            w.writerow([fmt(v) for v in row])
    finally:
        conn.close()
    return 0


def row_dict(cur, row):
    return {d[0].lower(): v for d, v in zip(cur.description, row)}


def do_unload(args):
    text = read_sql(args.sql_file)
    query = text.rstrip()
    if query.endswith(";"):
        query = query[:-1].rstrip()
    stage = "@~/duckdb-skills/%s/%s__%s/" % (args.project_id, args.name, uuid.uuid4().hex[:8])
    dest = args.dest
    conn = connect(args.connection)
    result = None
    err = None
    try:
        cur = conn.cursor()
        try:
            cur.execute("COPY INTO %s FROM (\n%s\n) FILE_FORMAT = (TYPE = PARQUET) "
                        "HEADER = TRUE OVERWRITE = TRUE" % (stage, query))
            r = row_dict(cur, cur.fetchone())
            qid = cur.sfqid
            rows_unloaded = r["rows_unloaded"]
            output_bytes = r["output_bytes"]

            os.makedirs(dest, exist_ok=True)
            cur.execute("GET %s 'file://%s/'" % (stage, dest.replace("\\", "/").rstrip("/")))
            files = [row_dict(cur, g).get("file") for g in cur.fetchall()]

            runtime = None
            for attempt in range(5):
                cur.execute("SELECT TOTAL_ELAPSED_TIME FROM TABLE(%s.INFORMATION_SCHEMA."
                            "QUERY_HISTORY_BY_SESSION()) WHERE QUERY_ID = '%s' "
                            "AND EXECUTION_STATUS = 'SUCCESS'" % (args.database, qid))
                h = cur.fetchone()
                if h is not None:
                    runtime = h[0] / 1000.0
                    break
                if attempt < 4:
                    time.sleep(1)
            if runtime is None:
                print("WARNING: no QUERY_HISTORY_BY_SESSION row for query id %s after 5 tries; "
                      "runtime_seconds omitted" % qid, file=sys.stderr)
            result = {"stage_path": stage, "row_count": rows_unloaded,
                      "output_bytes": output_bytes}
            if runtime is not None:
                result["runtime_seconds"] = runtime
            result["files"] = files
        except Exception as e:  # reported after cleanup
            err = e
        finally:
            try:
                cur.execute("REMOVE %s" % stage)
                n = len(cur.fetchall())
                print("removed=%d" % n, file=sys.stderr)
            except Exception as e2:
                print("ERROR: REMOVE %s failed: %s" % (stage, e2), file=sys.stderr)
    finally:
        conn.close()
    if err is not None:
        print(str(err), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Snowflake SQL through the Python connector")
    ap.add_argument("--connection", default="DATAHUB")
    sub = ap.add_subparsers(dest="mode", required=True)
    q = sub.add_parser("query")
    q.add_argument("--sql-file", required=True)
    u = sub.add_parser("unload")
    u.add_argument("--name", required=True)
    u.add_argument("--project-id", required=True)
    u.add_argument("--database", required=True)
    u.add_argument("--sql-file", required=True)
    u.add_argument("--dest", required=True)
    # allow --connection after the mode too
    for p in (q, u):
        p.add_argument("--connection", default=argparse.SUPPRESS)
    args = ap.parse_args()
    try:
        return do_query(args) if args.mode == "query" else do_unload(args)
    except Exception as e:
        print(str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
