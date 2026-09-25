# RESULT-2 — item 5 round 2: reclassifying assertions into invariant/floor/snapshot

Serves: same feature as RESULT-1 — "if a sheet quietly stops giving me all the rows, or a
column quietly goes blank, I want to be told — not to find out from a number that looks
plausible and is wrong." Round 1 shipped the harness and both contracts correctly (12 of 17
checks passed clean); the other five failed because the workbook refreshed overnight and
four pre-existing `@assert` lines asserted absolute snapshots by equality. This round's job
is C1: reclassify every assertion in both contracts so the harness reaches `failures=0` on
ordinary data growth and stays there. Nothing is left after this on PLAN-4 §5 except the
direction-aware row-count tolerance, which was split into its own item before round 1.

Commit: `d88a312` (pushed to `origin/main`). Branch: `main`. Built on top of round 1
(`d590a82`, `17cc7bf`) — no round-1 commit was rewritten.

## Files changed

- `tools/run-assertions.ps1` (modified) — added a fifth and sixth additive directive
  family, `-- @snapshot <name>: <expr>` / `-- @snapshot_committed <name>: <literal>`
  (zero or more, paired by name, same before-any-heavy-read guard discipline as the
  four existing directives). Evaluated in the same phase-2 DuckDB batch as
  ANCHOR/FINGERPRINT (no extra 68 MB read). Every run prints `SNAPSHOT,<name>,<value>`
  unconditionally and `SNAPSHOT_DRIFT,<name>,committed=<c>,observed=<o>` only on
  mismatch — neither line ever increments `$totalFailures`. New helper function
  `Get-NamedDirectiveOccurrences` (distinct from the existing `Get-DirectiveOccurrences`,
  which only supports "exactly one per file" directives).
- `contracts/Clayco_Job_Costs_from_GL.sql` (modified) — removed `jobcosts_nn`,
  `vendorname_nn`, `glperiod_nn`, `glperiod_range`, `jobcosts_sum` (all five hard-equality
  `@assert` lines); added `jobcosts_sum_exact_decimal`, `vendorname_ratio_floor`,
  `glperiod_ratio_floor` (new `@assert` lines); added five `@snapshot`/`@snapshot_committed`
  pairs (`rows`, `jobcosts_nn`, `vendorname_nn`, `glperiod_nn`, `jobcosts_sum`).
  `glperiod_is_date` untouched.
- `contracts/All_Sales_Data.sql` (modified) — removed `jobnum_nn`, `matchproject_nn`,
  `revtotal_nn`, `earntotal_nn`, `startdate_nn`, `enddate_nn`, `startdate_range`,
  `revtotal_sum`, `earntotal_sum`, `salesyear_distinct`, `revtotal_maxcast` (all eleven
  hard-equality `@assert` lines); added `matchproject_ratio_floor`, `revtotal_ratio_floor`,
  `enddate_ratio_floor`, `revtotal_sum_exact_decimal`, `earntotal_sum_exact_decimal`,
  `revtotal_maxcast_exact_decimal` (new `@assert` lines); added eleven
  `@snapshot`/`@snapshot_committed` pairs. `startdate_is_date` untouched.
- `tools/make-truncation-fixtures.ps1` (modified) — added fixture C (C4): three columns
  (C1, C2, C3), two fully-populated rows, one row populated only in C3, plus a matching
  throwaway contract that deliberately projects only C1/C2. Promotes round 1's improvised
  `dsk-orphan-fixture.xlsx` to a committed, reproducible build.
- `TASK.md` — already modified (round-2 CORRECTIONS appended before this session started);
  committed as-is per this project's convention that specs are committed artifacts.

Not touched: `docs\tasks\**`, the workbook, `skills\query\duckdb-compat.sql`,
`checks\gl-facts.sql`, `tools\check-contract.ps1` (item 4's `@assert` grammar and both
guards are inherited verbatim, exactly as round 1 left them), `REVIEW-task-1.md`, `Revenue`.

## C1 — reclassification, per assertion, per contract

### `Clayco_Job_Costs_from_GL.sql`

| assertion (round 1) | kind now | form now | why |
|---|---|---|---|
| `jobcosts_nn` (`count(JOB_COSTS)=62110`) | **INVARIANT** | deleted — replaced by the existing `@anchor: JOB_COSTS` mechanism, which already asserts `count(JOB_COSTS) = count(*)` and reports it as the `ANCHOR,...` line | anchor completeness held exactly (100.0% both sessions) where the literal count did not; no new code needed, the harness already computes this relationship for every contract's declared anchor |
| `vendorname_nn` (`count(VENDOR_NAME)=51928`) | **FLOOR** | `vendorname_ratio_floor: (SELECT count(VENDOR_NAME)::DOUBLE / count(*) FROM contract_view) >= 0.80` | ratio measured 0.83607 (09-24) and 0.83620 (09-25) — stable across a refresh that moved the absolute count by 109 |
| `glperiod_nn` (`count(GL_PERIOD)=18764`) | **FLOOR** | `glperiod_ratio_floor: ... >= 0.25` | ratio measured 0.30211 and 0.30345 across the same refresh |
| `glperiod_is_date` | **INVARIANT** | unchanged | already a relationship (`typeof(GL_PERIOD) = 'DATE'`), never a literal count |
| `glperiod_range` (`min=2026-07-01 AND max=2026-10-01`) | **INVARIANT, discharged elsewhere — deleted** | no replacement `@assert`; min/max reported nowhere for GL | adds nothing beyond `glperiod_is_date` (decodes to a real DATE) and `checks/gl-facts.sql`'s AC8 (two independent decoders agree row-for-row, not just on aggregates) — a literal min/max window is exactly the class of absolute figure this round removes, and unlike the three counts above it has no ratio form to fall back to |
| `jobcosts_sum` (`sum(JOB_COSTS)=22454928166.83`) | **INVARIANT + SNAPSHOT** | `jobcosts_sum_exact_decimal: typeof(sum(JOB_COSTS)) LIKE 'DECIMAL%'` (gates) + `@snapshot jobcosts_sum` (reported) | the cast producing an exact decimal is refresh-proof; the dollar value itself (which Phil ties to a report) is not, and must stay visible without gating |
| *(new)* | **SNAPSHOT** | `@snapshot rows` | AC7′ asks for row count reported alongside the three non-null counts and the sum |

### `All_Sales_Data.sql`

| assertion (round 1) | kind now | form now | why |
|---|---|---|---|
| `jobnum_nn` (`count("Job #")=219`) | **INVARIANT** | deleted — replaced by the existing `@anchor: Job #` mechanism | same reasoning as `jobcosts_nn` above |
| `matchproject_nn` (`=214`) | **FLOOR + SNAPSHOT** | `matchproject_ratio_floor: ... >= 0.90` (gates) + `@snapshot matchproject_nn` (reported) | ratio 0.9772; floor value given in TASK.md's C1 table |
| `revtotal_nn` (`=201`) | **FLOOR + SNAPSHOT** | `revtotal_ratio_floor: ... >= 0.85` + `@snapshot revtotal_nn` | ratio 0.9178; floor value given |
| `enddate_nn` (`=145`) | **FLOOR + SNAPSHOT** | `enddate_ratio_floor: ... >= 0.55` + `@snapshot enddate_nn` | ratio 0.6621; floor value given |
| `earntotal_nn` (`=201`) | **SNAPSHOT only** | `@snapshot earntotal_nn` | TASK.md's C1 floor table names only rows/Job #/Revenue Total/End Date/match project for this contract — no floor value was handed down for Earnings Total, and I was told not to invent one, so it stays a reported absolute count |
| `startdate_nn` (`=150`) | **SNAPSHOT only** | `@snapshot startdate_nn` | same reasoning — no floor given |
| `startdate_is_date` | **INVARIANT** | unchanged | already a relationship |
| `startdate_range` (`min=2023-07-15 AND max=2027-03-15`) | **discharged elsewhere — deleted, min/max moved to snapshot** | no `@assert`; `@snapshot startdate_min` / `@snapshot startdate_max` instead | same reasoning as `glperiod_range` for the assert; unlike GL, this contract has no independent second-decoder check, so the min/max values themselves are kept visible as snapshots rather than dropped outright |
| `revtotal_sum` (`=36580445574.84`) | **INVARIANT + SNAPSHOT** | `revtotal_sum_exact_decimal: typeof(sum(...)) LIKE 'DECIMAL%'` + `@snapshot revtotal_sum` | same pattern as `jobcosts_sum` |
| `earntotal_sum` (`=1439728975.91`) | **INVARIANT + SNAPSHOT** | `earntotal_sum_exact_decimal: ...` + `@snapshot earntotal_sum` | same pattern |
| `revtotal_maxcast` (`=1682000000.00`) | **INVARIANT + SNAPSHOT** | `revtotal_maxcast_exact_decimal: typeof(max("Revenue Total")) LIKE 'DECIMAL%'` + `@snapshot revtotal_max` | the assertion's real job (per its own original comment) was proving the cast happens before the comparison, not pinning the specific dollar figure — a type check proves that without gating on a number that will move as bigger deals close |
| `salesyear_distinct` (`=4`) | **SNAPSHOT** | `@snapshot salesyear_distinct` | a distinct-year count that legitimately grows every January; no ratio form applies |

## C2 — snapshots never gate; AC7′/AC9′ report side by side

### GL — committed (this session's baseline, 2026-09-25) vs. observed

| snapshot | committed | observed | drift? |
|---|---|---|---|
| `rows` | 62230 | 62230 | none |
| `jobcosts_nn` | 62230 | 62230 | none |
| `vendorname_nn` | 52037 | 52037 | none |
| `glperiod_nn` | 18884 | 18884 | none |
| `jobcosts_sum` | 22478661033.93 | 22478661033.93 | none |

(Committed values here are this round's own baseline, since the round-1 baseline had
already drifted by the time this round started — see "Workbook drift" below. Zero drift
observed *within* this round, which is expected: no time passed between committing the
snapshot values and running the harness against them.)

### All_Sales_Data — committed vs. observed

| snapshot | committed | observed | drift? |
|---|---|---|---|
| `matchproject_nn` | 214 | 214 | none |
| `revtotal_nn` | 201 | 201 | none |
| `earntotal_nn` | 201 | 201 | none |
| `startdate_nn` | 150 | 150 | none |
| `enddate_nn` | 145 | 145 | none |
| `revtotal_sum` | 36580445574.84 | 36580445574.84 | none |
| `earntotal_sum` | 1439728975.91 | 1439728975.91 | none |
| `revtotal_max` | 1682000000.00 | 1682000000.00 | none |
| `startdate_min` | 2023-07-15 | 2023-07-15 | none |
| `startdate_max` | 2027-03-15 | 2027-03-15 | none |
| `salesyear_distinct` | 4 | 4 | none |

`All_Sales_Data` has shown zero drift across every measurement session so far (09-24 and
09-25), unlike GL.

## C3 — workbook control re-baselined

Baseline captured before this round's first command and confirmed unchanged after every
command in this document:

```
A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3
2026-09-25 08:48:13
```

This is identical to round 1's own *final* reading (round 1's `RESULT-1.md` re-baselined
to exactly this hash/mtime after finding the spec's original 09-24 baseline had drifted via
a SharePoint sync). **No further drift occurred between round 1 finishing and round 2
starting, and none occurred during round 2 itself.** AC15 passes.

## C4 — fixture C, committed

Built by `tools\make-truncation-fixtures.ps1` (idempotent, alongside fixtures A and B).
Shape: columns C1, C2, C3; rows `(a,b,c)`, `(d,e,f)`, `(NULL,NULL,'z')`. Matching throwaway
contract projects only C1, C2 (the orphan-column defect requires exactly that mismatch).

Measured triple, matches TASK.md's C4 table exactly:

```
tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-c-contract.sql
```
```
CONTRACT,dsk-fixture-c-contract
ASSERT,row_count,PASS
TRUNCATION_DEFAULT_ROWS,3
TRUNCATION_WITHDATA_ROWS,3
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,2
ANCHOR,C1,2,PASS
ROWS_FLOOR,1,2,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=1,failures=1
```
Exit 1. Default 3, with-data over all 3 raw columns 3 (agrees), with-data over the 2
projected columns (the view itself) 2 (row dropped), anchor non-null among survivors 2 —
mismatch (3 vs. 2) correctly detected, `failures=1`.

## Acceptance checks

### AC0′ / AC1′ — first invocation, no setup, `failures=0`

```
git worktree add C:\Users\woodsonp\Claude\Dev\dsk-ac0-worktree-r2 d88a312
cd C:\Users\woodsonp\Claude\Dev\dsk-ac0-worktree-r2
Test-Path .duckdb-skills        # False
tools\run-assertions.ps1
```
```
CONTRACT,All_Sales_Data
ASSERT,startdate_is_date,PASS
ASSERT,matchproject_ratio_floor,PASS
ASSERT,revtotal_ratio_floor,PASS
ASSERT,enddate_ratio_floor,PASS
ASSERT,revtotal_sum_exact_decimal,PASS
ASSERT,earntotal_sum_exact_decimal,PASS
ASSERT,revtotal_maxcast_exact_decimal,PASS
TRUNCATION_DEFAULT_ROWS,219
TRUNCATION_WITHDATA_ROWS,219
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,219
ANCHOR,Job #,219,PASS
ROWS_FLOOR,200,219,PASS
FINGERPRINT,MATCH
SNAPSHOT,enddate_nn,145
SNAPSHOT,salesyear_distinct,4
SNAPSHOT,earntotal_nn,201
SNAPSHOT,startdate_max,2027-03-15
SNAPSHOT,startdate_nn,150
SNAPSHOT,matchproject_nn,214
SNAPSHOT,earntotal_sum,1439728975.91
SNAPSHOT,revtotal_max,1682000000.00
SNAPSHOT,revtotal_nn,201
SNAPSHOT,startdate_min,2023-07-15
SNAPSHOT,revtotal_sum,36580445574.84
CONTRACT,Clayco_Job_Costs_from_GL
ASSERT,jobcosts_sum_exact_decimal,PASS
ASSERT,vendorname_ratio_floor,PASS
ASSERT,glperiod_ratio_floor,PASS
ASSERT,glperiod_is_date,PASS
TRUNCATION_DEFAULT_ROWS,62230
TRUNCATION_WITHDATA_ROWS,62230
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,62230
ANCHOR,JOB_COSTS,62230,PASS
ROWS_FLOOR,50000,62230,PASS
FINGERPRINT,MATCH
SNAPSHOT,vendorname_nn,52037
SNAPSHOT,jobcosts_sum,22478661033.93
SNAPSHOT,rows,62230
SNAPSHOT,glperiod_nn,18884
SNAPSHOT,jobcosts_nn,62230
SUMMARY,contracts=2,assertions=11,failures=0
```
Exit **0**. Ran cleanly in a throwaway worktree with `.duckdb-skills\` absent (no prior
setup). Worktree removed afterward (`git worktree remove --force`).

**`SUMMARY,contracts=2,assertions=11,failures=0` now holds on the live sheet, whatever it
has drifted to** — exactly what C1/C2 exist to achieve. Elapsed: ~11.1s.

### AC2, AC3, AC4, AC5, AC6 — unchanged, re-verified

- **AC2**: `tools\make-truncation-fixtures.ps1` builds fixtures A, B, **and C**. Fixture A
  via harness: `row_count` PASS (=5), `sum_check` PASS (=120.00) — unchanged from round 1.
- **AC3**: fixture A: `TRUNCATION_DEFAULT_ROWS,2` / `TRUNCATION_WITHDATA_ROWS,5` /
  `TRUNCATION_ROWS_LOST,3`, exit 1. **PASS**, unchanged.
- **AC4**: fixture B: `TRUNCATION_ROWS_LOST,0`, exit 0. **PASS**, unchanged.
- **AC5**: fixture A with-data count is 5 (confirmed above), not 4. **PASS**.
- **AC6**: from AC0′/AC1′ output above — GL `TRUNCATION_ROWS_LOST,0` (62230/62230);
  `All_Sales_Data` `TRUNCATION_ROWS_LOST,0` (219/219). **PASS**.

### AC7′ — the GL correction changes nothing the contract computes

From AC0′/AC1′ output: `FINGERPRINT,MATCH`; `CONSISTENCY_VIEW_ROWS,62230` =
`TRUNCATION_WITHDATA_ROWS,62230` (consistency holds); `ANCHOR,JOB_COSTS,62230,PASS` (anchor
invariant `count(JOB_COSTS)=count(*)` holds); `ASSERT,jobcosts_sum_exact_decimal,PASS` (no
floating-point tail); all three floors PASS (`vendorname_ratio_floor`,
`glperiod_ratio_floor`, `ROWS_FLOOR,50000,62230,PASS`). Snapshots reported and matched — see
the committed-vs-observed table under C2 above. **PASS**, and unlike round 1's AC7, this is
now a literal pass with no caveat: every gating check is refresh-proof by construction.

### AC8 — `checks/gl-facts.sql` not regressed

```
duckdb -f checks\gl-facts.sql
```
```
AC5_VIEW_ROWS,62230
AC5_DIRECT_ROWS,62230
AC6_FINGERPRINT,PARENT_PROJECT_NUMBER|PROJECT_COMPANY|COST_TYPE_CODE|PHASE_DIVISION|PHASE|DIVISION|ACCRUAL_FLAG|VENDOR_NUMBER|VENDOR_NAME|GL_PERIOD|MONTH_OFFSET|MONTH_OFFSET_LABEL|JOB_COSTS
AC8_A_MINUS_B,0
AC8_B_MINUS_A,0
AC8_VIEW_MIN,2026-07-01
AC8_VIEW_MAX,2026-10-01
AC8_VIEW_NN,18884
AC8_BARE_MIN,2026-07-01
AC8_BARE_MAX,2026-10-01
AC8_BARE_NN,18884
AC9_DECIMAL_SUM,22478661033.93
AC9_DOUBLE_SUM,22478661033.929916
AC10_MAX_CAST,256178387.75
AC10_MAX_LEX,99999.72
AC11_JOBCOSTS_NN,62230
AC11_VENDORNAME_NN,52037
AC11_GLPERIOD_NN,18884
AC12_VENDORNUMBER_TYPE,BIGINT
AC12_DOT_ZERO_ROWS,0
```
Untouched by this round, exit 0. **PASS**, unregressed.

### AC9′ — `All_Sales_Data`: anchor invariant, four ratio floors, snapshots

From AC0′/AC1′ output: 16 columns unchanged (fingerprint MATCH); `ANCHOR,Job #,219,PASS`
(anchor invariant); `matchproject_ratio_floor`, `revtotal_ratio_floor`,
`enddate_ratio_floor`, `ROWS_FLOOR,200,219,PASS` (all four ratio floors PASS);
`startdate_is_date` PASS; the sum/max invariants (`revtotal_sum_exact_decimal`,
`earntotal_sum_exact_decimal`, `revtotal_maxcast_exact_decimal`) all PASS. `xl_date` range
unchanged (`startdate_min`/`startdate_max` snapshots: 2023-07-15/2027-03-15, matching the
committed range exactly — no extension). Absolute counts and both sums reported as
snapshots — see the committed-vs-observed table under C2 above. **PASS**.

### AC10, AC11 — raw SQL checks, unchanged

```sql
SELECT count(DISTINCT "Sales Year") FROM contract_view;   -- 4
SELECT count("match project") FROM contract_view;         -- 214
SELECT max("Revenue Total"::DECIMAL(18,2)) FROM asd_direct;  -- 1682000000.00
SELECT max("Revenue Total") FROM asd_direct;                 -- 99266455
```
Output: `AC10_SALESYEAR_DISTINCT,4` / `AC10_MATCHPROJECT_NN,214` /
`AC11_MAXCAST,1682000000.00` / `AC11_MAXLEX,99266455`. **PASS**, exact match, unchanged.

### AC12 — floors bite (re-verified on the reclassified ASD contract)

From AC0′/AC1′: `ROWS_FLOOR,50000,62230,PASS` (GL) and `ROWS_FLOOR,200,219,PASS` (ASD).
Throwaway-copy breach test (`@rows_floor: 200` → `300`):
```
CONTRACT,dsk-ac12-highfloor
...
ROWS_FLOOR,300,219,FAIL
SUMMARY,contracts=1,assertions=7,failures=1
```
Exit 1. **PASS**.

### AC13 — grammar and guards inherited (re-verified against current contracts)

- Zero `@assert` lines: `GUARD 1 FAILED: zero @assert directives parsed from: ...`, exit 1.
- Malformed `@assert` (missing colon): `GUARD 2 FAILED: malformed @assert directive(s), not
  skipped:`, exit 1.
- Missing `-- @sheet`: `ERROR,...,missing required directive: -- @sheet`, exit 1.
- Duplicated `-- @rows_floor`: `ERROR,...,duplicate directive: -- @rows_floor (found 2
  times)`, exit 1.

All non-zero exit, never silently skipped. **PASS.** (The duplicate-assertion-name case is
unchanged from round 1 and was not re-run separately since neither this round's contract
edits nor the harness edits touch that code path in `check-contract.ps1`.)

### AC14 — errors stay errors (re-verified)

Throwaway copy of the GL contract, `JOB_COSTS`'s source column renamed to
`NO_SUCH_COLUMN`:
```
ASSERT,jobcosts_sum_exact_decimal,ERROR,duckdb exited 1: Binder Error: Referenced column "NO_SUCH_COLUMN" not found in FROM clause!
...
ERROR,dsk-ac14-renamed,duckdb exited 1: Binder Error: Referenced column "NO_SUCH_COLUMN" not found in FROM clause! | ...
SUMMARY,contracts=1,assertions=4,failures=5
```
`ERROR` (not `FAIL`), exit **1**. **PASS.**

### AC15 — control: workbook unchanged, re-baselined per C3

Before this round's first command and after its last:
```
A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3
2026-09-25 08:48:13
```
Identical both times, and identical to round 1's own final (re-baselined) reading. **PASS.**

### AC16 — no BOM in any file this round touched

```powershell
foreach ($f in 'contracts\Clayco_Job_Costs_from_GL.sql','contracts\All_Sales_Data.sql',
               'tools\run-assertions.ps1','tools\make-truncation-fixtures.ps1',
               'checks\gl-facts.sql') {
    $b = [IO.File]::ReadAllBytes($f)
    $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
}
```
Output: `False` for all five. **PASS.**

### AC17 — refresh-proofing, demonstrated

Built a clean, minimal fixture (no blank-row trap — isolates C1's claim from the unrelated
truncation detector) and a contract using this round's reclassification pattern: anchor
invariant via `@anchor: NM`, floor via `@rows_floor: 1`, and `rows`/`sum_check` as
`@snapshot`/`@snapshot_committed` pairs (committed 5 / 120.00) instead of hard `@assert`
equalities.

**Step 1 — base fixture (5 rows, sum 120.00):**
```
CONTRACT,dsk-ac17-contract-base
ASSERT,amt_is_decimal,PASS
TRUNCATION_DEFAULT_ROWS,5
TRUNCATION_WITHDATA_ROWS,5
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,5
ANCHOR,NM,5,PASS
ROWS_FLOOR,1,5,PASS
FINGERPRINT,MATCH
SNAPSHOT,sum_check,120.00
SNAPSHOT,rows,5
SUMMARY,contracts=1,assertions=1,failures=0
```
Exit **0**.

**Step 2 — same contract shape, workbook has one more row appended (6 rows, sum 180.00):**
```
CONTRACT,dsk-ac17-contract-plus1
ASSERT,amt_is_decimal,PASS
TRUNCATION_DEFAULT_ROWS,6
TRUNCATION_WITHDATA_ROWS,6
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,6
ANCHOR,NM,6,PASS
ROWS_FLOOR,1,6,PASS
FINGERPRINT,MATCH
SNAPSHOT,sum_check,180.00
SNAPSHOT_DRIFT,sum_check,committed=120.00,observed=180.00
SNAPSHOT,rows,6
SNAPSHOT_DRIFT,rows,committed=5,observed=6
SUMMARY,contracts=1,assertions=1,failures=0
```
Exit **0**. **The invariant (`amt_is_decimal`) and the floor (`ROWS_FLOOR`) pass identically
both times; the anchor invariant reports the new total (6/6) and still PASSes; only the
snapshot values differ (with `SNAPSHOT_DRIFT` correctly surfacing the change) — and neither
change touches the exit code.** This is C1's central claim, demonstrated on a row-count
change rather than asserted in prose.

### AC18 — no snapshot gates the exit

**Half A — mutate a snapshot's committed value to a deliberately wrong number** (throwaway
copy of the real GL contract, `@snapshot_committed jobcosts_sum: 22478661033.93` →
`999999.99`):
```
CONTRACT,dsk-ac18-snapshot
...
SNAPSHOT,jobcosts_sum,22478661033.93
SNAPSHOT_DRIFT,jobcosts_sum,committed=999999.99,observed=22478661033.93
...
SUMMARY,contracts=1,assertions=4,failures=0
```
Exit **0**. The harness reports the (now-artificial) difference via `SNAPSHOT_DRIFT`, but
`failures` stays 0.

**Half B — breach a floor** (same style of throwaway copy, `vendorname_ratio_floor`'s
`>= 0.80` → `>= 0.99`):
```
CONTRACT,dsk-ac18-floor
...
ASSERT,vendorname_ratio_floor,FAIL,value is false
...
SUMMARY,contracts=1,assertions=4,failures=1
```
Exit **1**. **The two categories are wired differently, not merely labelled differently: an
identical-shape "this value should match/exceed X" check gates the exit code as a floor and
does not gate it as a snapshot.**

## Mutation proofs (all six)

Each: backed up `tools\run-assertions.ps1` first, applied the single-line change, ran the
check, then restored from backup and confirmed a byte-identical revert (`Compare-Object`
produced no output). All five original mutations applied to `tools\run-assertions.ps1`;
none touched `skills\query\duckdb-compat.sql`, the workbook, or `docs\tasks\`.

**1. Remove `stop_at_empty = false` from the harness's own with-data read, test on fixture
A.** Before: `TRUNCATION_WITHDATA_ROWS,5` / `TRUNCATION_ROWS_LOST,3`. After: `...ROWS,2` /
`...LOST,0` — rows-lost masked, exactly as specified. Reverted, byte-identical.

**2. Remove the all-null filter, test on fixture B.** Before: `TRUNCATION_WITHDATA_ROWS,3` /
`TRUNCATION_ROWS_LOST,0`. After: `...ROWS,5` / `...LOST,2` — phantom rows appear, AC4 fails.
Reverted, byte-identical.

**3. Narrow the all-null predicate to the contract's projected columns, test on fixture C
(the now-committed C4 fixture, replacing round 1's improvised one).** Before:
`TRUNCATION_WITHDATA_ROWS,3` vs. `CONSISTENCY_VIEW_ROWS,2` — mismatch correctly detected,
`failures=1`. After: `TRUNCATION_WITHDATA_ROWS,2` = `CONSISTENCY_VIEW_ROWS,2` — the two now
agree, the orphan-column case is masked, exactly as specified (`TRUNCATION_ROWS_LOST` goes
to `-1`, a related but distinct symptom of the same narrowing, reported honestly). Reverted,
byte-identical.

**4. Swap the generated predicate for `NOT (COLUMNS(*) IS NULL)`, test on fixture A.**
Before: `TRUNCATION_WITHDATA_ROWS,5`. After: `...ROWS,4` — the shorthand drops fixture A's
partially-null row, exactly the predicted value. Reverted, byte-identical.

**5. Point the anchor at `VENDOR_NAME` on a throwaway copy of the real GL contract.**
Before: `ANCHOR,JOB_COSTS,62230,PASS`. After: `ANCHOR,VENDOR_NAME,52037,FAIL`. Reverted (the
real contract was never touched — the mutation was applied to a `$env:TEMP` copy only).

**6 (new, the regression guard on C1 itself). Convert the anchor invariant back to a
hardcoded literal count, run against a fixture with a row added.** Applied to the AC17
"plus1" contract (6-row fixture): added `-- @assert row_count_hardcoded: (SELECT count(*)
FROM contract_view) = 5` (the *original*, pre-growth committed value — the direct fixture
analogue of reintroducing `count(JOB_COSTS) = 62110`).
```
CONTRACT,dsk-ac17-contract-plus1-hardcoded
ASSERT,amt_is_decimal,PASS
ASSERT,row_count_hardcoded,FAIL,value is false
...
ANCHOR,NM,6,PASS
ROWS_FLOOR,1,6,PASS
...
SNAPSHOT,rows,6
SNAPSHOT_DRIFT,rows,committed=5,observed=6
SUMMARY,contracts=1,assertions=2,failures=1
```
Exit **1** — `row_count_hardcoded` fails because the fixture grew from 5 to 6 rows, exactly
the failure mode round 1's four leftover hard-equality asserts hit on the live GL sheet.
Meanwhile the ANCHOR invariant, the floor, and the snapshot mechanism all correctly report
the new total without failing. **This is the proof that C1 solved the class, not just
today's numbers**: the old form breaks on the exact same kind of growth the new forms
absorb.

`git status` showed no tracked file modified outside this round's five files before
`RESULT-2.md` was written; `REVIEW-task-1.md` and the untracked `Revenue` file remain
untracked, per instructions.

## Summary of AC status

| AC | Status |
|---|---|
| AC0′ | **PASS** — exit 0, fresh worktree, no setup |
| AC1′ | **PASS** — `failures=0` literally holds on live, drifted data |
| AC2 | PASS (unchanged) |
| AC3 | PASS (unchanged) |
| AC4 | PASS (unchanged) |
| AC5 | PASS (unchanged) |
| AC6 | PASS (unchanged) |
| AC7′ | **PASS**, no caveat — every gating check refresh-proof |
| AC8 | PASS (unregressed) |
| AC9′ | **PASS**, no caveat |
| AC10 | PASS (unchanged) |
| AC11 | PASS (unchanged) |
| AC12 | PASS (re-verified) |
| AC13 | PASS (re-verified) |
| AC14 | PASS (re-verified) |
| AC15 | PASS — re-baselined per C3, zero drift within this round |
| AC16 | PASS |
| AC17 | **PASS** — invariants/floors pass across a row-count change, only snapshots differ |
| AC18 | **PASS** — snapshot mismatch exits 0, floor breach exits 1 |

**All checks pass. `SUMMARY,contracts=2,assertions=11,failures=0` holds on the live sheet.**

## Not done

Nothing in the CORRECTIONS section was skipped. C1, C2, C3, C4, AC17, AC18, and the added
mutation are all delivered and evidenced above.

## Concerns

- **The GL contract's snapshot-committed values are this round's own baseline (2026-09-25),
  not round 1's original (2026-09-24).** This is unavoidable — the workbook had already
  moved past round 1's committed figures before round 1 even finished, and asserting round
  1's now-stale numbers as "committed" would just relabel the same defect C1 exists to fix.
  The practical effect: today's `SNAPSHOT_DRIFT` reporting starts from a clean slate. The
  next time this sheet refreshes, `SNAPSHOT_DRIFT` lines will appear for `rows`,
  `jobcosts_nn`, `vendorname_nn`, `glperiod_nn`, and `jobcosts_sum` — that is the intended
  behavior (visible, not gating), not a bug.
- **`glperiod_range` and `startdate_range`'s hard-equality forms were deleted rather than
  reclassified into a fourth kind.** I judged this correct per C1's own rules (every
  assertion becomes invariant, floor, or snapshot) — GL's min/max is already discharged more
  strongly by `glperiod_is_date` plus `checks/gl-facts.sql`'s row-for-row AC8, so I dropped
  the redundant literal check outright rather than turn it into a floor with no headroom
  basis. ASD's min/max became `@snapshot startdate_min`/`startdate_max` instead of being
  dropped, since ASD has no equivalent independent second-decoder check to lean on. If Phil
  wants the deleted GL range value visible too, adding `@snapshot glperiod_min`/
  `glperiod_max` is a two-line change to the contract, not a design change.
- **`REVIEW-task-1.md`** was still untracked at the start of this round, as it was at the
  start of round 1. Left untracked per this round's explicit instruction; flagging again in
  case it was meant to be committed by whoever produced it.
- **The untracked `Revenue` file** (stray DuckDB database, magic bytes `DUCK`) is still
  present at repo root and still not matched by `.gitignore`. Left untracked and not added,
  per instructions.
- **AC13's duplicate-assertion-name sub-case** (from round 1's AC13) was not independently
  re-run this round, since neither this round's contract edits nor `run-assertions.ps1`'s
  edits touch that code path (`check-contract.ps1`'s own duplicate-name guard, inherited
  verbatim and untouched). The four sub-cases that *are* re-verified above exercise the same
  guard machinery on the current contract files.
