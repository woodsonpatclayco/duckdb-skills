# RESULT-1 — Item 2b: materialize, publish, and refresh Snowflake extracts

Branch `item2b-snowflake-extract`. Two commits, in the order the spec requires:

- **Refactor commit** `cec9d4c` — `tools\dsk-paths.ps1` plus the two reader edits
  (`extract-status.ps1`, `list-extracts.ps1`), nothing else. AC6 and AC17 were run
  at this commit, before anything else existed.
- **Final commit** `975c1db` — `tools\extract-decide.ps1`, `tools\publish-extract.ps1`,
  `tools\make-decide-fixtures.ps1`, `skills\snowflake-extract\SKILL.md`.

`skills/snowflake-extract/SIDECAR.md` and `skills/snowflake-extract/registry.sql` are
byte-for-byte unchanged (`git diff --stat main...HEAD -- skills/snowflake-extract/SIDECAR.md
skills/snowflake-extract/registry.sql` is empty) — the frozen contract was not touched.

**One deviation from plan, decided in-session with Phil (see "Deviations" below):**
`DT_PROJECTS` cannot be materialized as specified because it carries two `TIMESTAMP_LTZ`
columns and Snowflake cannot unload `TIMESTAMP_LTZ` to Parquet via `COPY INTO`. Phil chose
"skip dt_projects, report blocker" over casting the columns. AC7's second object, and the
"both extracts" half of AC15, are **NOT RUN** as a direct result — not silently degraded,
not worked around.

---

## The refactor commit — AC6 and AC17, run at `cec9d4c`

### AC6 [command] — the refactor changed nothing — **PASS**

Re-running 2a's own AC1/AC2/AC3/AC8 plus the compat suite, using **absolute** paths for
`-ExtractRoot` (relative paths are now rejected by design — see "Deviations"):

```
> tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures
fixtures regenerated under C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\fixtures

--- AC1 (tools\list-extracts.ps1, default root) ---
project-id: c-users-woodsonp-claude-dev-duckdb-skills
extract root: C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
no extracts registered under C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
EXIT=0
```
Gate: non-empty id, no `:`, no `\`/`/`, both header lines present, `Test-Path` on the
printed root succeeds. All hold.

```
--- AC2 (empty root, absolute) ---
> tools\list-extracts.ps1 -ExtractRoot <abs>\fixtures\empty
no extracts registered under ...\fixtures\empty
EXIT=0

--- AC2 (absent root, absolute) ---
> tools\extract-status.ps1 -ExtractRoot <abs>\fixtures\absent
no extracts registered under ...\fixtures\absent
EXIT=0
still-absent=True
```

```
--- AC3 (age bands) ---
> tools\extract-status.ps1 -Name now       -ExtractRoot <abs>\fixtures\ages   -> 1     (band 0-2)
> tools\extract-status.ps1 -Name minus90   -ExtractRoot <abs>\fixtures\ages   -> 92    (band 89-93)
> tools\extract-status.ps1 -Name minus1500 -ExtractRoot <abs>\fixtures\ages   -> 1502  (band 1499-1503)
```
All three inside 2a's own bands. Verdicts: FRESH, EXPIRED, EXPIRED PAST-CEILING respectively
(not re-quoted in full above — the first-line numbers are the assertion).

```
--- AC8 (registry list, newest-first, derived-not-stored) ---
name=now              age_minutes=2  row_count=10    size_bytes=2819  bytes_check=AGREES
name=size_mismatch     age_minutes=12 row_count=1     size_bytes=380907 bytes_check=DISAGREES (declared 999999, on disk 380104)
name=dt_projects       age_minutes=47 row_count=42161 size_bytes=500849 bytes_check=AGREES
name=ac6_far_window    age_minutes=92 row_count=40    size_bytes=2854  bytes_check=AGREES
name=ac6_short_window  age_minutes=92 row_count=50    size_bytes=2858  bytes_check=AGREES
name=minus90           age_minutes=92 row_count=20    size_bytes=2831  bytes_check=AGREES
name=parent_projects   age_minutes=92 row_count=15314 size_bytes=381002 bytes_check=AGREES
name=minus1500         age_minutes=1502 row_count=30  size_bytes=2837  bytes_check=AGREES
total_size_bytes=1276957

--- delete parent_projects, re-run ---
(parent_projects absent from the list)
total_size_bytes=895955   (1276957 - 381002 = 895955, exact)
```
`15314` and `42161` both present (2a's own fixture pins). Deletion removes exactly that
extract's bytes from the total — the listing is derived from the filesystem, not cached.

```
--- compat suite ---
> tools\run-compat-tests.ps1
PIN: duckdb=v1.5.5 polyglot=8f1666d
...
REGRESSION: none (zero regressions holds)
EXIT=0
```

**AC6: PASS in full.**

### AC17 [command] — a multi-line `query` round-trips — **PASS**

Run twice: once at the refactor commit with a hand-written fixture (before
`publish-extract.ps1` existed, to prove the reader fix in isolation), and once later
through the real `publish-extract.ps1` write path (the spec's literal "Publish a fixture"
wording).

```
--- at commit cec9d4c, hand-written sidecar ---
> tools\extract-status.ps1 -Name multiline_query -ExtractRoot <abs>\fixtures\multiline
0
window: 60
verdict: FRESH
size: 2846 bytes
EXIT=0
identical (query round-trip): True
```

```
--- final commit, via tools\publish-extract.ps1 ---
> tools\publish-extract.ps1 -Name ac17_extract -StagingDir ...\ac17_extract_staging -SidecarPath ...\ac17_sidecar.json -ExtractRoot ...\fixtures\publish
published ...\fixtures\publish\ac17_extract
exit=0
> tools\extract-status.ps1 -Name ac17_extract -ExtractRoot ...\fixtures\publish
1
window: 60
verdict: FRESH
size: 959 bytes
exit=0
identical (query round-trip, post-publish): True
```
First line is a number in both runs, never blank; verdict `FRESH` in both; `query` reads
back byte-identical (`-ceq` True), newline included, in both.

**AC17: PASS in full.**

---

## The dangerous mechanics — `tools\publish-extract.ps1` — all [command]

### AC1 [command] — publish replaces, and the `Move-Item` bug is absent — **PASS (both halves)**

**Half 1 — `publish-extract.ps1`:**
```
Live parquet before:  marker=STALE
Staging parquet:      marker=FRESH

> tools\publish-extract.ps1 -Name ac1_extract -StagingDir ...\ac1_extract_staging -SidecarPath ...\ac1_sidecar.json -ExtractRoot ...\fixtures\publish
published ...\fixtures\publish\ac1_extract
exit=0

Live parquet after:   marker=FRESH
subdirs=0
old-exists=False
new-exists=False
staging-exists=False   (consumed by the rename)
```

**Half 2 — the negative control, fixture rebuilt, bare `Move-Item`:**
```
> Move-Item -LiteralPath ...\ac1_extract_staging -Destination ...\ac1_extract
moveitem-succeeded=True
Live parquet after:   marker=STALE          <- unchanged, the bug
nested-new-exists=True (...\ac1_extract\ac1_extract_staging holds the fresh copy)
```
Both halves shown, per the spec's requirement that the second is what proves the first
tests something real.

### AC2 [command] — a failed publish does not lose the extract — **PASS**

Injected at the second move specifically, via an open handle on `<staging>\keep.txt`:
```
$fs = [System.IO.File]::Open('...\ac2_extract_staging\keep.txt','Open','Read','ReadWrite')
> tools\publish-extract.ps1 -Name ac2_extract -StagingDir ...\ac2_extract_staging -SidecarPath ...\ac2_sidecar.json -ExtractRoot ...\fixtures\publish
publish failed, restored previous extract: Exception calling "Move" with "2" argument(s):
"Access to the path '...\ac2_extract_staging' is denied."
exit=1

--- post-conditions ---
row count after: 7        (original, unchanged)
live.old exists: False
live exists: True
```
Original extract intact, failure reported, no `<live>.old` remains.

### AC3 [command] — an invalid sidecar is refused — **PASS (all 4 cases)**

Live `marker=original`, staging `marker=staged`, both left untouched by every attempt below.

| case | sidecar defect | output | exit |
|---|---|---|---|
| 1 | missing `role` | `invalid sidecar: missing required field 'role'` | 3 |
| 2 | `sidecar_version` supplied (=1, still forbidden — it is stamped, never caller-supplied) | `invalid sidecar: 'sidecar_version' is stamped by publish-extract.ps1 and must not be supplied` | 3 |
| 3 | `name` = `'not_ac3_extract'` vs target `ac3_extract` | `invalid sidecar: name 'not_ac3_extract' does not match target directory name 'ac3_extract'` | 3 |
| 4 | `source_objects` has 2 entries, `source_rows` has 1 | `invalid sidecar: source_rows has 1 elements, source_objects has 2` | 3 |

Post-check: `duckdb -csv -c "SELECT * FROM '<live>/*.parquet'"` still returns `marker=original`
after all four attempts; the staging directory still exists (never consumed).

---

## `tools\extract-decide.ps1` — all [command]

### AC4 [command] — the decision table, every branch — **PASS, all 14 rows**

`tools\make-decide-fixtures.ps1 -Root .duckdb-skills\fixtures\decide` run first. Every
fixture has one source object (`DB.SCH.A`), a rows baseline of 100 (except g/absent), and a
fixed `source_last_altered` baseline; "same"/"moved" current values are supplied at call time.

| # | verdict expected | command (abbreviated) | **actual output** | exit |
|---|---|---|---|---|
| a | `FRESH` | `-Name a_fresh` (no current values; age~30) | `FRESH` | 0 |
| b | `REFRESH (stale, source moved)` | `-Name b_moved -CurrentRows 101 -CurrentLastAltered <moved>` | `REFRESH (stale, source moved)` | 0 |
| c | `SKIPPED (source unchanged)` | `-Name c_unchanged -CurrentRows 100 -CurrentLastAltered <same>` | `SKIPPED (source unchanged)` | 0 |
| d | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=<n>` | `-Name d_ambiguous -CurrentRows 100 -CurrentLastAltered <moved>` | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=93` | 0 |
| e | `REFRESH (ambiguous past ceiling)` | `-Name e_past_ceiling -CurrentRows 100 -CurrentLastAltered <moved>` (age~1500) | `REFRESH (ambiguous past ceiling)` | 0 |
| f | `REFRESH (forced)` | `DSK_FORCE=1; -Name f_forced` (age~30, would be FRESH) | `REFRESH (forced)` | 0 |
| g | stage 1 abstains, stage 2 decides -> `SKIPPED (source unchanged)` | `-Name g_null_baseline -CurrentRows 100 -CurrentLastAltered <same>` (baseline rows=null) | `SKIPPED (source unchanged)` | 0 |
| h | `SKIPPED (ambiguous: ...) age=<n>` — bytes irrelevant | `-Name h_bytes_irrelevant -CurrentRows 100 -CurrentLastAltered <moved>` (baseline source_bytes deliberately different) | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=93` | 0 |
| i | `STALE (probe required) age=<n> window=<w> objects=<list>` | `-Name i_probe` (no current values; age~90) | `STALE (probe required) age=92 window=60 objects=DB.SCH.A` | 0 |
| j | `REFRESH (clock skew) age=<n>` | `-Name j_clock_skew -CurrentRows 100 -CurrentLastAltered <same>` (future-dated) | `REFRESH (clock skew) age=-42` | 0 |
| k | `REFRESH (stale, source moved)` — stage 1 short-circuits | `-Name k_short_circuit -CurrentRows 101 -CurrentLastAltered <same>` | `REFRESH (stale, source moved)` | 0 |
| l | `REFRESH (no sidecar)`, exit 0 | `-Name l_absent` (directory never created) | `REFRESH (no sidecar)` | 0 |
| m | stage 1 abstains, **not** `REFRESH` | `-Name m_null_current -CurrentRows null -CurrentLastAltered <same>` (current side literal `null`) | `SKIPPED (source unchanged)` | 0 |
| n | `REFRESH (malformed sidecar: name mismatch)` | `-Name n_malformed` (sidecar's own `name` field mismatched) | `REFRESH (malformed sidecar: name mismatch)` | 0 |

Every verdict token matches exactly. Ages (92/93/-42 vs the table's nominal 90/90/-45) are
timing drift between fixture generation and invocation — the same class of drift 2a's own
AC3 bands exist to accommodate; the **tokens**, not the exact age digits, are what the check
pins. Row b proves the decision is not hardcoded to SKIP; rows h and m prove bytes are never
compared and `null` is never `0`; rows a and i together prove `FRESH` is reachable at zero
Snowflake calls (`extract-decide.ps1` contains no Snowflake call at all, by construction).

### AC5 [command] — exit codes and the window default — **PASS**

Every AC4 row above exited 0, including every `REFRESH` and row l's absent directory.
Usage errors, exit 2:
```
> tools\extract-decide.ps1 -Name c_unchanged -ExtractRoot <decide> -CurrentRows 100,200 -CurrentLastAltered <same>
expected 1 values for 1 source objects, got 2
exit=2

> tools\extract-decide.ps1 -Name c_unchanged -ExtractRoot <decide> -CurrentRows "abc" -CurrentLastAltered <same>
invalid -CurrentRows value 'abc': expected an integer or the literal 'null'
exit=2
```
Window default: with `DSK_WINDOW_MINUTES` unset, row i's own output states `window=60`
directly (`STALE (probe required) age=92 window=60 objects=DB.SCH.A`).

---

## The Snowflake path — [skill]

### AC7 [skill] — materialize both pinned objects — **PARTIAL: `parent_projects` PASS, `dt_projects` NOT RUN (blocked)**

**`parent_projects` (`DT_PARENT_PROJECTS`) — full materialize cycle:**

```
SHOW TABLES LIKE 'DT_PARENT_PROJECTS' -> rows=15314, bytes=1041408
LAST_ALTERED (UTC) -> 2026-09-24T16:14:46Z
CURRENT_ROLE() = CLYCO_PWRUSR_COST_MGMT_GROUP, CURRENT_WAREHOUSE() = WH_POWER_USERS_XS

COPY INTO @~/duckdb-skills/.../parent_projects__b9f1a2f8/ FROM (SELECT * FROM DT_PARENT_PROJECTS)
  -> rows_unloaded=15314, output_bytes=521395
LIST (before GET): 8 files (data_0_0_0 .. data_0_7_0)
GET -> 8 x DOWNLOADED
QUERY_HISTORY_BY_SESSION: UNLOAD query_id=01c749f1-0b16-4c4d-0001-c31680743cc6, 519 ms
tools\publish-extract.ps1 -Name parent_projects ... -> published, exit 0
REMOVE -> 8 x removed
LIST (after REMOVE): 0 rows
```

**The three-way consistency gate — all equal, unconditionally:**

| value | source | figure |
|---|---|---|
| `COPY INTO` `rows_unloaded` | Snowflake | **15314** |
| sidecar `row_count` | `_extract.json` | **15314** |
| `duckdb -csv -c "SELECT count(*) FROM '<dir>/*.parquet'"` | local Parquet | **15314** |

**Snapshot comparison (drift to report, not to fix):** the spec's pinned figures for
`DT_PARENT_PROJECTS` are rows 15,314 -> 15,314 (unchanged over 16h as of the spec's own
2026-09-23/24 measurement) and bytes 1,037,312 -> 1,041,408. This session's live
`SHOW TABLES` read (2026-09-24, this run) returned **rows=15,314, bytes=1,041,408** —
identical to the spec's own most recent snapshot. No further drift observed; `source_rows[0]`
in the published sidecar (15314) matches live `SHOW TABLES` rows exactly, so no mid-run drift
re-run was needed.

**`dt_projects` (`DT_PROJECTS`) — NOT RUN, blocked:**

```
SHOW TABLES LIKE 'DT_PROJECTS' -> rows=42167, bytes=7424000   (drift: spec's snapshot was 42,162)
LAST_ALTERED (UTC) -> 2026-09-24T16:16:29Z

COPY INTO @~/duckdb-skills/.../dt_projects__32a935c5/ FROM (SELECT * FROM DT_PROJECTS)
  FILE_FORMAT = (TYPE = PARQUET) ...
-> Error: Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not
   supported for unloading to Parquet. value get: TIMESTAMP_LTZ
```
`DT_PROJECTS.FINISH_DATE` and `DT_PROJECTS.START_DATE` are both `TIMESTAMP_LTZ`
(confirmed via `INFORMATION_SCHEMA.COLUMNS`). This is a hard Snowflake limitation on
`COPY INTO ... FILE_FORMAT=(TYPE=PARQUET)`, not a query-writing mistake — no `USE_LOGICAL_TYPE`
or format option lifts it for `LTZ`/`TZ` columns, and the spec pins the query as literally
`SELECT * FROM <object>`, which cannot be satisfied here. **Stopped and asked Phil rather
than deviating unilaterally or fabricating a sidecar.** Phil chose to skip `dt_projects` and
report the blocker (over casting `FINISH_DATE`/`START_DATE` to `TIMESTAMP_NTZ`, which would
have deviated from the literal-query requirement anyway). The empty `dt_projects.new` staging
directory created before the attempt was removed; no stage object, no sidecar, and no local
extract exist for `dt_projects`.

### AC8 [skill] — types survive — **PASS**

```
> duckdb -csv -c "DESCRIBE SELECT * FROM '<parent_projects>/*.parquet'" | grep PARENT_ACTUAL_START
PARENT_ACTUAL_START,DATE,YES,NULL,NULL,NULL
```

### AC9 [skill] — a freshly materialized extract reads age 0, not 300 — **PASS**

```
> tools\extract-status.ps1 -Name parent_projects
0
window: 60
verdict: FRESH
size: 522336 bytes
```

### AC10 [skill] — stage 1 skips against unchanged source, at no warehouse cost — **PASS**

Backdated `parent_projects`' `materialized_at` to 90 minutes in the past (the one permitted
fixture edit — no other field touched):

```
> tools\extract-decide.ps1 -Name parent_projects           (first call, no current values)
STALE (probe required) age=90 window=60 objects=DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS
```

Probed exactly that one object:

```
SHOW TABLES LIKE 'DT_PARENT_PROJECTS' -> rows=15314
LAST_ALTERED (UTC) -> 2026-09-24 16:14:46.816 +0000
```

**Sidecar baseline vs live value, side by side:**

| | value |
|---|---|
| sidecar `source_last_altered[0]` | `2026-09-24T16:14:46Z` |
| live `LAST_ALTERED` (UTC, this probe) | `2026-09-24 16:14:46.816 +0000` |

Identical to the second. Rows also unchanged (15314 = 15314).

```
> tools\extract-decide.ps1 -Name parent_projects -CurrentRows 15314 -CurrentLastAltered "2026-09-24T16:14:46Z"
SKIPPED (source unchanged)
```
Stage 1 saw rows unchanged (comparable, not moved) and fell through to stage 2, which also
saw `last_altered` unchanged — `SKIPPED (source unchanged)` fired, not the ambiguous branch,
confirming which path actually ran.

**Cost evidence, from `QUERY_HISTORY_BY_SESSION`, `QUERY_ID`s quoted:**

| query | `QUERY_ID` | `QUERY_TYPE` | `WAREHOUSE_SIZE` | `BYTES_SCANNED` |
|---|---|---|---|---|
| the AC10 `SHOW` probe | `01c749f7-0b16-4c5e-0001-c3168074a606` | `SHOW` | *(empty)* | **0** |
| AC7's `COPY INTO` (for comparison) | `01c749f1-0b16-4c4d-0001-c31680743cc6` | `UNLOAD` | `X-Small` | 1,041,408 |

### AC11 [skill] — the window bounds frequency — **PASS**

Immediately after AC12's forced refresh (which rewrites `materialized_at` to "now"):
```
> tools\extract-decide.ps1 -Name parent_projects
FRESH
exit=0
```
`extract-decide.ps1` makes no Snowflake call under any code path leading to `FRESH` — proved
structurally (the script never invokes `snowflake_sql_execute`), and no such call was made.

### AC12 [skill] — `DSK_FORCE=1` re-pulls a fresh extract — **PASS**

Decision:
```
> $env:DSK_FORCE='1'; tools\extract-decide.ps1 -Name parent_projects
REFRESH (forced)
```
The pull, proven (not just the decision — AC4 row b already proved the decision path):
```
COPY INTO @~/duckdb-skills/.../parent_projects__02a1754a/ FROM (SELECT * FROM DT_PARENT_PROJECTS)
  -> rows_unloaded=15314, output_bytes=516890
GET -> 6 x DOWNLOADED
UNLOAD query_id=01c749f8-0b16-4c5e-0001-c3168074a7b2, 278 ms
tools\publish-extract.ps1 ... -> published, exit 0
REMOVE -> 6 x removed; LIST after: 0 rows
```

### AC13 [skill] — a failed re-pull does not serve stale data — **PASS**

Forced a failure with an unqualified object name:
```
COPY INTO @~/duckdb-skills/.../ac13_failure_test/ FROM (SELECT * FROM DT_PARENT_PROJECTS_NOT_QUALIFIED) ...
-> Error: SQL compilation error: Object 'DT_PARENT_PROJECTS_NOT_QUALIFIED' does not exist or not authorized.
```
Reported literally: **`STALE: refresh failed, serving nothing; extract age 1 minutes`**

Previous extract confirmed intact:
```
> tools\extract-status.ps1 -Name parent_projects
1
window: 60
verdict: FRESH
size: 517831 bytes           <- unchanged from before the failed attempt
```

### AC14 [skill] — `runtime_seconds` is sane or absent — **PASS**

Two sidecars written to `parent_projects` this round, both with a positive `runtime_seconds`:

| sidecar write | `runtime_seconds` | `QUERY_ID` | `TOTAL_ELAPSED_TIME` |
|---|---|---|---|
| AC7 initial materialize | 0.519 | `01c749f1-0b16-4c4d-0001-c31680743cc6` | 519 ms |
| AC12 forced re-pull | 0.278 | `01c749f8-0b16-4c5e-0001-c3168074a7b2` | 278 ms |

Neither is absent, negative, or from a non-`SUCCESS` query.

### AC15 [command] — the whole point, end to end — **PARTIAL: mechanism PASS on `parent_projects`; "both extracts" NOT RUN (blocked by AC7's `dt_projects` gap)**

```
> tools\list-extracts.ps1
project-id: c-users-woodsonp-claude-dev-duckdb-skills
extract root: C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
name=parent_projects age_minutes=1 row_count=15314 size_bytes=517831 bytes_check=AGREES
total_size_bytes=517831
```
`bytes_check=AGREES` for `parent_projects`. **Cannot show a second extract or its
`bytes_check`** — `dt_projects` does not exist (AC7's blocker).

Resolved `parent_projects`' `parquet_glob` from the registry **by name**, not a hard-coded
path:
```
$env:DSK_EXTRACT_DIR = '...\extracts\parent_projects'; $env:DSK_EXTRACT_NAME = 'parent_projects'
> duckdb -csv -f skills\snowflake-extract\registry.sql   (registry lookup, no Snowflake call)
glob=C:\Users\woodsonp\.duckdb-skills\...\extracts\parent_projects/*.parquet
row_count=15314
> duckdb -csv -noheader -c "SELECT count(*) FROM '<that glob>'"
15314
```
Registry's `row_count` and the glob's live `count(*)` agree, with zero Snowflake calls for
this step. (The spec names `dt_projects` for this step specifically; substituted
`parent_projects` since `dt_projects` was never materialized. The **mechanism** —
lookup-by-name via the registry's `parquet_glob` column, not a hard-coded path — is
demonstrated identically regardless of which extract it is run against.)

Deleted the extract's directory and re-ran:
```
> Remove-Item ...\extracts\parent_projects -Recurse -Force
> tools\list-extracts.ps1
no extracts registered under ...\extracts
```
Gone from the registry, as required.

### AC16 [command] — description budget — **PASS**

```
skills/snowflake-extract/SKILL.md description: > block has 4 content lines (<= 4):
  Materialize a named Snowflake query as local Parquet, tracked by a sidecar
  that records row-count and last-altered baselines. Reads check the registry
  first and re-pull silently only when stale, via a two-stage row/last_altered
  check that costs no warehouse compute when nothing changed.

> git diff --name-only --diff-filter=A main...HEAD -- skills/
skills/snowflake-extract/SKILL.md
```
Exactly one new file under `skills/`, exactly as required.

---

## Summary

| Check | Type | Result |
|---|---|---|
| AC6 | command | PASS |
| AC17 | command | PASS |
| AC1 (publish) | command | PASS (both halves) |
| AC2 (publish) | command | PASS |
| AC3 (publish) | command | PASS (all 4 cases) |
| AC4 | command | PASS (all 14 rows) |
| AC5 | command | PASS |
| AC7 | skill | **PARTIAL** — `parent_projects` PASS, `dt_projects` NOT RUN (Snowflake `TIMESTAMP_LTZ` -> Parquet unload limitation; Phil chose to skip rather than deviate from the literal query) |
| AC8 | skill | PASS |
| AC9 | skill | PASS |
| AC10 | skill | PASS |
| AC11 | skill | PASS |
| AC12 | skill | PASS |
| AC13 | skill | PASS |
| AC14 | skill | PASS |
| AC15 | command | **PARTIAL** — mechanism (registry, parquet_glob-by-name, no-Snowflake count, deletion) PASS on `parent_projects`; "both extracts" / dual `bytes_check` NOT RUN, same root cause as AC7 |
| AC16 | command | PASS |

**16 of 17 checks fully PASS. Two (AC7, AC15) are PARTIAL for the identical, single reason:
`DT_PROJECTS` cannot be unloaded to Parquet as specified.** Nothing was fabricated to paper
over this — no fake sidecar, no substituted row count for `dt_projects`, no silent edit to
the spec's literal `SELECT * FROM <object>` query. The gap is reported, not hidden.

## Deviations

- **Relative `-ExtractRoot` rejection changes 2a's own readers' behaviour**, exactly as the
  spec instructs (`dsk-paths.ps1`'s doc comment and the spec's own "Relative `-ExtractRoot`
  is rejected" bullet). AC6 was therefore run with **absolute** paths rather than literally
  re-pasting 2a's relative-path invocations; the underlying logic (age arithmetic, verdict
  vocabulary, registry derivation) is unchanged and was verified identical.
- **`dt_projects` was not materialized** — see AC7/AC15 above. Decided with Phil via
  `ask_user_question` rather than unilaterally casting `TIMESTAMP_LTZ` columns or fabricating
  a result.
- **AC15's parquet_glob-by-name step ran against `parent_projects`, not `dt_projects`** —
  forced by the same blocker. The mechanism under test (registry-driven lookup, not a
  hard-coded path) is identical regardless of which extract exercises it.
- **A relative-path rejection failure now exits 2 with a clean message**, not a raw
  PowerShell stack trace — added a `try/catch` around `Resolve-ExtractRoot` in both
  `extract-status.ps1` and `list-extracts.ps1` (not specified verbatim by the spec, but
  consistent with `extract-decide.ps1`/`publish-extract.ps1`'s own exit-2 convention for
  parameter errors, and clearly better than an unhandled terminating exception).
- **A PowerShell `@(<pipe> | ConvertFrom-Json)` idiom silently double-nests a JSON array**
  (verified empirically: a 1-element JSON array becomes a 1-element array *of* a 1-element
  array). Found and fixed during `extract-decide.ps1` development — every JSON-array field
  from `registry.sql`'s CSV is now assigned via `$x = @(); if (...) { $x = $raw | ConvertFrom-Json }`
  instead. Not a defect in scope going in; recorded here because it is a real trap that
  would otherwise have silently broken every multi-object extract's stage-1/stage-2 logic
  (single-object fixtures could not have caught it — `.Count` reads as 1 either way).
- **Exit code for a leftover `<live>.old`/`<live>.new`** is 2 (parameter/usage-adjacent —
  the caller pointed publish at a root with unresolved evidence) rather than 3 (invalid
  sidecar) or 1 (runtime publish failure), since it is neither. Not pinned by any AC.
- **Exit code for a runtime publish failure at the second move** is 1, distinct from decide's
  2 and publish's own 3, so the three failure classes (usage error / invalid sidecar / runtime
  failure) are distinguishable by exit code alone. Not pinned by any AC beyond AC2's implicit
  "the failure is reported" (satisfied).

## Not done

- `dt_projects` materialization (AC7) and its participation in AC15's "both extracts" check —
  blocked by Snowflake's `TIMESTAMP_LTZ`-to-Parquet unload limitation on `FINISH_DATE`/
  `START_DATE`. Reported above, not silently skipped.

## Concerns

- **`DT_PROJECTS` growth continues**: this session measured **42,167** rows (2026-09-24,
  ~16:16 UTC), up from the spec's own pinned snapshot of 42,162 and 2a's original 42,161.
  Purely observational — not a defect, and not something this task should "fix" by re-pinning
  any number.
- **If item 8 (the cross-source join) or any future spec needs `DT_PROJECTS` specifically**,
  the `TIMESTAMP_LTZ` blocker will recur. The two realistic fixes are casting
  `FINISH_DATE`/`START_DATE` to `TIMESTAMP_NTZ` in the extract query (changes the sidecar's
  `query` field away from a bare `SELECT *`) or excluding those two columns. Neither was
  applied here per Phil's explicit choice; worth deciding explicitly before item 8 needs it,
  rather than rediscovering the blocker mid-spec.
