# SHIPPED — item 3a of PLAN-5: undo the Cortex Code adaptations

**What shipped:** the fork is now Claude-Code-first (Phil, 2026-10-06). The work done to make
the original skills cope with Cortex Code is removed.
- **`duckdb-compat.sql`:** the 16 Snowflake-name macros and the polyglot guidance in the `query`
  skill are gone. The file holds only `xl_date()`.
- **Dialect test material:** `duckdb-compat-tests.csv` and `tools\run-compat-tests.ps1` are
  deleted.
- **`read-memories`:** it is the original project's Claude Code version again, with three
  Windows fixes.
  - **`--here`:** it finds the right log folder.
  - **The project column:** it is no longer blank.
  - **Paths:** they reach `duckdb.exe` in Windows form.
- **The `read-memories` description** sends the model to shared memory first.

## Before and after you can observe

- **Macros:**
  - **Before:** `SELECT IFF(true,1,2)` returned `1` once the compat file was loaded.
  - **After:** it fails with `Catalog Error`. The only function the file defines is `xl_date`.
- **Log search:**
  - **Before:** `read-memories` searched `~\.snowflake\cortex\conversations\` (Cortex Code).
  - **After:** it searches `~\.claude\projects\` (Claude Code). `--here` from this repo returns
    only rows with `project = C--Users-woodsonp-Claude-Dev-duckdb-skills`.
- **The lake:** your next `materialize` rebuilds both contracts once, because the compat
  file's fingerprint changed. In the scratch run, the rebuilt tables were row-for-row
  identical to before: 484 sales rows and 57,777 GL rows. GL may name
  `previous_checks_failed` as its reason instead, because its last real run failed.

## Deliberately did not change

- **`xl_date()`:** its body, the compat file's name, and how it reaches a session are all
  unchanged.
- **Removed features:** `read-memories` lost the Cortex-only `--full <id>` mode and the
  recovery of past Snowflake result sets. Neither came back. Cortex decisions reach Claude
  Code through shared memory, not log search.
- **`checks\gl-facts.sql`:** it still fails on today's workbook (cell I3, `City of DeKalb`). It
  is old dev scaffolding that deliberately type-infers its oracle read, and is left alone
  until it matters.
- **`docs\duckdb-snowflake-findings.md`:** kept as a historical record.
- **README lines 5–10, the fork note:** they still say Cortex Code. Item 4 rewrites them.
- **`.claude-plugin\`, `.cortex-plugin\`:** untouched, for item 4.
- **Snowflake access (`snowflake_sql_execute`):** untouched, for item 3b.
