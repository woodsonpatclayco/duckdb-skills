Verifies: RESULT-1.md (commit 4fafb77)
Serves: "show me which sheets exist in that workbook, and prove we can read one of them
correctly without corrupting it" -- independent confirmation that items 3+4 actually do this.

# VERIFY-1 -- Independent verification of items 3+4 (sheet discovery + first workbook contract)

Worktree used: `git worktree add` at commit `4fafb77` (RESULT-1.md's own commit, which
contains everything back through `ed88781`), path
`C:\Users\woodsonp\Claude\Dev\duckdb-skills-verify-wt`. A second, separate throwaway
worktree at `ed88781` (the implementer's commit, one before RESULT-1.md itself) was used
only for AC0, per TASK.md's literal instruction ("at the implementer's commit"). Both
removed with `git worktree remove --force` after use; confirmed gone
(`Test-Path` = False for both) and main working directory's `git status` unchanged
(only the pre-existing, unrelated untracked `Revenue` file) throughout.

**Verdict: SHIP.**

RESULT-1.md's claim of 17/17 PASS with zero drift holds. I independently re-ran every
check from a fresh shell against a disposable worktree and every figure matched both
RESULT-1.md and TASK.md's committed values exactly -- to the byte, in the case of the
fingerprint and the two decimal sums. I also ran an adversarial test not requested by
name in TASK.md's acceptance list but described in my brief -- sabotaging the decoder to
remap 6,654 of 18,764 interior dates while holding min/max/count constant -- and AC8
correctly caught it. No defect found. No file left mutated.

---

## Results table

| check | expected | actual (this session) | command | verdict |
|---|---|---|---|---|
| AC0 | exit 0, first invocation, no `.duckdb-skills\` | exit 0; `.duckdb-skills` absent (`Test-Path`=False); all 7 assertions PASS | `git worktree add <tmp> ed88781`; `Test-Path (Join-Path <tmp> '.duckdb-skills')`; `tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql` (cwd=worktree root) | PASS |
| AC1 | 26 sheets; pos1=MetaData; GL sheet + Project_Profit both present | 26 sheets; pos1=MetaData; pos13=Clayco_Job_Costs_from_GL; pos22=Project_Profit | `tools\list-sheets.ps1 "<pinned path>"` | PASS |
| AC2 | both truncated names intact at 31 chars | `("Subcontract_Totals_and_Invoicin").Length`=31; `("Actual_Substantial_Completion_D").Length`=31 | same run as AC1, checked independently in PowerShell | PASS |
| AC3 | exit non-zero, message contains the given path | exit 1; `ERROR: workbook not found: C:\Users\woodsonp\Claude\Dev\duckdb-skills\NONEXISTENT_FAKE_PATH.xlsm` | `tools\list-sheets.ps1 "C:\Users\woodsonp\Claude\Dev\duckdb-skills\NONEXISTENT_FAKE_PATH.xlsm"` | PASS |
| AC4 | exit 0, all PASS, assertion_count == number of `-- @assert` lines in file | exit 0; 7/7 PASS; `assertion_count=7`; independently counted 7 `-- @assert` lines via `Select-String` | `tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql`; `(Get-Content ... \| Select-String '-- @assert').Count` | PASS |
| AC5 | view rows == direct read_xlsx rows, same run | 62,110 == 62,110 | `duckdb -f checks\gl-facts.sql` | PASS |
| AC6 | fingerprint == committed 13-name ordered list | exact match, order included | same run | PASS |
| AC7 | `typeof(GL_PERIOD)` (any_value) = `DATE` | `glperiod_is_date` PASS in AC4's output | via AC4 | PASS |
| AC8 | both `EXCEPT ALL` diffs = 0 | `AC8_A_MINUS_B,0` / `AC8_B_MINUS_A,0`; min/max/nn 2026-07-01/2026-10-01/18,764 both paths | same `gl-facts.sql` run | PASS |
| AC8 sabotage (adversarial, not a named AC) | a decoder wrong for an interior chunk of dates but preserving min/max/count should still be CAUGHT (nonzero diffs) | remapped all 6,654 rows with serial 46235 (2026-08-01) to 2026-09-01 in a **temp copy** of the contract only; min/max/nn unchanged (07-01/10-01/18,764) on both sides, but `AC8_A_MINUS_B,6654` / `AC8_B_MINUS_A,6654` -- correctly nonzero | temp `duckdb -f` script pointing at a `$env:TEMP` copy of the contract with `xl_date(...)` wrapped in `CASE WHEN ... = DATE '2026-08-01' THEN DATE '2026-09-01' ELSE ... END`; `contracts\Clayco_Job_Costs_from_GL.sql` untouched, confirmed via `git status` clean in worktree | PASS (AC8 caught it) |
| AC9 | DECIMAL sum no float tail; differs from DOUBLE sum | `AC9_DECIMAL_SUM,22454928166.83` / `AC9_DOUBLE_SUM,22454928166.829914` | same `gl-facts.sql` run | PASS |
| AC10 | cast-first max = 256178387.75; lexicographic max = '99999.72' | exact match | same run | PASS |
| AC11 | 62,110 / 51,928 / 18,764, three distinct floors | exact match | same run | PASS |
| AC12 | (a) type BIGINT (b) 0 rows with trailing `.0` | `AC12_VENDORNUMBER_TYPE,BIGINT`; `AC12_DOT_ZERO_ROWS,0` | same run | PASS |
| AC13 | zero `-- @assert` lines -> exit non-zero | exit 1; `GUARD 1 FAILED: zero @assert directives parsed from: ...\verify-ac13.sql`; returned near-instantly (no 68 MB read) | temp copy in `$env:TEMP` with every `-- @assert` line stripped via `Where-Object`; `tools\check-contract.ps1 <fixture>`; fixture deleted after | PASS |
| AC14 | malformed directive (missing colon + duplicate name) -> exit non-zero, both reported | exit 1; `GUARD 2 FAILED` naming both `line 53` (missing colon) and `line 59` (duplicate `vendorname_nn`) | temp copy in `$env:TEMP`, `row_count:`->`row_count` and `glperiod_nn:`->`vendorname_nn:` (collision); fixture deleted after | PASS |
| AC15 | workbook SHA-256 and LastWriteTime unchanged | before: `CD6342D0...A7B968F` / `2026-09-24T09:38:56` / 67,980,942 bytes -- after (full session): identical, byte for byte | `Get-FileHash -Algorithm SHA256`; `Get-Item .LastWriteTime` before my first read and after my last check | PASS |
| AC16 | hostile sheet name -> listed, no filename suggested, exit 0 | `position=1 name=Q1 Sales (draft) contract_filename=REFUSED (...)`; `total_sheets=1`; exit 0 | `tools\make-ac16-fixture.ps1` then `tools\list-sheets.ps1 <fixture>`; fixture deleted after | PASS |
| Mutation: AC7 (`GL_PERIOD::TIMESTAMP`) | `glperiod_is_date` FAIL, `glperiod_nn`/`glperiod_range` ERROR, exit 1 | reproduced exactly, including the literal Conversion Error text | temp mutated contract copy, `tools\check-contract.ps1 <copy>` | PASS |
| Mutation: AC8 (`TRY_CAST(... AS DATE)`) | view GL_PERIOD all-NULL, `AC8_B_MINUS_A`=18,764 | `AC8_VIEW_NN,0`; both diffs = 18,764 | temp mutated contract + temp checks script, `duckdb -f` | PASS |
| Mutation: AC9 (`JOB_COSTS::DOUBLE`) | `jobcosts_sum` FAIL, sums collapse to identical | `FAIL jobcosts_sum: value is false`, exit 1 | temp mutated contract, `tools\check-contract.ps1 <copy>` | PASS |
| Mutation: AC12 (`VENDOR_NUMBER::DOUBLE`) | type DOUBLE, 62,110 rows with trailing `.0` | `AC12_VENDORNUMBER_TYPE,DOUBLE`; `AC12_DOT_ZERO_ROWS,62110` | temp mutated contract + temp checks script, `duckdb -f` | PASS |
| Mutations in contract only, not `duckdb-compat.sql` | unmodified | `skills\query\duckdb-compat.sql` never touched by any mutation; `git status` clean in worktree after every mutation cycle | `git status` (verify-wt) | PASS |
| BOM check, all 5 deliverable files | no BOM | `list-sheets.ps1`, `contracts\Clayco_Job_Costs_from_GL.sql`, `check-contract.ps1`, `checks\gl-facts.sql`, `make-ac16-fixture.ps1` -- all `BOM=False` | byte-level check: first 3 bytes != `EF BB BF` | PASS |
| Guard ordering (item 4 of my brief) | both guards run before any workbook read | confirmed by code inspection (`check-contract.ps1:105-114`, guards checked and the function returns before `$scratchDir`/`duckdb` invocation at line 118+) **and** by timing: AC13/AC14 returned with no measurable delay while every real read took 5-15s in this session | code read + wall-clock comparison | PASS |
| `$PSScriptRoot`-relative macro path (item 3 of my brief) | resolves relative to script, not hardcoded | `check-contract.ps1:63`: `[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))`; AC0 (run from a *different* worktree path than the main repo) succeeded, which a hardcoded absolute path pointing at the original repo could not have distinguished -- but the code itself is the proof | code read + AC0's success from a differently-pathed worktree | PASS |
| Project's own test suite (out of scope, regression check) | no regressions from item 1's shipped compat tests | `REGRESSION: none (zero regressions holds)`; raw 17/50, macro 34/50, polyglot 37/50 -- unrelated to this task, all pre-existing | `tools\run-compat-tests.ps1` | PASS (no regression) |

## Checks I could not run

None. TASK.md's claim that no check needs Snowflake held -- I do not have
`snowflake_sql_execute` and never needed it. Every one of AC0-AC16, all four named
mutation proofs, and the additional AC8 sabotage adversarial test ran to completion with
DuckDB CLI and PowerShell alone.

## Drift

None observed. Every figure I measured this session matches both RESULT-1.md and
TASK.md's committed snapshot exactly: 62,110 rows; 51,928 / 18,764 non-null floors;
22,454,928,166.83 / 22,454,928,166.829914 decimal/double sums; 256,178,387.75 /
'99999.72' cast/lexicographic max; 2026-07-01 / 2026-10-01 date range; 26 sheets; the
13-column fingerprint; the workbook's SHA-256 and byte length. The live, SharePoint-synced
workbook did not move between the implementer's session and mine.

## On item 8 of my brief -- `tools\make-ac16-fixture.ps1`

Not scope creep. TASK.md names four deliverables but does not forbid a fifth committed
tool, and the repo already has precedent for committing fixture builders (`tools\
make-extract-fixtures.ps1`, `tools\make-decide-fixtures.ps1` from item 2a, both present
in this worktree). More importantly, it closes a real reproducibility gap that AC13/AC14
do not have: those two guards' fixtures are built by editing a copy of a file **already
in the repo** (the contract), so a verifier could reconstruct them from TASK.md's prose
alone. AC16's fixture is a synthetic `.xlsx`-shaped zip with a hand-built `xl/workbook.xml`
that exists nowhere in the repo -- without a committed builder, a verifier would have to
hand-author raw OOXML bytes from a paragraph of prose, which is a materially worse
reproducibility story than AC13/AC14 have. I ran it myself, confirmed it writes only to
`-Path` (defaulting to `$env:TEMP`, never the repo or the workbook), confirmed the fixture
it produces is BOM-free, and confirmed `list-sheets.ps1` correctly refuses a filename for
the hostile sheet name it declares (`"Q1 Sales (draft)"` -- a space and parentheses, which
does exercise the `^[A-Za-z0-9_]+$` refusal rule for real, not vacuously).

## Notes on running this session (Windows/PowerShell quirk, not a defect in the deliverables)

Long-running `duckdb -f`/`.ps1` invocations in this session's own interactive shell
sometimes returned to the prompt before the underlying process had actually finished
writing output -- visible only because a redirected output file was briefly empty and
then correct a few seconds later. This is an artifact of my own terminal tool, not of
`check-contract.ps1` or `gl-facts.sql`: every `$LASTEXITCODE` and every output line, once
settled, matched expectations exactly, and I re-read outputs after a short wait rather
than trusting the first read. Noted here so a reader does not mistake this for a race
condition in the shipped scripts.