# PLAN-1 — One local SQL surface over Snowflake extracts and Excel workbooks

> **DRAFT, not frozen.** No `TASK.md` names this plan, so edit in place. Supersedes the separate
> `PLAN-2.md` (merged 2026-09-23; its content is in history at commit `185f93b`).

**Serves:** One SQL surface where a Snowflake extract and an Excel workbook sheet are both just
tables, so joining them is ordinary SQL — and the joined result is saved and re-queryable without
re-reading either source or re-running the query against Snowflake.

## Why this exists

Three problems, all observed rather than assumed:

1. **Cortex Code writes Snowflake SQL fluently and DuckDB SQL badly.** Phil has hit this in live
   sessions. Measured: 24 of 41 common Snowflake constructs fail on DuckDB v1.5.5.
2. **Snowflake results live only in the conversation.** Every follow-up question re-reads them
   from context or re-runs the query. `skills/read-memories/sqlresults.sql` exists purely to dig
   past result sets out of session logs — evidence that losing them is a real cost.
3. **Snowflake data and workbook data can't meet.** DuckDB can't reach Snowflake; Snowflake can't
   reach `Data Extracts.xlsm`. A local file is the only place both can be joined.

## Measured facts — all verified in-session on this machine, 2026-09-22/23

### Transport: the app's own connection

- `COPY INTO @~/<dir>/ FROM (<query>) FILE_FORMAT=(TYPE=PARQUET)` writes server-side;
  `GET @~/<dir>/ 'file://C:/...'` pulls it to local disk — **verified working** through
  `snowflake_sql_execute`.
- Types survive exactly: `decimal(5,0)`, `decimal(12,2)`, and `'01100'` as VARCHAR with its
  leading zero intact.
- No `.venv`, no pip dependency, no CSV hop, no Okta prompt, and **rows never pass through the
  conversation** — so results too large to read are still extractable.
- Two gotchas: `GET` fails `ENOENT` unless the local target directory already exists, and the
  stage copy bills storage until `REMOVE`.

Rejected: the Python connector (needs a venv, pops an Okta browser window, which would make a
"silent" refresh not silent). Rejected: `snow` CLI (not installed; CSV-only output forces a
type-losing hop). Rejected: the `snowflake` DuckDB extension — see non-goals.

### Dialect

41 common Snowflake constructs against DuckDB v1.5.5: **raw 17, the macro shim 28,
`polyglot` 36.** These are **error-free counts, not correctness counts** — both probes decide pass
by absence of a DuckDB error class, not by comparing values. Item 1's fixture fixes that. Every
failure is a loud `Catalog Error` at bind time, never a wrong value.

**`polyglot` is NOT transparent — verified.** With the extension loaded, plain
`SELECT IFF(1>0,'y','n')` still fails. Snowflake SQL must be **wrapped**:
`SELECT * FROM polyglot_query('<snowflake sql>', 'snowflake')`, with single quotes doubled. So
polyglot is a deliberate wrapper call, not ambient dialect support — this materially shapes item 1
and the skill guidance.

Wrapped, it reaches what macros structurally cannot: `TOP n`→`LIMIT`, `MINUS`→`EXCEPT`,
`NUMBER(38,2)`→`DECIMAL(38,2)`, `LISTAGG ... WITHIN GROUP`, `OBJECT_CONSTRUCT`→struct. It needs no
connection, no driver, no auth, and exits in 0.20s.

**The two compose — verified.** A session macro resolves *inside* `polyglot_query`:
`TO_VARCHAR(123)` returned `123` through the wrapper. And **polyglot loads under the ad-hoc
sandbox** (`enable_external_access=false`, `lock_configuration=true`, per
`skills/query/SKILL.md:90-95`) — `TOP 1` transpiled and ran.

**polyglot has one measured wrong translation, and the macros fix it.** `TRY_TO_NUMBER`:

| Path | valid `'12.3'` | bad `'abc'` |
|---|---|---|
| Snowflake | NUMBER | NULL |
| `polyglot` | `DOUBLE` | **errors** |
| macro shim | `12.300000`, `DECIMAL(38,6)` | **NULL** |

So the macro file is not a thin gap-filler — it is the value-correct path for this case, and the
reason to keep the full seed set rather than only `TO_VARCHAR`. Workflows must still **surface the
transpiled SQL** when polyglot is used, which `polyglot_transpile` makes possible.

Also measured: a hand-written `DATEADD` macro silently returned TIMESTAMP where Snowflake returns
DATE. **Every macro acceptance check must assert returned type as well as value**, and `DATEADD`
stays out of the shipped macro file until it is fixed and type-asserted.

### Workbook reads — type inference is unsafe

Measured on `Clayco_Job_Costs_from_GL` in `Data Extracts.xlsm` (64 MB, 26 sheets, 61,741 rows):

- `VENDOR_NAME` infers DOUBLE. With `ignore_errors=true`, `COUNT(VENDOR_NAME)` = **0 of 61,741**,
  silently, query "succeeded". With `all_varchar=true` it is **51,571**.
- Without `ignore_errors` it fails loudly: `Invalid Input Error: read_xlsx: Failed to parse cell
  'I3': Could not convert string 'City of DeKalb' to DOUBLE`.
- **`all_varchar` alone destroys dates.** `GL_PERIOD` returns VARCHAR holding Excel serials
  (46204–46296) and `TRY_CAST('46204' AS DATE)` → **NULL**, silently. Correct:
  `(DATE '1899-12-30' + to_days(GL_PERIOD::BIGINT))::DATE` → 2026-07-01 to 2026-10-01. The
  trailing `::DATE` is required — `+ to_days()` yields TIMESTAMP.
- **Lexicographic trap:** on `all_varchar` columns `MAX(JOB_COSTS)` = `'99999.72'`; cast first and
  it is **256,178,387.75**.
- Money survives exactly: `SUM(JOB_COSTS::DECIMAL(18,2))` = **22,390,953,840.93**.
- Null rates differ wildly per column — `JOB_COSTS` 0% null, `VENDOR_NAME` 83.5% non-null,
  `GL_PERIOD` **70.2% NULL**. Floors must be measured per column, never templated.
- `.xlsm` reads fine and fast — 123-column sheet plus 61,741-row sheet in 1.4s. Macros are
  irrelevant: DuckDB reads sheet values only, never touching `vbaProject.bin` or the Power Query
  DataMashup blob.
- No sheet-listing function exists. Sheet names come from `xl/workbook.xml` in the zip.
  `Data Extracts.xlsm` has **26 sheets**, and the first is a 2-row `MetaData` sheet, **not data** —
  matters for anything iterating all sheets.
- Column names are hostile: embedded newline in `Projected\nCompletion Date`; duplicate headers
  auto-suffixed **positionally** (`Job Cost to Date` / `...to Date3`).
- `read_xlsx` params are exactly: `col0, header, all_varchar, stop_at_empty, ignore_errors,
  range, sheet, empty_as_varchar, normalize_names`.

### Lakehouse

- `ducklake` and `excel` are **core** extensions (`installed_from = core`), not community.
- DuckLake runs on a purely local catalog — `ATTACH 'ducklake:cat.ducklake' AS lake (DATA_PATH ...)`
  — verified: created a table, `lake.snapshots()` returned 2 rows. **No PostgreSQL.** That was
  ducksync's requirement, not DuckLake's.
- History survives `CREATE OR REPLACE`: `FROM lake.snapshots()` lists every change and
  `AT (VERSION => 1)` still returns pre-replace data. Materializing does not destroy its own
  evidence.
- DuckLake **inlines** small tables into the catalog file (`file_count = 0`); Parquet appears only
  past a size threshold. Accepted — see non-goals.
- Proven end to end: wrote a real `.xlsx` and `.parquet`, joined them, materialized into DuckLake,
  then in a **separate process** read the result back without touching sources. Exits 0.64s/0.3s.

## Shared conventions and verified traps

These apply to every item. They are the reason the two source plans duplicated each other.

**Platform.** Windows / PowerShell 5.1; chain with `;` never `&&`; absolute paths. SQL lives in
`.sql` files invoked with `duckdb -f`, never inline `-c`, because PowerShell expands `$` inside
double-quoted strings and breaks any `'$.type'` JSON path. Parameters arrive as environment
variables. Path comparisons are case-insensitive and separator-normalized.

The eight upstream skills are POSIX bash and the README states Windows is unsupported upstream.
Only `skills/read-memories/` was written for this machine; **its conventions are the ones to
copy**, not upstream's.

**`duckdb -init` takes exactly one file, and a second `-init` silently replaces the first.**
Verified: `duckdb -init a.sql -init b.sql` loses everything in `a.sql`. Every session-mode call
already spends that slot on `state.sql` (`skills/query/SKILL.md:31,58,66,79,129`;
`skills/attach-db/SKILL.md:143`). So helper macros are delivered by appending a
`.read <forward-slash absolute path>` line to `state.sql`, idempotently — `.read` **requires
forward slashes**, a backslash path fails `Error: cannot open`. Composed this way, shim and state
macros both resolve (returned `shim_ok,7`).

**Never decide pass/fail by matching the bare word `Error`.** DuckDB writes its `-init` banner to
stderr and PowerShell surfaces that as `NativeCommandError`, so a working shim reports total
failure. This cost a full debugging cycle. Match DuckDB's error classes only — `Catalog Error`,
`Parser Error`, `Binder Error`, `Conversion Error`. The **exit code is trustworthy**: a
successful `-init` run exits 0.

**Assert returned types, not just values.** The `DATEADD` drift above is why.

**Never write a `.sql` file with `Set-Content -Encoding UTF8`.** PowerShell 5.1 writes a UTF-8 BOM
(bytes 239,187,191), and a BOM ahead of a `.read` dot-command breaks it —
`Parser Error ... ∩╗┐.read`. Use `[IO.File]::WriteAllText(...)`. This matters directly: item 1
appends a `.read` line to `state.sql`.

**Acceptance checks name real values.** Row counts, sums, ages in minutes. "Output compiles" and
"tests pass" are not observable by Phil and do not count.

## Non-goals — deliberate, do not add

- **The `snowflake` DuckDB extension is never loaded by anything here.** Its ADBC teardown defect
  leaves a process that does not exit, sometimes with results unreadable, once unkillable and
  holding a driver lock that required a reboot. Reproduced on driver v1.11.0 and v1.14.0; full
  write-up in `docs/duckdb-snowflake-findings.md`. Scope precisely: this forbids the **DuckDB
  extension**, not programmatic Snowflake access. The `COPY INTO` + `GET` transport is fine.
- **No ducksync, no Quack listener, no PostgreSQL.** ducksync routes every refresh through that
  extension. Its two-stage invalidation *design* is adopted in item 2.
- **No `.xls` support.** Excluded by Phil. No Excel COM, no conversion stage.
- **No source workbook is ever written to.** Read-only always, including in tests. Workbooks are
  read-only sources, so the entire `xlsx-connected-data` failure mode is out of scope by
  construction.
- **No long-lived service.** Every invocation is a short-lived DuckDB process that exits.
- **No forced Parquet flush.** Catalog-inlined tables are accepted (Phil, 2026-09-23);
  materialized tables need not be readable outside DuckDB.
- **`Project_Profit` and the suffixed-column decoding are deferred.** Decided 2026-09-23: ship on
  `Clayco_Job_Costs_from_GL` first. See "Follow-on work".
- **No scheduled or background refresh.** Refresh happens when a session reads an expired extract.
- **No extract retention or cleanup.** Growth is deliberately unmanaged; item 2 ships a
  size-reporting command so it is visible, and acting on it stays manual. Do not add deletion.
- **No contract scaffolder.** It existed to make a 123-column `Project_Profit` contract tractable;
  with that deferred, its justification goes too. Revisit alongside `Project_Profit`.
- **No Snowflake SQL emulator** (e.g. `nnnkkk7/snowflake-emulator`). Rejected 2026-09-22: a
  translation layer that fails *silently* in front of cost data, requiring Docker, replacing
  `duckdb -f` with HTTP and so discarding the ad-hoc sandbox, and shipping a separate CGO DuckDB
  build without the `spatial`/`excel`/`sqlite` extensions `read-file` needs.
- **No write outside this repo**, including under `~/.snowflake/`.

## Items

- **Item 1 first** — everything uses it.
- **Track A (Snowflake):** 1 → 2.
- **Track B (workbooks):** 1 → 3 → 4 → 5 → 6 → 7.
- **Item 8 requires both tracks complete.**

Ships independently: item 1 alone fixes the dialect friction Phil hits today. Track A alone
delivers extracts. Track B alone delivers the lakehouse on the GL sheet, without `Project_Profit`.

**Intended spec boundaries**, so the round count is visible before committing: `{1}`, `{2}`,
`{3,4}` (discovering sheets and building the first contract against them are one job), `{5}`,
`{6}`, `{7}`, `{8}` — seven specs. Items 4 and 5 are coupled through the assertion-format
decision, so 5's spec must cite what 4 settled.

### 1 — Dialect: a macro file plus polyglot, and a rule for which to use

Two mechanisms, each doing what it is good at, plus the routing rule between them — without that
rule an implementer cannot write the skill guidance.

**The macro file.** Promote the verified seed at `.duckdb-skills/sf-compat.sql` (currently
**gitignored** via `.gitignore:3`, so the evidence this item rests on is un-backed-up) to a tracked
**`skills/query/duckdb-compat.sql`** — named for what it is rather than for Snowflake, since it
also carries `xl_date()`. Retains the seed's **value-correct** macros, notably `TRY_TO_NUMBER`,
plus `TO_NUMBER`, `DIV0`, `DIV0NULL`, `NVL`, `NVL2`, `IFF`, `ZEROIFNULL`, `NULLIFZERO`,
`EQUAL_NULL`, `TO_VARCHAR`, `REGEXP_SUBSTR`, `CHARINDEX`, `LEN`. **Excludes `DATEADD`** until its
TIMESTAMP drift is fixed and type-asserted. Adds **`xl_date()`** for Excel serials so that
conversion is named once rather than retyped per column.

**Delivery — and not through `attach-db`.** `skills/attach-db/SKILL.md:111-137` is POSIX bash
(`grep -q`, `cat >> <<'STATESQL'`, `mkdir -p`, `$HOME`) and does not run on this machine, so
specifying it as the delivery path would ship macros that are never actually loaded. Instead ship
**`tools\ensure-duckdb-compat.ps1`**, which creates or idempotently appends a
`.read <forward-slash absolute path>` line to `state.sql`, BOM-free. Not a second `-init`.
Touching the eight bash skills is out of scope.

**Routing rule, to be stated in the skill text:** write plain DuckDB SQL with the macros loaded;
reach for `polyglot_query(<sql>,'snowflake')` when a construct fails with a `Catalog Error` or
when the SQL is being lifted verbatim from Snowflake; **always surface `polyglot_transpile`
output** when polyglot runs, because of the `TRY_TO_NUMBER` class of flaw. Note polyglot requires
doubling single quotes inside the wrapped string.

**Pin `polyglot` explicitly** and record that it is a **community** extension (unlike `ducklake`
and `excel`, which are core) — a community extension that auto-updates could change transpilation
silently, the same risk class as the `TRY_TO_NUMBER` flaw. State what "pin" means operationally
and assert it.

The construct list becomes a tracked fixture, **`skills/query/duckdb-compat-tests.csv`**, one row
per construct with `name, sql, expected_value, expected_type`. The existing probe cannot serve as
it: `.duckdb-skills/dialect-probe.ps1:44` decides pass/fail with `-match 'Error|error:'`, the exact
anti-pattern forbidden above, and it has no expected-value or expected-type column.

The residual set — constructs neither path reaches — is **whatever the fixture run reports**, not
a number asserted here. (The pre-merge list of six was measured against macros alone; polyglot
reaches four of those six, so that list is stale.) Document the residuals so a session rewrites
rather than retries blindly.

**Acceptance:**

- A before/after table over the fixture: pass count rises from 17, **zero regressions** among the
  original 17, every row asserting **value and returned type** — the first correctness-based
  measurement, since 17/28/36 are error-free counts only.
- `xl_date(46204)` = `2026-07-01` **and** `typeof()` = `DATE`.
- `TRY_TO_NUMBER('12.3')` via macro = `12.300000` typed `DECIMAL(38,6)`, and `TRY_TO_NUMBER('abc')`
  = `NULL` — the case polyglot gets wrong.
- `tools\ensure-duckdb-compat.ps1` run **twice** against a fresh `state.sql` and against one
  already holding an `ATTACH` line: show file contents both times — exactly one `.read` line, the
  `ATTACH` intact.
- A macro resolving through `-init "$STATE_DIR/state.sql"`, the way a session actually invokes it.

### 2 — The `snowflake-extract` skill

Materialize, sidecar, freshness check, bounded silent refresh.

**Split the deliverable explicitly, because half of it cannot be a script.** `COPY INTO` and `GET`
run through `snowflake_sql_execute`, an **agent tool** — no PowerShell script can call it. So:

- **2a, runnable and Phil-observable:** a freshness/age/size checker that reads sidecars. A real
  command with real output.
- **2b, agent-driven:** materialize and refresh, specified as `SKILL.md` instructions. Demonstrated
  by invoking the skill, not by running a script.

The acceptance list must say which checks are commands and which are skill invocations. Treating
both as one scriptable deliverable is a guaranteed correction round.

- `COPY INTO` Parquet → `GET` into a local directory it creates first → `REMOVE` the stage copy.
- **One directory per extract**, because `COPY INTO` splits output (`data_0_0_0.snappy.parquet`,
  …). Queried as `<dir>\*.parquet`, sidecar at `<dir>\_extract.json`, and temp-then-rename is a
  **directory** rename — which also settles concurrent refresh.
- Sidecar fields named explicitly: query text, source objects, UTC `materialized_at`, window
  written, computed expiry, `row_count`, warehouse, and **connection name, role, and database** —
  the same query under a different role returns different rows.
- `runtime_seconds` from Snowflake's `TOTAL_ELAPSED_TIME` via `QUERY_HISTORY_BY_SESSION()`, not a
  shell clock. If unreliable, drop the field and report `row_count` and bytes instead — but say
  which.
- Freshness check whose **first output line is the age**, taking the window as a parameter.
- **Two-stage invalidation**, adopted from ducksync's design: compare `SHOW TABLES` rows/bytes
  through a **no-warehouse** connection first; fall back to
  `information_schema.tables.last_altered` only when those move. Avoids waking a warehouse just to
  ask whether data changed.
- One extract location, absolute, confirmed gitignored — production data, never committable.
- `allowed-tools` must include the Snowflake execute tool. Note the field may be advisory: eight
  skills declare `allowed-tools: Bash`, but `read-memories` declares none and runs `duckdb` fine.
  Verify by invocation, not frontmatter.

**Freshness is a judgment, not a gate.** Each extract carries a window and expiry; the session
decides whether the work is staleness-sensitive from the data's nature — transactional tables go
stale fast, dimensional ones (`DT_PROJECTS`) do not. Defaults follow work mode (`AGENTS.md`):
**1 hour analysis, 24 hours dev**. **The reader's mode governs**, passed as
`DSK_WINDOW_MINUTES`; the sidecar records the writer's window as a fact only.

**Extract freshness is never mtime.** Every `GET` rewrites the Parquet, so mtime always advances
and every run would report REFRESHED for exactly the data most likely to be stale.

**Past the window: re-pull silently**, no prompt. Bounded to **one refresh per extract per
session**. Print the sidecar's `row_count` and `runtime_seconds` *before* refreshing, and report
elapsed time in one line after. The **first materialize is unguarded** — no prior runtime exists.
**A failed re-pull must not silently serve stale data:** report the failure and the age, and do
not present contents as current. **No sidecar = unknown age = stale.**

The once-per-session cap is **documentation, not an enforceable check** — skills are stateless
shell invocations with no session store. Stated plainly, following
`skills/read-memories/SKILL.md:15-18`.

**Acceptance.** Pin a real, small Snowflake object and its current row count at spec time — the
way item 4 pins 61,741 rows — so Phil has a figure to check against; "a known row count" is not
runnable. Then: that row count matching the sidecar's; an age in minutes from a backdated fixture
sidecar (a command, 2a); an expiry that actually trips; a missing sidecar treated as stale; and one
command reporting total extract size on disk.

**Stage-side collision:** state the stage path convention literally — how an extract name maps to
a `@~/<dir>` subdirectory, and what happens when two sessions choose the same name. The directory
rename above settles only the *local* torn-file case.

### 3 — Sheet discovery tool

`tools\list-sheets.ps1 <absolute-workbook-path>` reads `xl/workbook.xml` from the zip. Read-only,
no Excel, never opens the workbook. Must handle Excel's 31-character name truncation
(`Subcontract_Totals_and_Invoicin`) and a contract-filename convention surviving spaces and
multiple dots.

**Acceptance:** against the pinned absolute path to `Data Extracts.xlsm`, prints **26** sheets,
first is `MetaData`, and both `Project_Profit` and `Clayco_Job_Costs_from_GL` appear.

### 4 — First hand-built contract: `Clayco_Job_Costs_from_GL`

A **contract** is one `.sql` file per sheet holding a `CREATE OR REPLACE VIEW` over `read_xlsx`
with `all_varchar = true`, **never** `ignore_errors`, and an explicit cast per column.

Two format decisions to settle here rather than leave open: where assertions live (a `-- @assert`
directive parsed by item 5, or a companion `<name>__assert` view — pick one), and
`normalize_names = true` versus positional selection for headers containing literal newlines.

Pin the absolute workbook path; there are ~30 files named `Data Extracts*.xlsm` on this machine
and the numbers are meaningless without it.

**Acceptance**, every value measured: **61,741** rows; `COUNT(VENDOR_NAME)` = **51,571**;
`GL_PERIOD` `typeof()` = `DATE`, min **2026-07-01**, max **2026-10-01**, **18,395** non-null;
`SUM(JOB_COSTS)` = **22,390,953,840.93** as `DECIMAL(18,2)` — a figure Phil can tie to a report;
`MAX(JOB_COSTS)` = **256,178,387.75**, proving the cast-before-compare rule; and the ordered
header list matching a committed fingerprint.

### 5 — Assertion harness

Runs each contract's assertions, reporting pass/fail per column. Covers per-column non-null floors
(**measured individually** — `VENDOR_NAME` at 83.5% is a misleading template when `GL_PERIOD` is
70.2% NULL), **direction-aware** row-count tolerance so a growing GL sheet doesn't cry wolf
monthly, casts applied before any range comparison, and item 4's header fingerprint.

**Acceptance — two mutation tests:**

1. Drop `all_varchar` **and** add `ignore_errors = true` → harness FAILS naming `VENDOR_NAME` and
   the **51,571 → 0** collapse. This is the silent-nulling detector and the harness's whole reason
   to exist.
2. Drop `all_varchar` only → harness FAILS reporting the `'City of DeKalb'` parse error and a
   non-zero exit. Mutation 2 alone cannot prove the detector works, because the read dies before
   any row exists.

### 6 — Materialize into the lakehouse, with workbook freshness

`CREATE OR REPLACE TABLE lake.<name> AS SELECT * FROM <contract>`. A `lake.manifest` table records
source path, mtime, row count, and contract hash — `snapshots()` records changes but not
provenance, so the manifest is still justified.

**Workbook mtime is a valid signal** (unlike extract mtime, item 2).

**Single writer.** The DuckLake catalog is one local DuckDB file; two sessions materializing at
once will hit a lock. State the single-writer expectation and what the lock error looks like, so a
session recognises it instead of retrying.

**Workbook may be locked or mid-sync.** `Data Extracts.xlsm` is SharePoint-synced and Phil often
has Excel open. State the expected behaviour when `read_xlsx` meets a locked or partially-synced
file — this is the most likely real-world failure of the workbook track.

**Acceptance:** run refresh twice → second reports SKIPPED for all; touch a **scratch copy** of
the workbook → next run reports REFRESHED with a row count. Never touch the live
`Data Extracts.xlsm` — writing triggers a full re-upload and version churn, and violates this
plan's own read-only non-goal. Also assert `FROM lake.snapshots()` lists the replace and
`AT (VERSION => 1)` still returns pre-replace data. Note **`DATA_PATH` creates no directory** until
the inlining threshold is crossed, so absence of a Parquet directory is not evidence of failure.

### 7 — Workbook proof, routing, and the extension non-goal (lands with the workbook track)

The **`Serves:` test**: point the contract at a nonexistent path, query the materialized table,
get the identical row count — proving results really are re-queryable without re-reading sources.

The non-goal asserted **behaviourally**: `SELECT extension_name FROM duckdb_extensions()
WHERE loaded` returns **no** `snowflake` row, and every entrypoint exits 0 within budget. A grep
for `LOAD snowflake` is a fake check — it already matches `docs/duckdb-snowflake-findings.md`, and
it would miss `INSTALL snowflake` and `ATTACH ... (TYPE snowflake)`.

Workbook routing: must say whether this extends `skills/read-file/SKILL.md` (which already routes
`.xlsx` to `read_xlsx`) or adds a new skill.

**Acceptance:** the nonexistent-path test returns the pinned GL row count; `duckdb_extensions()`
shows no loaded `snowflake`.

### 8 — The cross-source join (requires items 2 and 6)

The thing this plan exists for: a landed extract directory (`<dir>\*.parquet`) joined to a
materialized workbook table in one statement, process exiting under 2s.

**The joined output must print the extract's age line alongside the row count.** Otherwise the
headline feature can silently join a three-day-old extract — item 2 tracks extract age and item 6
tracks workbook mtime, but the join itself would report neither. This also puts the freshness work
in front of Phil in the one command he will actually run.

README gains the patterns and the freshness rule. Standing-context budget: **≤ 4 description lines
per new skill, maximum two new skills.** Nine descriptions already load at every session start
whether used or not; README prose is free because it is not auto-loaded.

**Acceptance:** Phil follows the doc from a clean shell and reaches a specific joined row count,
with the extract age printed beside it.

## Risks

- **Positional column drift.** Mitigated by item 4's header fingerprint. Unresolved for
  `Project_Profit`, which is why it is deferred.
- **Casting money `DOUBLE → DECIMAL` freezes what Excel already stored.** It makes values exact
  going forward; it does not recover precision Excel lost. The cent-exact SUM shows nothing was
  lost *here* — a fact about this sheet, not a guarantee.
- **polyglot mistranslation.** `TRY_TO_NUMBER` is the known case. Surfacing transpiled SQL is the
  mitigation; it is a reporting discipline, not a fix.
- **Catalog inlining** means materialized tables are not readable as Parquet by other tools.
  Accepted deliberately.

## Follow-on work — not in this plan

- **`Project_Profit` contract (123 columns).** Blocked on decoding the positionally-suffixed
  columns: four `...to Date`/`...To Date` pairs plus four `Segment` equivalents differ only by an
  integer suffix DuckDB assigned by position, and an upstream column insertion silently changes
  it. Meaning must be established by reading the workbook's Power Query through the
  `xlsx-power-query` skill (M code is base64 in `customXml`; grep and openpyxl never find it),
  delivered as a committed mapping table. A separate spec once the GL sheet ships.
- **Porting the eight upstream skills to PowerShell.** A real gap, but mixing a Windows port into
  this work makes both unreviewable.
- **Revisiting the `snowflake` extension** if its teardown defect is fixed upstream. Its
  capabilities were never the problem.
