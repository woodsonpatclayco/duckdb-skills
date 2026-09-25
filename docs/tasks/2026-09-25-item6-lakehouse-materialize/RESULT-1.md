# RESULT-1 — Materialize contracts into a DuckLake lakehouse (item 6)

Commit: `58996cd68ef45e73a747734bd2bf7489711e2cb8` (pushed to `origin/main`).

Deliverables: `tools\materialize.ps1`, `tools\lake-status.ps1`, `skills\lakehouse\SKILL.md`,
plus one additive helper `Resolve-LakeRoot` in `tools\dsk-paths.ps1` (same shape as the
existing `Resolve-ExtractRoot`, same absolute-path rejection).

## Summary

All 22 acceptance checks (AC0–AC21) pass. All 7 required mutation proofs are shown failing
under the mutation and passing again after revert. No figure drifted from what the
contracts already have committed (both real contracts' committed snapshots are the
2026-09-25 baseline from item 5's round-2 corrections, and every value measured this
session matches them exactly). The live workbook's SHA-256 and `LastWriteTime` are
unchanged before and after this entire session, matching AC20's baseline exactly.

## Environment note on command quoting

Every `powershell -NoProfile -Command "..."` invocation in this session that contained a
PowerShell variable (`$x =`) was silently mangled by this tool's shell layer — the `$var`
got stripped before PowerShell ever saw it, producing parser errors. Every test below was
therefore run by writing a `.ps1` file to `$env:TEMP` with the `write` tool and invoking it
via `powershell -NoProfile -File <path>`, which does not have this problem. This is
tooling-environment behaviour, not a project convention change, and it explains why every
command quoted below is `-File`, never inline `-Command` with a variable in it.

---

## AC0 — fresh worktree, no setup

```
git worktree add C:\Users\woodsonp\AppData\Local\Temp\dsk-ac0-worktree 58996cd
Set-Location C:\Users\woodsonp\AppData\Local\Temp\dsk-ac0-worktree
.\tools\materialize.ps1
```

```
LAKE_ROOT,C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-appdata-local-temp-dsk-ac0-worktree\lake
MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=no_manifest
MANIFEST_SNAPSHOT_ID,3
CHECKS_PASSED,true
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=no_manifest
MANIFEST_SNAPSHOT_ID,6
CHECKS_PASSED,true
SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0
SCRIPT_EXIT=0
```

Exit 0 on first invocation, no prior setup. Note for the record: my first attempt at this
check invoked the worktree's script by full path *without* changing the process's working
directory first, and it silently reused the **main repo's** project-id and lake (because
`Get-ProjectId`'s `git rev-parse --show-toplevel` runs against the process CWD, not the
script's own location — exactly the class of trap `tools\dsk-paths.ps1`'s own header
warns about for `-ExtractRoot`/`-LakeRoot`). `Set-Location` into the worktree first, as
shown above, is required to actually exercise AC0; a verifier should do the same.

Cleanup performed (per AC0's own note): `git worktree remove --force
...\dsk-ac0-worktree`, then the orphaned lake directory
`~\.duckdb-skills\c-users-woodsonp-appdata-local-temp-dsk-ac0-worktree\` was deleted.

## AC1 — first run, both contracts, cross-checked

```
tools\materialize.ps1
```
```
MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=no_manifest
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=no_manifest
SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0
```
Cross-checked in the same session against the independent harness:
```
tools\run-assertions.ps1
```
```
CONTRACT,All_Sales_Data
TRUNCATION_WITHDATA_ROWS,219
CONTRACT,Clayco_Job_Costs_from_GL
TRUNCATION_WITHDATA_ROWS,62230
```
219 = 219, 62230 = 62230. Exit 0.

## AC2 — freshness (SKIP, no write)

Before the second run: `SELECT max(snapshot_id) FROM lake.snapshots()` → **8**;
`SELECT count(*) FROM lake.check_history` → **39**.

```
tools\materialize.ps1
```
```
MATERIALIZE,All_Sales_Data,SKIPPED
MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED
SUMMARY,contracts=2,refreshed=0,skipped=2,refused=0,forced=0
```
After: max `snapshot_id` → **8** (unchanged), `check_history` count → **39** (unchanged).
All four numbers quoted. The script did read the workbook's bytes to hash it (via
`sha256(content) FROM read_blob(...)`, confirmed by instrumenting the run) — required by
the decision, not a defect — but parsed no sheet and wrote nothing.

## AC3 — changed workbook forces a refresh

Against a scratch copy (`%TEMP%\dsk-wbscratch\scratch.xlsm`, never the live file) pointed
to by a throwaway contract copy: appended one byte, which changed both mtime and SHA-256.
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=workbook_mtime+workbook_sha256
```

## AC4 — changed contract forces a refresh

Added a trailing comment line to a throwaway contract copy (only `contract_sha256` moves):
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=contract_sha256
```

## AC5 — changed macro forces a refresh

`skills\query\duckdb-compat.sql` is on the do-not-modify list, so this was proved by a
**temporary, verified-reverted swap**: the file's bytes were backed up, a trailing comment
appended (hash `B00E72A6...`), the run below taken, then the original bytes restored
byte-for-byte from the backup and confirmed with `git diff --stat` (empty output).
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=compat_sha256
```
`git diff --stat -- skills/query/duckdb-compat.sql` after restore: **no output** (clean).

## AC6 — same mtime, changed content still caught

Appended a byte to the scratch workbook, then reset `LastWriteTime` back to
`2026-09-25 08:48:13` (its value before the edit) with
`(Get-Item ...).LastWriteTime = $before`. Mtime confirmed unchanged
(`MTIME_AFTER_RESET=2026-09-25 08:48:13`), hash confirmed changed.
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=workbook_sha256
```
`reason` names only `workbook_sha256` — `workbook_mtime` is correctly absent.

## AC7 — missing target defeats SKIP

Clean SKIP run confirmed first, then `DROP TABLE lake.All_Sales_Data` (on the official
lake), then re-run:
```
MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=target_missing
MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED
```
Exact literal `reason=target_missing`, 219 rows, GL correctly still SKIPPED (only its
sibling's target was dropped).

## AC8 — time travel

Built a small throwaway fixture (`COPY (VALUES ...) TO ... (FORMAT xlsx)`, the same
technique `tools\make-truncation-fixtures.ps1` uses) with 3 rows, materialized it, then
rebuilt the **same workbook path** with a 4th row and materialized again:
```
run 1: MANIFEST_SNAPSHOT_ID,3   rows=3
run 2: MANIFEST_SNAPSHOT_ID,6   rows=4
```
`lake.manifest` confirms: `{"lake_snapshot_id":3,"row_count":3,...}`,
`{"lake_snapshot_id":6,"row_count":4,...}`. Reading the snapshot id from the manifest
(never a hardcoded version literal):
```sql
SELECT count(*) FROM lake.ac8fixture AT (VERSION => 3);  -- 3, the first run's count
SELECT count(*) FROM lake.ac8fixture;                    -- 4, the current count
```
Both confirmed exactly as required.

## AC9 — manifest provenance

Run-1 manifest rows for both contracts, and independent `Get-FileHash`:

| field | manifest (All_Sales_Data) | manifest (GL) | independent `Get-FileHash` |
|---|---|---|---|
| `row_count` | 219 | 62230 | (harness: 219 / 62230 — AC1) |
| `checks_passed` | true | true | — |
| `forced` | false | false | — |
| `source_sha256` | `a9cff71a...ba33e3` | `a9cff71a...ba33e3` | `A9CFF71A...BA33E3` |
| `contract_sha256` | `f9ce8fd5...293450` | `d89a94b7...504dbe` | `F9CE8FD5...293450` / `D89A94B7...504DBE` |
| `compat_sha256` | `a8ee1e52...c7d6af` | `a8ee1e52...c7d6af` | `A8EE1E52...C7D6AF` |

All three hashes match `Get-FileHash`'s own output exactly (case aside). Every column
populated, none NULL.

## AC10 — check_history is per check, per materialization

After two materializations of both contracts (the second forced by dropping both target
tables — a legitimate `target_missing` REFRESH, not `-Force`):
```sql
SELECT count(*) FROM lake.check_history;   -- 78
SELECT contract_name, kind, count(*) FROM lake.check_history GROUP BY contract_name, kind ORDER BY contract_name, kind;
```
```
All_Sales_Data,           floor,     8
All_Sales_Data,           invariant, 14
All_Sales_Data,           snapshot,  24
Clayco_Job_Costs_from_GL, floor,     6
Clayco_Job_Costs_from_GL, invariant, 10
Clayco_Job_Costs_from_GL, snapshot,  16
```
GL: 6+10+16 = 32/run × 2 runs... decomposed per run: floor 3 (2 `_floor` asserts + 1
ROWS_FLOOR), invariant 5 (2 asserts + ANCHOR + TRUNCATION_ROWS_LOST + CONSISTENCY_VIEW_ROWS),
snapshot 8 (7 SNAPSHOT + 1 FINGERPRINT) = 16/run × 2 = 16/10/6... i.e. exactly
**4 ASSERT + 1 ANCHOR + 1 ROWS_FLOOR + 1 TRUNCATION + 1 CONSISTENCY + 7 SNAPSHOT + 1
FINGERPRINT = 16 per run**, matching TASK.md's own decomposition exactly. All_Sales_Data:
**7 + 1 + 1 + 1 + 1 + 11 + 1 = 23 per run**, also exact. 16×2 + 23×2 = 32 + 46 = 78.
The live workbook did not refresh between runs (row counts identical, 62230/219 both
times), so no new arithmetic is needed.

## AC11 — the history answers the question

```
tools\lake-status.ps1 -History Clayco_Job_Costs_from_GL
```
Across the two materializations above, shows (among others):
```
HISTORY,Clayco_Job_Costs_from_GL,2026-09-25 21:23:32.050252,vendorname_nn,snapshot,PASS,52037,52037,MATERIALIZED
HISTORY,Clayco_Job_Costs_from_GL,2026-09-25 21:23:32.050252,rows,snapshot,PASS,62230,62230,MATERIALIZED
HISTORY,Clayco_Job_Costs_from_GL,2026-09-25 21:23:32.050252,ROWS_FLOOR,floor,PASS,62230,50000,MATERIALIZED
HISTORY,Clayco_Job_Costs_from_GL,2026-09-25 21:23:32.050252,vendorname_ratio_floor,floor,PASS,PASS,NULL,MATERIALIZED
NOTE,Clayco_Job_Costs_from_GL,vendorname_ratio_floor has no measured observed value -- the harness emits only PASS/FAIL/ERROR for -- @assert lines, never the underlying ratio/date/sum
```
(repeated identically for the second materialized_at). The explicit `NOTE` line states,
per every `@assert`-derived row, that it carries no measured observed value — required by
TASK.md §4.

## AC12 — failing checks block materialization

Throwaway copy of the GL contract with `-- @anchor: VENDOR_NAME` (52,037 of 62,230 — not
100%). Captured before: GL table row count **62230**, `lake.manifest` newest
`lake_snapshot_id` for GL **14**.
```
tools\materialize.ps1 -Contract <throwaway>.sql
```
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFUSED,reason=checks_failed
MANIFEST_SNAPSHOT_ID,14
CHECKS_PASSED,false
SUMMARY,contracts=1,refreshed=0,skipped=0,refused=1,forced=0
```
Exit 1. After: GL table row count still **62230**; newest manifest `lake_snapshot_id` for
GL still **14** (the value carried forward unchanged into the new REFUSED manifest row —
this is what "unchanged" means at the per-contract level; the lake's own **global** max
`snapshot_id` did advance, from 14 to 18, because writing the REFUSED run's own manifest +
check_history rows is itself a DuckLake write — see the design note below). `check_history`
records the anchor failure with `outcome=REFUSED`:
```
{"check_id":"ANCHOR","status":"FAIL","outcome":"REFUSED"}
```

## AC13 — `-Force` overrides and is recorded

Same throwaway contract, `-Force`:
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=previous_checks_failed
MANIFEST_SNAPSHOT_ID,19
CHECKS_PASSED,false
SUMMARY,contracts=1,refreshed=1,skipped=0,refused=0,forced=1
```
Exit 0. `lake.manifest`: `{"forced":true,"checks_passed":false,"lake_snapshot_id":19}`.
`check_history` for that run: `outcome='FORCED'` on every row.

## AC14 — a forced bad run is re-checked, never skipped

Immediately re-run the same throwaway contract without `-Force`:
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFUSED,reason=checks_failed
SCRIPT_EXIT=1
```
Not `SKIPPED` — the newest manifest row's `checks_passed = false` forced a re-check, which
still fails on the same bad anchor.

## AC15 — snapshot drift never blocks

Fresh copy of the (otherwise correct) GL contract with
`-- @snapshot_committed jobcosts_nn: 99999999` (wrong on purpose):
```
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62230,reason=previous_checks_failed
CHECKS_PASSED,true
SCRIPT_EXIT=0
```
`check_history` for `jobcosts_nn`: `{"status":"DRIFT","observed":"62230","committed":"99999999"}`.
Exit 0 — drift recorded, never gates.

## AC16 — the dated question

Built a genuine passing → refused → passing sequence for GL on the official lake:
```
2026-09-25 21:23:32.050252  checks_passed=true   rows=62230
2026-09-25 21:25:08.461922  checks_passed=true   rows=62230
2026-09-25 21:26:05.470680  checks_passed=false  rows=NULL   (bad-anchor throwaway)
2026-09-25 21:26:30.229338  checks_passed=true   rows=62230
```
```
tools\lake-status.ps1 -AsOf "2026-09-25 21:26:10" -Contract Clayco_Job_Costs_from_GL
```
```
ASOF,Clayco_Job_Costs_from_GL,2026-09-25 21:26:10,effective_run_id=fe1f3e1b-...,
  materialized_at=2026-09-25 21:25:08.461922,...,rows=62230,checks_passed=true,
  forced=false,snapshot_id=14,outcome=MATERIALIZED
ASOF_LATER_REFUSED,Clayco_Job_Costs_from_GL,count=1,times=2026-09-25 21:26:05.47068
NOTE,Clayco_Job_Costs_from_GL,the 1 refused run(s) above did not change the data --
  the effective state as of 2026-09-25 21:26:10 is still the
  materialized_at=2026-09-25 21:25:08.461922 run printed above
```
followed by that run's own `ASOF_CHECK,...` rows. The tool correctly skipped past the
21:26:05 refused row to print the 21:25:08 landed row as the effective state, and named
the refused run explicitly.

**A design note this AC exposed, recorded for the reviewer**: TASK.md's own sentence
("prints the newest manifest row at or before that date and states that any **later**
REFUSED runs did not change the data") only parses if "the newest manifest row" means the
newest row that actually landed data, not literally the row with the largest
`materialized_at`. I implemented it that way — `-AsOf` finds the newest row with
`(checks_passed OR forced)` at or before the date, then separately reports any `REFUSED`
rows strictly after that row's timestamp (and at or before the queried date). This is a
judgment call on an underspecified point, not a disagreement — see "Design decisions" below.

## AC17 — DuckLake serializes writers by itself

Held the lock with a genuinely non-foldable delay in a separate process:
```sql
CREATE OR REPLACE TABLE lake.ac17_holder AS SELECT max(hash(i*7+1)) AS h FROM range(2000000000) t(i);
```
(confirmed still running via `Wait-Process`/`HasExited=False` 4 seconds in). While held,
```
tools\materialize.ps1 -LakeRoot <same lake>
```
```
MATERIALIZE,All_Sales_Data,ERROR
IO Error: Failed to attach DuckLake MetaData "__ducklake_metadata_lake" at path
"...lake.ducklake"Cannot open file "...\lake.ducklake": The process cannot access
the file because it is being used by another process.
File is already open in ...\duckdb.exe (PID 115692)
NOTE: DuckLake's own catalog lock is the serializer; see ducklake_max_retry_count /
ducklake_retry_backoff / ducklake_retry_wait_ms. No retry attempted.
SCRIPT_EXIT=1
```
PID 115692 matched the holder process exactly. After the holder exited,
`SELECT * FROM lake.snapshots()` showed exactly **2** snapshots total (schema creation +
the holder's own table) — proving the loser wrote **nothing**: `SELECT count(*) FROM
duckdb_tables() WHERE ... table_name='All_Sales_Data'` → **0**.

## AC18 — a locked workbook is loud and harmless

A scratch workbook copy held open with `FileShare.None` in a separate process (confirmed:
`Get-FileHash` in-process gives a plain, PID-less .NET message; DuckDB's own
`read_blob`/`sha256` — what this tool actually uses — gives the rich message below).
Captured before: GL table row count **62230**, manifest `lake_snapshot_id` **24**.
```
tools\materialize.ps1 -Contract <pointed at the locked scratch copy>
```
```
MATERIALIZE,Clayco_Job_Costs_from_GL,ERROR
IO Error: Cannot open file ".../scratch.xlsm": The process cannot access the file
because it is being used by another process.
File is already open in ...\powershell.exe (PID 111536)
ERROR,Clayco_Job_Costs_from_GL,could not read workbook at ...\scratch.xlsm (see output above)
SCRIPT_EXIT=1
```
PID 111536 matched the holder exactly. After: GL row count still **62230**, manifest
`lake_snapshot_id` still **24** — no lake interaction happened at all (the hash read fails
before the lake is ever attached).

## AC19 — data lands as Parquet

After both contracts materialized:
```
DATA_PATH\main\Clayco_Job_Costs_from_GL\ducklake-....parquet   (3 files, ~828 KB each)
DATA_PATH\main\All_Sales_Data\ducklake-....parquet             (2 files, ~17 KB each)
```
```sql
SELECT changes FROM lake.snapshots() ORDER BY snapshot_id;
```
shows `"tables_created":["main.Clayco_Job_Costs_from_GL"],"tables_inserted_into":[...]`
for the contract-table writes — never `inlined_insert` (that appears only for the small
`manifest` rows). `SELECT count(*) FROM lake.Clayco_Job_Costs_from_GL` → **62230**,
matching the harness's own count in the same session.

## AC20 — control

Before this session's work (recorded at the start): `A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3`,
`2026-09-25T08:48:13`. After everything in this document, including the final commit and
push: **identical** — `A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3`,
`2026-09-25T08:48:13`. No drift, no write. Matches the spec's own pinned baseline exactly.

## AC21 — no UTF-8 BOM

Checked the four files this item created or modified:
```
tools\materialize.ps1       BOM=False
tools\lake-status.ps1       BOM=False
tools\dsk-paths.ps1         BOM=False
skills\lakehouse\SKILL.md   BOM=False
```
All written via `[IO.File]::WriteAllText` + `New-Object Text.UTF8Encoding($false)` (the
tool itself) or the `write` tool (independently confirmed byte-for-byte BOM-free).

---

## Mutation proofs (all 7, both directions)

Each mutation was applied to the committed `tools\materialize.ps1`, proven failing, then
reverted and proven passing again; `Get-FileHash` against a pre-mutation backup confirmed
byte-for-byte identity after every revert (`MATCH=True`, checked after every single
mutation below).

**1. Compare only mtime, dropping the workbook SHA-256 → AC6 fails.**
Removed the `workbook_sha256` comparison line. AC6's setup (content changed, mtime reset
to its original value) then produced `MATERIALIZE,...,SKIPPED` — wrong; reverted →
`REFRESHED,...,reason=workbook_sha256` — correct again.

**2. Drop `contract_sha256` from the decision → AC4 fails.**
Removed that comparison line. A contract comment edit then produced `SKIPPED` — the fix
was silently ignored; reverted → `REFRESHED,...,reason=contract_sha256`.

**3. Drop `compat_sha256` from the decision → AC5 fails.**
Removed that comparison line. The (temporarily swapped-in, later restored) edited
`duckdb-compat.sql` then produced `SKIPPED` — a changed date decoder would be served
silently; reverted → `REFRESHED,...,reason=compat_sha256`.

**4. Drop the target-exists check → AC7 fails.**
Removed the whole `elseif (-not $targetExists -or $targetRowCount -le 0)` branch. After
`DROP TABLE lake.Clayco_Job_Costs_from_GL`, the next run produced `SKIPPED` — a dropped
table stays SKIPPED forever; reverted → `REFRESHED,...,reason=target_missing`.

**5. Let a non-zero harness exit through without `-Force` → AC12 fails.**
Changed the refuse-guard to `if ($false -and -not $checksPassed -and -not $Force)`. The
bad-anchor throwaway contract then produced `MATERIALIZE,...,REFRESHED,62230,...` with
`CHECKS_PASSED,false` and **exit 0** — the lake was replaced with known-bad data; reverted
→ `REFUSED,reason=checks_failed`, **exit 1**, previous data intact.

**6. Write one `check_history` row per materialization instead of per check → AC10 and
AC11 both fail.**
Changed `$checkRows | ForEach-Object {...}` to `$checkRows | Select-Object -First 1 |
ForEach-Object {...}` in the successful-write branch. Two materializations of both real
contracts then gave `SELECT count(*) FROM lake.check_history` → **4** (not 78), and
`-History Clayco_Job_Costs_from_GL` showed only `jobcosts_sum_exact_decimal` per run — no
`ROWS_FLOOR`, no `vendorname_nn`, nothing else. Reverted and re-run: the next run's own
contribution was **23** (All_Sales_Data) and **16** (GL) check_history rows — the exact
per-contract totals AC10 requires.

**7. Omit `outcome` → AC16 fails.**
Changed the last tuple field from `$(ConvertTo-SqlLiteral $outcome)` to a literal `NULL`
in both write branches. A passing run and a refused run (bad-anchor throwaway) for the
same contract then both wrote `outcome = NULL`:
```
{"checks_passed":true,  "outcome":null, "n":16}
{"checks_passed":false, "outcome":null, "n":16}
```
— a refused run's checks are indistinguishable from a landed run's, by `outcome` alone,
exactly as predicted. Reverted, re-ran the same refused scenario: `outcome = 'REFUSED'`
for the new run, distinct from a landed run's `'MATERIALIZED'`.

`git status --porcelain` after all seven mutation/revert cycles showed no diff on
`tools\materialize.ps1` (confirmed by hash match before writing this document).

---

## Design decisions on points TASK.md left underspecified

Not disagreements — nothing in the spec was found to be wrong or impossible. These are the
places TASK.md's own "assigning kind and status" table pins `status` but not
`observed`/`committed`, or leaves a mechanism's exact shape to the implementer. Recorded so
a reviewer can judge them on their merits, and duplicated as code comments in
`tools\materialize.ps1`'s header and in `skills\lakehouse\SKILL.md`:

- **`ASSERT` rows**: `observed` = the emitted status text itself, `committed` = NULL. This
  is TASK.md's own literal instruction ("For `ASSERT` rows, `observed` is the status and
  `committed` is NULL") — flagged here only because a paraphrase of the same rule
  elsewhere reads as "observed is NULL", which is a different (and wrong) rule. The
  contract's own `-- @assert <name>: <expr>` boolean is never re-evaluated to recover the
  underlying ratio/date/sum; that would be a second source of truth for a value the
  harness deliberately does not emit.
- **`ANCHOR`**: `committed` = the row total, read from the already-parsed
  `CONSISTENCY_VIEW_ROWS` line earlier in the same harness output stream (the harness
  itself never prints `ANCHOR_TOTAL`).
- **`ROWS_FLOOR`**: `observed`/`committed` = the row count and the floor, both already
  present verbatim in the harness's own `ROWS_FLOOR,<floor>,<observed>,<status>` line.
- **`TRUNCATION_ROWS_LOST`**: `committed` = the literal `"0"` it is compared against.
- **`CONSISTENCY_VIEW_ROWS`**: `committed` = the `TRUNCATION_WITHDATA_ROWS` value parsed
  moments earlier in the same stream.
- **`FINGERPRINT`**: on `MATCH`, the harness prints no fingerprint text at all (only on
  `DRIFT` does it print `FINGERPRINT_COMMITTED`/`FINGERPRINT_OBSERVED`), so `observed` and
  `committed` are both read from the contract's own `-- @fingerprint:` directive text — a
  static literal already required to exist by the harness's guard, not a recomputation.
- **`SNAPSHOT,<name>`**: `committed` = the contract's own `-- @snapshot_committed <name>:`
  literal, read the same way, always (not only on drift).
- **A harness-level `ERROR,<contract>,<message>` line** (a guard failure, or a DuckDB error
  inside `run-assertions.ps1`'s own reads) becomes one `check_history` row:
  `check_id=HARNESS_ERROR`, `kind=invariant`, `status=ERROR`, `observed=<message>`. TASK.md's
  kind-assignment table does not cover this line shape at all; without recording it, a
  guard failure would correctly refuse materialization but leave no trace of *why* in
  `check_history`.
- **Manifest rows on a `REFUSED` run**: TASK.md's deliverable text says a refusal should
  "write `check_history` rows" but does not explicitly say a `manifest` row too. I write
  one, because `check_history` carries no `materialized_at` of its own (only `manifest`
  does), so without a manifest row a refused attempt could never be dated — which
  `tools\lake-status.ps1 -AsOf`/`-History` both need to do. "One row per materialization
  attempt that reached a decision" (TASK.md's own manifest description) reads as covering
  this: a refusal is a decision that was reached.
- **`-AsOf` semantics**: see the AC16 note above — implemented as "the newest row that
  landed data, plus a separate report of any later refusals", which is the only reading
  under which TASK.md's own sentence about "later REFUSED runs" parses.
- **The `MATERIALIZE,<name>,REFUSED[,reason=...]` line**: TASK.md's deliverable text names
  only `SKIPPED` and `REFRESHED` explicitly for this line; `REFUSED` follows the same shape
  by extension, since the surrounding paragraph clearly requires *some* visible signal for
  a refusal and the two named forms are the established pattern from item 5.
- **`-LakeRoot` on `tools\lake-status.ps1`**: not named in TASK.md's deliverable text for
  that tool (only for `materialize.ps1`), added anyway for testability/symmetry via the
  same `Resolve-LakeRoot` helper. No acceptance check requires its absence, and every
  acceptance flow above uses the default project lake.

## Not verified / known limitations

- **AC10/AC11's "if the live workbook refreshed" branch** was not exercised, because the
  live workbook did not refresh during this session (confirmed unchanged by AC20). The
  arithmetic for that case is stated in TASK.md and not independently re-derived here.
- **Concurrent-write interleaving of `manifest`/`check_history` writes themselves** (as
  opposed to the table replace) was not stress-tested beyond AC17's single-overlap case;
  TASK.md does not ask for this.
- Every other item in TASK.md's "Out of scope" section (direction-aware row tolerance,
  workbook proof/routing, cross-source join, compaction, a third contract, Snowflake
  extracts) was correctly left untouched, per spec.

## Files changed

- `tools\materialize.ps1` (new) — the per-contract decide/run/materialize/write pipeline.
- `tools\lake-status.ps1` (new) — read-only status, `-History`, `-AsOf`.
- `tools\dsk-paths.ps1` (modified) — added `Resolve-LakeRoot`, same shape as
  `Resolve-ExtractRoot`; no existing function's behaviour changed.
- `skills\lakehouse\SKILL.md` (new) — 4-line description, covers querying the lake, the
  four-way freshness key, SKIPPED vs REFRESHED/REFUSED/FORCED, Parquet/`DATA_PATH`,
  DuckLake's lock and retry settings, `AT (VERSION => n)`, and the `_floor` suffix rule.
- `TASK.md` (new, committed with this round) — the spec itself.

`REVIEW-task-1.md` was left untracked, as instructed, and is not part of this commit.
