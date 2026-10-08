<#
tests\prove-formula-checks.ps1 -- PLAN-6 item 4: formula checks in contracts.

Runs tests\contracts\SDI_Combined_Formulas.sql (four formula checks on the SDI Calculator's
Combined_SDI_Data table) against a clean staged copy, then against throwaway copies that each
carry ONE planted defect, then against the clean copy again. A check that only ever passes
proves nothing, so each run must fail EXACTLY the checks listed for it -- no more, no fewer.

The clean copy is pinned at .duckdb-skills\formula-proof\SDI-clean.xlsx (gitignored), so the
committed counts in the contract stay true. Delete that file to re-stage from the live SDI
Calculator; the live file is only ever read, through a shared read-only open.
Finally the clean run is materialized into a scratch lake, to show the four checks land in
check_history as invariants.
#>
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$dir = Join-Path $repo '.duckdb-skills\formula-proof'
$clean = Join-Path $dir 'SDI-clean.xlsx'
$work = Join-Path $dir 'SDI.xlsx'
$contract = Join-Path $repo 'tests\contracts\SDI_Combined_Formulas.sql'
$plant = Join-Path $PSScriptRoot 'plant-formula-defect.py'
$SDIlive = 'C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\SDI Calculator\SDI Calculator Data thru Current Month.xlsx'
New-Item -ItemType Directory -Force $dir | Out-Null

if (-not (Test-Path -LiteralPath $clean)) {
    $in = [IO.File]::Open($SDIlive, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
    try { $out = [IO.File]::Create($clean); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }
    Write-Output "NOTE: staged a fresh clean copy from the live SDI Calculator. If the workbook's error count"
    Write-Output "      has moved since 2026-10-08, workbook_errors (committed max 748) will say so on the clean run."
}
$cleanSha = (Get-FileHash -LiteralPath $clean -Algorithm SHA256).Hash

$checks = @('sdi_basis_consistent', 'sdi_basis_formula', 'sdi_basis_errors', 'workbook_errors')
$scenarios = @(
    @{ what = 'clean copy';                                          plant = $null;                                                                         fails = @() },
    @{ what = 'a value typed over Combined!A20';                      plant = @('A20', 'typed', '12345');                                                    fails = @('sdi_basis_consistent') },
    @{ what = 'Combined!A30 edited to read row 31 ($AG31)';           plant = @('A30', 'formula', 'INDEX(_xlfn.ANCHORARRAY(AI$10),$AG31)');                  fails = @('sdi_basis_consistent', 'sdi_basis_formula') },
    @{ what = 'whole column edited to read column AH (consistent)';   plant = @('A10:A90', 'formula', 'INDEX(_xlfn.ANCHORARRAY(AI$10),$AH{row})');           fails = @('sdi_basis_formula') },
    @{ what = 'one extra #REF! at Combined!A40';                      plant = @('A40', 'error', '#REF!');                                                    fails = @('sdi_basis_errors', 'workbook_errors') },
    @{ what = 'clean copy again';                                    plant = $null;                                                                         fails = @() }
)

$fail = 0
$results = foreach ($s in $scenarios) {
    if ($s.plant) { & py -3.12 $plant $clean $work Combined @($s.plant) | Out-Null }
    else { Copy-Item -LiteralPath $clean -Destination $work -Force }
    $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\tools\run-assertions.ps1" -Contract $contract 2>$null | ForEach-Object { [string]$_ })
    $status = @{}; $detail = @{}
    foreach ($l in $lines) {
        if ($l -match '^ASSERT,([^,]+),([^,]+)(?:,(.*))?$') { $status[$Matches[1]] = $Matches[2]; $detail[$Matches[1]] = $Matches[3] }
    }
    $failed = @($checks | Where-Object { $status[$_] -ne 'PASS' })
    # Expected checks must say FAIL -- an ERROR (the check itself broke) is not the check working.
    $asExpected = (-not (Compare-Object @($failed) @($s.fails))) -and ($status.Count -eq $checks.Count) -and
                  -not ($failed | Where-Object { $status[$_] -ne 'FAIL' })
    if (-not $asExpected) { $fail++ }
    [pscustomobject]@{
        ok = if ($asExpected) { 'PASS' } else { 'FAIL' }
        defect = $s.what
        consistent = $status['sdi_basis_consistent']; fingerprint = $status['sdi_basis_formula']
        col_errors = $status['sdi_basis_errors']; wb_errors = $status['workbook_errors']
        _details = @($failed | ForEach-Object { "      $_ : $($detail[$_])" })
        _other = @($lines | Where-Object { $_ -like 'ERROR,*' })
    }
}

Write-Output 'Each run must fail exactly the checks its defect breaks:'
$results | Select-Object ok, defect, consistent, fingerprint, col_errors, wb_errors |
    Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | Write-Output
Write-Output ''
Write-Output 'What each failing check said:'
foreach ($r in $results) {
    if ($r._details.Count -or $r._other.Count) {
        Write-Output "   $($r.defect)"
        $r._details | ForEach-Object { Write-Output $_ }
        $r._other | ForEach-Object { Write-Output "      $_" }
    }
}

# Check history: the clean run materialized into a scratch lake.
Copy-Item -LiteralPath $clean -Destination $work -Force
$lake = Join-Path ([IO.Path]::GetTempPath()) "prove-formula-checks-lake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$m = @(& powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\tools\materialize.ps1" -Contract $contract -LakeRoot $lake 2>$null | Where-Object { $_ -like 'MATERIALIZE,*' })
$q = Join-Path $lake 'q.sql'
@("LOAD ducklake;", "ATTACH 'ducklake:$($lake.Replace('\','/'))/lake.ducklake' AS lake (DATA_PATH '$($lake.Replace('\','/'))/data');",
  ".mode csv", "SELECT check_id, kind, status FROM lake.check_history WHERE check_id IN ('$($checks -join "','")') ORDER BY check_id;") |
    Set-Content -Encoding ascii $q
$hist = @(& duckdb -f $q | ConvertFrom-Csv)
Write-Output ''
Write-Output "Materialized the clean run into a scratch lake: $m"
$hist | ForEach-Object { Write-Output "   check_history: $($_.check_id)  kind=$($_.kind)  status=$($_.status)" }
$ok = if ($hist.Count -eq 4 -and -not ($hist | Where-Object { $_.kind -ne 'invariant' -or $_.status -ne 'PASS' })) { 'PASS' } else { $fail++; 'FAIL' }
Write-Output "   $ok  all four recorded as invariant / PASS"
Remove-Item -LiteralPath $lake -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ''
if ((Get-FileHash -LiteralPath $clean -Algorithm SHA256).Hash -eq $cleanSha) { Write-Output 'PASS  clean copy unchanged (every defect went into a throwaway copy)' }
else { $fail++; Write-Output 'FAIL  the clean copy changed' }

Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (every check fires on its defect and only there; clean runs pass; history records them)'
