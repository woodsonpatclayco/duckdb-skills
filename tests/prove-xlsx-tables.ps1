<#
tests\prove-xlsx-tables.ps1 -- PLAN-6 item 1: read an Excel table or named range by its name.

For each table / named range below, compares two numbers that come from different places:
  expected  the data-row count implied by the table's own ref in the workbook XML
            (tools\xlsx_meta.py tables/names), header and totals rows removed
  got       the rows DuckDB actually returns through read_xlsx_table / read_xlsx_name
Then shows that each refusal fires (ambiguous name, broken name, unknown table, unknown
workbook), and that no source workbook changed (SHA-256 before and after).

The SDI Calculator is a live working file, so it is copied to %TEMP% and only the copy is read.
Data Extracts.xlsm and Executive_Reviews.xlsx are read in place, read-only, as the existing
contracts already do. Expected values are re-derived every run, so the script stays valid as
the workbooks refresh.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$an   = 'C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics'
$DE   = "$an\Excel Exports Data Warehousing\Domo\Data Extracts.xlsm"
$ER   = "$an\Executive_Review_Automation\Executive_Reviews.xlsx"
$SDIlive = "$an\SDI Calculator\SDI Calculator Data thru Current Month.xlsx"
$work = Join-Path ([IO.Path]::GetTempPath()) 'prove-xlsx-tables'
New-Item -ItemType Directory -Force $work | Out-Null
$SDI  = Join-Path $work 'SDI.xlsx'
$meta = Join-Path $repo 'tools\xlsx_meta.py'

# Open read-only but share read/write, so a workbook Phil has open in Excel can still be read.
function Open-Shared($p) { [IO.File]::Open($p, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete') }
function Get-Sha($p) {
    $fs = Open-Shared $p
    try { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fs)) -replace '-', '' }
    finally { $fs.Dispose() }
}

$sources = @($DE, $ER, $SDIlive)
$before = @{}
foreach ($f in $sources) { $before[$f] = Get-Sha $f }
$in = Open-Shared $SDIlive
try { $out = [IO.File]::Create($SDI); try { $in.CopyTo($out) } finally { $out.Dispose() } }
finally { $in.Dispose() }

$macros = Join-Path $work 'macros.sql'
& py -3.12 $meta macros $DE $ER $SDI -o $macros | Out-Null
if ($LASTEXITCODE -ne 0) { throw "xlsx_meta.py macros failed" }
$macrosFwd = $macros.Replace('\', '/')   # duckdb's .read treats \ as an escape

function Catalog($kind, $wb) { & py -3.12 $meta $kind $wb --format csv | ConvertFrom-Csv }
$cat = @{ "t$DE" = Catalog tables $DE; "t$ER" = Catalog tables $ER; "n$SDI" = Catalog names $SDI }

function Sq($s) { "'" + $s.Replace("'", "''") + "'" }

$checks = @(
    @{ label = 'Executive_Reviews  table Exec_Review_Details';  kind = 't'; wb = $ER; key = 'Exec_Review_Details' },
    @{ label = 'Executive_Reviews  table Exec_Review_Details8'; kind = 't'; wb = $ER; key = 'Exec_Review_Details8' },
    @{ label = 'Data Extracts      table Job_Base_Rate';        kind = 't'; wb = $DE; key = 'Job_Base_Rate' },
    @{ label = 'Data Extracts      table Job_Rate_Tiers';       kind = 't'; wb = $DE; key = 'Job_Rate_Tiers' },
    @{ label = 'Data Extracts      table Project_Rate_Tiers';   kind = 't'; wb = $DE; key = 'Project_Rate_Tiers' },
    @{ label = 'SDI copy  name SDI_Costcodes!ExternalData_1';   kind = 'n'; wb = $SDI; key = 'SDI_Costcodes!ExternalData_1' },
    @{ label = "SDI copy  name 'Excluded Vendors by Project'!ExternalData_1"; kind = 'n'; wb = $SDI; key = "'Excluded Vendors by Project'!ExternalData_1" }
)

$parts = foreach ($c in $checks) {
    if ($c.kind -eq 't') {
        $row = $cat["t$($c.wb)"] | Where-Object { $_.table -eq $c.key }
        $expected = [int]$row.data_rows
        $fn = 'read_xlsx_table'
    } else {
        $row = $cat["n$($c.wb)"] | Where-Object { $_.address -eq $c.key }
        $expected = [int]$row.rows - 1   # first row of the range is the header
        $fn = 'read_xlsx_name'
    }
    "SELECT $(Sq $c.label) AS what, $expected AS expected, count(*) AS got FROM $fn($(Sq $c.wb), $(Sq $c.key))"
}
$sql = Join-Path $work 'counts.sql'
@(".read $macrosFwd", ".mode csv", ($parts -join "`nUNION ALL ") + ";") | Set-Content -Encoding ascii $sql
$rows = & duckdb -f $sql | ConvertFrom-Csv
if ($LASTEXITCODE -ne 0) { throw "duckdb count query failed" }

$fail = 0
Write-Output ''
Write-Output 'By-name reads: rows DuckDB returned vs rows the workbook says the table holds'
$rows | ForEach-Object {
    $ok = if ([int]$_.got -eq [int]$_.expected) { 'PASS' } else { $fail++; 'FAIL' }
    [pscustomobject]@{ result = $ok; expected = [int]$_.expected; got = [int]$_.got; what = $_.what }
} | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | Write-Output

Write-Output ''
# For contrast: the old way. One sheet holds all three rate tables side by side.
$contrast = Join-Path $work 'contrast.sql'
@(".mode csv", "SELECT count(*) AS n FROM read_xlsx($(Sq $DE), sheet = 'Job_Internal_Rates', all_varchar = true);") |
    Set-Content -Encoding ascii $contrast
$sheetRows = (& duckdb -f $contrast | ConvertFrom-Csv).n
Write-Output "For contrast, a sheet-only read of Job_Internal_Rates returns $sheetRows rows -- none of the three tables' counts."
Write-Output ''

# Refusals: each must fail with its own message, never return rows.
$refusals = @(
    @{ what = 'bare ExternalData_1 (on 5 sheets)';    q = "FROM read_xlsx_name($(Sq $SDI), 'ExternalData_1')";      want = 'is ambiguous' },
    @{ what = 'Excluded_Vendors (refers to #REF!)';   q = "FROM read_xlsx_name($(Sq $SDI), 'Excluded_Vendors')";    want = 'is broken' },
    @{ what = 'a table that does not exist';          q = "FROM read_xlsx_table($(Sq $DE), 'No_Such_Table')";       want = "no table 'No_Such_Table'" },
    @{ what = 'a workbook not given to the generator'; q = "FROM read_xlsx_table('C:/elsewhere/Data Extracts.xlsm', 'Job_Rate_Tiers')"; want = "no table 'Job_Rate_Tiers'" }
)
Write-Output 'Refusals: each of these must stop with an error, not return rows'
foreach ($r in $refusals) {
    $f = Join-Path $work 'refusal.sql'
    @(".read $macrosFwd", "$($r.q);") | Set-Content -Encoding ascii $f
    # cmd merges stderr as plain text; PowerShell 5.1 would wrap each stderr line as an error record.
    $out = (cmd /c "duckdb -f `"$f`" 2>&1" | Out-String)
    $code = $LASTEXITCODE
    $msg = ($out -split "`n" | Where-Object { $_ -match 'Error:' } | Select-Object -First 1)
    $ok = if ($code -ne 0 -and $out -match [regex]::Escape($r.want)) { 'PASS' } else { $fail++; 'FAIL' }
    Write-Output ("  {0}  {1}" -f $ok, $r.what)
    Write-Output ("        {0}" -f ($msg -replace '^\s+', '').Trim())
}
Write-Output ''

$changed = @($sources | Where-Object { (Get-Sha $_) -ne $before[$_] })
if ($changed.Count) { $fail++; Write-Output "FAIL  source workbook changed during the run: $($changed -join '; ')" }
else { Write-Output "PASS  all 3 source workbooks unchanged (SHA-256 before = after)" }

Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output "RESULT: PASS ($($checks.Count) reads, $($refusals.Count) refusals, sources unchanged)"
