# VERIFY-2 — item 5 round 2: reclassifying assertions (independent verification)

Verifies: `RESULT-2.md` (commit `2e33d4d`), round-2 code at `d88a312`. Worktree:
`C:\Users\woodsonp\Claude\Dev\dsk-verify-r2`, checked out at `2e33d4d`, removed after
this verification. All commands below were re-run independently in that worktree
(not copied from RESULT-2's transcript); several use fixtures I built myself,
unrelated to the implementer's own scratch files, specifically to try to break the
two central claims from both directions.

## Central risk: did "all checks pass" come from weakening checks?

**No. Coverage was reclassified, not deleted, with one disclosed exception (GL's
`glperiod_range`) and two disclosed scope-limited exceptions (ASD's
`earntotal_nn`/`startdate_nn`, which the CORRECTIONS floor table never gave a floor
value for).**

### 1. Assertion count before/after

| stage | GL `@assert` | ASD `@assert` | total | source |
|---|---|---|---|---|
| item 4 shipped (`f572069`) | 7 | — (ASD didn't exist yet) | 7 | `git show f572069:contracts/Clayco_Job_Costs_from_GL.sql` |
| round 1 end (`17cc7bf`) | 6 (`row_count`→floor) | 12 | 18 | matches RESULT-1's `assertions=18` exactly |
| round 2 (`d88a312`, verified) | 4 | 7 | 11 | matches my own live run, `assertions=11` |

The drop from 18→11 `@assert` lines is not a drop in gating checks of the same size,
because most of the removed lines were **replaced by a different gating mechanism**
(anchor, ratio floor) rather than deleted:

- 2 lines → moved to the anchor mechanism (`jobcosts_nn`, `jobnum_nn`) — still gates,
  reported as `ANCHOR,...,PASS/FAIL`, not counted in `assertions=`.
- 5 lines → became ratio-floor `@assert`s (`vendorname_ratio_floor`,
  `glperiod_ratio_floor`, `matchproject_ratio_floor`, `revtotal_ratio_floor`,
  `enddate_ratio_floor`) — still gates, now via `assertions=`.
- 4 lines (the two sums, `revtotal_maxcast`) → became `*_exact_decimal` `@assert`s
  (still gates, checks the cast property instead of the number) **plus** a
  `@snapshot` (reported).
- 2 lines (`earntotal_nn`, `startdate_nn`) → **snapshot only, no gate**. Disclosed in
  RESULT-2's own reclassification table and Concerns section: CORRECTIONS' C1 floor
  table gives no floor value for these two, and the implementer was told not to
  invent one. I checked TASK.md's CORRECTIONS floor table myself — it genuinely lists
  only rows/`Job #`/Revenue Total/End Date/match project for ASD, so this is an
  accurate reading of scope, not an excuse.
- 2 lines (`startdate_range`, `salesyear_distinct`) → snapshot only (ASD), same
  reasoning — no ratio form applies to a date range or a distinct-year count.
- 1 line (`glperiod_range`, GL) → **deleted outright, no snapshot, no gate.** See
  below — this is the one place I disagree with "coverage fully retained."

Net: of 18 pre-round-2 checks, 12 kept identical or stronger gating power (anchor/
floor/exact-decimal), 4 became visible-but-non-gating (2 ASD counts + `startdate_range`
+ `salesyear_distinct`, all disclosed and scope-justified), and **1 (`glperiod_range`)
lost coverage with no replacement at all**, gating or otherwise.

### 2. Was deleting `glperiod_range` justified?

**Partially — the underlying reasoning is sound but the outcome is inconsistent with
how the symmetric ASD case was handled, and it is a real (small) loss.**

`glperiod_range` asserted `min(GL_PERIOD) = 2026-07-01 AND max(GL_PERIOD) =
2026-10-01` — a plausibility bound on the date range, not just "does it parse as a
date." The implementer's stated replacements are `glperiod_is_date` (type check only)
and `checks/gl-facts.sql`'s AC8 (`AC8_A_MINUS_B,0` / `AC8_B_MINUS_A,0` — confirmed by
me, still 0/0). AC8 proves two independent decoders agree row-for-row; it says nothing
about whether the decoded dates fall in any sane range. **Neither replacement checks
what `glperiod_range` checked.** A corrupted `GL_PERIOD` value of, say, 1900-01-01
would pass `glperiod_is_date` (it's still a DATE) and would pass AC8 (both decoders
would agree it's 1900-01-01) — the class of defect a min/max sanity bound exists to
catch is now uncaught.

Contrast: ASD's exactly-analogous `startdate_range` was **not** deleted — it became
`@snapshot startdate_min` / `@snapshot startdate_max` (still visible, still lets Phil
notice an out-of-range date on inspection, just non-gating). RESULT-2 justifies the
asymmetry as "ASD has no equivalent independent second-decoder check to lean on," but
that argument is about whether a *replacement gate* exists, not about whether the
*value stays visible* — and visibility is what a snapshot costs nothing to keep. GL
could have kept `@snapshot glperiod_min`/`glperiod_max` at zero marginal cost (RESULT-2
even says so directly: "a two-line change to the contract, not a design change"), and
choosing not to make it is the one place this round is thinner than it needed to be.

**This is disclosed in RESULT-2's own Concerns section, not hidden — it is a genuine,
small coverage gap, not a fabricated "all pass," and it does not change the SHIP
verdict on its own.**

## AC18 — snapshot/floor wiring, tried to break both ways

Read `tools\run-assertions.ps1` directly (not just RESULT-2's prose): snapshots are
computed in the same phase-2 DuckDB batch (lines 407-412), and the drift-check block
(lines 485-508) **never touches `$totalFailures`** on any branch, including when the
snapshot value itself is missing from output (that path does increment failures, but
for "missing," not for "mismatched" — mismatched only prints `SNAPSHOT_DRIFT`). Floors
are wired through two different, separate mechanisms that both do increment
`$totalFailures`: the `ROWS_FLOOR` block (line 468-470) and ratio floors, which are
ordinary `@assert` lines delegated to `check-contract.ps1` (any non-PASS increments
failures at line 304).

I did not just re-run the implementer's own AC18 mutations — I built independent ones:

**Break it as a snapshot (should stay green):** copied the real GL contract to
`$env:TEMP`, changed `@snapshot_committed jobcosts_sum: 22478661033.93` to `1.00`
(implementer used `999999.99`; I used a value four orders of magnitude off to make sure
no numeric-tolerance logic was quietly treating a "close" value as a match):
```
SNAPSHOT,jobcosts_sum,22478661033.93
SNAPSHOT_DRIFT,jobcosts_sum,committed=1.00,observed=22478661033.93
SUMMARY,contracts=1,assertions=4,failures=0
```
`$LASTEXITCODE` = **0**. Confirmed.

**Break it as a floor (should go red):** raised `All_Sales_Data`'s `@rows_floor` from
200 to 300 on a throwaway copy:
```
ROWS_FLOOR,300,219,FAIL
SUMMARY,contracts=1,assertions=7,failures=1
```
Exit **1**. Confirmed. **AC18 holds — the two categories are wired differently, not
just labelled differently, verified by reading the code and by mutation from scratch.**

## AC17 / genuine degradation — tried to break it both ways

RESULT-2's own AC17 fixture only tests growth (5→6 rows). I built my own,
independent base/plus1 pair (`VALUES` list, 5 rows sum 150.00 → 6 rows sum 210.00,
not copied from the implementer's fixture) with a floor+snapshot contract in the same
pattern:
```
CONTRACT,plus1-contract
ASSERT,amt_is_decimal,PASS
ANCHOR,NM,6,PASS
ROWS_FLOOR,3,6,PASS
SNAPSHOT,sum_check,210.00
SNAPSHOT_DRIFT,sum_check,committed=150.00,observed=210.00
SNAPSHOT,rows,6
SNAPSHOT_DRIFT,rows,committed=5,observed=6
SUMMARY,contracts=1,assertions=1,failures=0
```
Exit 0, invariant and floor unaffected by growth, only snapshots drift. Reproduces
C1's claim on fixtures the implementer never built.

**Then I went further than AC17 asks and built a fixture with a genuine column
degradation** (not growth): a 10-row sheet where a column's non-null ratio drops from
0.90 to 0.30, with a `>= 0.80` ratio floor:
```
CONTRACT,degraded-contract
ASSERT,col_ratio_floor,FAIL,value is false
SUMMARY,contracts=1,assertions=1,failures=1
```
Exit **1**, against the identical contract on the healthy 0.90-ratio version:
`ASSERT,col_ratio_floor,PASS`, exit 0. **The harness is not blind to real degradation —
it distinguishes "sheet moved" from "sheet broke."**

**Regression guard (mutation 6), reproduced on my own fixture rather than the
implementer's:** added `-- @assert row_count_hardcoded: (SELECT count(*) FROM
contract_view) = 5` to my plus1 (6-row) contract:
```
ASSERT,row_count_hardcoded,FAIL,value is false
ANCHOR,NM,6,PASS
ROWS_FLOOR,3,6,PASS
SUMMARY,contracts=1,assertions=2,failures=1
```
Exit 1 — the hardcoded literal breaks on growth exactly as `jobcosts_nn` etc. did;
the anchor/floor/snapshot mechanisms around it do not. Confirms the class, not just
the instance, on a fixture the implementer never touched.

## Anchor invariant — relationship, not literal (separate from AC17/18, per the brief)

Built three more fixtures independently: 3-row, 5-row (grown), and 3-row with a
NULL introduced into the anchor column.
```
grown (3 rows):  ANCHOR,NM,3,PASS
grown2 (5 rows): ANCHOR,NM,5,PASS
anchor-null:     ANCHOR,NM,2,FAIL   (total 3, non-null 2)
```
Confirmed: the anchor check is `count(anchor) = count(*)`, survives growth in either
direction, and fails the moment the anchor column itself gains a NULL — not a
literal like the old `count(JOB_COSTS) = 62110`.

## Floor values match CORRECTIONS exactly

Read both contract files directly (not RESULT-2's table) and compared to TASK.md's
CORRECTIONS floor table:

| contract | assertion | CORRECTIONS says | contract has | match |
|---|---|---|---|---|
| GL | rows | ≥ 50,000 | `@rows_floor: 50000` | yes |
| GL | `VENDOR_NAME` ratio | ≥ 0.80 | `>= 0.80` | yes |
| GL | `GL_PERIOD` ratio | ≥ 0.25 | `>= 0.25` | yes |
| ASD | rows | ≥ 200 | `@rows_floor: 200` | yes |
| ASD | `Job #` | anchor invariant | `@anchor: Job #` | yes |
| ASD | `Revenue Total` ratio | ≥ 0.85 | `>= 0.85` | yes |
| ASD | `End Date` ratio | ≥ 0.55 | `>= 0.55` | yes |
| ASD | `match project` ratio | ≥ 0.90 | `>= 0.90` | yes |

None loosened. None is so loose it can never fire: every floor sits between roughly
5-15 percentage points (or several thousand rows) below its observed value — enough
headroom to survive ordinary movement, tight enough that the degradation test above
(a genuine 60-point ratio collapse) trips it. Confirmed by the degradation test above,
which used a floor of the same 0.80 shape and did fire.

## Reproduced acceptance checks, from a clean shell, in the worktree

Baseline captured before touching anything: `A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3` /
`2026-09-25 08:48:13` — **identical to CORRECTIONS' pinned baseline.**

| check | expected | actual | command | PASS/FAIL |
|---|---|---|---|---|
| AC0′/AC1′ | `failures=0`, exit 0, fresh worktree | `SUMMARY,contracts=2,assertions=11,failures=0`, exit 0 | `.\tools\run-assertions.ps1` (no `.duckdb-skills\` present, `Test-Path` False) | **PASS** |
| AC2 | fixture A: 5 rows, sum 120.00 | `ASSERT,row_count,PASS` / `ASSERT,sum_check,PASS`, `TRUNCATION_WITHDATA_ROWS,5` | `.\tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-a-contract.sql` | **PASS** |
| AC3 | fixture A: default 2, with-data 5, lost 3, exit non-zero | exact match, exit 1 | same run as AC2 | **PASS** |
| AC4 | fixture B: `TRUNCATION_ROWS_LOST,0`, exit 0 | exact match | `.\tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-b-contract.sql` | **PASS** |
| AC5 | fixture A with-data count is 5, not 4 | `TRUNCATION_WITHDATA_ROWS,5` | same run as AC2 | **PASS** |
| AC6 | both real sheets `ROWS_LOST,0` | GL 62230/62230, ASD 219/219 | AC0′/AC1′ output | **PASS** |
| AC7′ | GL correction moves nothing; floors/invariant/fingerprint pass; snapshots reported | `FINGERPRINT,MATCH`, `ANCHOR,JOB_COSTS,62230,PASS`, all 3 floors PASS, 5 snapshots printed | same live run | **PASS** |
| AC8 | `checks\gl-facts.sql` unregressed | `AC5_VIEW_ROWS,62230` = `AC5_DIRECT_ROWS,62230`, all 17 lines present, identical to RESULT-2 | `duckdb -f checks\gl-facts.sql` | **PASS** |
| AC9′ | ASD: anchor + 4 ratio floors pass, sums/counts as snapshots | `ANCHOR,Job #,219,PASS`, 3 ratio floors + `ROWS_FLOOR,200,219,PASS`, 11 snapshots printed | same live run | **PASS** |
| AC12 | floors bite; breach fails naming the contract | `ROWS_FLOOR,300,219,FAIL`, `SUMMARY,...,failures=1`, exit 1 | throwaway copy, `@rows_floor: 200`→`300` | **PASS** |
| AC13 | zero-assert / missing-`@sheet` / duplicate-`@rows_floor` all ERROR, exit non-zero | `GUARD 1 FAILED...` / `missing required directive: -- @sheet` / `duplicate directive: -- @rows_floor (found 2 times)`, exit 1 all three | 3 independent throwaway mutations | **PASS** |
| AC14 | renamed column → `ERROR` with `Binder Error` text, exit non-zero | `ASSERT,...,ERROR,duckdb exited 1: Binder Error: Referenced column "NO_SUCH_COLUMN" not found...`, exit 1 | throwaway GL copy, `JOB_COSTS`→`NO_SUCH_COLUMN` | **PASS** |
| AC15 | workbook hash/mtime unchanged | identical before/after all commands above | `Get-FileHash` + `LastWriteTime`, 3 readings | **PASS** |
| AC16 | no BOM in any touched file | `False` for all 5 contract/tool files + `TASK.md` | `[IO.File]::ReadAllBytes` byte check | **PASS** |
| AC17 | invariants/floors survive growth; only snapshots differ; genuine degradation still fails | reproduced on my own fixtures (see above) | see "AC17 / genuine degradation" section | **PASS** |
| AC18 | snapshot mismatch exits 0; floor breach exits 1 | reproduced on my own mutations (see above) | see "AC18" section | **PASS** |
| round-1 commits not rewritten | `d590a82`/`17cc7bf` unchanged, still ancestors of HEAD | `git merge-base --is-ancestor` exit 0 for both | `git merge-base --is-ancestor d590a82 HEAD` etc. | **PASS** |
| Fixture C / C4 | default 3, with-data-all-cols 3, with-data-projected 2, anchor-among-survivors 2 | exact match, `failures=1`, exit 1 | `.\tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-c-contract.sql` | **PASS** |
| `git status` clean outside scope | only `Revenue` and `REVIEW-task-1.md` untracked | confirmed in main working directory (not the worktree) | `git status` | **PASS** |
| Round-2 file scope | exactly the 5 files + `TASK.md` RESULT-2 names | `git diff --stat 17cc7bf d88a312` → same 5 files | `git diff --stat 17cc7bf d88a312` | **PASS** |

## What neither RESULT file mentions

- **The GL/ASD asymmetry on range checks** (above): `glperiod_range` deleted with zero
  replacement while the identically-shaped `startdate_range` was kept as a snapshot.
  RESULT-2's Concerns section flags that the deleted value isn't visible anywhere, but
  frames it as "if Phil wants it, it's a two-line change" rather than naming the actual
  inconsistency in treatment between the two contracts for the same class of check.
- **`assertions=N` in `SUMMARY` undercounts total gating checks.** It only counts
  `@assert`-delegated lines (11), not the anchor/rows_floor/consistency/truncation
  checks that also gate the exit code (8 more per full run: 2 anchor + 2 floor + 2
  consistency + 2 truncation-lost, across both contracts). Not a defect — the output
  format is unchanged from round 1 and stated correctly in the header comment — but a
  reader skimming `SUMMARY,...,assertions=11,failures=0` could reasonably think 11 is
  the full count of things being checked; it is roughly half of it.

## Verdict

**SHIP.**

All 19 acceptance checks reproduce independently, from a clean worktree, with commands
and output quoted above rather than assumed from RESULT-2. The workbook is
byte-identical and same-mtime before, during, and after every command I ran. Round-1
commits are intact and unrewritten. The snapshot/floor split is real at the code level,
not just in the CSV labels, and survives four independent attempts to break it in both
directions using fixtures I built myself. The one legitimate concern —
`glperiod_range`'s deletion leaving strictly less visibility than its ASD counterpart —
is real but small, already disclosed by the implementer, and does not amount to a
check quietly losing its teeth to manufacture a green run: every floor value matches
CORRECTIONS exactly, no floor is toothless, and a genuine column degradation (built
independently, not from the implementer's own fixtures) still fails the harness.