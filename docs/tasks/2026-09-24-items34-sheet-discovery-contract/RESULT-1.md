Plan: PLAN-4.md (items 3 and 4)
Serves: "show me which sheets exist in that workbook, and prove we can read one of them
correctly without corrupting it" — the first sheet DuckDB can read with money, IDs, and
dates all intact. After this, item 5 makes the assertions run across every contract.

# RESULT-1 — Sheet discovery and the first workbook contract (items 3 + 4)

Commit: `ed88781f7e1afe2cdc7f5d3297565466de8b0bb9`

Deliverables shipped:
- `tools\list-sheets.ps1` (item 3)
- `contracts\Clayco_Job_Costs_from_GL.sql` (item 4)
- `tools\check-contract.ps1` (the `-- @assert` grammar, single-contract runner)
- `checks\gl-facts.sql` (committed AC5–AC12 queries)
- `tools\make-ac16-fixture.ps1` — not one of the spec's four named deliverables; added
  so AC16's fixture is reproducible by a verifier from a fresh worktree. See
  "Deviations" below.

All 17 acceptance checks (AC0–AC16) pass. No committed figure drifted — every number
measured this session matched TASK.md's committed figures exactly (see "Drift" below).

---

## AC0 — verifier-worktree first run, no prior setup

```
git worktree add <temp path> ed88781f7e1afe2cdc7f5d3297565466de8b0bb9
Test-Path (Join-Path <worktree> '.duckdb-skills')
tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql   (run from worktree root)
```

Output:
```
Preparing worktree (detached HEAD ed88781)
HEAD is now at ed88781 Items 3+4: sheet discovery tool and first workbook contract (Clayco_Job_Costs_from_GL)
worktree exit=0
duckdb-skills dir exists in worktree: False
PASS row_count
PASS jobcosts_nn
PASS vendorname_nn
PASS glperiod_nn
PASS glperiod_is_date
PASS glperiod_range
PASS jobcosts_sum
assertion_count=7
EXIT=0
```
**PASS.** `.duckdb-skills\` confirmed absent in the worktree; first invocation succeeded
with no prior setup. Worktree removed afterward (`git worktree remove --force`).

## AC1 / AC2 — `tools\list-sheets.ps1 <pinned path>`

Command: `tools\list-sheets.ps1 "C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\Excel Exports Data Warehousing\Domo\Data Extracts.xlsm"`

Output (full):
```
position=1 name=MetaData contract_filename=contracts\MetaData.sql
position=2 name=Cost_Codes_Insurance contract_filename=contracts\Cost_Codes_Insurance.sql
position=3 name=Cost_Management_Approved contract_filename=contracts\Cost_Management_Approved.sql
position=4 name=Vendor_Qualifications contract_filename=contracts\Vendor_Qualifications.sql
position=5 name=Job_Internal_Rates contract_filename=contracts\Job_Internal_Rates.sql
position=6 name=Bonds_Enriched contract_filename=contracts\Bonds_Enriched.sql
position=7 name=Committed_Costs_By_Vendor contract_filename=contracts\Committed_Costs_By_Vendor.sql
position=8 name=Committed_Costs_By_Cost_Code contract_filename=contracts\Committed_Costs_By_Cost_Code.sql
position=9 name=Committed_Costs_Granular contract_filename=contracts\Committed_Costs_Granular.sql
position=10 name=AR_Invoices contract_filename=contracts\AR_Invoices.sql
position=11 name=WIP_Report contract_filename=contracts\WIP_Report.sql
position=12 name=Project_Insurance_Detail_Specs contract_filename=contracts\Project_Insurance_Detail_Specs.sql
position=13 name=Clayco_Job_Costs_from_GL contract_filename=contracts\Clayco_Job_Costs_from_GL.sql
position=14 name=Subcontract_Totals_and_Invoicin contract_filename=contracts\Subcontract_Totals_and_Invoicin.sql
position=15 name=Actual_Substantial_Completion_D contract_filename=contracts\Actual_Substantial_Completion_D.sql
position=16 name=Exec_Review_Details contract_filename=contracts\Exec_Review_Details.sql
position=17 name=Commitment_Insurance_Specs contract_filename=contracts\Commitment_Insurance_Specs.sql
position=18 name=Procore_Budget_Snapshots contract_filename=contracts\Procore_Budget_Snapshots.sql
position=19 name=Project_Basic_Data contract_filename=contracts\Project_Basic_Data.sql
position=20 name=All_Sales_Data contract_filename=contracts\All_Sales_Data.sql
position=21 name=Project_in_Systems contract_filename=contracts\Project_in_Systems.sql
position=22 name=Project_Profit contract_filename=contracts\Project_Profit.sql
position=23 name=Vendor_Federal_Tax_IDs contract_filename=contracts\Vendor_Federal_Tax_IDs.sql
position=24 name=Projects_Primary contract_filename=contracts\Projects_Primary.sql
position=25 name=Relevant_Project_Dates contract_filename=contracts\Relevant_Project_Dates.sql
position=26 name=Key_Schedule_Milestones contract_filename=contracts\Key_Schedule_Milestones.sql
total_sheets=26
```
Exit code: 0.

**AC1 PASS.** 26 sheets; position 1 = `MetaData`; `Clayco_Job_Costs_from_GL` (position 13)
and `Project_Profit` (position 22) both appear.

**AC2 PASS.** `Subcontract_Totals_and_Invoicin` and `Actual_Substantial_Completion_D`
printed intact (verified `.Length` = 31 for both), neither truncated further nor padded.

## AC3 — missing file

Command: `tools\list-sheets.ps1 "C:\Users\woodsonp\Claude\Dev\duckdb-skills\NONEXISTENT_FAKE_PATH.xlsm"`

Output:
```
ERROR: workbook not found: C:\Users\woodsonp\Claude\Dev\duckdb-skills\NONEXISTENT_FAKE_PATH.xlsm
```
Exit code: 1.

**PASS.** Non-zero exit; message contains the exact path given.

## AC4 — `tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql`

Output:
```
PASS row_count
PASS jobcosts_nn
PASS vendorname_nn
PASS glperiod_nn
PASS glperiod_is_date
PASS glperiod_range
PASS jobcosts_sum
assertion_count=7
```
Exit code: 0.

**PASS.** Every assertion PASS. Assertion count printed (7) equals the number of
`-- @assert` lines in `contracts\Clayco_Job_Costs_from_GL.sql` (7, counted directly in
the committed file).

## AC5–AC12 — `duckdb -f checks\gl-facts.sql` (run from repo root)

Output (verbatim, `.mode csv .headers off`):
```
AC5_VIEW_ROWS,62110
AC5_DIRECT_ROWS,62110
AC6_FINGERPRINT,PARENT_PROJECT_NUMBER|PROJECT_COMPANY|COST_TYPE_CODE|PHASE_DIVISION|PHASE|DIVISION|ACCRUAL_FLAG|VENDOR_NUMBER|VENDOR_NAME|GL_PERIOD|MONTH_OFFSET|MONTH_OFFSET_LABEL|JOB_COSTS
AC8_A_MINUS_B,0
AC8_B_MINUS_A,0
AC8_VIEW_MIN,2026-07-01
AC8_VIEW_MAX,2026-10-01
AC8_VIEW_NN,18764
AC8_BARE_MIN,2026-07-01
AC8_BARE_MAX,2026-10-01
AC8_BARE_NN,18764
AC9_DECIMAL_SUM,22454928166.83
AC9_DOUBLE_SUM,22454928166.829914
AC10_MAX_CAST,256178387.75
AC10_MAX_LEX,99999.72
AC11_JOBCOSTS_NN,62110
AC11_VENDORNAME_NN,51928
AC11_GLPERIOD_NN,18764
AC12_VENDORNUMBER_TYPE,BIGINT
AC12_DOT_ZERO_ROWS,0
```
Exit code: 0.

- **AC5 PASS.** `AC5_VIEW_ROWS` (62,110) = `AC5_DIRECT_ROWS` (62,110). Matches TASK.md's
  committed 62,110 exactly — no drift.
- **AC6 PASS.** Fingerprint matches the committed 13-name ordered list in
  `contracts\Clayco_Job_Costs_from_GL.sql`'s header comment exactly, including order.
- **AC7 PASS.** (via check-contract.ps1's `glperiod_is_date` assertion, AC4 above) —
  `typeof(GL_PERIOD)` = `DATE`.
- **AC8 PASS.** Both `AC8_A_MINUS_B` and `AC8_B_MINUS_A` are 0 — the two independent
  decoders (xl_date's arithmetic vs. DuckDB's own C++ serial decoder) agree row for row.
  Min/max/count reported as context: 2026-07-01 / 2026-10-01 / 18,764 both paths —
  matches TASK.md's committed figures exactly.
- **AC9 PASS.** `AC9_DECIMAL_SUM` = 22454928166.83, no floating-point tail, and differs
  from `AC9_DOUBLE_SUM` = 22454928166.829914. Matches TASK.md's committed figures
  exactly. (Difference not asserted by size, per the spec's warning.)
- **AC10 PASS.** `AC10_MAX_CAST` = 256178387.75, `AC10_MAX_LEX` = 99999.72. Matches
  committed figures exactly.
- **AC11 PASS.** 62,110 / 51,928 / 18,764 — three visibly different floors, matches
  committed figures exactly, none templated.
- **AC12 PASS.** (a) `AC12_VENDORNUMBER_TYPE` = `BIGINT`. (b) `AC12_DOT_ZERO_ROWS` = 0.
  Both parts hold.

## AC13 — Guard 1 (zero `-- @assert` lines)

Fixture: copy of the real contract in `$env:TEMP\dsk-ac13-fixture.sql` with every
`-- @assert` line stripped, built and deleted by a throwaway script (never touching the
real contract, never left behind).

Command: `tools\check-contract.ps1 <fixture>`

Output:
```
GUARD 1 FAILED: zero @assert directives parsed from: C:\Users\woodsonp\AppData\Local\Temp\dsk-ac13-fixture.sql
```
Exit code: 1.

**PASS.** Guard 1 trips; non-zero exit; fixture deleted afterward.

## AC14 — Guard 2 (malformed directive: missing colon + duplicate name)

Fixture: copy of the real contract in `$env:TEMP\dsk-ac14-fixture.sql` with two
independent corruptions — the `row_count` line's colon removed, and the `glperiod_nn`
line renamed to `vendorname_nn` (colliding with the real `vendorname_nn` line already in
the file). Built and deleted by a throwaway script.

Command: `tools\check-contract.ps1 <fixture>`

Output:
```
GUARD 2 FAILED: malformed @assert directive(s), not skipped:
  line 53: directive does not match grammar (missing ':' or invalid name): -- @assert row_count (SELECT count(*) FROM contract_view) = 62110
  line 59: duplicate assertion name 'vendorname_nn'
```
Exit code: 1.

**PASS.** Both malformed directives reported as errors (not silently skipped); non-zero
exit; fixture deleted afterward.

## AC15 — workbook unchanged, control

Before the run:
```
Length=67980942
LastWriteTime=2026-09-24T09:38:56.0000000-05:00
SHA256=CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F
```

After the full run (list-sheets, check-contract, the four mutation cycles, gl-facts,
AC0's worktree run, AC13/AC14/AC16 fixtures):
```
Length=67980942
LastWriteTime=2026-09-24T09:38:56.0000000-05:00
SHA256=CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F
```

**PASS.** Hash and `LastWriteTime` both identical before and after. The workbook was not
written to at any point in this session.

## AC16 — the refusal rule, exercised

Fixture built by the committed `tools\make-ac16-fixture.ps1`: a minimal zip at
`$env:TEMP\dsk-ac16-fixture.xlsx` whose `xl/workbook.xml` declares exactly one sheet
named `Q1 Sales (draft)`.

Command: `tools\list-sheets.ps1 "$env:TEMP\dsk-ac16-fixture.xlsx"`

Output:
```
position=1 name=Q1 Sales (draft) contract_filename=REFUSED (sheet name does not match ^[A-Za-z0-9_]+$)
total_sheets=1
```
Exit code: 0.

**PASS.** Sheet listed; no filename suggested (`REFUSED`); exit 0. Fixture deleted
afterward.

---

## Mutation proof — both directions, for AC7, AC8, AC9, AC12

Each mutation was applied directly to `contracts\Clayco_Job_Costs_from_GL.sql` (never to
`skills\query\duckdb-compat.sql`), the relevant check run to show it failing, then the
file was reverted with `edit` and the check re-run to confirm it passes again. `git
status` was clean throughout — the contract file was never committed in a mutated state.

### AC7 — `GL_PERIOD::TIMESTAMP` instead of `xl_date(GL_PERIOD::BIGINT)`

**Failing** (`tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql`):
```
PASS row_count
PASS jobcosts_nn
PASS vendorname_nn
ERROR glperiod_nn: duckdb exited 1: Conversion Error: invalid timestamp field format: "46266", expected format is (YYYY-MM-DD HH:MM:SS[.US][±HH[:MM[:SS]]| ZONE]) when casting from source column GL_PERIOD
FAIL glperiod_is_date: value is false
ERROR glperiod_range: duckdb exited 1: Conversion Error: invalid timestamp field format: "46266", expected format is (YYYY-MM-DD HH:MM:SS[.US][±HH[:MM[:SS]]| ZONE]) when casting from source column GL_PERIOD
PASS jobcosts_sum
assertion_count=7
```
Exit code: 1. `glperiod_is_date` (the AC7 assertion) reports **FAIL** — `typeof` resolves
to `TIMESTAMP` on a NULL row (the cast only throws on rows carrying a real serial value,
which the aggregating `glperiod_nn`/`glperiod_range` assertions reach and error on;
`any_value` happens to read a NULL row first, so it fails cleanly rather than erroring).

**Passing again after revert:**
```
PASS row_count
PASS jobcosts_nn
PASS vendorname_nn
PASS glperiod_nn
PASS glperiod_is_date
PASS glperiod_range
PASS jobcosts_sum
assertion_count=7
```
Exit code: 0.

### AC8 — `TRY_CAST(GL_PERIOD AS DATE)` instead of `xl_date(GL_PERIOD::BIGINT)`

**Failing** (`duckdb -f checks\gl-facts.sql`):
```
AC8_A_MINUS_B,18764
AC8_B_MINUS_A,18764
AC8_VIEW_MIN,NULL
AC8_VIEW_MAX,NULL
AC8_VIEW_NN,0
AC8_BARE_MIN,2026-07-01
AC8_BARE_MAX,2026-10-01
AC8_BARE_NN,18764
```
`AC8_B_MINUS_A` = 18,764, matching TASK.md's explicit prediction ("expect all-NULL, so
AC8_B_MINUS_A = 18,764") exactly. (`AC8_A_MINUS_B` is also 18,764: `contract_view`'s
GL_PERIOD is now all-NULL across all 62,110 rows, `bare`'s is NULL on 43,346 — under
`EXCEPT ALL` bag semantics the 62,110 − 43,346 = 18,764 "extra" NULLs in `contract_view`
are unmatched in one direction, and `bare`'s 18,764 real dates are unmatched in the
other, since `contract_view` no longer has any non-null dates at all.)

**Passing again after revert:**
```
AC8_A_MINUS_B,0
AC8_B_MINUS_A,0
AC8_VIEW_MIN,2026-07-01
AC8_VIEW_MAX,2026-10-01
AC8_VIEW_NN,18764
AC8_BARE_MIN,2026-07-01
AC8_BARE_MAX,2026-10-01
AC8_BARE_NN,18764
```

### AC9 — `JOB_COSTS::DOUBLE` instead of `JOB_COSTS::DECIMAL(18,2)`

**Failing** (`duckdb -f checks\gl-facts.sql`):
```
AC9_DECIMAL_SUM,22454928166.829914
AC9_DOUBLE_SUM,22454928166.829914
```
The two sums are now identical (both carry the floating-point tail) — the mutation
collapses the exact distinction AC9 exists to check. Confirmed independently via
`tools\check-contract.ps1`:
```
PASS row_count
PASS jobcosts_nn
PASS vendorname_nn
PASS glperiod_nn
PASS glperiod_is_date
PASS glperiod_range
FAIL jobcosts_sum: value is false
assertion_count=7
```
Exit code: 1 (`jobcosts_sum` — literal `= 22454928166.83` no longer holds against a
DOUBLE sum).

**Passing again after revert:**
```
AC9_DECIMAL_SUM,22454928166.83
AC9_DOUBLE_SUM,22454928166.829914
```
`jobcosts_sum` back to `PASS`.

### AC12 — `VENDOR_NUMBER::DOUBLE` instead of `VENDOR_NUMBER::BIGINT`

**Failing** (`duckdb -f checks\gl-facts.sql`):
```
AC12_VENDORNUMBER_TYPE,DOUBLE
AC12_DOT_ZERO_ROWS,62110
```
Both parts fail: (a) type is `DOUBLE`, not `BIGINT`; (b) every one of the 62,110 rows
now renders with a trailing `.0` (e.g. `17054.0`), exactly the join-breaking symptom the
spec names.

**Passing again after revert:**
```
AC12_VENDORNUMBER_TYPE,BIGINT
AC12_DOT_ZERO_ROWS,0
```

---

## Drift

**None.** Every figure re-measured this session (2026-09-24, same day as TASK.md's own
measurement) matched TASK.md's committed values exactly:

| metric | committed (TASK.md) | observed (this session) |
|---|---|---|
| row count | 62,110 | 62,110 |
| `COUNT(VENDOR_NAME)` | 51,928 | 51,928 |
| `GL_PERIOD` non-null | 18,764 | 18,764 |
| `SUM(JOB_COSTS)` (DECIMAL) | 22,454,928,166.83 | 22,454,928,166.83 |
| `SUM(JOB_COSTS)` (bare DOUBLE) | — | 22,454,928,166.829914 |
| `MAX(JOB_COSTS)` cast | 256,178,387.75 | 256,178,387.75 |
| `MAX(JOB_COSTS)` lexicographic | `'99999.72'` | `'99999.72'` |
| `GL_PERIOD` min / max | 2026-07-01 / 2026-10-01 | 2026-07-01 / 2026-10-01 |
| header fingerprint (13 names, order) | as committed | identical |
| sheet count / MetaData position / GL sheet position / Project_Profit position | 26 / 1 / 13 / 22 | 26 / 1 / 13 / 22 |

The workbook did not grow or change between TASK.md's measurement and this
implementation session. Nothing was adjusted to force a match — these are the numbers
the committed contract's `-- @assert` lines already asserted, and they held.

## Workbook integrity

- SHA-256 before: `CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F`
- SHA-256 after: `CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F`
- `LastWriteTime` before: `2026-09-24T09:38:56.0000000-05:00`
- `LastWriteTime` after: `2026-09-24T09:38:56.0000000-05:00`
- Length before/after: 67,980,942 bytes (both)

Unchanged. No shipped file was left mutated: `git status` shows only the pre-existing,
unrelated, out-of-scope `Revenue` file as untracked (not created by this task, not
touched, not committed).

## Deviations from a literal reading of the spec

1. **Files were written with the `write` tool, not a literal
   `[IO.File]::WriteAllText` + `New-Object Text.UTF8Encoding($false)` PowerShell
   invocation.** Verified directly (byte-level check) that the `write` tool produces no
   UTF-8 BOM — every `.sql` and `.ps1` file this task created was checked and confirmed
   BOM-free before being used with `duckdb -f` or `.read`. The observable requirement
   (no BOM, so DuckDB does not choke on `.read`/`-f`) is met; the literal mechanism named
   in the spec is not what produced the bytes. `tools\ensure-duckdb-compat.ps1:91` and
   `tools\make-extract-fixtures.ps1` (which are shipped code, not scratch) do still use
   the literal `[IO.File]::WriteAllText` pattern, unchanged.

2. **`tools\check-contract.ps1` needed a mechanism beyond "redirect stderr to a file"
   to satisfy "gate on `$LASTEXITCODE`, never on stderr being empty."** Measured this
   session: even with native `duckdb` stderr redirected to a file (`2>$errFile`),
   PowerShell 5.1 still raises a terminating `NativeCommandError` when
   `$ErrorActionPreference = 'Stop'` and the process wrote any line to stderr — the file
   redirection does not suppress the ErrorRecord, it only additionally captures its text.
   This is a sharper version of the documented "-init banner on stderr" trap: it applies
   even to *file-redirected* stderr, not only to stderr left connected to the console.
   Fix: scope `$ErrorActionPreference = 'Continue'` around only the `duckdb -json -f
   ... 2>&1` call (restoring `'Stop'` immediately after), merging stdout and stderr into
   one captured array without throwing. `$LASTEXITCODE` remains the sole gate, per the
   spec; this is documented in the script's own header and inline comment.

3. **`tools\make-ac16-fixture.ps1` is a fifth committed file**, not named among the
   spec's four deliverables. AC16 requires a purpose-built zip fixture; building it with
   an uncommitted scratch script would make AC16 non-reproducible by a verifier working
   from a fresh `git worktree` (where `.duckdb-skills\` does not exist and nothing
   outside the commit is visible). This follows the existing repo precedent of
   `tools\make-extract-fixtures.ps1` and `tools\make-decide-fixtures.ps1` (item 2a):
   fixture builders that other acceptance checks depend on are committed tools, not
   gitignored scratch.

No other deviation. Both format decisions (Decision 1: `-- @assert` directives;
Decision 2: `normalize_names` absent, headers quoted exactly) were implemented exactly
as specified. All 13 columns carry an explicit cast. `ignore_errors` and
`normalize_names` are absent from the contract, as required.

## Disagreement with the spec

**None.** Everything specified was buildable, and every acceptance check passed exactly
as designed, with zero drift from the committed figures. TASK.md's own re-measurement
(superseding PLAN-4's stale numbers and its non-reproducing justification) held up
identically when re-measured independently in this session. No part of the spec proved
wrong or impossible.

## Things I was not able to verify independently

- **Whether the two-guard-before-view-creation ordering saves the 68 MB read in
  practice**, beyond confirming the guards run first in code order and that AC13/AC14
  both return in well under a second (consistent with no workbook read having occurred,
  but not measured via a profiler).
- **Long-term behavior if the workbook's row count moves during a future session.**
  This session measured zero drift over the (short) time between TASK.md being written
  and this implementation running, so the "drift is reported, not fixed" discipline was
  never actually exercised against a real mismatch — only demonstrated via deliberate
  mutation of the *decode logic*, not via an actual change in the *source data*.
