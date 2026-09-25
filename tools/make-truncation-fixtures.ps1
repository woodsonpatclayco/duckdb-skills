<#
tools\make-truncation-fixtures.ps1 [-Path <dir>]

Builds fixture A and fixture B for TASK.md item 5's truncation detector, plus a
matching throwaway contract .sql for each so tools\run-assertions.ps1 -Contract can be
pointed at them without either becoming a discoverable "third contract" under
contracts\ (per TASK.md's "Out of scope"). Test scaffolding, not a plan deliverable in
its own right -- committed so the verifier reproduces the fixtures from a clean
worktree rather than trusting a byte-for-byte .xlsx checked into git.

-Path defaults to $env:TEMP; idempotent -- deletes any existing files at the fixed
names first, then writes fresh ones, so reruns never fail on "file already exists".

Fixture A (the partially-null trap): header NM,AMT, then five real data rows and one
fully-blank row in the middle. Every figure below is read off THIS VALUES list, not
derived from prose or from reading the file back:
    default (stop_at_empty=true)                        : 2 rows,  sum 30.00
    stop_at_empty=false, raw (no filter)                : 6 rows
    stop_at_empty=false + explicit all-null filter      : 5 rows,  sum 120.00
    "NOT (COLUMNS(*) IS NULL)" shorthand (wrong, banned): 4 rows -- drops the row
        populated only in NM (AMT is null there), which is exactly the trap this
        fixture exists to make visible.

Fixture B (trailing blanks only, no false alarm): header NM,AMT, three real data rows,
then two fully-blank trailing rows.
    default (stop_at_empty=true)                   : 3 rows
    stop_at_empty=false, raw (no filter)           : 5 rows
    stop_at_empty=false + explicit all-null filter : 3 rows -- matches default: no real
        data was ever lost, so TRUNCATION_ROWS_LOST is 0 despite the raw
        stop_at_empty=false count (5) being higher than either.

Fixture C (round 2, TASK.md C4 -- the orphan-column fixture, promoted from an
improvised RESULT-1 throwaway to a committed, reproducible fixture): header C1,C2,C3,
two fully-populated data rows, then one row populated ONLY in C3 (C1 and C2 both
NULL). The matching contract deliberately projects only C1 and C2 -- the orphan-column
defect this fixture exists to make visible requires a contract that does NOT project
every raw column, which neither real contract in contracts\ does today. Every figure
below is read off THIS VALUES list, matched against TASK.md's own measured triple:
    default (stop_at_empty=true)                              : 3 rows -- row 3 is not
        blank (C3 is populated), so DuckDB does not stop early.
    with-data over all 3 raw columns (independent discovery)  : 3 rows -- agrees with
        default: nothing lost when every raw column is considered.
    with-data over the 2 contract-projected columns (C1, C2)  : 2 rows -- row 3 is
        wrongly treated as blank and dropped, because C3 (where its only data lives)
        is invisible to a predicate scoped to the contract's own projection.
    anchor (C1) non-null among the 2 survivors                : 2 of 2 -- the anchor
        assertion alone PASSES even though a real row was silently dropped, which is
        exactly why the harness's own with-data column source must be independent of
        the contract's projection (see tools\run-assertions.ps1's "MUTATION POINT"
        comment on $rawColumns) and must never be narrowed to it.

Both fixture A and B contracts use @rows_floor: 1 (row-count floors are not what these
fixtures exist to exercise -- that is covered on the two real contracts) and
@anchor: NM (populated on every real data row in both fixtures). Fixture C's contract
uses @rows_floor: 1 and @anchor: C1.

Requires `LOAD excel;` before `COPY ... TO (FORMAT xlsx)` -- read_xlsx autoloads the
extension, the COPY function does not (measured: Catalog Error without it).
#>
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $Path = $env:TEMP
}
$dir = [System.IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$fixtureAXlsx = Join-Path $dir 'dsk-fixture-a.xlsx'
$fixtureBXlsx = Join-Path $dir 'dsk-fixture-b.xlsx'
$fixtureCXlsx = Join-Path $dir 'dsk-fixture-c.xlsx'
$fixtureAContract = Join-Path $dir 'dsk-fixture-a-contract.sql'
$fixtureBContract = Join-Path $dir 'dsk-fixture-b-contract.sql'
$fixtureCContract = Join-Path $dir 'dsk-fixture-c-contract.sql'

foreach ($f in @($fixtureAXlsx, $fixtureBXlsx, $fixtureCXlsx, $fixtureAContract, $fixtureBContract, $fixtureCContract)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

# --- build the three workbooks -------------------------------------------------------
$fixtureAXlsxFwd = $fixtureAXlsx -replace '\\', '/'
$fixtureBXlsxFwd = $fixtureBXlsx -replace '\\', '/'
$fixtureCXlsxFwd = $fixtureCXlsx -replace '\\', '/'

$buildSql = "LOAD excel;`r`n" +
    "COPY (VALUES ('NM','AMT'),('r1','10'),('r2','20'),(NULL,NULL),('r4','40'),('r5','50'),('r6',NULL))`r`n" +
    "TO '$fixtureAXlsxFwd' (FORMAT xlsx);`r`n" +
    "COPY (VALUES ('NM','AMT'),('r1','10'),('r2','20'),('r3','30'),(NULL,NULL),(NULL,NULL))`r`n" +
    "TO '$fixtureBXlsxFwd' (FORMAT xlsx);`r`n" +
    "COPY (VALUES ('C1','C2','C3'),('a','b','c'),('d','e','f'),(NULL,NULL,'z'))`r`n" +
    "TO '$fixtureCXlsxFwd' (FORMAT xlsx);`r`n"

$buildFile = Join-Path $dir "dsk-make-fixtures-build-$([guid]::NewGuid().ToString('N')).sql"
[System.IO.File]::WriteAllText($buildFile, $buildSql, $utf8NoBom)

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$buildOutput = & duckdb -f $buildFile 2>&1
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Remove-Item -LiteralPath $buildFile -Force -ErrorAction SilentlyContinue

if ($buildExit -ne 0) {
    Write-Output "ERROR: duckdb exited $buildExit while building fixture workbooks:"
    $buildOutput | ForEach-Object { Write-Output "  $_" }
    exit 1
}

if (-not (Test-Path -LiteralPath $fixtureAXlsx -PathType Leaf)) {
    Write-Output "ERROR: fixture A workbook was not created: $fixtureAXlsx"
    exit 1
}
if (-not (Test-Path -LiteralPath $fixtureBXlsx -PathType Leaf)) {
    Write-Output "ERROR: fixture B workbook was not created: $fixtureBXlsx"
    exit 1
}
if (-not (Test-Path -LiteralPath $fixtureCXlsx -PathType Leaf)) {
    Write-Output "ERROR: fixture C workbook was not created: $fixtureCXlsx"
    exit 1
}

# --- write the matching throwaway contracts -----------------------------------------
function New-FixtureContractText {
    param([string]$WorkbookPathFwd, [string]$RowCountAssert, [string]$ExtraAssert)
    $extra = if ($ExtraAssert) { "$ExtraAssert`r`n" } else { '' }
    return "-- Throwaway fixture contract built by tools\make-truncation-fixtures.ps1 -- not a`r`n" +
        "-- real contract, never discoverable under contracts\, exercised only via`r`n" +
        "-- tools\run-assertions.ps1 -Contract <this file>.`r`n" +
        "-- @sheet: Sheet1`r`n" +
        "-- @anchor: NM`r`n" +
        "-- @rows_floor: 1`r`n" +
        "-- @fingerprint: NM|AMT`r`n" +
        "`r`n" +
        "CREATE OR REPLACE VIEW contract_view AS`r`n" +
        "SELECT`r`n" +
        "    NM::VARCHAR AS NM,`r`n" +
        "    AMT::DECIMAL(18,2) AS AMT`r`n" +
        "FROM (`r`n" +
        "    SELECT *`r`n" +
        "    FROM read_xlsx(`r`n" +
        "        '$WorkbookPathFwd',`r`n" +
        "        sheet = 'Sheet1',`r`n" +
        "        all_varchar = true,`r`n" +
        "        stop_at_empty = false`r`n" +
        "    )`r`n" +
        "    WHERE NOT (NM IS NULL AND AMT IS NULL)`r`n" +
        ") AS with_data;`r`n" +
        "`r`n" +
        "-- @assert row_count: $RowCountAssert`r`n" +
        $extra
}

$fixtureAContractText = New-FixtureContractText -WorkbookPathFwd $fixtureAXlsxFwd `
    -RowCountAssert '(SELECT count(*) FROM contract_view) = 5' `
    -ExtraAssert '-- @assert sum_check: (SELECT sum(AMT) FROM contract_view) = 120.00'

$fixtureBContractText = New-FixtureContractText -WorkbookPathFwd $fixtureBXlsxFwd `
    -RowCountAssert '(SELECT count(*) FROM contract_view) = 3' `
    -ExtraAssert ''

[System.IO.File]::WriteAllText($fixtureAContract, $fixtureAContractText, $utf8NoBom)
[System.IO.File]::WriteAllText($fixtureBContract, $fixtureBContractText, $utf8NoBom)

# Fixture C (round 2, C4): the orphan-column fixture, promoted to a committed,
# reproducible build. Unlike New-FixtureContractText above, this contract deliberately
# projects only 2 of the sheet's 3 raw columns (C1, C2) -- the orphan-column defect
# requires exactly that mismatch between what the contract projects and what the raw
# sheet actually returns. Its own WHERE clause is scoped to C1/C2 only, on purpose:
# the harness's independent raw-column discovery (tools\run-assertions.ps1, never the
# contract's own projection) is what is supposed to catch row 3 surviving in the raw
# sheet (C3 = 'z') while this view drops it.
$fixtureCContractText = "-- Throwaway fixture contract built by tools\make-truncation-fixtures.ps1 -- not a`r`n" +
    "-- real contract, never discoverable under contracts\, exercised only via`r`n" +
    "-- tools\run-assertions.ps1 -Contract <this file>. Deliberately projects only C1`r`n" +
    "-- and C2 of the sheet's 3 raw columns -- see TASK.md C4 / the header comment above.`r`n" +
    "-- @sheet: Sheet1`r`n" +
    "-- @anchor: C1`r`n" +
    "-- @rows_floor: 1`r`n" +
    "-- @fingerprint: C1|C2`r`n" +
    "`r`n" +
    "CREATE OR REPLACE VIEW contract_view AS`r`n" +
    "SELECT`r`n" +
    "    C1::VARCHAR AS C1,`r`n" +
    "    C2::VARCHAR AS C2`r`n" +
    "FROM (`r`n" +
    "    SELECT *`r`n" +
    "    FROM read_xlsx(`r`n" +
    "        '$fixtureCXlsxFwd',`r`n" +
    "        sheet = 'Sheet1',`r`n" +
    "        all_varchar = true,`r`n" +
    "        stop_at_empty = false`r`n" +
    "    )`r`n" +
    "    WHERE NOT (C1 IS NULL AND C2 IS NULL)`r`n" +
    ") AS with_data;`r`n" +
    "`r`n" +
    "-- @assert row_count: (SELECT count(*) FROM contract_view) = 2`r`n"

[System.IO.File]::WriteAllText($fixtureCContract, $fixtureCContractText, $utf8NoBom)

Write-Output "fixture_a_workbook=$fixtureAXlsx"
Write-Output "fixture_a_contract=$fixtureAContract"
Write-Output "fixture_b_workbook=$fixtureBXlsx"
Write-Output "fixture_b_contract=$fixtureBContract"
Write-Output "fixture_c_workbook=$fixtureCXlsx"
Write-Output "fixture_c_contract=$fixtureCContract"
exit 0
