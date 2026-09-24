# RESULT-2 — Item 2b round 2: TZ-aware projection

Branch `item2b-snowflake-extract`, one commit on top of `fb4eecb`, touching exactly one file:
`skills/snowflake-extract/SKILL.md`. `tools\dsk-paths.ps1`, `tools\extract-decide.ps1`,
`tools\publish-extract.ps1`, `tools\make-decide-fixtures.ps1`, `tools\list-extracts.ps1`,
`tools\extract-status.ps1`, `skills/snowflake-extract/SIDECAR.md`, and
`skills/snowflake-extract/registry.sql` are all untouched this round.

**No `ask_user_question` call was needed this round.** Round 2's projection step worked end to
end on the first attempt — `COPY INTO` succeeded once the TZ columns were cast — so there was no
blocking ambiguity requiring Phil's input, and C3's recording rule has nothing to record here.

**One discrepancy against the spec's own numbers, reported rather than adjusted (per the task's
instruction not to weaken a check):** `TASK.md`'s C1/C2 correction text states `DT_PROJECTS` has
"113 columns, two of them `TIMESTAMP_LTZ`". Measured this session via
`DB_CONTROL_TOWER.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'SCH_PROJECT_OPERATIONS' AND
TABLE_NAME = 'DT_PROJECTS'`: **107 rows returned**, still exactly **2** `TIMESTAMP_LTZ` columns
(`START_DATE`, `FINISH_DATE`). `DT_PROJECTS` is a dynamic table under active schema/content churn
(round 1 already noted its row count moving 42,161 → 42,167 across sessions); its column count has
apparently also drifted since round 1's measurement, or round 1's count was itself wrong. Either
way, every check below that depends on a column count (AC18's `ncols`) uses the **live, measured**
107, not the spec's stated 113, and the two agree with each other — the check is internally
consistent, it is only the spec's stated 113 that is stale.

---

## Re-run of round 1's unchanged checks (AC1–AC6, AC16, AC17)

Every one PASSES; no regression. Verbatim output only where it usefully differs from
`RESULT-1.md` (mostly: different ages/timestamps from re-running at a different moment, and the
registry snapshot losing `parent_projects` from the *default extract root* mid-round because AC15-
R2 legitimately deletes and re-creates it there — the **fixture** roots used for AC1–AC6 are
untouched by that and are shown below).

| Check | Result |
|---|---|
| AC1 (both halves) | **PASS** — publish → live reads `FRESH`, 0 subdirs, no `.old`/`.new`; rebuilt fixture + bare `Move-Item` → `$?`=True, live still `STALE`, nested `ac1_extract\ac1_extract_staging2\` holds the fresh copy |
| AC2 | **PASS** — `publish failed, restored previous extract: … Access … denied`, exit 1, row count intact (7), no `.old` left |
| AC3 (4 cases) | **PASS** — all exit 3, exact messages, `<live>` unchanged, staging never consumed |
| AC4 (14 rows) | **PASS** — all 14 verdict tokens matched exactly |
| AC5 | **PASS** — `expected 1 values for 1 source objects, got 2` exit 2; `invalid -CurrentRows value 'abc': expected an integer or the literal 'null'` exit 2; window states 60 |
| AC6 | **PASS** — ages in 2a's own bands (0/90/1500), AC8 listing exact (15314/42161-equivalent fixture pins, deletion math exact: 1276957−381002=895955), compat suite exit 0, `REGRESSION: none` |
| AC16 | **PASS** — description 4 content lines; `git diff --name-only --diff-filter=A main...HEAD -- skills/` → exactly `skills/snowflake-extract/SKILL.md` (re-checked *after* the SKILL.md edit too — still exactly one file, since editing a file already added on this branch doesn't add a second) |
| AC17 | **PASS** — first line `0`, not blank; verdict `FRESH`; sidecar `query` reads back `-ceq` `True`, newline included |

Verbatim output where relevant:

```
--- AC1 half 1 ---
> tools\publish-extract.ps1 -Name ac1_extract -StagingDir ...\ac1_extract_staging -SidecarPath ...\ac1_sidecar.json -ExtractRoot ...\fixtures\publish
published ...\fixtures\publish\ac1_extract
EXIT=0
live marker after: FRESH   subdirs=0   old-exists=False   new-exists=False

--- AC1 half 2 (rebuilt fixture, bare Move-Item) ---
live rebuilt: marker=STALE
> Move-Item -LiteralPath ...\ac1_extract_staging2 -Destination ...\ac1_extract
moveitem-succeeded=True
live marker after: STALE
nested dir exists: ...\ac1_extract\ac1_extract_staging2 = True

--- AC2 ---
$fs = [System.IO.File]::Open('...\ac2_extract_staging\keep.txt','Open','Read','ReadWrite')
> tools\publish-extract.ps1 -Name ac2_extract ...
publish failed, restored previous extract: Exception calling "Move" with "2" argument(s): "Access to the path '...\ac2_extract_staging' is denied."
EXIT=1
row count after: 7   live.old exists: False

--- AC3 ---
case 1 (missing role):        invalid sidecar: missing required field 'role'                                  EXIT=3
case 2 (sidecar_version set): invalid sidecar: 'sidecar_version' is stamped by publish-extract.ps1 and must not be supplied   EXIT=3
case 3 (name mismatch):       invalid sidecar: name 'not_ac3_extract' does not match target directory name 'ac3_extract'      EXIT=3
case 4 (short source_rows):   invalid sidecar: source_rows has 1 elements, source_objects has 2                              EXIT=3
post-check: live still reads marker=original; staging dir never consumed.

--- AC4 (all 14) ---
a: FRESH
b: REFRESH (stale, source moved)
c: SKIPPED (source unchanged)
d: SKIPPED (ambiguous: last_altered moved, rows unchanged) age=91
e: REFRESH (ambiguous past ceiling)
f: REFRESH (forced)
g: SKIPPED (source unchanged)
h: SKIPPED (ambiguous: last_altered moved, rows unchanged) age=91
i: STALE (probe required) age=91 window=60 objects=DB.SCH.A
j: REFRESH (clock skew) age=-44
k: REFRESH (stale, source moved)
l: REFRESH (no sidecar)
m: SKIPPED (source unchanged)
n: REFRESH (malformed sidecar: name mismatch)

--- AC5 ---
> tools\extract-decide.ps1 -Name c_unchanged -ExtractRoot <decide> -CurrentRows 100,200 -CurrentLastAltered <same>
expected 1 values for 1 source objects, got 2
EXIT=2
> tools\extract-decide.ps1 -Name c_unchanged -ExtractRoot <decide> -CurrentRows abc -CurrentLastAltered <same>
invalid -CurrentRows value 'abc': expected an integer or the literal 'null'
EXIT=2

--- AC6 ---
project-id: c-users-woodsonp-claude-dev-duckdb-skills
extract root: C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
AC1 (list-extracts): headers present, EXIT=0
AC2 (empty root): no extracts registered under ...\fixtures\empty, EXIT=0
AC2 (absent root): extract whatever not found under ...\fixtures\absent, EXIT=2
AC3 (ages): now->0 (band 0-2), minus90->90 (band 89-93), minus1500->1500 (band 1499-1503)
AC8 (registry, .duckdb-skills\fixtures\ages root):
  name=now age_minutes=0 row_count=10 size_bytes=2819 bytes_check=AGREES
  name=size_mismatch age_minutes=10 row_count=1 size_bytes=380907 bytes_check=DISAGREES (declared 999999, on disk 380104)
  name=dt_projects age_minutes=45 row_count=42161 size_bytes=500849 bytes_check=AGREES
  name=ac6_far_window age_minutes=90 row_count=40 size_bytes=2854 bytes_check=AGREES
  name=ac6_short_window age_minutes=90 row_count=50 size_bytes=2858 bytes_check=AGREES
  name=minus90 age_minutes=90 row_count=20 size_bytes=2831 bytes_check=AGREES
  name=parent_projects age_minutes=90 row_count=15314 size_bytes=381002 bytes_check=AGREES
  name=minus1500 age_minutes=1500 row_count=30 size_bytes=2837 bytes_check=AGREES
  total_size_bytes=1276957
  --- delete parent_projects, re-run ---
  total_size_bytes=895955   (1276957 - 381002 = 895955, exact)
compat suite: raw 17/50, macro 34/50, polyglot 37/50, REGRESSION: none (zero regressions holds), EXIT=0

--- AC16 ---
description block (4 content lines):
  Materialize a named Snowflake query as local Parquet, tracked by a sidecar
  that records row-count and last-altered baselines. Reads check the registry
  first and re-pull silently only when stale, via a two-stage row/last_altered
  check that costs no warehouse compute when nothing changed.
> git diff --name-only --diff-filter=A main...HEAD -- skills/
skills/snowflake-extract/SKILL.md

--- AC17 ---
> tools\publish-extract.ps1 -Name ac17_extract -StagingDir ...\ac17_extract_staging -SidecarPath ...\ac17_sidecar.json -ExtractRoot ...\fixtures\publish
published ...\fixtures\publish\ac17_extract
publish-exit=0
> tools\extract-status.ps1 -Name ac17_extract -ExtractRoot ...\fixtures\publish
0
window: 60
verdict: FRESH
size: 962 bytes
status-exit=0
identical(-ceq): True
```

---

## AC8–AC14 re-run (unchanged in substance, verbatim SQL recorded per the round-2 rule)

All against `parent_projects` in the real extract root
(`C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts`), which
this round re-materialized fresh (see AC7-R2/AC15-R2 below) — so these are genuinely fresh
re-runs, not a replay of round 1's numbers.

### AC8 — types survive — PASS

```sql
-- SQL (via duckdb, local, no Snowflake call)
SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM '<parent_projects>/*.parquet')
WHERE column_name = 'PARENT_ACTUAL_START'
```
```
column_name,column_type
PARENT_ACTUAL_START,DATE
```

### AC9 — freshly materialized extract reads age 0/1, not 300 — PASS

```
> tools\extract-status.ps1 -Name parent_projects
1
window: 60
verdict: FRESH
size: 521823 bytes
```

### AC10 — stage 1 skips against unchanged source, at no warehouse cost — PASS

Backdated `parent_projects`' `materialized_at` to 90 minutes in the past (the one permitted
fixture edit — no other field touched):

```
> tools\extract-decide.ps1 -Name parent_projects
STALE (probe required) age=90 window=60 objects=DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS
```

Probed exactly that one object:

```sql
SELECT CONVERT_TIMEZONE('UTC', LAST_ALTERED) AS LAST_ALTERED_UTC
FROM DB_CONTROL_TOWER.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SCH_PROJECT_OPERATIONS' AND TABLE_NAME = 'DT_PARENT_PROJECTS'
-- -> 2026-09-24 18:47:58.489 +0000

SHOW TABLES LIKE 'DT_PARENT_PROJECTS' IN SCHEMA DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS
-- -> rows=15314, bytes=1042944
```

Sidecar baseline vs live, side by side:

| | value |
|---|---|
| sidecar `source_last_altered[0]` | `2026-09-24T18:47:58Z` |
| live `LAST_ALTERED` (this probe) | `2026-09-24 18:47:58.489 +0000` |

Identical to the second; rows also unchanged (15314 = 15314).

```
> tools\extract-decide.ps1 -Name parent_projects -CurrentRows 15314 -CurrentLastAltered "2026-09-24T18:47:58Z"
SKIPPED (source unchanged)
```

Cost evidence:

```sql
SELECT QUERY_ID, QUERY_TYPE, WAREHOUSE_SIZE, BYTES_SCANNED
FROM TABLE(DB_CONTROL_TOWER.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE QUERY_TYPE = 'SHOW' ORDER BY START_TIME DESC LIMIT 1
```

| query | `QUERY_ID` | `QUERY_TYPE` | `WAREHOUSE_SIZE` | `BYTES_SCANNED` |
|---|---|---|---|---|
| this AC10 `SHOW` probe | `01c74a6c-0b16-4c5e-0001-c316807b9dd6` | `SHOW` | *(empty)* | **0** |
| AC7-R2's `dt_projects` `COPY INTO` (for comparison) | `01c74a63-0b16-4c4d-0001-c316807b18de` | `UNLOAD` | `X-Small` | nonzero |

### AC11 — window bounds frequency — PASS

Run immediately after AC12's forced refresh (see below), which rewrites `materialized_at`:

```
> tools\extract-decide.ps1 -Name parent_projects
FRESH
exit=0
```
No Snowflake call under any path leading to `FRESH` (structural: `extract-decide.ps1` contains no
Snowflake-calling code, and none was made).

### AC12 — `DSK_FORCE=1` re-pulls a fresh extract — PASS

Decision:
```
> $env:DSK_FORCE='1'; tools\extract-decide.ps1 -Name parent_projects
REFRESH (forced)
```
The pull:
```sql
COPY INTO @~/duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/parent_projects__ac12force/
FROM (SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS)
FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE
-- -> rows_unloaded=15314, output_bytes=517984
```
```
GET -> 7 x DOWNLOADED
duckdb count(*) on staging -> 15314   (matches rows_unloaded)
tools\publish-extract.ps1 ... -> published, exit 0
REMOVE -> 7 x removed
```

### AC13 — a failed re-pull does not serve stale data — PASS

```sql
COPY INTO @~/duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/ac13_failure_test/
FROM (SELECT * FROM DT_PARENT_PROJECTS_NOT_QUALIFIED)
FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE
-- -> Error: SQL compilation error: Object 'DT_PARENT_PROJECTS_NOT_QUALIFIED' does not exist or not authorized.
```
Age at the time of this attempt was **1** minute (from `extract-status.ps1` immediately before and
after); the literal message the skill would print is:
**`STALE: refresh failed, serving nothing; extract age 1 minutes`**

Previous extract confirmed intact, byte-for-byte unchanged:
```
before: 0 / FRESH / 518925 bytes
after:  1 / FRESH / 518925 bytes    <- size unchanged
```

### AC14 — `runtime_seconds` is sane or absent — PASS

Every sidecar written this round carries a positive `runtime_seconds`, traced to real queries:

| sidecar write | `runtime_seconds` | `QUERY_ID` | `TOTAL_ELAPSED_TIME` |
|---|---|---|---|
| AC7-R2 `dt_projects` materialize | 0.451 | `01c74a63-0b16-4c4d-0001-c316807b18de` | 451 ms |
| AC7-R2 `parent_projects` materialize | 0.470 | `01c74a63-0b16-4c5e-0001-c316807b5082` | 470 ms |
| AC15-R2 `parent_projects` re-materialize (after delete) | 0.441 | `01c74a6a-0b16-4999-0001-c316807b7d6a` | 441 ms |
| AC12 `parent_projects` forced re-pull | 0.677 | `01c74a6d-0b16-4c4d-0001-c316807ba48a` | 677 ms |

None negative, none from a non-`SUCCESS` query.

---

## AC7-R2 — materialize both pinned objects, including the TZ one

### `parent_projects` over `DT_PARENT_PROJECTS` — unchanged `SELECT *`

```sql
SHOW TABLES LIKE 'DT_PARENT_PROJECTS' IN SCHEMA DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS
-- rows=15314, bytes=1043456

COPY INTO @~/duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/parent_projects__473fa438/
FROM (SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS)
FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE
-- rows_unloaded=15314, output_bytes=521096
```
`GET` → 8 × DOWNLOADED. `duckdb count(*)` on staged Parquet → **15314**.

### `dt_projects` over `DT_PROJECTS` — the generated TZ-aware projection

**Column inventory driving the decision** (measured this session, database-qualified —
bare `INFORMATION_SCHEMA` fails `invalid identifier` on this connection):

```sql
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE
FROM DB_CONTROL_TOWER.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'SCH_PROJECT_OPERATIONS' AND TABLE_NAME = 'DT_PROJECTS'
ORDER BY ORDINAL_POSITION
```
→ **107 rows**. Two are `TIMESTAMP_LTZ`: `START_DATE` (ordinal 75), `FINISH_DATE` (ordinal 76).
(See the discrepancy note at the top of this file re: the spec's stated 113.)

**The generated projection SQL in full** — first column `"PROJECT_NUMBER"`, last column
`"REVISED_CONTRACT_VALUE"`:

```sql
SELECT "PROJECT_NUMBER",
       "PARENT_PROJECT_NUMBER",
       "MASTER_PROJECT_NUMBER",
       "PROCORE_SOURCE",
       "PROCORE_PROJECT_NUMBER",
       "ROLLUP_PROJECT_NUMBER",
       "ROLLUP_PROJECT_NUMBER_COMPLETE",
       "ROLLUP_PARENT_PROJECT_NUMBER_COMPLETE",
       "PROJECT_DESCRIPTION",
       "DESCRIPTION_02",
       "DESCRIPTION_03",
       "PARENT_PROJECT_NAME",
       "MASTER_PROJECT_NAME",
       "PROJECT_ACCOUNTANT",
       "COMPANY",
       "COMPANY_NAME",
       "COMPANY_ROLLUP",
       "COMPANY_ROLLUP_NAME",
       "WIP_STATUS",
       "CAPITALIZED_PREBID",
       "POSTING_EDIT_BUSINESS_UNIT",
       "BUSINESS_UNIT_CODE",
       "BUSINESS_UNIT",
       "BUSINESS_UNIT_ROLLUP",
       "BUSINESS_UNIT_ROLLUP_NAME",
       "AR_AGING_FLAG",
       "PROJECT_CONTRACT",
       "BONDED_FLAG",
       "LEVEL_OF_DETAIL",
       "REGION",
       "AR_INVOICE_DUE_DATE",
       "AR_INVOICE_DAY_BILL_DUE",
       "PROJECT_TYPE",
       "PROJECT_TYPE_NAME",
       "CLAYCO_JOB",
       "INSURANCE_CHARGE",
       "INSURANCE_COVERAGE",
       "SUBGUARD",
       "BILLING_RATES",
       "PLANNED_START_DATE",
       "ACTUAL_START_DATE",
       "PLANNED_COMPLETE_DATE",
       "ACTUAL_COMPLETE_DATE",
       "CUSTOMER_NUMBER",
       "DEVELOPER_NUMBER",
       "DEVELOPER_NAME",
       "PARENT_WIP_STATUS",
       "PARENT_CAPITALIZED_PREBID",
       "PARENT_LEVEL_OF_DETAIL",
       "PARENT_PROJECT_CONTRACT",
       "PARENT_PLANNED_START",
       "PARENT_ACTUAL_START",
       "PARENT_PLANNED_COMPLETE",
       "PARENT_ACTUAL_COMPLETE",
       "PARENT_BUSINESS_UNIT",
       "WIP_GROUP",
       "LAST_CLOSED_PERIOD_DATE",
       "PMI_SYSTEM",
       "PMI_SOURCE",
       "ALTERNATE_PROJECT_ID",
       "ALTERNATE_PROJECT_NUMBER",
       "PROGRAM_ID",
       "PROJECT_NAME",
       "ADDRESS1",
       "ADDRESS2",
       "STATE",
       "CITY",
       "ZIP_CODE",
       "COUNTRY",
       "GOOGLE_ADDRESS",
       "LONGITUDE",
       "LATITUDE",
       "MAP_CENTER",
       "PMWEB_PROJECT_TYPE",
       CONVERT_TIMEZONE('UTC', "START_DATE")::TIMESTAMP_NTZ AS "START_DATE",
       CONVERT_TIMEZONE('UTC', "FINISH_DATE")::TIMESTAMP_NTZ AS "FINISH_DATE",
       "PROJECT_MANAGER",
       "PROJECT_EXECUTIVE",
       "PROJECT_SUPERINTENDENTS",
       "CUSTOMER_NAME",
       "OWNER_COMPANY",
       "GENERAL_CONTRACTOR_COMPANY",
       "ARCHITECT_COMPANY",
       "SCOPE",
       "FINANCIAL_STATUS",
       "PROJECT_STATUS",
       "IS_ACTIVE",
       "PROJECT",
       "OPS_MANAGER_NAME",
       "OPS_EXECUTIVE_NAME",
       "PERCENT_BUYOUT_BASED_ON_AMOUNT",
       "PERCENT_BUYOUT_BASED_ON_COUNT",
       "BRIDGIT_SOURCE",
       "BRIDGIT_PROJECT_NUMBER",
       "CSI_PROJECT_MANAGER",
       "CSI_BUSINESS_REGION",
       "CSI_CONTRACT_TYPE",
       "CSI_CUSTOMER",
       "CSI_GENERAL_CONTRACTOR",
       "CSI_STATE_LOCATION",
       "CSI_ZIP_CODE",
       "CSI_TYPE",
       "CSI_MARKET_SECTOR",
       "CSI_A_D_O",
       "CSI_ACTIVE_FLAG",
       "ORIGINAL_CONTRACT_VALUE",
       "REVISED_CONTRACT_VALUE"
FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS
```

Written with `\n` as the only line separator (no `\r`), 3074 characters. This is exactly the
`query` field stored in the published sidecar (see AC19).

```sql
COPY INTO @~/duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/dt_projects__22187dbe/
FROM ( <the projection above> )
FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE
-- rows_unloaded=42167, output_bytes=5219637
```
`LIST` before `GET`: **8** files. `GET` → 8 × DOWNLOADED. `REMOVE` → 8 × removed.
`LIST @~/duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/` after both `REMOVE`s → **0 rows**
(confirmed by an empty result set).

**Three-way consistency, unconditional:**

| | `dt_projects` | `parent_projects` |
|---|---|---|
| `COPY INTO` `rows_unloaded` | **42167** | **15314** |
| sidecar `row_count` | **42167** | **15314** |
| `duckdb count(*)` on landed Parquet | **42167** | **15314** |

**Snapshots quoted, not asserted:** live `SHOW TABLES` this session read `DT_PROJECTS` at
rows=**42167**, bytes=7435776 (spec's most-recent prior snapshot: 42,167 also — no drift this
time) and `DT_PARENT_PROJECTS` at rows=**15314**, bytes=1043456→1042944 across two reads in this
session (rows stable, bytes moved — the same pattern round 1 already established for this table).
Directory holds more than one `.parquet` file in both cases (8 for `dt_projects`, 8 then 7 for
`parent_projects` across its two materializes this round) — consistent with the spec's note that
the file count varies with unload parallelism.

---

## AC18 — TZ columns land as usable timestamps, at the right instant — PASS

```powershell
duckdb -csv -c "SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM '<dt_projects>/*.parquet') WHERE column_name IN ('START_DATE','FINISH_DATE')"
```
```
column_name,column_type
START_DATE,TIMESTAMP
FINISH_DATE,TIMESTAMP
```

```powershell
duckdb -csv -noheader -c "SELECT count(*) AS ncols FROM (DESCRIBE SELECT * FROM '<dt_projects>/*.parquet')"
```
```
107
```
**`ncols` (107) equals the row count of the `INFORMATION_SCHEMA.COLUMNS` query above (107).**
Exact match — no silent column loss.

**The instant, via an independent reference path** (three keys, `PROJECT_NUMBER` as the
identifying key — chosen because it is the table's natural business key and every row has one):

```sql
SELECT PROJECT_NUMBER, DATE_PART(EPOCH_SECOND, START_DATE) AS epoch_s
FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS
WHERE PROJECT_NUMBER IN ('10000986','10001043','10001169') ORDER BY PROJECT_NUMBER
```
```
PROJECT_NUMBER,EPOCH_S
10000986,1567746000
10001043,1459746000
10001169,1739426400
```
```powershell
duckdb -csv -c "SELECT PROJECT_NUMBER, epoch(START_DATE)::BIGINT AS epoch_s FROM '<dt_projects>/*.parquet' WHERE PROJECT_NUMBER IN ('10000986','10001043','10001169') ORDER BY PROJECT_NUMBER"
```
```
PROJECT_NUMBER,epoch_s
10000986,1567746000
10001043,1459746000
10001169,1739426400
```
**All three match exactly** — no multiple-of-3600 shift; the landed value is the correct instant,
not merely self-consistent (this reference path never reuses the extract's own
`CONVERT_TIMEZONE` expression — it uses `DATE_PART(EPOCH_SECOND, …)` on the Snowflake side against
DuckDB's `epoch()`, two independent implementations).

Plausibility:
```powershell
duckdb -csv -c "SELECT count(START_DATE) AS n_start, min(START_DATE) AS min_start, max(START_DATE) AS max_start FROM '<dt_projects>/*.parquet'"
```
```
n_start,min_start,max_start
6321,2013-11-01 05:00:00,2029-01-16 06:00:00
```
Non-zero count, plausible project-date range — not 1970, not all-NULL.

---

## AC19 — the projection is recorded, not lost — PASS

Reference other than the sidecar itself: extracted the exact `FROM ( … )` body from Snowflake's
own `QUERY_TEXT` for the `QUERY_ID` AC14 already quotes (`01c74a63-0b16-4c4d-0001-c316807b18de`),
via server-side `SUBSTR`/`MD5` rather than trusting this tool's markdown rendering (which
collapses embedded newlines in table cells and would give a false sense of a byte-level check):

```sql
WITH q AS (
  SELECT QUERY_TEXT FROM TABLE(DB_CONTROL_TOWER.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
  WHERE QUERY_ID = '01c74a63-0b16-4c4d-0001-c316807b18de'
)
SELECT
  SUBSTR(QUERY_TEXT, POSITION('FROM (' IN QUERY_TEXT) + 7, 3074) AS body,
  LENGTH(SUBSTR(QUERY_TEXT, POSITION('FROM (' IN QUERY_TEXT) + 7, 3074)) AS body_len,
  MD5(SUBSTR(QUERY_TEXT, POSITION('FROM (' IN QUERY_TEXT) + 7, 3074)) AS body_md5,
  SUBSTR(QUERY_TEXT, POSITION('FROM (' IN QUERY_TEXT) + 7 + 3074, 30) AS next_30_chars
FROM q
```
Result: `body_len = 3074`, `body_md5 = 305dc30966b8a5847b954ed54e2322d5`,
`next_30_chars = ' ) FILE_FORMAT = (TYPE = PARQU'` (confirming the body ends exactly where
expected, one space before the closing paren).

Independently, locally: the generated projection file (`.duckdb-skills\dt_projects_query.sql`,
never committed — gitignored scratch) is **3074 characters**, MD5
`305DC30966B8A5847B954ED54E2322D5` (case-insensitive identical to the Snowflake-side hash above),
and contains **no `\r`** (`Contains([char]13)` = `False`).

The published sidecar's `query` field, read back and compared with PowerShell's case-sensitive
`-ceq` against that same local file's content: **`True`**, length **3074**, no CRLF. So:

- **Sidecar `query`** = **Snowflake's own extracted `FROM(...)` body** = **the locally generated
  projection file** — all three identical (proven via matching length + MD5, not by re-pasting a
  3074-character string three times into this document). The full text is quoted once, above,
  under AC7-R2's "generated projection SQL in full" — that is the exact string all three of these
  are equal to.
- Sidecar `query` contains `CONVERT_TIMEZONE('UTC', "START_DATE")::TIMESTAMP_NTZ AS "START_DATE"`:
  **True**. Same for `FINISH_DATE`: **True**.

```
> tools\extract-status.ps1 -Name dt_projects
5
window: 60
verdict: FRESH
size: 5223915 bytes
```
First line **`5`** — numeric, not blank — round 1's CSV multi-line fix holding under a real
113-character-per-line, 107-column, genuinely multi-line `query` payload (3074 characters, ~107
lines), not the round-1 fixture's short hand-built multi-line string.

---

## AC20 — a non-TZ table is untouched by the new step — PASS

Tied to a fresh materialize this round (not the round-1 sidecar already on disk):

| | value |
|---|---|
| `materialized_at` before this round (round 1's sidecar, read at session start) | `2026-09-24T17:22:37Z` |
| `materialized_at` after this round's fresh materialize | `2026-09-24T18:51:23Z` |

**Later** — a real re-materialize happened, not a stale file satisfying the check by accident.

`query` in that fresh sidecar, exactly:
```
SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS
```
Fully qualified, no projection, no casts — matches byte-for-byte (this is the literal string
stored; round 1's `RESULT-1.md` abbreviated this when transcribing, this file does not).

Evidence that drove the decision:
```sql
SELECT TABLE_NAME, COUNT_IF(DATA_TYPE IN ('TIMESTAMP_TZ','TIMESTAMP_LTZ')) AS tz_col_count, COUNT(*) AS total_cols
FROM DB_CONTROL_TOWER.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'SCH_PROJECT_OPERATIONS' AND TABLE_NAME IN ('DT_PROJECTS','DT_PARENT_PROJECTS')
GROUP BY TABLE_NAME
```
```
TABLE_NAME,TZ_COL_COUNT,TOTAL_COLS
DT_PARENT_PROJECTS,0,12
DT_PROJECTS,2,107
```
**Zero** TZ columns for `DT_PARENT_PROJECTS` against **two** for `DT_PROJECTS` — the rule fires by
column type, distinguishable from special-casing two specific table names (the `SKILL.md` text
itself never names either table or either column — see below).

---

## AC15-R2 — the whole point, end to end — PASS

```
> tools\list-extracts.ps1
name=dt_projects age_minutes=4 row_count=42167 size_bytes=5223915 bytes_check=AGREES
name=parent_projects age_minutes=4 row_count=15314 size_bytes=522036 bytes_check=AGREES
total_size_bytes=5745951
```
Both listed by name, `bytes_check=AGREES` for both.

`dt_projects`' `parquet_glob` resolved **from the registry, by name** (not hard-coded):
```
$env:DSK_EXTRACT_DIR = '...\extracts\dt_projects'; $env:DSK_EXTRACT_NAME = 'dt_projects'
> duckdb -csv -f skills\snowflake-extract\registry.sql
-> parquet_glob = C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts\dt_projects/*.parquet
-> row_count = 42167
> duckdb -csv -noheader -c "SELECT count(*) FROM '<that glob>'"
42167
```
Registry's `row_count` and the glob's live count agree, **zero Snowflake calls** for this step.

**Deleted `parent_projects` specifically** (per the correction — `dt_projects` must survive):
```
> Remove-Item ...\extracts\parent_projects -Recurse -Force
> tools\list-extracts.ps1
name=dt_projects age_minutes=4 row_count=42167 size_bytes=5223915 bytes_check=AGREES
total_size_bytes=5223915
```
`parent_projects` gone; `dt_projects` intact and unaffected.

Re-materialized `parent_projects` (full cycle: `SHOW TABLES` → `COPY INTO` → `GET` → publish →
`REMOVE`; `rows_unloaded`=15314=local count=sidecar `row_count`). Final listing, both present:
```
> tools\list-extracts.ps1
name=parent_projects age_minutes=0 row_count=15314 size_bytes=521823 bytes_check=AGREES
name=dt_projects age_minutes=5 row_count=42167 size_bytes=5223915 bytes_check=AGREES
total_size_bytes=5745738
```
No leftover `.old`/`.new` directories anywhere under the extract root (checked explicitly —
`Get-ChildItem -Directory -Filter "*.old"` / `"*.new"` both empty).

---

## The `SKILL.md` new section, quoted verbatim

This replaces the old materialize step 3→4 boundary; steps renumbered 4→9. Nothing else in the
file changed (`git diff --stat -- skills/snowflake-extract/` shows only this one file, 41
insertions / 7 deletions):

```markdown
4. **Determine the query -- never issue a blind `SELECT *` without checking first.**
   `COPY INTO ... FILE_FORMAT=(TYPE=PARQUET)` refuses to unload `TIMESTAMP_TZ` or
   `TIMESTAMP_LTZ` columns, so the query must be built, not assumed. This step
   applies to a whole-object `SELECT * FROM <object>` with exactly one entry in
   `source_objects`; for a hand-written or multi-object query the author supplies
   the projection and owns the same TZ risk described here.
   - Split the fully-qualified source object into `<db>`/`<sch>`/`<obj>` and query
     `<db>.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '<sch>' AND
     TABLE_NAME = '<obj>' ORDER BY ORDINAL_POSITION`. **Bare `INFORMATION_SCHEMA`
     fails `invalid identifier` on this connection** -- qualify with `<db>`, same
     trap as `QUERY_HISTORY_BY_SESSION` below.
   - If no column has `DATA_TYPE IN ('TIMESTAMP_TZ','TIMESTAMP_LTZ')`, the query
     stays `SELECT * FROM <object>` -- unchanged for the common case.
   - Otherwise build an explicit column list **in ordinal order** (this is what
     makes the projection produce the same column set `SELECT *` would have):
     every TZ/LTZ column projects as
     `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"`; every other
     column is named plainly. **Every column name is emitted double-quoted, in
     both forms.** `COLUMN_NAME` comes back from `INFORMATION_SCHEMA.COLUMNS`
     without its own quotes, so a bare identifier is a syntax error on a reserved
     word or on any column actually created as a quoted identifier; double any
     `"` that appears inside a `COLUMN_NAME`.
   - **The resulting DuckDB type is a naive `TIMESTAMP` holding UTC**, not
     `TIMESTAMPTZ` -- the same discipline as `materialized_at` applies: compare
     against `timezone('UTC', now())`, never `now()`.
   - **Re-derive the projection on every materialize, including every refresh --
     never replay a stored column list.** An upstream column added after the
     first materialize (including a new TZ column) would be silently dropped
     otherwise. The extract's identity is its `name`, never its query text.
   - **If `COPY INTO` still fails with a type-unload error after projection, stop
     and report the column and its type. Do not widen the cast to make it pass.**
     A TZ column nested inside another type is not caught by the check above,
     and this is what turns that miss into a loud stop instead of a silent one.
```

The text names no table and no column — `START_DATE`, `FINISH_DATE`, `DT_PROJECTS` appear nowhere
in `SKILL.md`. The rule is stated purely by `DATA_TYPE IN ('TIMESTAMP_TZ','TIMESTAMP_LTZ')`.

`git diff -- skills/snowflake-extract/SKILL.md` (full): 41 insertions, 7 deletions, entirely
within the renumbered materialize step 3→9 block; the frontmatter, the Read section, the
freshness-window section, and the stage-collision section are byte-for-byte unchanged.

---

## Known gap, recorded rather than closed

**Unchanged from round 1, still true:** every `extract-decide.ps1` fixture
(`tools\make-decide-fixtures.ps1`) is single-object, so the multi-object stage-1/stage-2 rule and
round 1's `@(… | ConvertFrom-Json)` nesting fix have **no passing evidence**. This round did not
add multi-object fixtures (out of scope per the correction's own scope note), so the gap persists
into round 3 if a future round needs it.

## Deviations

- **`INFORMATION_SCHEMA.COLUMNS` measured 107 columns for `DT_PROJECTS`, not the spec's stated
  113.** Reported above rather than adjusting AC18's `ncols` check to a hard-coded number — the
  check compares against the **live** query result, so it is self-consistent regardless of which
  number is "right", but the spec's own narrative text is stale.
- **AC19's "two query strings in full" is satisfied by quoting the string once** (it is the same
  3074-character string on both sides, proven identical by length + MD5 rather than by re-pasting
  it three times) rather than printing it twice verbatim. The full text appears once, under AC7-R2.
- **AC10/AC12/AC13/AC15-R2 all operated on `parent_projects`**, per the correction's explicit
  requirement that `dt_projects` survive the round untouched after AC7-R2/AC18/AC19 read it.
  `dt_projects` was never re-materialized, backdated, or force-refreshed after its single AC7-R2
  materialize — confirmed still present with its original `row_count`=42167 in the final AC15-R2
  listing.
- Round 1's three accepted deviations (absolute `-ExtractRoot`, the reader `try/catch`, the
  publish exit-1/exit-2 classes) are contract per the round-2 handoff and are not re-adjudicated
  or re-reported here.

## Not done

Nothing in this round's scope was left undone. The multi-object gap above is a pre-existing,
explicitly-deferred gap, not an incomplete round-2 deliverable.

## Concerns

- `DT_PROJECTS`' column count itself now appears to drift (113 → 107) in addition to its
  previously-noted row-count drift (42,161 → 42,162 → 42,167). If a future round needs a
  byte-exact schema contract against this table (e.g. for item 6's manifest or item 8's join),
  the column set should be re-measured at that time rather than trusted from either round's
  narrative text.
- The generated projection query is 3074 characters / ~107 lines. `registry.sql`'s CSV output
  (and the multi-line-query reader fix from round 1) both held up under this real payload (AC19's
  `extract-status.ps1 -Name dt_projects` printed a clean numeric first line), but this is the
  first time that fix has been exercised against a payload this large — worth remembering if a
  future table has an even wider projection.
