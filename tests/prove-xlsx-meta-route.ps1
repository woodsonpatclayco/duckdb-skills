<#
tests\prove-xlsx-meta-route.ps1

PLAN-7 step 4 proof: the contract tools read Excel tables by name through the xlsx_meta
extension when this DuckDB can load it, and through tools\xlsx_meta.py when it can't, with
the same results either way. contracts\Job_Rate_Tiers.sql is run twice: once as shipped
(extension) and once with DSK_XLSX_META=python (the fallback a different DuckDB version gets).

  1. Which route each mode takes (Get-XlsxMetaExtension).
  2. run-assertions.ps1 and check-contract.ps1 output: identical line for line.
  3. materialize.ps1 into a scratch lake in %TEMP%: the same row count both times. The second
     run refreshes, because switching route changes the freshness key (by design).

Reads Data Extracts.xlsm in place, read-only. The real lake is never touched.
#>
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) "prove-xlsx-meta-route-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$lake = Join-Path $work 'lake'
New-Item -ItemType Directory -Force $lake | Out-Null
$jr = "$repo\contracts\Job_Rate_Tiers.sql"
$fail = 0

function Run($script, [string[]]$argList) {
    @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>$null | ForEach-Object { [string]$_ })
}
function LakeRows {
    $q = "$work\count.sql"
    @("LOAD ducklake;", "ATTACH 'ducklake:$($lake.Replace('\','/'))/lake.ducklake' AS lake (DATA_PATH '$($lake.Replace('\','/'))/data');",
      ".mode csv", "SELECT count(*) AS n FROM lake.Job_Rate_Tiers;") | Set-Content -Encoding ascii $q
    (& duckdb -f $q | ConvertFrom-Csv).n
}

$out = @{}
foreach ($mode in 'extension', 'python') {
    $env:DSK_XLSX_META = if ($mode -eq 'python') { 'python' } else { $null }
    $probe = & powershell -NoProfile -Command ". '$repo\tools\contract-xlsx.ps1'; `$e = Get-XlsxMetaExtension; if (`$e) { `$e } else { 'python generator' }"
    $out[$mode] = @{
        Probe  = $probe
        Assert = Run "$repo\tools\run-assertions.ps1" @('-Contract', $jr)
        Check  = Run "$repo\tools\check-contract.ps1" @('-Contract', $jr)
        Mat    = (Run "$repo\tools\materialize.ps1" @('-Contract', $jr, '-LakeRoot', $lake)) | Where-Object { $_ -like 'MATERIALIZE,*' }
        Rows   = LakeRows
    }
}
$env:DSK_XLSX_META = $null

Write-Output '1. Route'
foreach ($mode in 'extension', 'python') { Write-Output ("   {0,-9}  {1}" -f $mode, $out[$mode].Probe) }
if ($out.extension.Probe -notlike '*xlsx_meta.duckdb_extension' -or $out.python.Probe -ne 'python generator') {
    $fail++; Write-Output '   FAIL  the two modes did not take the two routes'
}

Write-Output ''
Write-Output '2. Contract checks, extension vs python'
foreach ($k in 'Assert', 'Check') {
    $a = $out.extension[$k]; $b = $out.python[$k]
    $diff = Compare-Object $a $b -SyncWindow 0
    $ok = if (-not $diff -and $a.Count -gt 0) { 'PASS' } else { $fail++; 'FAIL' }
    $name = if ($k -eq 'Assert') { 'run-assertions' } else { 'check-contract' }
    Write-Output ("   {0}  {1}: {2} lines, {3}" -f $ok, $name, $a.Count, $(if ($diff) { "$(@($diff).Count) differ" } else { 'identical' }))
    if ($diff) { $diff | ForEach-Object { Write-Output "         $($_.SideIndicator) $($_.InputObject)" } }
}
$out.extension.Assert | Where-Object { $_ -like 'SOURCE,*' -or $_ -like 'SUMMARY,*' -or $_ -like 'CONSISTENCY_VIEW_ROWS,*' } |
    ForEach-Object { Write-Output "         $_" }

Write-Output ''
Write-Output '3. Materialize into a scratch lake'
foreach ($mode in 'extension', 'python') { Write-Output ("   {0,-9}  {1}  -> {2} rows" -f $mode, $out[$mode].Mat, $out[$mode].Rows) }
$ok = if ($out.extension.Rows -and $out.extension.Rows -eq $out.python.Rows -and
          $out.extension.Mat -like '*,REFRESHED,*' -and $out.python.Mat -like '*,REFRESHED,*') { 'PASS' } else { $fail++; 'FAIL' }
Write-Output "   $ok  same row count; the route switch refreshed it"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (extension and Python fallback give the same checks and the same lake table)'
