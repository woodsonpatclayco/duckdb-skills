Plan: PLAN-4.md
Serves: **Ask one question across a Snowflake extract and a workbook sheet — job costs from
`Data Extracts.xlsm` by parent project from Snowflake — in one SQL statement, with the age of every input
printed beside the answer, and optionally save the joined result so it can be re-queried later without
re-reading either source or touching Snowflake.** This is the feature PLAN-4 exists for; it is the last
item.

# Item 8 — The cross-source join

PLAN-4 §8 (lines 631-650), plus the `Serves:` line (PLAN-4:51-53) and the Risks bullet on extract versions
(PLAN-4:672-677).

Three parts. **A** is a new runner, `tools\cross-query.ps1`. **B** is a shipped worked example.
**C** is documentation.

## Measured facts this spec rests on — all taken 2026-09-29 on this machine

**The two landed extracts** (`~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts\`),
from `tools\list-extracts.ps1`:

```
name=parent_projects age_minutes=8408 row_count=15314 size_bytes=518925 bytes_check=AGREES
name=dt_projects     age_minutes=8416 row_count=42167 size_bytes=5223915 bytes_check=AGREES
```

Both are **~5.8 days old** (materialized 2026-09-24 18:46/18:54 UTC). Snowflake now has
**15,322** rows in `DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS` against the extract's
15,314 — measured live. **This is exactly the silent staleness PLAN-4 §8 says a join must not hide.**

**The join key.** `Clayco_Job_Costs_from_GL.PARENT_PROJECT_NUMBER` (VARCHAR, 345 distinct, never NULL,
length 8-10, no padding) against `parent_projects.PARENT_PROJECT_NUMBER` (VARCHAR, **unique across all
15,314 rows**, no padding; also unique in Snowflake, 15,322 of 15,322, `VARCHAR(256)`). Because the
extract side is unique, the join cannot fan out.

| join | GL rows | joined rows | unmatched | `SUM(JOB_COSTS)` both sides |
|---|---|---|---|---|
| real lake (materialized 2026-09-25) ⋈ extract | 62,230 | 62,230 | **0** | `22478661033.93` |
| live workbook via contract ⋈ extract | 62,603 | 62,603 | **0** | `22505496119.72` |

**The join takes 0.14-0.15 s** (three fresh processes, `LOAD ducklake` + `ATTACH … READ_ONLY` + the
join), against PLAN-4's 2 s budget.

**The real lake is itself stale.** It holds 62,230 GL rows from 2026-09-25; the workbook now has 62,603
(it was 62,377 earlier today — a SharePoint refresh landed mid-session). So a join has **two** kinds of
input age to report, not one: the extract's, and whether the lake table's workbook has changed since it
was materialized.

**Name resolution can be plain SQL.** Measured in one `duckdb` process:

```sql
SET VARIABLE dsk_extract_globs = MAP {'parent_projects': '<root>/parent_projects/*.parquet'};
CREATE MACRO extract_table(n) AS TABLE
  SELECT * FROM read_parquet(coalesce(getvariable('dsk_extract_globs')[n],
                                      error('unknown extract: ' || n || ' (not in the registry)')));
SELECT count(*) FROM extract_table('parent_projects');        -- 15314, exit 0
SELECT count(*) FROM extract_table('no_such_extract');        -- Invalid Input Error: unknown extract: no_such_extract (not in the registry), exit 1
```

Without the `coalesce(…, error(…))`, an unknown name fails with the cryptic
`read_parquet cannot take NULL list as parameter`. No built-in named `extract_table` exists; the
built-in `extract()` still works.

**Saving a join must create a TABLE, not a VIEW.** Measured in a scratch DuckLake:
`CREATE TABLE lake.j AS SELECT * FROM extract_table('parent_projects')` → 15,314, and a **new process**
reads it back (15,314) with no macro defined. `CREATE VIEW` does the same in-session, but a new process
fails: `Catalog Error: Table Function with name extract_table does not exist!`. A table keeps its data —
which also means it silently keeps whichever extract version it was built from.

**Nothing records an extract's version today.** PLAN-4:674-675 says "item 6's manifest records
[`materialized_at`] alongside the contract hash". **It does not**: `lake.manifest` has twelve columns
(`run_id materialized_at contract_name source_path source_mtime source_sha256 contract_sha256
compat_sha256 row_count lake_snapshot_id checks_passed forced`, `materialize.ps1:316`), all about the
workbook side. This item is where that claim becomes true, for saved joins.

**DuckDB's own parser can list a query's inputs.** `json_serialize_sql('<sql>')` returns the parse tree;
walking it with `json_tree` finds every `BASE_TABLE` and `TABLE_FUNCTION` node. On a query with decoys
planted in a comment (`-- … lake.decoy and extract_table('decoy_in_comment')`) and a string literal
(`'lake.not_a_table'`), it returned exactly `All_Sales_Data`, `Clayco_Job_Costs_from_GL`, the CTE name
`x`, and `extract_table('parent_projects')` — **no decoy**. Further, measured:

| input | parser output |
|---|---|
| `lake.Clayco_Job_Costs_from_GL` | `BASE_TABLE`, `schema_name = lake`, `catalog_name` empty |
| `lake.main.All_Sales_Data` | `BASE_TABLE`, `catalog_name = lake`, `schema_name = main` |
| `DROP TABLE lake.manifest` | `{"error":true,…"Only SELECT statements can be serialized to json!"}` |
| `CREATE TABLE x AS SELECT 1` | same refusal |
| `SELECT 1; SELECT 2` | `statements` array length **2** |
| `SELEC 1` | `{"error":true,"error_type":"parser",…"syntax error at or near \"SELEC\""}` |
| `extract_table('par' \|\| 'ent')` | first child's `class` = `FUNCTION`, not `CONSTANT` — a non-literal name is detectable |

A regex would match the decoys.

**But a quoted file path and a CTE name are the same node shape, and several shapes read files**
(reviewer, measured against the real extract read-only):

| query | node | reads a file? |
|---|---|---|
| `FROM 'C:/x/*.parquet'` | `BASE_TABLE`, catalog `""`, schema `""`, table `C:/x/*.parquet` | yes — 15314 |
| `FROM "C:/x/y.parquet"` | same shape | yes — 15314 |
| `WITH Clayco_Job_Costs_from_GL AS (…) SELECT * FROM Clayco_Job_Costs_from_GL` | `BASE_TABLE`, catalog/schema empty — **same shape as a quoted path** | no (a CTE) |
| `SELECT (SELECT count(*) FROM 'C:/x/a.parquet') …` | `BASE_TABLE` inside a scalar subquery | yes — 15314 |
| `FROM parent_projects.parquet` | `BASE_TABLE`, schema `parent_projects`, table `parquet` — **qualified** | yes — a replacement scan: `No files found that match the pattern "parent_projects.parquet"` |
| `FROM lake.x.parquet` (with `lake` attached) | schema `lake` / catalog `lake` shapes | yes — `No files found that match the pattern "lake.x.parquet"` |
| a CTE *named* with a file path, referenced outside its scope | `BASE_TABLE` matching a CTE name | yes — `n = 28` |
| `lake."Quoted Name"` | schema `lake`, table `Quoted Name` | no |
| `lake.snapshots()` | `TABLE_FUNCTION` `snapshots`, `function.schema = lake` | n/a |

`.xlsm` gets no replacement scan (`Catalog Error`); `.xlsx`, `.csv` and `.json` do. So classification must
be an **allow-list**, not "ignore what looks like a CTE" (step 1 below).

**Four more facts the runner depends on** (reviewer, measured):

- **Quoted identifiers are case-insensitive in DuckDB.** `CREATE TABLE "Clayco_Job_Costs_from_GL" …;
  CREATE OR REPLACE TABLE "clayco_job_costs_from_gl" …` leaves **one** table holding the replacement's
  data. Quoting protects nothing; every name comparison must be `lower()` on both sides.
- **`lake.manifest.source_mtime` is local time**, `LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')`
  (`materialize.ps1:305`) — truncated to the second, **not** UTC. Real lake: `source_mtime 2026-09-25
  08:48:13` beside `materialized_at 2026-09-25 21:23:23.99` (UTC). Here, local vs UTC for the same file is
  `16:26:30` vs `21:26:30`.
- **The real lake holds a REFUSED GL manifest row** (`7e9d53bb…, 2026-09-25 21:26:05, row_count NULL,
  lake_snapshot_id 14, checks_passed false, forced false`) carrying the same snapshot id as the landed row
  before it. Default-mode `lake-status.ps1` takes the latest row of **any** outcome (`:211`); only `-AsOf`
  filters `(checks_passed OR forced)` (`:159`).
- **`registry.sql` exits 0 on a name mismatch**: `DSK_EXTRACT_NAME='other'` → `reason = name mismatch`,
  exit 0; `parallel array mismatch` the same. Its `parquet_glob` has mixed separators
  (`C:\…\extracts\parent_projects/*.parquet`), which `read_parquet` accepts (15314).
- **A trailing `--` comment swallows an appended `;`**: `CREATE TEMP TABLE _q AS SELECT 7 AS k --
  trailing comment;` merges the next statement: `Parser Error: syntax error at or near "SELECT"`. It
  passes the parse step (inside a string literal the comment ends cleanly), so it fails only at run time.
  A line starting with `.` inside a statement is **not** run as a dot-command.
- **Timestamp offsets are dropped on cast**: `'2026-09-30T09:10:00-05:00'::TIMESTAMP` → `09:10:00`.
- **DuckLake `DATA_PATH` subdirectories are created on attach** — even for an in-memory catalog. Any
  `-LakeRoot` a check passes must therefore be scratch.
- **`Resolve-ExtractRoot` / `Resolve-LakeRoot` create the default directory** when no root is passed
  (`dsk-paths.ps1:65-67`, `:84-86`); `Resolve-LakeRoot` also creates an explicit root (`:77-79`). Earlier
  verifier worktrees left `c-users-woodsonp-claude-dev-_verify-2a`, `_verify-2b`, `_verify-2b-r2` behind
  this way.

**Timing of the runner's pieces** (reviewer): `powershell -NoProfile` startup 272–278 ms; parse process
~60 ms; `registry.sql` 79 ms; manifest lookup with `LOAD ducklake` 164–213 ms; join process 159–194 ms.
Estimated whole-command wall time **~0.8–1.2 s** — PLAN-4's "process exiting under 2s" is achievable as
written, so AC1 gates the whole command.

**Real-lake safety.** Three `READ_ONLY` attaches of the real lake during these measurements left it
byte- and timestamp-identical (8,663,040 bytes, `2026-09-25T16:26:30`).

## Decisions

**D1 — A runner, not a macro file the session loads.** The age of every input must print beside every
answer, and nothing forces a session to print it if the join is hand-written. So joins run through
`tools\cross-query.ps1`, which computes ages from the registry and the lake manifest **before** it runs
the query, and cannot be told not to print them. Hand-writing a join remains possible — the skill text
says to use the runner, and that this is guidance, not enforcement.

**D2 — Extracts are referenced as `extract_table('<name>')`, resolved from the registry at run time.**
The query never contains a path. Refreshing an extract into a new directory changes what the name
resolves to on the next run, with no edit to the query (PLAN-4:641-643).

**D3 — Every input must be dateable, so the runner refuses inputs it cannot date.** A query may read
only `lake.<table>` and `extract_table('<literal name>')`. It refuses a quoted file path, `read_parquet`,
`read_csv`, `read_xlsx`, `read_json` or any other file-reading table function — each is an input with no
age the runner can report, and a raw `read_xlsx` also bypasses the contracts item 7 routes sessions
through. The refusal names what to use instead.

**D4 — Freshness is reported, never enforced.** PLAN-4:489: "Freshness is a judgment, not a gate." A
stale extract or a lake table whose workbook has changed is printed loudly and recorded, never refused.
**The runner cannot refresh an extract**: refreshing needs `snowflake_sql_execute`, an agent tool no
script can call (PLAN-4:392-394). The skill text tells a session to refresh through the
`snowflake-extract` skill first when the work is staleness-sensitive.

**D5 — A saved join is a TABLE, with its inputs' versions recorded in a new `lake.join_manifest`.** Not a
view (measured above). `lake.manifest` is **not** altered — it is item 6's freshness key, and
`materialize.ps1` rebuilds decisions from it. The new table records, per save: the query text and its
SHA-256, and for every input its name and version token — the extract's `materialized_at` and
`row_count`, or the lake table's `lake.manifest` `run_id` and `materialized_at`.

**D6 — Tests read the real extracts through an explicit root, and never write the real lake.** Fixture
extracts from `make-extract-fixtures.ps1` hold filler bytes, not Parquet, so they cannot be joined. The
real extract root is read-only for every check, always passed as `-ExtractRoot`, because the verifier's
worktree resolves a different, empty default (item 7 D5). Every lake a check writes is a scratch lake
under `$env:TEMP`.

## A — `tools\cross-query.ps1` (new)

`powershell -NoProfile -File tools\cross-query.ps1 -Sql <path to .sql> [-Save <table>] [-Limit <n>]
[-ExtractRoot <dir>] [-LakeRoot <dir>]`

Defaults: `-Limit 20`; roots from `Resolve-ExtractRoot` / `Resolve-LakeRoot` (`tools\dsk-paths.ps1`).
The window is `DSK_WINDOW_MINUTES` (default 60), read by `registry.sql` as today.

### 1. Parse and refuse

Read the file. Strip one trailing `;` and surrounding whitespace. Run `json_serialize_sql` on it in a
`duckdb` process (quotes doubled for the string literal). **Wherever the query text is embedded later,
put a newline after it before any `;` or following text** — a trailing `--` comment otherwise swallows
the `;`. **Refuse**, exit non-zero, and run nothing if:

- the parser returns `"error":true` — print its `error_message` verbatim (covers non-SELECT statements
  and syntax errors);
- `statements` has length ≠ 1;
- any `extract_table(...)` call's argument is not a single string constant;
- any `TABLE_FUNCTION` other than an **unqualified** `extract_table` appears — including
  `lake.snapshots()`, `range()`, `query()`, `query_table()`, `read_parquet`, `read_csv`, `read_xlsx`,
  `read_json` (D3);
- any CTE name contains `.`, `/`, `\` or `:`;
- any `BASE_TABLE` fails the allow-list below;
- the query references no `extract_table` and no lake table at all.

**The allow-list — classification is by exact shape, never by "looks like a path".** Collect every CTE
name: the `key` of each `cte_map.map[]` entry, at any depth. Then every `BASE_TABLE` node is exactly one
of:

- `catalog_name = lake` and `schema_name = main`, **or** `catalog_name` empty and `schema_name = lake` →
  a **lake input** named `table_name`. Step 2 confirms it exists (`duckdb_tables()` with
  `database_name = 'lake'`, compared with `lower()`), else refuses
  `ERROR,lake,<table>,no such table in the lake at <root>` — this is what catches `lake.x.parquet`;
- `catalog_name` and `schema_name` both empty, and `lower(table_name)` equal to a collected CTE name → a
  CTE, ignored;
- **anything else is refused**:
  `ERROR,input,<name>,not a lake table or an extract — use lake.<table> or extract_table('<name>')`. This
  catches single- and double-quoted paths, `parent_projects.parquet`, and paths in subqueries.

### 2. Date every input — before running anything

**Resolve the extract root only if the query has an `extract_table` input, and the lake root only if it
has a lake input** — resolving a default root creates a directory (`dsk-paths.ps1:65-67`, `:84-86`).

For each extract name: locate `<ExtractRoot>\<name>\_extract.json` and run
`skills\snowflake-extract\registry.sql` for it with `DSK_EXTRACT_DIR` / `DSK_EXTRACT_NAME` set as
`list-extracts.ps1:43-45` does. Refuse if the directory or `_extract.json` is missing
(`ERROR,extract,<name>,not in the registry at <root>`), if `registry.sql` exits non-zero (its error), or
if its `reason` column is non-empty (`ERROR,extract,<name>,<reason>` — `registry.sql` exits **0** on a
name mismatch). A NULL or negative `age_minutes` is `UNKNOWN` and counts as stale (SIDECAR.md:51-52).
Use `parquet_glob` as returned (mixed separators are accepted); double any single quote when embedding
it as a literal. Print:

`EXTRACT,<name>,age_minutes=<n>,window=<n>,stale=<true|false>,rows=<row_count>,materialized_at=<utc>`

For each lake table: if `-LakeRoot`'s catalog does not exist, refuse (`ERROR,lake,no lake at <root> —
run tools\materialize.ps1 first`); never create one. Then:

- a **contract table** (has a `lake.manifest` row): take
  `… FROM lake.manifest WHERE lower(contract_name) = lower('<table>') AND (checks_passed OR forced)
  ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1` — the row
  `lake-status.ps1 -AsOf <now> -Contract <table>` reports as effective, **not** its default mode, which
  can show a REFUSED row. Compare the workbook's current `LastWriteTime` (**local** time, not
  `LastWriteTimeUtc`) formatted `yyyy-MM-dd HH:mm:ss` exactly as `materialize.ps1:305` does, with
  `source_mtime`'s text; unequal → `true`. A moved mtime with identical content still counts `true`:
  `materialize.ps1` would refresh on its next run, which is what the flag means. Only `age_minutes` uses
  UTC (`materialized_at` against `timezone('UTC', now())`). Print
  `LAKE,<table>,age_minutes=<n>,materialized_at=<ts>,workbook_changed_since=<true|false>` —
  or `workbook_present=false` instead of `workbook_changed_since` if the workbook is absent (item 7's
  case; not an error). If a newer REFUSED row exists, append `,refused_since=<n>`;
- a **saved join** (has a `lake.join_manifest` row): print
  `SAVED,<table>,age_minutes=<n>,saved_at=<ts>,inputs=<name>@<version>;…` from its newest row, with each
  extract input's recorded `materialized_at`. **The age is that of the oldest recorded input**, not of the
  save;
- neither: `LAKE,<table>,provenance=NONE`.

Read the workbook's `LastWriteTime` only — never open it.

### 3. Run

In one fresh `duckdb` process: `LOAD ducklake;` `ATTACH` the lake — **`READ_ONLY` unless `-Save`**; set
`dsk_extract_globs` to the registry's `parquet_glob` for each extract found in step 2; define
`extract_table` with the `coalesce(…, error(…))` guard; `CREATE TEMP TABLE _r AS <query>`; print the row
count and elapsed time of that statement; print the first `-Limit` rows as CSV with a header.

Output order, exactly:

```
EXTRACT,…          (one per extract input)
LAKE,… / SAVED,…   (one per lake input)
RESULT,rows=<n>,elapsed=<s>,extract_ages=<name>:<minutes>;…|none,stale_inputs=<n>
<csv header>
<up to -Limit rows>
```

`stale_inputs` counts extracts with `stale=true`, contract tables with `workbook_changed_since=true`,
and saved joins whose oldest input is stale. It is information, not a verdict: exit 0 regardless (D4).

### 4. Save (`-Save <table>`)

- The name must match `^[A-Za-z_][A-Za-z0-9_]*$`, and is quoted as an identifier anyway (the unquoted-
  identifier bug in `materialize.ps1` is the reason).
- **Refuse names `manifest`, `check_history`, `join_manifest`, and any existing lake table that has no
  `lake.join_manifest` row** — a saved join may only replace a saved join, never a contract table. **Every
  comparison is `lower()` on both sides**: quoted identifiers are case-insensitive, so
  `-Save clayco_job_costs_from_gl` would otherwise replace the contract table.
- In the same process as step 3's run, in this order: `CREATE TABLE IF NOT EXISTS lake.join_manifest …`;
  then `CREATE OR REPLACE TABLE lake."<table>" AS SELECT * FROM _r` (not the query a second time); then
  capture `SELECT max(snapshot_id) FROM lake.snapshots()` as `lake_snapshot_id`, exactly as
  `materialize.ps1:497` does; then insert one `lake.join_manifest` row. (Measured: capturing at attach time
  instead records an id at which the table does not yet exist — `Catalog Error: … does not exist at
  version 0`.) The table:

  `lake.join_manifest(run_id UUID, saved_at TIMESTAMP, table_name VARCHAR, query VARCHAR,
  query_sha256 VARCHAR, row_count BIGINT, inputs VARCHAR, lake_snapshot_id BIGINT)`, where `inputs` is
  a JSON array of `{kind, name, version, materialized_at, row_count}`: `kind` is `extract` (version = its
  `materialized_at`), `contract` (version = the `lake.manifest` `run_id`), or `saved` (version = that
  saved join's `run_id`). `materialized_at` is naive UTC for every kind; for a `saved` input it is the
  **oldest** `materialized_at` among that saved join's own recorded inputs. A saved join is stale when its
  oldest input's age exceeds `DSK_WINDOW_MINUTES`. `saved_at` is naive UTC, compared against
  `timezone('UTC', now())`.
- Print `SAVED_AS,<table>,rows=<n>,run_id=<uuid>` after the `RESULT` line.
- The lock: a writer holding the catalog makes an `ATTACH` fail with item 6's
  `IO Error: Failed to attach DuckLake MetaData … File is already open in …`. It may surface at **step
  2's read-only attach** or at the save attach — the reviewer expects the former but could not measure it.
  Either is reported verbatim, exit 1, no retry. Measure which, and state it in `RESULT-1.md`.

### Exit codes

0 = the query ran (stale or not); 1 = a refusal, a DuckDB error, or a lock; 2 = usage error (no `-Sql`,
file missing).

## B — `examples\job-costs-by-parent-project.sql` (new)

The worked example, a single SELECT:

```sql
SELECT g.PARENT_PROJECT_NUMBER, p.PARENT_PROJECT_NAME, p.PARENT_WIP_STATUS,
       count(*) AS gl_rows, sum(g.JOB_COSTS) AS job_costs
FROM lake.Clayco_Job_Costs_from_GL g
JOIN extract_table('parent_projects') p USING (PARENT_PROJECT_NUMBER)
GROUP BY ALL
ORDER BY job_costs DESC
```

Plus `examples\job-costs-unmatched.sql` — the same inputs with `ANTI JOIN`, returning GL rows whose
project is missing from the extract. This is the check a stale extract fails first: a project created in
Snowflake after the extract was taken appears here. Both files carry a short header comment saying what
they answer. **Measure both against the real extract and a scratch lake, and paste the figures into
`RESULT-1.md`.**

## C — Documentation

- **`README.md`**: a new section after "Session state", **"Joining a Snowflake extract to a workbook
  sheet"**. Self-contained steps a person can follow from a clean shell in this repo:
  1. `tools\materialize.ps1` — bring the lake current (and why: a stale lake table is reported, not
     fixed);
  2. `tools\list-extracts.ps1` — see which extracts exist and how old they are; refreshing one is done
     through the `snowflake-extract` skill in a session, not by a script;
  3. `tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql` — read the `EXTRACT`, `LAKE`
     and `RESULT` lines;
  4. the unmatched check;
  5. `-Save`, and re-querying the saved table with `cross-query.ps1` so its `SAVED` provenance line prints.

  Then the **freshness rule** in plain words: every input's age prints beside the answer; nothing is
  refused for being old; the reader's window (`DSK_WINDOW_MINUTES`, 60 by default) decides `stale`; a
  saved join keeps the data it was built from and reports its oldest input's age every time it is read.
  And the **patterns**: `extract_table('<name>')` for extracts, `lake.<table>` for workbook sheets, no
  paths; why a saved join is a table, not a view.
- **`skills\snowflake-extract\SKILL.md`** and **`skills\lakehouse\SKILL.md`**: one short paragraph each in
  the body pointing to `tools\cross-query.ps1` and the README section. **Both descriptions stay
  byte-identical** — the two-skill budget is spent and both are at the 4-line cap. No new skill.

## Out of scope — do not do these

- No change to `lake.manifest`'s schema, `materialize.ps1`, `lake-status.ps1`, `run-assertions.ps1`,
  `check-contract.ps1`, `registry.sql`, `SIDECAR.md`, either contract, or the extract tools.
- **Do not refresh either extract**, and do not call `snowflake_sql_execute` — the checks depend on the
  extracts being old, and nothing here needs Snowflake. (Their staleness is the feature being shown.)
- **Never write the real lake.** Every `-Save` in a check targets a scratch `-LakeRoot`.
- **The live workbook is read-only**: `LastWriteTime` reads only; materialize into scratch lakes from it
  via the shipped contracts, as item 7 did.
- Do not load the `snowflake` DuckDB extension, or write `ATTACH … (TYPE snowflake)`.
- No retention or cleanup of saved joins (PLAN-4:281). Do not edit `PLAN-4.md` (frozen) or `docs\tasks\`.

## Conventions

Windows / PowerShell 5.1; `;` never `&&`; absolute paths. SQL in `.sql` files run with `duckdb -f`.
**Gate on `$LASTEXITCODE`, never stderr** — scope `$ErrorActionPreference = 'Continue'` around DuckDB
calls. Write files with `[IO.File]::WriteAllText` + `New-Object Text.UTF8Encoding($false)`. DuckDB
dot-command paths must be forward-slash (item 7: backslashes are silently stripped). `powershell -File`
cannot bind a `[string[]]` from multiple arguments. Compare UTC with `timezone('UTC', now())`, never
`now()`. The real extract root is
`C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts` — read-only.

**Every check invocation passes both `-ExtractRoot` and `-LakeRoot` explicitly.** Before any `-Save`,
any mutation, or any `Remove-Item`, assert that the target's full path starts with `$env:TEMP` and is not
`<X>`, and print that assertion. If the implementer works in the main checkout, `Resolve-LakeRoot`'s
default **is the real lake** — a `-Save` without `-LakeRoot` would write it. Fixture timestamps:
`(Get-Date).ToUniversalTime().AddMinutes(-<n>).ToString('yyyy-MM-ddTHH:mm:ssZ')` — never a local
`ToString('o')`, whose offset is dropped on cast (300 minutes off here).

## Acceptance checks

Figures marked *runtime* move with the workbook and the clock; compare them against a figure computed in
the same run, never a pinned number. `<X>` below is the real extract root. **`<L>` is a fresh scratch
lake materialized from scratch copies of both contracts pointing at a scratch copy of the workbook**
(item 7's rewrite: exactly one forward-slash occurrence replaced per contract; scratch contracts outside
`contracts\`), so a SharePoint sync mid-run cannot flip `workbook_changed_since`. Only AC12 uses the live
workbook. Checks labelled *control* pass on today's repo and guard against collateral damage.

**AC1 — the headline.** `cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql -ExtractRoot <X>
-LakeRoot <L>` prints, in order: an `EXTRACT,parent_projects,…,stale=true,rows=15314,…` line with
`age_minutes` ≥ 8,400; a `LAKE,Clayco_Job_Costs_from_GL,…,workbook_changed_since=false` line; a
`RESULT,rows=<n>,…,extract_ages=parent_projects:<minutes>,stale_inputs=1` line where `<n>` equals the
number of distinct `PARENT_PROJECT_NUMBER` values in `lake.Clayco_Job_Costs_from_GL` (*runtime*; 345
today); and 20 CSV rows. Exit 0. **`Measure-Command` wall time of the whole
`powershell -NoProfile -File tools\cross-query.ps1 …` ≤ 2 s** (PLAN-4 §8's "process exiting under 2s";
~1 s expected), with the statement's own `elapsed` printed beside it.

**AC2 — the join loses and duplicates nothing.** A check query summing `gl_rows` and `job_costs` over the
example's result equals `count(*)` and `SUM(JOB_COSTS)` of `lake.Clayco_Job_Costs_from_GL` in `<L>`
(*runtime*; 62,603 / `22505496119.72` today). `examples\job-costs-unmatched.sql` returns `rows=0`.

**AC3 — the age is real, not decorative.** Build a scratch extract root `<Y>` holding a copy of the whole
`parent_projects` directory whose sidecar has only `materialized_at` rewritten, to
`(Get-Date).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')` (it must pass
`registry.sql` with an empty `reason`). With `DSK_WINDOW_MINUTES=60`, `-ExtractRoot <Y>` reports
`age_minutes` 10 (±1), `stale=false`, `stale_inputs=0`. With `DSK_WINDOW_MINUTES=5` the same root reports
`stale=true`. Same query file both times, no edit.

**AC4 — the name, not a path, is what resolves.** Build `<Z>`: a scratch extract root whose
`parent_projects` directory holds one Parquet file written with
`COPY (SELECT * FROM read_parquet('<X>/parent_projects/*.parquet') ORDER BY PARENT_PROJECT_NUMBER LIMIT 1000) TO … (FORMAT parquet)`
(ordered: an unordered `LIMIT` is read-order dependent — it matched 52 of 345 projects in one run) and a
sidecar with `row_count` 1,000 and a fresh `materialized_at`. The **same** example file, run with
`-ExtractRoot <X>` then `<Z>`: the `RESULT` row count for `<Z>` equals a same-run
`count(DISTINCT PARENT_PROJECT_NUMBER)` of GL rows whose project is in `<Z>`'s file — **that** is the
proof the name resolved to `<Z>` (the `EXTRACT` line's `rows=1000` only echoes the sidecar). And
`examples\job-costs-unmatched.sql` returns a non-zero count against `<Z>`. `grep` the example files for
`parquet` and `:\` / `:/`: no match. (`list-extracts.ps1` will show `bytes_check=DISAGREES` for `<Z>`;
`registry.sql` does not check `output_bytes` or `expires_at`. Harmless.)

**AC5 — a saved join is re-queryable with its provenance.** With `<L>`: `-Save gl_by_parent` prints
`SAVED_AS,gl_by_parent,rows=<n>,run_id=<uuid>`. Then **delete the scratch copy of `parent_projects`**
used as `-ExtractRoot` (use a scratch copy of `<X>` for this check, never `<X>`; assert the path is under
`$env:TEMP` before removing), and in a new process run a query file
`SELECT count(*) AS n, sum(job_costs) AS c FROM lake.gl_by_parent` through `cross-query.ps1` with
`-ExtractRoot <the deleted scratch path>`. It prints `SAVED,gl_by_parent,…,inputs=parent_projects@<the
extract's materialized_at>;Clayco_Job_Costs_from_GL@<run_id>`, `age_minutes` ≥ 8,400 (the oldest input,
not the save), and `n`/`c` equal to AC1's `rows` and AC2's job-cost sum. Show `Test-Path <deleted scratch
path>` → `False` before and after, and `Test-Path <X>\parent_projects\_extract.json` → `True`. Show one
`lake.join_manifest` row with its `inputs` JSON.

**AC6 — a refreshed extract does not silently change a saved join.** Continuing AC5: save
`gl_by_parent` again from `<Z>` (the 1,000-row copy). `lake.join_manifest` now holds two rows for
`gl_by_parent`; the newest names `<Z>`'s `materialized_at`; `SAVED` reports it; and
`SELECT count(*) FROM lake.gl_by_parent AT (VERSION => <first row's lake_snapshot_id>)` still returns the
first save's count.

**AC7 — refusals, each exit 1, nothing run, `<L>` unchanged** (`lake.snapshots()` count identical
before and after). Show the message for each:

- a `DROP TABLE lake.manifest` file → the parser's `Only SELECT statements can be serialized to json!`;
- `SELECT 1; DROP TABLE lake.manifest` **with `-Save x`** → refused for 2 statements;
- `extract_table('par' || 'ent')` → refused, non-literal name;
- `extract_table('no_such_extract')` → `ERROR,extract,no_such_extract,not in the registry at <root>`;
- `FROM '<X>/parent_projects/*.parquet'` (single quotes), `FROM "<X>/parent_projects/*.parquet"`
  (double quotes), `FROM parent_projects.parquet`, and `SELECT (SELECT count(*) FROM '<X>/parent_projects/*.parquet')`
  → each refused by the allow-list, naming `extract_table` as the alternative;
- `FROM lake.x.parquet` → refused, `no such table in the lake`;
- `FROM lake.snapshots()` → refused as a table function;
- a CTE named `'C:/x.parquet'` → refused for path characters in a CTE name;
- `read_xlsx('<live workbook path>', sheet='Clayco_Job_Costs_from_GL')` → refused, names `lake.<table>`
  and contracts as the alternative; the live workbook's mtime and hash unchanged;
- `-Save manifest`, `-Save Clayco_Job_Costs_from_GL`, and **`-Save clayco_job_costs_from_gl`** →
  refused, and `<L>`'s GL row count unchanged;
- `-Save bad-name` → refused by the name rule;
- `-LakeRoot <an empty scratch dir>` → `ERROR,lake,no lake at …`, and no `lake.ducklake` is created there.

**AC8 — decoys are not inputs.** A query with `-- lake.decoy extract_table('decoy_in_comment')` in a
comment and `'lake.not_a_table'` as a string literal, around a real `extract_table('parent_projects')` ⋈
`lake.Clayco_Job_Costs_from_GL` join, prints exactly one `EXTRACT` line and one `LAKE` line, and runs.

**AC9 — a changed workbook is reported.** Materialize `<L2>` exactly as `<L>` (its own scratch workbook
copy). Query it: `workbook_changed_since=false`. Set the scratch copy's `LastWriteTime` forward one hour (no
content change): `workbook_changed_since=true`, `stale_inputs` rises by 1, exit still 0. Remove the copy:
`workbook_present=false`, the query still runs and returns the same count.

**AC10 — the non-save path cannot write.** Record `<L>`'s `lake.ducklake` `LastWriteTime`; run AC1, AC2,
AC8 and every AC7 refusal that does not pass `-Save`; show it unchanged. Show the process's `ATTACH`
carries `READ_ONLY` by reading the generated SQL (print it on `-Verbose`).

**AC11 — the lock is reported, not retried.** While a separate process holds `<L>` open with a genuine
~12 s workload (`SELECT max(hash(i*7+1)) FROM range(2000000000) t(i)` after attaching `<L>`
read-write — **with the `t(i)` alias**; without it the statement is a Binder Error, found in item 7),
`-Save x` prints the verbatim `File is already open in …` text and exits 1 within 5 s, with the holder
confirmed `HasExited=False` at that moment (as item 6's AC17 did). State which attach failed — step 2's
read-only one or the save's. A non-save query during the hold is reported the same way.

**AC12 — docs.** Follow the README section's steps literally, substituting only `-ExtractRoot <X>
-LakeRoot <a fresh scratch lake>` (a verifier's worktree cannot use the defaults — D6), and reach AC1's
`RESULT` line. This is the one check against the **live** workbook: if a sync landed,
`workbook_changed_since=true` and `stale_inputs=2` — quote it as drift, not a failure.
*Control:* `snowflake-extract` and `lakehouse` descriptions are byte-identical to `main`. Quote the new
README section and both skill paragraphs in `RESULT-1.md`.

**AC13 — *control:* nothing real was touched.** The real lake's `lake.ducklake` size and `LastWriteTime` are
unchanged (8,663,040 bytes, `2026-09-25T16:26:30` at spec time). Every file under `<X>` has an unchanged
size and `LastWriteTime`. The live workbook is `unchanged` or `SYNCED` by item 7's rule, never `CHANGED`.
No `~\.duckdb-skills\<id>\` directory was created for the worktree's project-id.

**AC14 — *control:* no BOM** on any new or changed `.ps1`, `.sql` or `.md`.

## Mutation proofs — each must fail, then pass again after revert

1. Find inputs with a regex over the raw SQL instead of the parse tree → AC8 fails (`decoy_in_comment`
   reported, and refused as not in the registry).
1b. Replace the allow-list with "ignore unqualified `BASE_TABLE` nodes" → AC7's quoted-path cases **run
   and read the file** instead of being refused. This is the hole the first draft of this spec specified.
2. Save with `CREATE VIEW` instead of `CREATE TABLE` → AC5 fails in the new process.
3. Resolve `parent_projects` to a hard-coded glob under `<X>` instead of the registry → AC4 fails
   (`<Z>` still reports 15,314).
4. Drop the statement-count guard → AC7's `SELECT 1; DROP TABLE lake.manifest` with `-Save x` **drops
   `lake.manifest` in `<L>`** — run only with `-LakeRoot <L>`, after printing the assertion that `<L>`
   is under `$env:TEMP`; show `lake.manifest` gone, then rebuild `<L>`.
4b. Compare `-Save` names case-sensitively → AC7's `-Save clayco_job_costs_from_gl` replaces the contract
   table (GL row count changes).
5. Attach read-write on the non-save path → AC10 fails (catalog `LastWriteTime` moves, or the generated
   SQL lacks `READ_ONLY`). If DuckLake does not touch the file on a read-write attach with no write,
   say so and rely on the generated-SQL half.
6. Report the save's age instead of the oldest input's → AC5's `age_minutes` ≥ 8,400 fails.
7. Omit the `coalesce(…, error(…))` guard and the step-2 registry check → AC7's unknown-name case prints
   `read_parquet cannot take NULL list as parameter` instead of the named error.

## Deliverables

`tools\cross-query.ps1`, `examples\job-costs-by-parent-project.sql`, `examples\job-costs-unmatched.sql`
(new); `README.md`, `skills\snowflake-extract\SKILL.md`, `skills\lakehouse\SKILL.md` (edited). Branch
`item8-cross-source-join` from `main`. Commit and push before writing `RESULT-1.md`.
