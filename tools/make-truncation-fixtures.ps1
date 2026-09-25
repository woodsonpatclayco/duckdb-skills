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

Both fixture contracts use @rows_floor: 1 (row-count floors are not what these fixtures
exist to exercise -- that is covered on the two real contracts) and @anchor: NM
(populated on every real data row in both fixtures).

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
$fixtureAContract = Join-Path $dir 'dsk-fixture-a-contract.sql'
$fixtureBContract = Join-Path $dir 'dsk-fixture-b-contract.sql'

foreach ($f in @($fixtureAXlsx, $fixtureBXlsx, $fixtureAContract, $fixtureBContract)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

# --- build the two workbooks --------------------------------------------------------
$fixtureAXlsxFwd = $fixtureAXlsx -replace '\\', '/'
$fixtureBXlsxFwd = $fixtureBXlsx -replace '\\', '/'

$buildSql = "LOAD excel;`r`n" +
    "COPY (VALUES ('NM','AMT'),('r1','10'),('r2','20'),(NULL,NULL),('r4','40'),('r5','50'),('r6',NULL))`r`n" +
    "TO '$fixtureAXlsxFwd' (FORMAT xlsx);`r`n" +
    "COPY (VALUES ('NM','AMT'),('r1','10'),('r2','20'),('r3','30'),(NULL,NULL),(NULL,NULL))`r`n" +
    "TO '$fixtureBXlsxFwd' (FORMAT xlsx);`r`n"

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

Write-Output "fixture_a_workbook=$fixtureAXlsx"
Write-Output "fixture_a_contract=$fixtureAContract"
Write-Output "fixture_b_workbook=$fixtureBXlsx"
Write-Output "fixture_b_contract=$fixtureBContract"
exit 0
