<#
tests\prove-xlsx-formulas.ps1 -- PLAN-6 item 3: read a workbook's formulas.

  1. Trap fixture (tests\make-formula-fixture.py, built in %TEMP%): every row the formula view
     produces must equal the expected row -- kind, A1 text, R1C1 form, cached value, error --
     and no row may be missing or extra. The R1C1 forms were checked once against Excel's own
     Formula2R1C1 on 2026-10-08: every reference identical.
  2. SDI Calculator (a copy in %TEMP%; the live file is a working file): the view's counts of
     formula cells and error cells must equal an independent recount of the same copy
     (tests\recount-formulas.py, plain regular expressions, no shared code). Both are
     re-measured every run, so this stays valid as the workbook is saved.
  3. The plan's example: Combined!A10 and A11 hold different A1 text for one logical formula
     and must share one R1C1 form.
  4. The live SDI Calculator is unchanged (SHA-256 before = after).
#>
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$SDIlive = 'C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\SDI Calculator\SDI Calculator Data thru Current Month.xlsx'
$work = Join-Path ([IO.Path]::GetTempPath()) 'prove-xlsx-formulas'
New-Item -ItemType Directory -Force $work | Out-Null
$meta = Join-Path $repo 'tools\xlsx_meta.py'
$fail = 0

# Open read-only but share read/write, so a workbook open in Excel can still be read.
function Open-Shared($p) { [IO.File]::Open($p, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete') }
function Get-Sha($p) {
    $fs = Open-Shared $p
    try { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fs)) -replace '-', '' }
    finally { $fs.Dispose() }
}
function Fwd($p) { $p.Replace('\', '/') }
function DuckCsv([string[]]$lines) {
    $f = Join-Path $work 'q.sql'
    $lines | Set-Content -Encoding ascii $f
    & duckdb -f $f | ConvertFrom-Csv
}

# --- 1. trap fixture --------------------------------------------------------------------------
$traps = Join-Path $work 'traps.xlsx'
& py -3.12 (Join-Path $PSScriptRoot 'make-formula-fixture.py') $traps | Out-Null
& py -3.12 $meta macros $traps --formulas -o "$work\traps.sql" | Out-Null
$rows = DuckCsv @(".read '$(Fwd "$work\traps.sql")'", ".mode csv",
    "SELECT coalesce(e.sheet, g.sheet) || '!' || coalesce(e.cell, g.cell) AS cell,",
    "  CASE WHEN e.cell IS NULL THEN 'EXTRA' WHEN g.cell IS NULL THEN 'MISSING'",
    "       WHEN (e.kind, coalesce(e.formula_a1, ''), coalesce(e.formula_r1c1, ''), coalesce(e.cached_value, ''), coalesce(e.error, ''))",
    "          = (g.kind, coalesce(g.formula_a1, ''), coalesce(g.formula_r1c1, ''), coalesce(g.cached_value, ''), coalesce(g.error, ''))",
    "       THEN 'PASS' ELSE 'FAIL' END AS result,",
    "  coalesce(g.kind, '') AS kind, coalesce(g.formula_a1, '') AS stored_a1, coalesce(g.formula_r1c1, '') AS r1c1,",
    "  coalesce(e.formula_r1c1, '') AS expected_r1c1",
    "FROM read_csv('$(Fwd "$traps.expected.csv")', all_varchar = true) e",
    "FULL JOIN (FROM read_xlsx_formulas('$(Fwd $traps)')) g USING (sheet, cell) ORDER BY 1;")
Write-Output '1. Trap fixture: every row of the formula view against its expected row'
$rows | ForEach-Object {
    if ($_.result -ne 'PASS') { $fail++ }
    [pscustomobject]@{ result = $_.result; cell = $_.cell; kind = $_.kind; stored_A1 = $_.stored_a1; R1C1 = $_.r1c1 }
} | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { $_.TrimEnd() } | Write-Output
$bad = @($rows | Where-Object { $_.result -ne 'PASS' })
foreach ($b in $bad) { Write-Output "   $($b.result) $($b.cell): got [$($b.r1c1)] expected [$($b.expected_r1c1)]" }
Write-Output ("   {0} of {1} rows PASS" -f (@($rows).Count - $bad.Count), @($rows).Count)

# --- 2. SDI copy: view vs independent recount -------------------------------------------------
$before = Get-Sha $SDIlive
$SDI = Join-Path $work 'SDI.xlsx'
$in = Open-Shared $SDIlive
try { $out = [IO.File]::Create($SDI); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }

$sw = [Diagnostics.Stopwatch]::StartNew()
& py -3.12 $meta macros $SDI --formulas -o "$work\sdi.sql" | Out-Null
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$view = DuckCsv @(".read '$(Fwd "$work\sdi.sql")'", ".mode csv",
    "WITH f AS (FROM read_xlsx_formulas('$(Fwd $SDI)'))",
    "SELECT 'formula_cells' AS metric, count(*) FILTER (WHERE kind <> 'none') AS value FROM f",
    "UNION ALL SELECT 'kind_' || k, (SELECT count(*) FROM f WHERE kind = k) FROM (VALUES ('normal'), ('shared'), ('array'), ('data-table')) t(k)",
    "UNION ALL SELECT 'error_cells', count(*) FILTER (WHERE error <> '') FROM f",
    "UNION ALL SELECT 'error_in_formula', count(*) FILTER (WHERE error <> '' AND kind <> 'none') FROM f",
    "UNION ALL SELECT 'error_as_value', count(*) FILTER (WHERE error <> '' AND kind = 'none') FROM f",
    "UNION ALL SELECT 'error_' || error, count(*) FROM f WHERE error <> '' GROUP BY error;")
$recount = & py -3.12 (Join-Path $PSScriptRoot 'recount-formulas.py') $SDI | ConvertFrom-Csv
Write-Output ''
Write-Output "2. SDI Calculator copy: the formula view (built in $secs s) vs an independent recount"
$metrics = @($recount | ForEach-Object metric) + @($view | ForEach-Object metric) | Select-Object -Unique
$metrics | ForEach-Object {
    $m = $_
    $v = ($view | Where-Object metric -eq $m).value
    $r = ($recount | Where-Object metric -eq $m).value
    $ok = if ("$v" -eq "$r") { 'PASS' } else { $fail++; 'FAIL' }
    [pscustomobject]@{ result = $ok; metric = $m; view = $v; recount = $r }
} | Format-Table -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Output

# --- 3. the plan's example --------------------------------------------------------------------
$ex = DuckCsv @(".read '$(Fwd "$work\sdi.sql")'", ".mode csv",
    "SELECT cell, formula_a1, formula_r1c1 FROM read_xlsx_formulas('$(Fwd $SDI)')",
    "WHERE sheet = 'Combined' AND cell IN ('A10', 'A11') ORDER BY row;")
Write-Output ''
Write-Output '3. One logical formula on two rows: different A1 text, one R1C1 form'
$ex | ForEach-Object { Write-Output "   Combined!$($_.cell)  A1: $($_.formula_a1)    R1C1: $($_.formula_r1c1)" }
$ok = if (@($ex).Count -eq 2 -and $ex[0].formula_a1 -ne $ex[1].formula_a1 -and $ex[0].formula_r1c1 -eq $ex[1].formula_r1c1) { 'PASS' } else { $fail++; 'FAIL' }
Write-Output "   $ok  same R1C1, different A1"

# --- 4. live file untouched -------------------------------------------------------------------
Write-Output ''
if ((Get-Sha $SDIlive) -eq $before) { Write-Output 'PASS  live SDI Calculator unchanged (SHA-256 before = after)' }
else { $fail++; Write-Output 'FAIL  live SDI Calculator changed during the run (was it saved meanwhile?)' }

Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (trap fixture exact; SDI view matches the independent recount; one R1C1 per logical formula)'
