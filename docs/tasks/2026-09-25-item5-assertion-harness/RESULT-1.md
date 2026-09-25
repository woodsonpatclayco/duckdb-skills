# RESULT-1 — item 5: multi-contract assertion harness

Serves: "if a sheet quietly stops giving me all the rows, or a column quietly goes
blank, I want to be told — not to find out from a number that looks plausible and is
wrong." This is item 5 (the harness itself); items 3+4 (sheet discovery and the first
contract) already shipped. Nothing left after this on PLAN-4 §5 except the
direction-aware row-count tolerance, which this spec explicitly split into its own,
not-yet-written item.

Commit: `d590a82` (pushed to `origin/main`). Branch: `main`.

## Files changed

- `contracts/Clayco_Job_Costs_from_GL.sql` (modified) — added the `stop_at_empty=false`
  + explicit all-null-row read rule; added the four new directives
  (`@sheet`/`@anchor`/`@rows_floor`/`@fingerprint`); replaced the hard
  `row_count = 62110` `@assert` with the floor + consistency mechanism (no longer an
  `@assert` — driven entirely by the harness from the new directives, per the spec's
  "the absolute count becomes reported context, not a gate"). Left the other four
  pre-existing `@assert` lines (`jobcosts_nn`, `vendorname_nn`, `glperiod_nn`,
  `jobcosts_sum`) byte-for-byte as committed by item 4 — see "Disagreements /
  limitations" below, this is exactly what causes AC0/AC1/AC4/AC7 to show non-zero
  failures today.
- `contracts/All_Sales_Data.sql` (new) — the second contract: 16 columns, hostile
  quoted headers (`"Job #"`, `"Start Date"`, `"Revenue Total"`, `"match project"`), the
  read rule, the four directives, 12 `@assert` lines including the cast-before-compare
  guard on `MAX("Revenue Total")`.
- `tools/run-assertions.ps1` (new) — the harness. Discovers `contracts\*.sql` (or runs
  one file via `-Contract`, including paths outside `contracts\`, so fixtures never
  become a discoverable "third contract"). Parses and guards the four new directives
  itself; delegates every `@assert` result to `tools\check-contract.ps1`, run as a
  genuinely separate `powershell.exe -File` process (never `&` in-process or
  dot-sourced — `check-contract.ps1` ends in `exit N`, which would otherwise kill this
  script's own host). Independently discovers every column the raw sheet returns
  (never the contract's own projection), generates the all-null predicate explicitly,
  and materializes a `TEMP TABLE` for both the contract's own data and an independent
  raw with-data read so per-contract cost stays at two full workbook reads plus one
  cheap describe, rather than one read per assertion.
- `tools/make-truncation-fixtures.ps1` (new) — builds fixture A (the partially-null
  trap) and fixture B (trailing blanks only), plus a matching throwaway contract for
  each, in `$env:TEMP`.
- `checks/gl-facts.sql` (modified) — updated the AC5 comment to record that it is now
  the orphan-column/truncation detector (relabelled, per the spec), not just an
  item-4-era sanity check. No SQL logic changed.
- `TASK.md` — committed per this project's convention that specs are committed
  artifacts (was untracked before this round).

Not touched: `docs\tasks\**`, the workbook, `skills\query\duckdb-compat.sql`,
`REVIEW-task-1.md`, `Revenue`.

## Disagreements / limitations — READ THIS FIRST

**The workbook drifted a full extra day beyond what the spec measured, and this makes
AC0, AC1, AC4, and part of AC7 literally unsatisfiable without violating the spec's own
"never adjust a figure to make a check pass" rule.**

The spec's own baseline (`RESULT-1.md`'s antecedent, TASK.md) was measured 2026-09-24.
When I started this round (2026-09-25), the workbook had already moved again:

| metric | committed (item 4, 2026-09-24) | observed (this round, 2026-09-25) |
|---|---|---|
| GL rows | 62,110 | **62,230** |
| GL `VENDOR_NAME` non-null | 51,928 | **52,037** |
| GL `GL_PERIOD` non-null | 18,764 | **18,884** |
| GL `SUM(JOB_COSTS)` | 22,454,928,166.83 | **22,478,661,033.93** |
| GL `GL_PERIOD` min/max | 2026-07-01 / 2026-10-01 | **unchanged** |
| `All_Sales_Data` (all figures) | — | **unchanged, zero drift** |

Item 4's own pre-existing `@assert` lines `jobcosts_nn`, `vendorname_nn`, `glperiod_nn`,
and `jobcosts_sum` are hard equalities against the 2026-09-24 numbers. Deliverable 4's
instruction was narrow and explicit: *"replace the hard `row_count = 62110` with the
floor plus the consistency equality... every committed figure must be unchanged."* It
named only `row_count`. It did not ask me to touch `jobcosts_nn`/`vendorname_nn`/
`glperiod_nn`/`jobcosts_sum`, and the top-level instructions for this round were
explicit and repeated: *"A difference is drift to be reported, not a failure to be
fixed. Never adjust a figure to make a check pass."*

I followed that instruction literally: those four lines are untouched, byte-for-byte
as item 4 committed them. Given today's actual data, they **evaluate to FAIL** — not
because anything is broken, but because the sheet grew between 2026-09-24 and
2026-09-25, exactly as it grew three times in the six weeks before that (per TASK.md's
own drift table). The practical effect:

- **AC0** ("exits 0 on the first invocation with no prior setup") — the harness runs
  correctly end-to-end from a fresh worktree (proven below), but exits **1**, because
  4 of the GL contract's 6 `@assert` lines now fail on live data.
- **AC1** ("`SUMMARY,...,failures=0`. Exit 0.") — actual: `failures=4`, exit 1, for the
  same reason.
- **AC4** ("On fixture B: ... exit 0") — this one is unaffected; it names fixture B
  specifically, not the real contracts, and passes exactly as specified.
- **AC7** ("`SUM(JOB_COSTS)` 22,454,928,166.83 ... FINGERPRINT,MATCH") — the structural
  claims (consistency, fingerprint) hold exactly; the absolute figures have moved, and
  are reported side-by-side above and in AC7 below, per the spec's own drift policy.

I did not adjust either the four pre-existing values or the harness's failure counting
to paper over this. I consider this the correct reading of an explicit, repeated
instruction, but flagging it plainly here rather than silently presenting a "clean"
run: **the multi-contract harness itself is correct and every mechanism it is meant to
prove (truncation detection, orphan-column detection, floors, fingerprint, cast
fidelity) works exactly as specified — the only thing keeping this from a literal
`failures=0` today is that item 4 shipped four hardcoded snapshot values that the spec
told me not to touch, and the workbook grew again before I could run the checks.**

Two secondary, much smaller points, recorded rather than silently resolved:

1. **Mutation 3's exact wording doesn't fit the real GL/ASD data.** The spec's mutation
   bullet is *"narrow the all-null predicate to the contract's projected columns → the
   orphan-column case is dropped silently; the consistency check in AC7 fails."*
   Today, both real contracts project every column the sheet returns (GL: 13 of 13;
   `All_Sales_Data`: 16 of 16) — there is no orphan column to drop, so this mutation is
   a no-op against the real GL contract (narrowing "all raw columns" to "projected
   columns" changes nothing when the two sets are identical). This matches the
   spec's own reviewer note (`REVIEW-task-1.md`, finding B3): the defect this mutation
   exercises was itself only demonstrable earlier via a purpose-built fixture, not the
   real sheets. I built one (documented under "Mutation proofs" below) rather than
   silently skip the mutation or claim a no-op result was "passing."
2. **`TRUNCATION_ROWS_LOST` can be negative** when the with-data read undercounts the
   default read (this only happens under the mutation-3 scenario above, on the
   3-column orphan fixture, never on real data) — reported as observed rather than
   clamped, since a negative value is itself diagnostic (something is wrong).

## Acceptance checks

Commands and output exactly as run. All from repo root unless noted.

### AC0 — throwaway worktree, first invocation, no setup

```
git worktree add C:\Users\woodsonp\Claude\Dev\dsk-ac0-worktree d590a82
cd C:\Users\woodsonp\Claude\Dev\dsk-ac0-worktree
Test-Path .duckdb-skills          # False — confirms no gitignored state present
.\tools\run-assertions.ps1
```

Output: identical to the AC1 output below (same commit, same data). **Result: the
script runs correctly end-to-end with zero prior setup — `LOAD excel`, `xl_date`
resolution via `$PSScriptRoot`, and both contracts all worked on the first try in a
worktree with no `.duckdb-skills\`.** Exit code is **1**, not the specified 0 — see
"Disagreements" above. Worktree removed afterward (`git worktree remove --force`).

### AC1 — no-argument run, both contracts discovered

```
tools\run-assertions.ps1
```

```
CONTRACT,All_Sales_Data
ASSERT,jobnum_nn,PASS
ASSERT,matchproject_nn,PASS
ASSERT,revtotal_nn,PASS
ASSERT,earntotal_nn,PASS
ASSERT,startdate_nn,PASS
ASSERT,enddate_nn,PASS
ASSERT,startdate_is_date,PASS
ASSERT,startdate_range,PASS
ASSERT,revtotal_sum,PASS
ASSERT,earntotal_sum,PASS
ASSERT,salesyear_distinct,PASS
ASSERT,revtotal_maxcast,PASS
TRUNCATION_DEFAULT_ROWS,219
TRUNCATION_WITHDATA_ROWS,219
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,219
ANCHOR,Job #,219,PASS
ROWS_FLOOR,200,219,PASS
FINGERPRINT,MATCH
CONTRACT,Clayco_Job_Costs_from_GL
ASSERT,jobcosts_nn,FAIL,value is false
ASSERT,vendorname_nn,FAIL,value is false
ASSERT,glperiod_nn,FAIL,value is false
ASSERT,glperiod_is_date,PASS
ASSERT,glperiod_range,PASS
ASSERT,jobcosts_sum,FAIL,value is false
TRUNCATION_DEFAULT_ROWS,62230
TRUNCATION_WITHDATA_ROWS,62230
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,62230
ANCHOR,JOB_COSTS,62230,PASS
ROWS_FLOOR,50000,62230,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=2,assertions=18,failures=4
```

Elapsed: ~14.2s. `CONTRACT,All_Sales_Data` and `CONTRACT,Clayco_Job_Costs_from_GL` both
present. **PASS on structure** (both contracts discovered, all mechanisms ran); **FAIL
on the literal `failures=0`** — 4 failures, all four are the pre-existing
2026-09-24-snapshot `@assert` lines on live-drifted GL data (see "Disagreements").
Exit code **1**, not 0.

### AC2 — fixtures built, harness against fixture A gives 5 rows / sum 120.00

```
tools\make-truncation-fixtures.ps1
tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-a-contract.sql
```

```
fixture_a_workbook=C:\Users\woodsonp\AppData\Local\Temp\dsk-fixture-a.xlsx
fixture_a_contract=C:\Users\woodsonp\AppData\Local\Temp\dsk-fixture-a-contract.sql
fixture_b_workbook=C:\Users\woodsonp\AppData\Local\Temp\dsk-fixture-b.xlsx
fixture_b_contract=C:\Users\woodsonp\AppData\Local\Temp\dsk-fixture-b-contract.sql

CONTRACT,dsk-fixture-a-contract
ASSERT,row_count,PASS
ASSERT,sum_check,PASS
TRUNCATION_DEFAULT_ROWS,2
TRUNCATION_WITHDATA_ROWS,5
TRUNCATION_ROWS_LOST,3
CONSISTENCY_VIEW_ROWS,5
ANCHOR,NM,5,PASS
ROWS_FLOOR,1,5,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=2,failures=1
```

**PASS**: `row_count` (=5) and `sum_check` (=120.00) both `PASS`, both values read off
fixture A's own `VALUES` list per the spec's own numbers. (Overall exit is 1 — AC2 does
not ask for exit 0 here; AC3 covers the exit code.)

### AC3 — the detector fires on fixture A

Same run as AC2. `TRUNCATION_DEFAULT_ROWS,2`, `TRUNCATION_WITHDATA_ROWS,5`,
`TRUNCATION_ROWS_LOST,3`, exit **1**. **PASS**, exact match to spec.

### AC4 — no false alarm on fixture B

```
tools\run-assertions.ps1 -Contract $env:TEMP\dsk-fixture-b-contract.sql
```

```
CONTRACT,dsk-fixture-b-contract
ASSERT,row_count,PASS
TRUNCATION_DEFAULT_ROWS,3
TRUNCATION_WITHDATA_ROWS,3
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,3
ANCHOR,NM,3,PASS
ROWS_FLOOR,1,3,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=1,failures=0
```

`TRUNCATION_ROWS_LOST,0`, exit **0**. **PASS**, exact match to spec.

### AC5 — the partially-null trap: with-data count is 5, not 4

From AC2's output: `TRUNCATION_WITHDATA_ROWS,5`. Confirmed by mutation (below) that the
`COLUMNS(*)` shorthand would give 4. **PASS**.

### AC6 — control: both real sheets show zero truncation

From AC1's output: GL `TRUNCATION_ROWS_LOST,0` (62,230/62,230); `All_Sales_Data`
`TRUNCATION_ROWS_LOST,0` (219/219). **PASS**.

### AC7 — the GL correction moves nothing

```
tools\run-assertions.ps1 -Contract contracts\Clayco_Job_Costs_from_GL.sql
```

| figure | committed (2026-09-24) | observed (2026-09-25) |
|---|---|---|
| `CONSISTENCY_VIEW_ROWS` | 62,110 | **62,230** |
| `SUM(JOB_COSTS)` | 22,454,928,166.83 | **22,478,661,033.93** |
| `jobcosts_nn` floor | 62,110 | **62,230** |
| `vendorname_nn` floor | 51,928 | **52,037** |
| `glperiod_nn` floor | 18,764 | **18,884** |
| `FINGERPRINT` | MATCH | **MATCH** |

The structural claims hold exactly (consistency: `TRUNCATION_WITHDATA_ROWS,62230` =
`CONSISTENCY_VIEW_ROWS,62230`; fingerprint MATCH). The absolute figures have drifted —
reported here side by side, not adjusted. **PASS on the correction being neutral and
on internal consistency; the absolute-value comparison shows the drift documented
above, which is why `jobcosts_nn`/`vendorname_nn`/`glperiod_nn`/`jobcosts_sum` show
FAIL in AC1.**

### AC8 — `checks\gl-facts.sql` not regressed

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

Every line still present, same shape as item 4 shipped. `AC5_VIEW_ROWS` = `AC5_DIRECT_ROWS`
(62,230 = 62,230, both drifted together from committed 62,110 — the two-independent-
reads-agree structure is unregressed). `AC8_A_MINUS_B`/`AC8_B_MINUS_A` still both 0.
`AC9` decimal has no float tail and differs from double. `AC10` cast vs lex still
differ correctly. `AC12` type still `BIGINT`, dot-zero rows still 0. **PASS** (structure
unregressed; absolute values drifted, as documented).

### AC9 — `All_Sales_Data` figures

```
tools\run-assertions.ps1 -Contract contracts\All_Sales_Data.sql
```

All 12 `@assert` lines `PASS` (from AC1's output above). Directly measured:
rows 219, columns 16, `Job #` 219, `match project` 214, `Revenue Total` 201,
`Earnings Total` 201, `Start Date` 150, `End Date` 145, `SUM("Revenue Total")`
36,580,445,574.84, `SUM("Earnings Total")` 1,439,728,975.91, `xl_date` range
2023-07-15–2027-03-15. **Every figure matches the spec exactly — zero drift on this
sheet.** **PASS.**

### AC10 — hostile headers reached, provably

```sql
SELECT count(DISTINCT "Sales Year") FROM contract_view;   -- 4
SELECT count("match project") FROM contract_view;         -- 214
```

Output: `AC10_SALESYEAR_DISTINCT,4` / `AC10_MATCHPROJECT_NN,214`. **PASS**, exact match.

### AC11 — cast before compare, on the new contract

```sql
SELECT max("Revenue Total"::DECIMAL(18,2)) FROM asd_direct;  -- cast first
SELECT max("Revenue Total") FROM asd_direct;                 -- lexicographic
```

Output: `AC11_MAXCAST,1682000000.00` / `AC11_MAXLEX,99266455`. **PASS**, exact match
(and `revtotal_maxcast` `PASS`es as a live `@assert` in the shipped contract).

### AC12 — the floors bite

From AC1: `ROWS_FLOOR,50000,62230,PASS` (GL) and `ROWS_FLOOR,200,219,PASS`
(`All_Sales_Data`). Both carry and pass their floor.

Throwaway-copy breach test:

```
Copy-Item contracts\All_Sales_Data.sql $env:TEMP\dsk-ac12-highfloor.sql
# @rows_floor: 200  ->  @rows_floor: 300
tools\run-assertions.ps1 -Contract $env:TEMP\dsk-ac12-highfloor.sql
```

```
CONTRACT,dsk-ac12-highfloor
...
ROWS_FLOOR,300,219,FAIL
SUMMARY,contracts=1,assertions=12,failures=1
```
Exit **1**. The failing contract is named (`CONTRACT,dsk-ac12-highfloor`) and the
`ROWS_FLOOR` line shows the breach directly. **PASS.**

### AC13 — grammar and guards inherited

All four sub-cases run against throwaway copies in `$env:TEMP`, deleted after:

- Zero `@assert` lines:
  `ERROR,<name>,GUARD 1 FAILED: zero @assert directives parsed from: ...`, exit 1.
- Malformed `@assert` (missing colon):
  `ERROR,<name>,GUARD 2 FAILED: malformed @assert directive(s), not skipped:`, exit 1.
- Duplicate `@assert` name (same malformed-directive grammar path in
  `check-contract.ps1` — a duplicate name is Guard 2's territory, confirmed):
  `ERROR,<name>,GUARD 2 FAILED: ...`, exit 1.
- Missing `-- @sheet`:
  `ERROR,<name>,missing required directive: -- @sheet`, exit 1.
- Duplicated `-- @rows_floor`:
  `ERROR,<name>,duplicate directive: -- @rows_floor (found 2 times)`, exit 1.

All five: non-zero exit, never silently skipped. **PASS.**

### AC14 — errors stay errors

```
# throwaway copy of the GL contract, JOB_COSTS's sibling column renamed to
# NO_SUCH_COLUMN (a column the sheet does not have)
tools\run-assertions.ps1 -Contract $env:TEMP\dsk-ac14-renamed-column.sql
```

```
CONTRACT,dsk-ac14-renamed-column
ASSERT,jobcosts_nn,ERROR,duckdb exited 1: Binder Error: Referenced column "NO_SUCH_COLUMN" not found in FROM clause!
ERROR,dsk-ac14-renamed-column,duckdb exited 1: Binder Error: Referenced column "NO_SUCH_COLUMN" not found in FROM clause! | ...
SUMMARY,contracts=1,assertions=1,failures=2
```

`ERROR` (not `FAIL`) with the `Binder Error` text verbatim, exit **1**. **PASS.**

### AC15 — control: workbook unchanged

Baseline captured before any work this session:
- SHA-256: `A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3`
- `LastWriteTime`: `2026-09-25 08:48:13`

Final check, after every command in this document had been run:
- SHA-256: `A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3`
- `LastWriteTime`: `2026-09-25 08:48:13`

**Identical. PASS.**

Note on the spec's own pinned AC15 baseline
(`CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F`,
`2026-09-24T09:38:56`): the hash observed at the *start* of this session already
differed from that, with a **later** `LastWriteTime` (2026-09-25 08:48:13 vs.
2026-09-24 09:38:56) — per the spec's own interpretation rule, that is a SharePoint
sync, not a write by this session, and I re-baselined against it (both baseline and
final readings above are from this session, and they agree with each other, which is
the actual control this check performs).

### AC16 — no BOM in any file this item touched

```powershell
foreach ($f in 'contracts\Clayco_Job_Costs_from_GL.sql','contracts\All_Sales_Data.sql',
               'tools\run-assertions.ps1','tools\make-truncation-fixtures.ps1',
               'checks\gl-facts.sql') {
    $b = [IO.File]::ReadAllBytes($f)
    $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
}
```
Output: `False` for all five (i.e. no BOM on any). **PASS.**

## Mutation proofs (all five)

Each: backed up the file first, applied the single-line change, ran the check, then
restored from backup and re-ran to confirm a byte-identical revert
(`Compare-Object` produced no output — files identical). All mutations were applied to
`tools\run-assertions.ps1` (4, 3, "swap predicate", and mutations 1/2) or to
`contracts\Clayco_Job_Costs_from_GL.sql` (mutation 5) — never to
`skills\query\duckdb-compat.sql`, never to the workbook, never under `docs\tasks\`.

**1. Remove `stop_at_empty = false` from the harness's own with-data read (the
"fixture-A check path"), test on fixture A.**

Before: `TRUNCATION_DEFAULT_ROWS,2` / `TRUNCATION_WITHDATA_ROWS,5` /
`TRUNCATION_ROWS_LOST,3`.
After mutation: `TRUNCATION_DEFAULT_ROWS,2` / `TRUNCATION_WITHDATA_ROWS,2` /
`TRUNCATION_ROWS_LOST,0` — **AC3 fails to report the lost rows**, exactly as specified.
After revert: back to `TRUNCATION_ROWS_LOST,3`. Confirmed via `Compare-Object` that
`run-assertions.ps1` matched its pre-mutation backup byte-for-byte.

**2. Remove the all-null filter from the harness's own with-data read, test on
fixture B.**

Before: `TRUNCATION_WITHDATA_ROWS,3` / `TRUNCATION_ROWS_LOST,0`.
After mutation: `TRUNCATION_WITHDATA_ROWS,5` / `TRUNCATION_ROWS_LOST,2` — **fixture B
gains its two phantom trailing-blank rows and AC4 fails**, exactly as specified.
After revert: back to `TRUNCATION_ROWS_LOST,0`, exit 0. Confirmed byte-identical revert.

**3. Narrow the all-null predicate to the contract's projected columns.**

The real GL contract projects all 13 of the sheet's 13 columns (and `All_Sales_Data`
all 16 of 16) — there is no orphan column today, so this mutation is a provable no-op
against either real contract (see "Disagreements" above). I built a purpose-built
3-column throwaway fixture (`dsk-orphan-fixture.xlsx`: columns `C1,C2,C3`; a contract
that only projects `C1,C2`; last row populated only in the unprojected `C3`) — the
same shape the spec's own reviewer round used to first prove this defect
(`REVIEW-task-1.md`, finding B3).

Before mutation (harness discovers all 3 raw columns independently of the contract):
`TRUNCATION_WITHDATA_ROWS,3` (row 3 survives — it has data in `C3`) vs.
`CONSISTENCY_VIEW_ROWS,2` (the contract's own narrow filter drops it) — **mismatch
correctly detected**, `failures=1`, exit 1.
After mutation (harness's own column source narrowed to the `@fingerprint` directive,
i.e. the contract's projected columns): `TRUNCATION_WITHDATA_ROWS,2` = `CONSISTENCY_VIEW_ROWS,2`
— **the two now silently agree; the orphan-column case is masked** exactly as the spec
predicts ("dropped silently"). (The run still exits non-zero overall, via
`TRUNCATION_ROWS_LOST` going to `-1` against the unaffected default-read count of 3 —
a related but distinct symptom of the same narrowing, reported honestly rather than
suppressed; the specific claim under test — the consistency check being fooled — is
the `2 = 2` shown above.)
After revert: `TRUNCATION_WITHDATA_ROWS,3` again, mismatch against `CONSISTENCY_VIEW_ROWS,2`
restored, detection working again. Confirmed byte-identical revert via `Compare-Object`.

**4. Swap the generated predicate for `NOT (COLUMNS(*) IS NULL)`, test on fixture A.**

Before: `TRUNCATION_WITHDATA_ROWS,5`.
After mutation: `TRUNCATION_WITHDATA_ROWS,4` — **exactly the spec's predicted value**
(the shorthand drops fixture A's partially-null row `r6`).
After revert: back to `TRUNCATION_WITHDATA_ROWS,5`. Confirmed byte-identical revert.

**5. Point the anchor at `VENDOR_NAME` on the real GL contract.**

Before: `ANCHOR,JOB_COSTS,62230,PASS`.
After mutation (`-- @anchor: JOB_COSTS` → `-- @anchor: VENDOR_NAME`):
`ANCHOR,VENDOR_NAME,52037,FAIL` — **the anchor check fails, naming `VENDOR_NAME`**,
exactly as specified (52,037 of 62,230 non-null — drifted numbers, same conclusion as
the spec's 51,928 of 62,110).
After revert: `ANCHOR,JOB_COSTS,62230,PASS` again. Confirmed via re-run that the
contract file's content matched its pre-mutation backup.

## Summary of AC status

| AC | Status |
|---|---|
| AC0 | Mechanism PASS (runs cleanly, zero setup, from a throwaway worktree); exit code is 1 not 0, due to drift — see Disagreements |
| AC1 | Structure PASS (both contracts, correct discovery); `failures=0` not met (`failures=4`, drift) — see Disagreements |
| AC2 | PASS |
| AC3 | PASS |
| AC4 | PASS |
| AC5 | PASS |
| AC6 | PASS |
| AC7 | Structural claims PASS (consistency, fingerprint); absolute figures drifted, reported side by side |
| AC8 | PASS (structure unregressed; absolute values drifted, reported) |
| AC9 | PASS (zero drift on this sheet) |
| AC10 | PASS |
| AC11 | PASS |
| AC12 | PASS |
| AC13 | PASS |
| AC14 | PASS |
| AC15 | PASS |
| AC16 | PASS |

12 of 17 fully PASS with no caveat; AC0/AC1/AC7/AC8 pass on every structural/mechanism
claim and only diverge from the spec's literal wording on absolute figures that moved
due to genuine, out-of-my-control workbook drift between the spec's measurement time
and this round's implementation time — documented above with committed-vs-observed
values throughout, never silently adjusted.

## Not done

Nothing in the spec's five deliverables was skipped. The only deliberate omission is
the one the spec itself calls out as split to a follow-on item: direction-aware
row-count tolerance (replaced here, as specified, by the two conservative absolute
floors).

## Concerns

- `REVIEW-task-1.md` and `TASK.md` were both untracked at the start of this round.
  Per this project's convention that specs and reviews are committed artifacts, I
  committed `TASK.md` (the spec) but left `REVIEW-task-1.md` untracked, per this
  round's explicit instruction to leave it alone. Flagging this asymmetry in case it
  was meant to be committed by whoever produced it.
- The untracked `Revenue` file (a stray DuckDB database, magic bytes `DUCK`) is still
  present at repo root and still not matched by `.gitignore`. Left untracked and not
  added, per instructions, but it will keep showing up in `git status` for every future
  round until either `.gitignore` is updated or the file is removed — neither of which
  was in scope here.
- The four pre-existing hardcoded `@assert` snapshot values on the GL contract
  (`jobcosts_nn`, `vendorname_nn`, `glperiod_nn`, `jobcosts_sum`) will fail again the
  next time this live sheet grows, exactly as `row_count` did before this round. They
  were out of scope to fix here (deliverable 4 named only `row_count`), but they are
  the same defect in the same contract, and a future round converting them to floors
  (as `row_count` was converted here) would make `tools\run-assertions.ps1`'s
  no-argument run actually reach `failures=0` on ordinary data growth.
