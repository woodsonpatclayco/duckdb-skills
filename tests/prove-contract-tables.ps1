<#
tests\prove-contract-tables.ps1 [-Baseline <commit>]

PLAN-6 item 2 proof: a contract can read an Excel table by name (`-- @table:`), and the two
existing sheet contracts behave exactly as they did before item 2.

  1. The two existing contracts' check output from the code BEFORE item 2 (extracted from git
     at -Baseline into %TEMP%, never checked out over this folder) and from the code NOW --
     must be line-for-line identical.
  2. Both versions materialize the existing contracts into a scratch lake in %TEMP% (the real
     lake is never touched). The freshness key (compat_sha256) each run records must be the
     same, so a real lake would not refresh just because this code changed.
  3. contracts\Job_Rate_Tiers.sql -- the first by-table contract -- passes every check and
     materializes; its lake table has the table's row count.

Reads Data Extracts.xlsm in place, read-only, as the existing contracts already do.
#>
param(
    # The last commit before item 2 (item 1: xlsx_meta.py).
    [string]$Baseline = 'ed1d8b5'
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$work = Join-Path ([IO.Path]::GetTempPath()) "prove-contract-tables-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$old  = Join-Path $work 'old'
$lake = Join-Path $work 'lake'
New-Item -ItemType Directory -Force $old, $lake | Out-Null
$fail = 0

& git archive --format=tar -o "$work\old.tar" $Baseline tools skills
& tar -xf "$work\old.tar" -C $old
if (-not (Test-Path "$old\tools\run-assertions.ps1")) { Write-Output "ERROR: could not extract $Baseline"; exit 1 }

function Run($script, [string[]]$argList) {
    @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>$null | ForEach-Object { [string]$_ })
}
$existing = @('All_Sales_Data', 'Clayco_Job_Costs_from_GL')

# --- 1. check output, before vs now ---------------------------------------------------------
Write-Output "1. Existing contracts' check output: code at $Baseline vs code now"
foreach ($c in $existing) {
    $cf = "$repo\contracts\$c.sql"
    $a = Run "$old\tools\run-assertions.ps1" @('-Contract', $cf)
    $b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $cf)
    $diff = Compare-Object $a $b -SyncWindow 0
    $ok = if (-not $diff -and $a.Count -gt 0) { 'PASS' } else { $fail++; 'FAIL' }
    Write-Output ("   {0}  {1}: {2} lines before, {3} now, {4}" -f $ok, $c, $a.Count, $b.Count, $(if ($diff) { "$(@($diff).Count) differ" } else { 'identical' }))
    if ($diff) { $diff | ForEach-Object { Write-Output "         $($_.SideIndicator) $($_.InputObject)" } }
}

# --- 2. freshness key, before vs now --------------------------------------------------------
Write-Output ''
Write-Output '2. Existing contracts materialized by the old code, then by the new code (scratch lake)'
foreach ($c in $existing) {
    $cf = "$repo\contracts\$c.sql"
    $o = Run "$old\tools\materialize.ps1" @('-Contract', $cf, '-LakeRoot', $lake) | Where-Object { $_ -like "MATERIALIZE,*" }
    $n = Run "$repo\tools\materialize.ps1" @('-Contract', $cf, '-LakeRoot', $lake) | Where-Object { $_ -like "MATERIALIZE,*" }
    Write-Output "   old code: $o"
    Write-Output "   new code: $n"
}
$q = "$work\manifest.sql"
@("LOAD ducklake;", "ATTACH 'ducklake:$($lake.Replace('\','/'))/lake.ducklake' AS lake (DATA_PATH '$($lake.Replace('\','/'))/data');",
  ".mode csv",
  "SELECT contract_name, count(*) AS runs, count(DISTINCT compat_sha256) AS distinct_keys FROM lake.manifest GROUP BY ALL ORDER BY 1;") |
    Set-Content -Encoding ascii $q
$keys = @(& duckdb -f $q | ConvertFrom-Csv)
foreach ($c in $existing) {
    $k = $keys | Where-Object { $_.contract_name -eq $c }
    $ok = if ($k -and [int]$k.runs -ge 1 -and [int]$k.distinct_keys -eq 1) { 'PASS' } else { $fail++; 'FAIL' }
    Write-Output ("   {0}  {1}: {2} manifest row(s), {3} distinct freshness key(s) -- the code change alone never refreshes it" -f $ok, $c, $k.runs, $k.distinct_keys)
}

# --- 3. the new by-table contract ------------------------------------------------------------
Write-Output ''
Write-Output '3. contracts\Job_Rate_Tiers.sql (reads the Excel table Job_Rate_Tiers by name)'
$jr = "$repo\contracts\Job_Rate_Tiers.sql"
$r = Run "$repo\tools\run-assertions.ps1" @('-Contract', $jr)
$r | Where-Object { $_ -notlike 'CONTRACT,*' } | ForEach-Object { Write-Output "   $_" }
if (-not ($r -match '^SUMMARY,.*failures=0$')) { $fail++; Write-Output '   FAIL  checks did not all pass' }
$m = Run "$repo\tools\materialize.ps1" @('-Contract', $jr, '-LakeRoot', $lake) | Where-Object { $_ -like 'MATERIALIZE,*' }
Write-Output "   $m"
@("LOAD ducklake;", "ATTACH 'ducklake:$($lake.Replace('\','/'))/lake.ducklake' AS lake (DATA_PATH '$($lake.Replace('\','/'))/data');",
  ".mode csv", "SELECT count(*) AS n FROM lake.Job_Rate_Tiers;") | Set-Content -Encoding ascii $q
$lakeRows = (& duckdb -f $q | ConvertFrom-Csv).n
$viewRows = ($r | Where-Object { $_ -like 'CONSISTENCY_VIEW_ROWS,*' }) -replace '.*,', ''
$ok = if ($m -like 'MATERIALIZE,Job_Rate_Tiers,REFRESHED,*' -and $lakeRows -and $lakeRows -eq $viewRows) { 'PASS' } else { $fail++; 'FAIL' }
Write-Output "   $ok  lake.Job_Rate_Tiers holds $lakeRows rows; the table holds $viewRows"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (existing contracts unchanged; Job_Rate_Tiers reads by table name and materializes)'
