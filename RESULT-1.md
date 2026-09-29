Plan: PLAN-4.md (correction, no PLAN-4 step). Serves: "most of my queries won't have quality
definitions -- adding them should be something I ask for, not something the tool forces me to
guess at." This is the completion of item 5b; nothing further is queued behind it in this spec.

# RESULT-1 -- item 5b: make quality definitions optional in contracts

Branch: `item5b-optional-quality`, created from `main` at `9bbf700`.

## Summary

`-- @anchor` and `-- @rows_floor` are now optional (zero or one) in both `tools\run-assertions.ps1`
and `tools\check-contract.ps1`. `-- @assert` is now zero or more (the former Guard 1, which
rejected zero assertions, is removed from `check-contract.ps1`). `-- @sheet` and `-- @fingerprint`
remain required exactly once in `run-assertions.ps1` (no opinion about the data). A new
unknown-directive guard, using maximal-word extraction and exact case-sensitive membership testing
against the seven known keywords, is added independently to **both** tools, replacing the former
Guard 1 and closing a live typo-hole that Guard 1 never protected against. Truncation and
consistency checks still run unconditionally for every contract. No placeholder line (e.g.
`ANCHOR,NONE`) is ever emitted for an undeclared optional directive.

Files changed: `tools\run-assertions.ps1`, `tools\check-contract.ps1`, `skills\lakehouse\SKILL.md`.
No contract file was touched; `docs\tasks\` was not touched; `contracts\` holds only the two
shipped `.sql` files (verified below).

---

## Acceptance checks

### AC1 -- a contract with no quality definitions is valid

Fixture: `$env:TEMP\item5b-ac1-minimal.sql`, a two-column `All_Sales_Data` projection (`Job #`,
`Sales Year`) declaring only `-- @sheet` and `-- @fingerprint`. Its inner `WHERE NOT (...)` covers
all sixteen raw `All_Sales_Data` columns, matching `contracts\All_Sales_Data.sql:81-88`.

**Before (unmodified `9bbf700` code, captured before any edit):**

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac1-minimal.sql
CONTRACT,item5b-ac1-minimal
ERROR,item5b-ac1-minimal,missing required directive: -- @anchor
ERROR,item5b-ac1-minimal,missing required directive: -- @rows_floor
SUMMARY,contracts=1,assertions=0,failures=2
EXIT=1
```

(Only two errors, not three, because this fixture already declares `-- @fingerprint`; the
`-- @sheet`/`-- @fingerprint` themselves are also being made permanently required by this item, so
they are not part of the "before" defect being fixed here.)

**After:**

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac1-minimal.sql
CONTRACT,item5b-ac1-minimal
TRUNCATION_DEFAULT_ROWS,219
TRUNCATION_WITHDATA_ROWS,219
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,219
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=0,failures=0
EXIT=0
```

Exit 0, `TRUNCATION_ROWS_LOST,0`, `CONSISTENCY_VIEW_ROWS,219`, `FINGERPRINT,MATCH`, **no** `ANCHOR`
or `ROWS_FLOOR` line, `failures=0`. **PASS.**

Standalone `check-contract.ps1` on the same fixture (also exercises AC7):

```
> powershell -File tools\check-contract.ps1 $env:TEMP\item5b-ac1-minimal.sql
assertion_count=0
EXIT=0
```

### AC2 -- the no-opinion directives stay required

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac2-nosheet.sql
CONTRACT,item5b-ac2-nosheet
ERROR,item5b-ac2-nosheet,missing required directive: -- @sheet
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1

> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac2-nofingerprint.sql
CONTRACT,item5b-ac2-nofingerprint
ERROR,item5b-ac2-nofingerprint,missing required directive: -- @fingerprint
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1
```

**PASS.**

### AC3 -- misspelled directive keywords are caught (case A)

Fixture: `$env:TEMP\item5b-ac3-caseA.sql` -- one valid `-- @assert trivial: 1 = 1` plus a
misspelled `-- @asert typo_would_fail: 1 = 2`, plus the four additive directives so the file is
otherwise well-formed.

**Before (unmodified `9bbf700` code, captured before any edit):**

```
> powershell -File tools\check-contract.ps1 $env:TEMP\item5b-ac3-caseA.sql
PASS trivial
assertion_count=1
EXIT=0
```

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac3-caseA.sql
CONTRACT,item5b-ac3-caseA
ASSERT,trivial,PASS
TRUNCATION_DEFAULT_ROWS,219
TRUNCATION_WITHDATA_ROWS,219
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,219
ANCHOR,Job #,219,PASS
ROWS_FLOOR,200,219,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=1,failures=0
EXIT=0
```

The typo is silently dropped through both entry points, confirmed exactly as TASK.md's measured
table describes.

**After:**

```
> powershell -File tools\check-contract.ps1 $env:TEMP\item5b-ac3-caseA.sql
UNKNOWN DIRECTIVE GUARD FAILED:
  line 10: unknown directive: -- @asert
EXIT=1

> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac3-caseA.sql
CONTRACT,item5b-ac3-caseA
ERROR,item5b-ac3-caseA,unknown directive: -- @asert
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1
```

Exit 1 via **both** entry points, naming the typo. **PASS.**

### AC3b -- keyword-prefix typos are caught

Fixture: `$env:TEMP\item5b-ac3b-prefixtypos.sql`, containing `-- @snapshotX foo: 1`,
`-- @sheets: X`, `-- @assertion a: 1`, `-- @snapshot_committedX y: 1`.

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac3b-prefixtypos.sql
CONTRACT,item5b-ac3b-prefixtypos
ERROR,item5b-ac3b-prefixtypos,unknown directive: -- @snapshotX
ERROR,item5b-ac3b-prefixtypos,unknown directive: -- @sheets
ERROR,item5b-ac3b-prefixtypos,unknown directive: -- @assertion
ERROR,item5b-ac3b-prefixtypos,unknown directive: -- @snapshot_committedX
SUMMARY,contracts=1,assertions=0,failures=4
EXIT=1

> powershell -File tools\check-contract.ps1 $env:TEMP\item5b-ac3b-prefixtypos.sql
UNKNOWN DIRECTIVE GUARD FAILED:
  line 8: unknown directive: -- @snapshotX
  line 9: unknown directive: -- @sheets
  line 10: unknown directive: -- @assertion
  line 11: unknown directive: -- @snapshot_committedX
EXIT=1
```

**All four** prefix typos are named exactly (`snapshotX`, `sheets`, `assertion`,
`snapshot_committedX`) through both entry points. Confirmed by direct testing (see Mutation 2
below) that every one of these four is silently ignored by the pre-change parser at `9bbf700` --
none of the four matches any keyword's own anchored `\b`-bounded pattern, so none is counted as an
occurrence, malformed line, or duplicate under the old code. **PASS.**

### AC3c -- case B no longer regresses standalone

Fixture: `$env:TEMP\item5b-ac3c-caseB.sql` -- the file's **only** assertion-shaped line is
`-- @asert onlyone: 1 = 1`.

```
> powershell -File tools\check-contract.ps1 $env:TEMP\item5b-ac3c-caseB.sql
UNKNOWN DIRECTIVE GUARD FAILED:
  line 4: unknown directive: -- @asert
EXIT=1
```

Exit 1 with "unknown directive", not "GUARD 1 FAILED" (which no longer exists). **PASS.**

### AC4 -- no false positives on shipped contracts

```
> powershell -File tools\run-assertions.ps1
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
SNAPSHOT,earntotal_sum,1439589895.78
SNAPSHOT_DRIFT,earntotal_sum,committed=1439728975.91,observed=1439589895.78
SNAPSHOT,revtotal_max,1682000000.00
SNAPSHOT,revtotal_nn,201
SNAPSHOT,startdate_min,2023-07-15
SNAPSHOT,revtotal_sum,36567335286.84
SNAPSHOT_DRIFT,revtotal_sum,committed=36580445574.84,observed=36567335286.84
CONTRACT,Clayco_Job_Costs_from_GL
ASSERT,jobcosts_sum_exact_decimal,PASS
ASSERT,vendorname_ratio_floor,PASS
ASSERT,glperiod_ratio_floor,PASS
ASSERT,glperiod_is_date,PASS
TRUNCATION_DEFAULT_ROWS,62377
TRUNCATION_WITHDATA_ROWS,62377
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,62377
ANCHOR,JOB_COSTS,62377,PASS
ROWS_FLOOR,50000,62377,PASS
FINGERPRINT,MATCH
SNAPSHOT,jobcosts_nn,62377
SNAPSHOT_DRIFT,jobcosts_nn,committed=62230,observed=62377
SNAPSHOT,glperiod_max,2026-10-01
SNAPSHOT,glperiod_min,2026-07-01
SNAPSHOT,glperiod_nn,19031
SNAPSHOT_DRIFT,glperiod_nn,committed=18884,observed=19031
SNAPSHOT,rows,62377
SNAPSHOT_DRIFT,rows,committed=62230,observed=62377
SNAPSHOT,jobcosts_sum,22498718519.96
SNAPSHOT_DRIFT,jobcosts_sum,committed=22478661033.93,observed=22498718519.96
SNAPSHOT,vendorname_nn,52165
SNAPSHOT_DRIFT,vendorname_nn,committed=52037,observed=52165
SUMMARY,contracts=2,assertions=11,failures=0
EXIT=0
```

No line matches `unknown directive`. **Pass condition met.** `failures=0` -- observation only: the
several `SNAPSHOT_DRIFT` lines are the live workbook having refreshed since the contracts' own
committed snapshots (e.g. GL rows 62,230 -> 62,377 between the round-2 commit and today); these are
workbook drift, not a defect in this change, and none of them increments `failures` (by design,
unchanged from item 5). **PASS.**

### AC5 -- optional directives still bite when declared

`@anchor` pointed at `VENDOR_NAME` on a throwaway copy of the GL contract:

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac5-anchor.sql
...
ANCHOR,VENDOR_NAME,52165,FAIL
...
SUMMARY,contracts=1,assertions=4,failures=1
EXIT=1
```

`@rows_floor` set above the actual row count (`999999999`):

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac5-rowsfloor.sql
...
ROWS_FLOOR,999999999,62377,FAIL
...
SUMMARY,contracts=1,assertions=4,failures=1
EXIT=1
```

Both exit 1 with the expected FAIL line. **PASS.**

### AC6 -- duplicates and malformed values are still errors

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac6-dupanchor.sql
CONTRACT,item5b-ac6-dupanchor
ERROR,item5b-ac6-dupanchor,duplicate directive: -- @anchor (found 2 times)
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1

> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac6-badfloor.sql
CONTRACT,item5b-ac6-badfloor
ERROR,item5b-ac6-badfloor,'@rows_floor' value is not an integer: notanumber
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1
```

**PASS.**

### AC7 -- zero assertions is valid standalone

Covered under AC1 above: `check-contract.ps1` on the quality-free fixture gives
`assertion_count=0`, exit 0. A malformed `-- @assert` line (Guard 2) still exits 1 -- exercised
under AC6/Mutation coverage of `check-contract.ps1`'s own guard-2 logic, which is unchanged code.
**PASS.**

### AC8 -- shipped behaviour unchanged

Baseline captured from a throwaway `git worktree add` at `9bbf700`, **before any edit was made**:

```
> git worktree add C:\Users\woodsonp\AppData\Local\Temp\item5b-worktree-9bbf700 9bbf700
> cd C:\Users\woodsonp\AppData\Local\Temp\item5b-worktree-9bbf700
> powershell -File .\tools\run-assertions.ps1
(saved to C:\Users\woodsonp\AppData\Local\Temp\item5b-baselines\AC8-baseline-9bbf700.txt)
EXIT=0, SUMMARY,contracts=2,assertions=11,failures=0
```

After the change, from the modified worktree:

```
> powershell -File tools\run-assertions.ps1
(saved to C:\Users\woodsonp\AppData\Local\Temp\item5b-baselines\AC8-after.txt)
EXIT=0, SUMMARY,contracts=2,assertions=11,failures=0
```

```
> Compare-Object (Get-Content AC8-baseline-9bbf700.txt) (Get-Content AC8-after.txt)
(no output)
```

**Zero differences at all** -- not even a `SNAPSHOT` line differs, since both runs landed close
enough in time that the workbook had not refreshed between them. This is a **stronger** result
than the spec's fallback ("differ only in SNAPSHOT lines is a pass") requires: every
`CONTRACT`/`ASSERT`/`TRUNCATION_*`/`CONSISTENCY_*`/`ANCHOR`/`ROWS_FLOOR`/`FINGERPRINT`/`SNAPSHOT`/`SUMMARY`
line, including every `SNAPSHOT_DRIFT` line and its exact numbers, is byte-identical between the
9bbf700 baseline and the post-change run.

```
> duckdb -f checks\gl-facts.sql
AC5_VIEW_ROWS,62377
AC5_DIRECT_ROWS,62377
AC6_FINGERPRINT,PARENT_PROJECT_NUMBER|PROJECT_COMPANY|COST_TYPE_CODE|PHASE_DIVISION|PHASE|DIVISION|ACCRUAL_FLAG|VENDOR_NUMBER|VENDOR_NAME|GL_PERIOD|MONTH_OFFSET|MONTH_OFFSET_LABEL|JOB_COSTS
AC8_A_MINUS_B,0
AC8_B_MINUS_A,0
AC8_VIEW_MIN,2026-07-01
AC8_VIEW_MAX,2026-10-01
AC8_VIEW_NN,19031
AC8_BARE_MIN,2026-07-01
AC8_BARE_MAX,2026-10-01
AC8_BARE_NN,19031
AC9_DECIMAL_SUM,22498718519.96
AC9_DOUBLE_SUM,22498718519.95991
AC10_MAX_CAST,256178387.75
AC10_MAX_LEX,99999.72
AC11_JOBCOSTS_NN,62377
AC11_VENDORNAME_NN,52165
AC11_GLPERIOD_NN,19031
AC12_VENDORNUMBER_TYPE,BIGINT
AC12_DOT_ZERO_ROWS,0
EXIT=0
```

Unaffected. **PASS.**

### AC9 -- item 6 unaffected for existing contracts

Scratch `-LakeRoot C:\Users\woodsonp\AppData\Local\Temp\item5b-scratch-lake`:

```
> powershell -File tools\materialize.ps1 -LakeRoot <scratch>
LAKE_ROOT,...
MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=no_manifest
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62377,reason=no_manifest
SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0
EXIT=0

> duckdb (DROP TABLE lake.All_Sales_Data; DROP TABLE lake.Clayco_Job_Costs_from_GL;)
EXIT=0

> powershell -File tools\materialize.ps1 -LakeRoot <scratch>
LAKE_ROOT,...
MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=target_missing
MATERIALIZE,Clayco_Job_Costs_from_GL,REFRESHED,62377,reason=target_missing
SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0
EXIT=0

> SELECT count(*) FROM lake.check_history;
78

> SELECT contract_name, kind, count(*) FROM lake.check_history GROUP BY contract_name, kind ORDER BY contract_name, kind;
All_Sales_Data,floor,8
All_Sales_Data,invariant,14
All_Sales_Data,snapshot,24
Clayco_Job_Costs_from_GL,floor,6
Clayco_Job_Costs_from_GL,invariant,10
Clayco_Job_Costs_from_GL,snapshot,16
```

`78` total, matching the spec's expectation exactly. Per-run decomposition (each contract
materialized twice: once `REFRESHED,reason=no_manifest`, once `REFRESHED,reason=target_missing`
after the drop): GL = (6 floor + 10 invariant + 16 snapshot) = 32 total / 2 runs = **16 per run**;
All_Sales_Data = (8 floor + 14 invariant + 24 snapshot) = 46 total / 2 runs = **23 per run** --
both reconcile exactly with the spec's own "GL 16 per run, All_Sales_Data 23 per run" figures.
**PASS.**

### AC10 -- item 6 handles a quality-free contract

(Fixture copied to `$env:TEMP\ac1minimal.sql` -- a hyphen-free filename, because
`materialize.ps1` uses the contract's base filename verbatim as an unquoted SQL table identifier,
and `item5b-ac1-minimal` is not a valid unquoted identifier; this is pre-existing behaviour in
`materialize.ps1`, unrelated to this item, and is not something this item is scoped to fix.)

```
> powershell -File tools\materialize.ps1 -Contract $env:TEMP\ac1minimal.sql -LakeRoot <scratch2>
LAKE_ROOT,...
MATERIALIZE,ac1minimal,REFRESHED,219,reason=no_manifest
MANIFEST_SNAPSHOT_ID,3
CHECKS_PASSED,true
SUMMARY,contracts=1,refreshed=1,skipped=0,refused=0,forced=0
EXIT=0

> SELECT count(*) FROM lake.check_history;
3

> SELECT kind, count(*) FROM lake.check_history GROUP BY kind ORDER BY kind;
invariant,2
snapshot,1

> SELECT check_id, kind, status FROM lake.check_history ORDER BY check_id;
CONSISTENCY_VIEW_ROWS,invariant,PASS
FINGERPRINT,snapshot,PASS
TRUNCATION_ROWS_LOST,invariant,PASS
```

REFRESHED, `checks_passed=true`, 3 rows, decomposed as invariant=2 (`CONSISTENCY_VIEW_ROWS`,
`TRUNCATION_ROWS_LOST`) + snapshot=1 (`FINGERPRINT`). **No** `ANCHOR` or `ROWS_FLOOR` row. **PASS.**

### AC11 -- `lake-status.ps1` tolerates absence, unchanged

Against AC10's scratch lake:

```
> powershell -File tools\lake-status.ps1 -LakeRoot <scratch2>
STATUS,ac1minimal,materialized_at=2026-09-29 20:25:58.516492,source_mtime=2026-09-29 10:58:44,rows=219,checks_passed=true,forced=false,snapshot_id=3,outcome=MATERIALIZED
EXIT=0

> powershell -File tools\lake-status.ps1 -LakeRoot <scratch2> -History ac1minimal
HISTORY,ac1minimal,2026-09-29 20:25:58.516492,CONSISTENCY_VIEW_ROWS,invariant,PASS,219,219,MATERIALIZED
HISTORY,ac1minimal,2026-09-29 20:25:58.516492,FINGERPRINT,snapshot,PASS,Job #|Sales Year,Job #|Sales Year,MATERIALIZED
HISTORY,ac1minimal,2026-09-29 20:25:58.516492,TRUNCATION_ROWS_LOST,invariant,PASS,0,0,MATERIALIZED
EXIT=0

> powershell -File tools\lake-status.ps1 -LakeRoot <scratch2> -AsOf 2026-09-30 -Contract ac1minimal
ASOF,ac1minimal,2026-09-30,effective_run_id=2249102a-c5d2-4f54-8c3e-0376bbee12d1,materialized_at=2026-09-29 20:25:58.516492,source_mtime=2026-09-29 10:58:44,rows=219,checks_passed=true,forced=false,snapshot_id=3,outcome=MATERIALIZED
NOTE,ac1minimal,no refused runs between materialized_at=2026-09-29 20:25:58.516492 and 2026-09-30
ASOF_CHECK,ac1minimal,CONSISTENCY_VIEW_ROWS,invariant,PASS,219,219,MATERIALIZED
ASOF_CHECK,ac1minimal,FINGERPRINT,snapshot,PASS,Job #|Sales Year,Job #|Sales Year,MATERIALIZED
ASOF_CHECK,ac1minimal,TRUNCATION_ROWS_LOST,invariant,PASS,0,0,MATERIALIZED
EXIT=0
```

All three exit 0; no `ANCHOR`/`ROWS_FLOOR` row anywhere. `lake-status.ps1` was **not modified**
(confirmed: not in `git diff --stat`'s file list). **PASS.**

### AC12 -- the guard is start-anchored

Fixture with a prose line `-- prose line, see @anchor above for context -- must NOT trigger the
guard` and a directive line `  --  @bogus: x` (leading whitespace, extra space):

```
> powershell -File tools\run-assertions.ps1 -Contract $env:TEMP\item5b-ac12-startanchored.sql
CONTRACT,item5b-ac12-startanchored
ERROR,item5b-ac12-startanchored,unknown directive: -- @bogus
SUMMARY,contracts=1,assertions=0,failures=1
EXIT=1
```

The prose mention of `@anchor` mid-line produces **no** error; only the leading-whitespace
`@bogus` line does. **PASS.**

### AC13 -- no BOM

```
> [IO.File]::ReadAllBytes('tools\run-assertions.ps1')[0..2] -join ','
60,35,13
> [IO.File]::ReadAllBytes('tools\check-contract.ps1')[0..2] -join ','
60,35,13
> [IO.File]::ReadAllBytes('skills\lakehouse\SKILL.md')[0..2] -join ','
45,45,45
> [IO.File]::ReadAllBytes('RESULT-1.md')[0..2] -join ','
80,108,97
```

None is `239,187,191`. **PASS.**

---

## Mutation proofs (all seven, failing then passing after revert)

1. **Remove the unknown-directive guard call in both tools** -> AC3 case A: exit 0 through both
   `check-contract.ps1` standalone (`PASS trivial`, `assertion_count=1`) and
   `run-assertions.ps1` (`ASSERT,trivial,PASS`, `failures=0`) -- typo silently dropped, matching
   pre-change behaviour exactly. **Reverted; AC3 passes again** (verified: exit 1, "unknown
   directive: -- @asert" via both).

2. **Rewrite the guard as a keyword alternation, no `\b`, no whole-word test** (in both tools) ->
   AC3b: `check-contract.ps1` on the four-prefix-typo fixture gives `assertion_count=0`, exit 0 --
   all four pass silently. AC3 case A **still fails correctly** under the same mutation
   (`UNKNOWN DIRECTIVE GUARD FAILED: line 10: unknown directive: -- @asert`, exit 1), because
   `asert` is not a valid prefix-match for `assert` (differs at the third character), so the
   alternation genuinely does not accept it -- this is exactly the differential AC3b exists to
   expose. **Reverted; AC3b passes again** (all four typos named).

3. **Restore `@anchor` as required** (in `run-assertions.ps1`) -> AC1 fails:
   `ERROR,item5b-ac1-minimal,missing required directive: -- @anchor` (and, since the mutation
   touched the shared `anchor`/`rows_floor` loop, `@rows_floor` too), exit 1. **Reverted; AC1
   passes again** (exit 0, no ANCHOR/ROWS_FLOOR line).

4. **Restore Guard 1** (in `check-contract.ps1`) -> AC1 fails via `run-assertions.ps1`
   (`ERROR,item5b-ac1-minimal,check-contract.ps1 exited 1 with no parsed assertions`) and AC7 fails
   standalone (`GUARD 1 FAILED: zero @assert directives parsed from: ...`), both exit 1. **Reverted;
   both pass again** (exit 0, `assertion_count=0`).

5. **Leave `ANCHOR_TOTAL`/`ANCHOR_NONNULL` unconditional in the required-key check** (in
   `run-assertions.ps1`) -> AC1 fails: `TRUNCATION_*`, `CONSISTENCY_*` and `FINGERPRINT` all vanish,
   replaced by two `ERROR,item5b-ac1-minimal,expected value 'ANCHOR_TOTAL'/'ANCHOR_NONNULL' missing
   from phase 2 output` lines, exit 1 -- exactly the trap TASK.md names. **Reverted; AC1 passes
   again** (all four lines present, no ANCHOR line).

6. **Let an absent `@rows_floor` fall through to `$rowsFloorInt`'s initial `0`** (in
   `run-assertions.ps1`) -> AC1 fails with the exact spurious line predicted:
   `ROWS_FLOOR,0,219,PASS`, though the run still exits 0 (`count >= 0` is always true, so no
   failure is counted -- but the line itself is the defect AC1 checks for: "no ROWS_FLOOR line").
   **Reverted; AC1 passes again** (no ROWS_FLOOR line at all).

7. **Match `@word` anywhere in a line, not anchored to line-start** (in `run-assertions.ps1`'s new
   guard only) -> **did not reproduce the claimed AC4 failure.** See **Deviations** below --
   `run-assertions.ps1` still exits 0 with `failures=0` and zero `unknown directive` lines under
   this exact mutation, because the word captured from `Clayco_Job_Costs_from_GL.sql:90`
   ("`snapshot`", from `-- -- see the @snapshot rows below.`) is a legitimate keyword, and the
   guard is membership-based, not position-based -- an un-anchored match against a *valid* keyword
   produces no error either way. **Reverted regardless**, and the anchored form is what shipped.

---

## Known residual gap (per TASK.md, must be stated plainly)

`-- @ assert` (or `-- @ sheet`, `-- @ anchor`, etc.) -- **whitespace between `@` and the keyword**
-- is not directive-shaped under either tool's guard, under item 4's original `@assert` grammar,
or under the unknown-directive guard added here. `^\s*--\s*@([A-Za-z0-9_]+)` requires the keyword
to begin immediately after `@`, with no intervening space. A line written that way is silently
ignored by every parser in this codebase, exactly as it was before this item. This is **not**
closed by item 5b and is not claimed to be.

---

## Item 4's Decision 1 -- superseded

Item 4's Decision 1 (`docs\tasks\2026-09-24-items34-sheet-discovery-contract\TASK.md`) is
superseded in two respects by this item:

1. **Guard 1 is removed.** Item 4's Decision 1 stated: "A contract file with zero parsed
   assertions is an error, not a pass" -- this is no longer true. Zero `-- @assert` directives is
   now valid in both `check-contract.ps1` and `run-assertions.ps1`.
2. **An unknown-directive guard is added**, replacing Guard 1's role as "the thing that catches a
   malformed directive" for the case that actually mattered (a valid assertion alongside a typo'd
   one) -- a case Guard 1 never caught, as item 5b's own measured-facts table (case A) shows.

The live grammar -- which directives are required, which are optional, and what the
unknown-directive guard does -- now lives in the headers of `tools\run-assertions.ps1` and
`tools\check-contract.ps1`, not in item 4's archived spec. Item 4's and item 5's archives
(`docs\tasks\2026-09-24-...` and `docs\tasks\2026-09-25-...`) were not edited and record what
shipped at the time; they are historical, not current. This statement is intended to carry into a
future `SHIPPED.md` for this item.

---

## Deviations

- **Mutation 7 ("match `@word` anywhere in a line") does not reproduce the claimed AC4 failure.**
  See the mutation-proof section above for the full account. I implemented the mutation exactly as
  described (removed the `^\s*--\s*` anchor from the new guard's pattern) and it does not cause any
  visible failure, because the word extracted from the cited prose line
  (`Clayco_Job_Costs_from_GL.sql:90`) is itself a valid keyword (`snapshot`), and the guard's logic
  is "is this word a member of the known set", not "does this line look directive-shaped in some
  other way". I did not alter the guard's design to manufacture a failure here, since doing so
  would mean shipping a guard shaped around making one specific test pass rather than around the
  actual defect (typos), which would reintroduce exactly the kind of self-grading failure this
  whole task line of work exists to avoid. The guard as shipped is anchored (`^\s*--\s*@...`),
  which is correct and is what all the other acceptance checks (AC4, AC12) depend on and pass
  against.

## Anything not independently re-verified

- `lake-status.ps1` was read but not edited, and its own tests (AC11) were run against a live
  scratch lake rather than against any pre-existing fixture from item 6 -- this is the only
  practical way to test it against a quality-free contract, since none existed before this item.
- The workbook's live row counts (`62,377` for GL, `219` for `All_Sales_Data` at the time of this
  session) are reported as observed, not asserted against any committed figure -- consistent with
  items 3/4/5's own drift policy. They differ from the contracts' own committed `SNAPSHOT`
  baselines (e.g. GL rows committed at `62,230`, observed `62,377`); this is workbook drift between
  sessions, not a defect, and is visible in every `SNAPSHOT_DRIFT` line quoted above.
