Plan: PLAN-5.md
Serves: **Under Claude Code, `snowflake-extract` reaches Snowflake through the Python connector**
instead of Cortex Code's `snowflake_sql_execute` tool. That tool does not exist in Claude Code.
This is item 3b. Items 1, 2 and 3a have shipped. After this comes item 4, installing the plugin
in Claude Code.

# Item 3b — Snowflake extracts through the Python connector

PLAN-5 §"Item 3b", plus fact 7.

## Measured facts this spec rests on — taken 2026-10-06 on `main` at `d5bd2cc`

- **The skill runs Snowflake SQL through Cortex Code's tool.** `skills\snowflake-extract\SKILL.md`
  frontmatter has `allowed-tools: Bash, snowflake_sql_execute`. Steps 2–7 and 9 of
  "Materialize", and the stale-probe in "Read", tell the model to run SQL through that tool.
  Claude Code has no such tool.
- **The Python connector works on this machine.** These were measured read-only today:
  - `py -3.12`, `snowflake.connector` 4.8.0, and `connect(connection_name='DATAHUB')` connects
    in 0.61 s.
  - `~\.snowflake\connections.toml` `[DATAHUB]` uses `authenticator = "externalbrowser"`, so a
    cached token is used. When the token has expired, a browser sign-in opens mid-run.
  - `SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE()` returns
    `CLYCO_PWRUSR_COST_MGMT_GROUP`, `WH_POWER_USERS_XS`, and `None`. The skill's step 3 already
    says the database comes from the source object, not from `CURRENT_DATABASE()`.
  - `SHOW TABLES LIKE 'DT_PROJECTS' IN SCHEMA DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS` works.
  - `DB_CONTROL_TOWER.INFORMATION_SCHEMA.COLUMNS` for `DT_PROJECTS` reports 107 columns,
    **2 of them `TIMESTAMP_LTZ`**, which is exactly the case step 4's projection exists for.
  - **Bare `INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION()` fails `invalid identifier`.** The
    database-qualified form works, and it sees **only the calling session's** queries
    (plan-review measurement).
- **A real `dt_projects` extract already exists**, made through Cortex Code on 2026-09-24, at
  `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts\dt_projects\`.
  - **Size:** 8 Parquet files, 107 columns, 2 of them `TIMESTAMP`. The sidecar reads
    `row_count` 42,167 and `runtime_seconds` 0.451.
  - **Its `query`** is the explicit projected column list from step 4.
  - **Why it matters:** it is the reference for "types survive exactly" through the old
    transport.
- **Where Snowflake writes happen:** the transport writes **only to Phil's user stage `@~`**.
  It runs `COPY INTO @~/…`, then `GET`, then `REMOVE @~/…`. No table is created or changed.
  Phil approved real extracts for this item's checks on 2026-10-06.

## Decisions

1. **One runner: `tools\sf.py`,** run as `py -3.12 "${CLAUDE_PLUGIN_ROOT}/tools/sf.py" <mode> …`.
   - **How it connects:** `snowflake.connector.connect(connection_name=<name>)`, where the name
     comes from `--connection`, default `DATAHUB`.
   - **SQL comes from files, never from the command line.** This avoids shell quoting of
     `$`, quotes and newlines, the same reason the fork's `read-memories` used `.sql` files.
   - **Standard library plus `snowflake-connector-python` only.**
   - **Reading the SQL file:** it is read with `encoding='utf-8-sig'`, so a BOM written by
     PowerShell does not break the read-only guard.
   - **Output encoding:** before writing anything, sf.py calls
     `sys.stdout.reconfigure(encoding='utf-8', newline='\n')`. Output is UTF-8 with LF line
     endings. Measured: without this, redirected output is cp1252 and CSV rows end
     `\r\r\n`.
   - **Sign-in messages stay off stdout.** `connect()` runs inside
     `contextlib.redirect_stdout(sys.stderr)`. The connector's browser sign-in `print()`s
     (`webbrowser.py:166-177`) then go to stderr, and stdout carries only the result.
   - **One statement per call.** sf.py uses `cursor.execute()` only, never `execute_string` or
     `num_statements`. The connector's single-statement default then rejects `SELECT 1;
     SELECT 2` (measured: `000008 Actual statement count 2 did not match…`). The read-only
     guard below is a guardrail against mistakes, not a security boundary. The role's
     privileges are the real limit.
2. **Mode `query --sql-file <path>`** runs **one** read-only statement and prints its result as
   CSV, with a header row, to stdout.
   - **The read-only guard:** the statement must start, after leading whitespace and `--`
     comments, with `SELECT`, `WITH`, `SHOW` or `DESC`/`DESCRIBE`, case-insensitive. Anything
     else is refused with
     `ERROR: sf.py query only runs SELECT/WITH/SHOW/DESCRIBE; use the unload mode for COPY/GET/REMOVE`,
     exit 2, and it never connects.
   - **CSV format:** written with `csv.writer(sys.stdout, lineterminator='\n')`.
   - **How values print:**
     - `datetime` values as ISO 8601. TZ-aware values are converted to UTC with a `Z`
       suffix.
     - `None` as an empty field.
   - **On a Snowflake error:** the error message goes to stderr, exit 1.
3. **Mode `unload` does steps 5, 6, 7 and 9 in one connector session.** Its arguments:
   `--name <extract name> --project-id <id> --database <db> --sql-file <query.sql>
   --dest <root>\<name>.new`.
   1. **Generate the stage path.** It makes an 8-hex suffix itself, giving
      `@~/duckdb-skills/<project-id>/<name>__<8hex>/`.
   2. **Unload.**
      - **Query text:** it strips trailing whitespace and one trailing `;` from the file.
      - **The statement:** it runs `COPY INTO <stage> FROM (\n<query>\n) FILE_FORMAT = (TYPE =
        PARQUET) HEADER = TRUE OVERWRITE = TRUE`. The newlines stop a trailing `--` comment
        from swallowing the `)`.
      - **What it keeps:** it reads `rows_unloaded` and `output_bytes` from the result row by
        column name, case-insensitively. It keeps the COPY's query id (`cursor.sfqid`).
      - **The sidecar's `query`** stays the file text as written.
   3. **Download.** It runs `GET <stage> 'file://<dest with forward slashes>/'`. It creates
      `--dest` first if it is missing.
   4. **Time the unload.** It reads `TOTAL_ELAPSED_TIME` for **that query id** from
     `TABLE(<db>.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())` with
     `EXECUTION_STATUS = 'SUCCESS'`, converted from ms to seconds.
     - **History can lag.** It retries up to 5 times, 1 s apart.
     - **If still absent:** it omits the value and writes a warning to stderr.
   5. **Clean up.** It runs `REMOVE <stage>` in a `finally`, so the stage is cleaned even when
      `GET` or the lookup fails. It writes `removed=<n>` to stderr, where n is the number of
      rows `REMOVE` returned.
   6. **Report.** It prints one JSON object to stdout:
      `{"stage_path":…, "row_count":…, "output_bytes":…, "runtime_seconds":… (optional),
      "files":[…local file names…]}`.
   - **On a COPY failure** (for example the TZ/LTZ unload error), it prints Snowflake's error
     verbatim to stderr and exits 1. It never retries and never widens a cast. The skill text
     already says what happens then.
4. **Steps 2–4 stay model-driven**, and each step's SQL runs through `sf.py query`. The model
   writes the SQL to a temporary `.sql` file first. The projection rule and its
   column-quoting rules in step 4 are unchanged.
5. **The skill text changes, and the rules stay the same.** In `skills\snowflake-extract\SKILL.md`:
   - **`allowed-tools: Bash`:** `snowflake_sql_execute` is removed.
   - **Where `--project-id` comes from:** the `project-id:` line that `list-extracts` prints.
   - **A new section, "Running Snowflake SQL",** next to "Running the tools". It gives:
     - both `sf.py` forms;
     - the note that SQL is written to a file first, as UTF-8;
     - the `query` mode's read-only rule;
     - the note that an expired token opens a browser sign-in. If one appears, Phil signs in,
       and the call then continues.
   - **Steps 5–7 and 9** become one step: "run `sf.py unload …`". Its JSON fills `row_count`,
     `output_bytes` and `runtime_seconds`. `runtime_seconds` is omitted only if `unload` omitted
     it.
   - **Step 8 (`publish-extract`)** is unchanged.
   - **The "Read" section's stale probe** runs its `SHOW TABLES` / `LAST_ALTERED` queries
     through `sf.py query`.
   - **No other rule changes:** the freshness window, the failed-re-pull rule, the stage
     collision note and the TZ projection rules keep their substance.
6. **`README.md` is not changed.** It has no mention of `snowflake_sql_execute`.

## Deliverables

- `tools\sf.py` (new).
- `skills\snowflake-extract\SKILL.md`.
- `RESULT-1.md` at repo root.

## Out of scope — do not do these

- **The registry scripts and sidecar format:** `publish-extract.ps1`, `extract-decide.ps1`,
  `list-extracts.ps1`, `extract-status.ps1`, `registry.sql` and `SIDECAR.md` do not change.
- **Snowflake objects:** no change of any kind. The only Snowflake writes allowed are `@~` stage
  files under `duckdb-skills/`, and every run removes them.
- **The real extracts:** nothing writes under
  `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\`. That includes the existing
  `dt_projects` and `parent_projects`, which are only read.
- **`.claude-plugin\`, `.cortex-plugin\`, and the README fork note:** these are item 4's.
- **Other connections:** do not add a connection other than `DATAHUB` and do not change
  `connections.toml`.

## Conventions

- **Worktrees:**
  - **`$W`:** the verifier's throwaway worktree at the implementer's commit.
  - **`$X`:** a scratch extract root under `%TEMP%`, outside any repo. Every check passes it
    as `-ExtractRoot`, so nothing touches the real registry.
- **How things run:**
  - **PowerShell tools:** via `Start-Process` with separate stdout/stderr files, as before.
  - **`sf.py`:** via `Start-Process 'py' -ArgumentList '-3.12', <sf.py>, …`, with the same
    capture.
  - **Never** use `2>`/`2>&1` on these calls.
- **SQL files:** write `.sql` files with `[IO.File]::WriteAllText($p, $sql)`, which gives
  UTF-8 and no BOM. Never use `Out-File`, `>` or `Set-Content -Encoding UTF8`.
- **Sign-in:** run every sf.py call with a 180 s timeout.
  - **If stderr contains `Initiating login request`,** the cached token has expired and a
    sign-in needs Phil. Mark that check `NOT RUN (needs sign-in)` and stop the Snowflake
    checks.
  - **To keep this from happening,** the main session runs a read-only connector sign-in
    check just before starting the implementer, and again just before the verifier. Any
    sign-in then happens while Phil is present.
- **Stage hygiene** is checked from `unload`'s own report. After its `REMOVE`, `unload` writes
  `removed=<n>` to stderr, where n is the number of rows `REMOVE` returned. n must equal
  `len(files)`.
  - **Why this way:** `LIST @~` is not in `query` mode's read-only allow-list, and no other
    flag or mode is added to check it.

## Acceptance checks

**AC1 — The read-only guard refuses writes, without connecting.**
- **Run:** `sf.py query --sql-file <f>`, where `<f>` contains
  `COPY INTO @~/x FROM (SELECT 1)`.
- **Expect:** exit 2 with the pinned refusal message, and no connection attempt. To prove it,
  run with `--connection NO_SUCH_CONNECTION`. A connection attempt would fail with a
  connection-name error, so getting the refusal instead shows `connect` was never called.
- **Same for** a file whose two lines are `-- comment` and then `DELETE FROM t`: exit 2.

**AC2 — `query` mode returns metadata the skill needs.**
- **`SHOW TABLES LIKE 'DT_PROJECTS' IN SCHEMA DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS`:**
  stdout has exactly 2 lines. Line 1 contains `rows` and `bytes`, lowercase. Line 2's `rows`
  is a positive integer.
- **`SELECT CONVERT_TIMEZONE('UTC', LAST_ALTERED) AS LA FROM DB_CONTROL_TOWER.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='SCH_PROJECT_OPERATIONS' AND TABLE_NAME='DT_PROJECTS'`:**
  header `LA`, then one value matching `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$`.
- **`SELECT COLUMN_NAME, DATA_TYPE FROM DB_CONTROL_TOWER.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='SCH_PROJECT_OPERATIONS' AND TABLE_NAME='DT_PROJECTS' ORDER BY ORDINAL_POSITION`:**
  108 lines (header plus 107), 2 of them `TIMESTAMP_LTZ` (`START_DATE`, `FINISH_DATE`).

**AC3 — End-to-end extract of `DT_PROJECTS` through the connector, following the skill text.**
Follow the new `SKILL.md` "Materialize" steps literally, with name `ac3_dt_projects` and
`-ExtractRoot $X`.
- **`--project-id`:** pass `verify-3b`, because `list-extracts -ExtractRoot` prints no
  project id. The stage path is only a namespace.
- **Step 4 builds the projected query** from AC2's column list. The 2 LTZ columns become
  `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"`.
- **`unload`'s JSON:**
  - `row_count` > 0 (it is COPY's `rows_unloaded`), and `output_bytes` > 0;
  - `runtime_seconds` **present and > 0**;
  - `files` non-empty.
- **Stage cleaned:** stderr has `removed=<n>`, where n equals `len(files)`.
- **`publish-extract`:** prints `published <$X>\ac3_dt_projects`.
- **The sidecar** has:
  - `role` `CLYCO_PWRUSR_COST_MGMT_GROUP`, `warehouse` `WH_POWER_USERS_XS`, `database`
    `DB_CONTROL_TOWER` and `connection` `DATAHUB`;
  - `runtime_seconds` > 0;
  - `source_rows[0]` a positive integer;
  - `source_last_altered[0]` matching `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$`.

  Do not pin the row number. `DT_PROJECTS` is a dynamic table: it had 42,257 rows on
  2026-10-06 against 42,167 on 2026-09-24.
- **Read-back:** DuckDB's `count(*)` over `$X\ac3_dt_projects\*.parquet` equals the sidecar's
  `row_count`.
- **`list-extracts -ExtractRoot $X`:** lists `ac3_dt_projects` with `bytes_check=AGREES`.

**AC4 — Types survive exactly as they did through Cortex Code.** Compare
`DESCRIBE SELECT * FROM read_parquet('$X/ac3_dt_projects/*.parquet')` with the same query over
the real
`~/.duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/extracts/dt_projects/*.parquet`
(read-only).
- **Expect:** identical `(column_name, column_type)` lists, in the same order. That is 107
  columns, with the 2 LTZ columns as `TIMESTAMP` in both.
- **If Snowflake's schema changed since 2026-09-24,** quote the difference and mark AC4
  NOT RUN. Do not adjust anything to make them match.

**AC5 — A COPY failure is loud and still cleans up.**
- **Run:** `unload` with a query that selects one `TIMESTAMP_LTZ` column **unprojected**
  (`SELECT "<one LTZ col>" FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS LIMIT 1`).
- **Expect:**
  - exit 1;
  - stderr contains `TIMESTAMP_TZ and LTZ types are not supported for unloading to Parquet`;
  - no JSON on stdout;
  - stderr contains `removed=`;
  - `--dest` is absent or holds no `*.parquet`.

## Mutation proof — must fail, then pass again after revert

- **M1:** in `$W`, make `unload` open a **second** connection for the history lookup. A second
  connection is a different session, which `QUERY_HISTORY_BY_SESSION()` does not see.
  - **Run** `sf.py unload` alone with AC3's `.sql` file and `--dest $X\m1.new`.
  - **Expect:** exit 0, JSON **without** `runtime_seconds`, and the history warning on stderr.
  - **After revert:** re-run it. `runtime_seconds` is back and > 0.

Mutate only in `$W`. Revert by re-checking-out the committed file there.

## Final check — Phil

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills; [IO.File]::WriteAllText("$env:TEMP\sf-check.sql", 'SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()'); py -3.12 .\tools\sf.py query --sql-file "$env:TEMP\sf-check.sql"
```

**Expect** exactly two lines:
- `CURRENT_ROLE(),CURRENT_WAREHOUSE()`
- `CLYCO_PWRUSR_COST_MGMT_GROUP,WH_POWER_USERS_XS`

If a browser sign-in opens, sign in; the command then finishes. The full extract path gets
exercised for real once the plugin is installed (item 4).
