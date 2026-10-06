# SHIPPED — item 3b of PLAN-5: Snowflake extracts through the Python connector

**What shipped:** `tools\sf.py`, a small runner over the Snowflake Python connector (`py -3.12`,
connection `DATAHUB`).
- **`query` mode:** runs one read-only statement and prints CSV.
- **`unload` mode:** does `COPY INTO @~` → `GET` → run-time lookup → `REMOVE` in one
  session.

The `snowflake-extract` skill now uses `sf.py` instead of Cortex Code's `snowflake_sql_execute`
tool, which does not exist in Claude Code.

## Before and after you can observe

- **Before:** in Claude Code, the extract skill named a tool that wasn't there, so a fresh
  Snowflake extract could not be made.
- **After:** a fresh `DT_PROJECTS` extract made through `sf.py` (42,259 rows, run time 0.322 s,
  `bytes_check=AGREES`) has **the same 107 column names and types, in the same order**, as the
  `dt_projects` extract Cortex Code made on 2026-09-24. That includes the two time-zone columns
  as `TIMESTAMP`. Every temporary file left on the Snowflake stage is removed (`removed=8`).
- **Try it:**

  ```powershell
  [IO.File]::WriteAllText("$env:TEMP\sf-check.sql", 'SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()'); py -3.12 .\tools\sf.py query --sql-file "$env:TEMP\sf-check.sql"
  ```

  It prints a two-line CSV ending `CLYCO_PWRUSR_COST_MGMT_GROUP,WH_POWER_USERS_XS`.

## Deliberately did not change

- **The extract rules:** the time-zone projection rule, the freshness window, the
  two-stage stale probe, the failed-re-pull rule, the stage-path naming, and the sidecar
  format.
- **The registry tools:** `publish-extract`, `extract-decide`, `list-extracts` and
  `extract-status` are untouched.
- **Snowflake itself:** no tables or objects were changed. The only writes are temporary
  `@~/duckdb-skills/` stage files, removed by every run.
- **The existing real extracts** (`dt_projects`, `parent_projects`) were not refreshed.
- **The guard in `query` mode** stops accidental writes but is not a security boundary. Your
  Snowflake role is the real limit.
- **Known and left alone:**
  - `publish-extract.ps1` does not check the element types inside the sidecar arrays.
  - The skill's step numbers jump from 5 to 8.
