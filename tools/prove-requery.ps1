<#
tools\prove-requery.ps1

TASK.md item 7, part A. Proves the Serves: claim -- once a workbook sheet is
materialized, the lake keeps answering questions about it with the workbook
closed, moved, or absent -- for both shipped contracts, re-runnably, without
ever writing to the live workbook or touching the real lake.

Never derives the path to remove from a contract's read_xlsx text: under AC2's
second mutation (skip the rewrite in step 2) that text is the live workbook's
own path, not a scratch one. $scratchWb is captured in a variable from this
script's own copy step (step 1) and is the only file this script ever removes,
after asserting it is still under $scratch (F7 / step 5).

Querying the lake does not read the contract at all, so "point the contract at
a nonexistent path" (PLAN-4's original check) proves nothing -- the workbook
itself must be made absent. Steps 3 and 6 below read the source-side and
lake-side figures independently: step 3 reads $scratchWb directly, before it
is removed; step 6 reads the lake in a brand-new `duckdb` process, after
removal, so the two figures cannot share any cached state.

All lakes and roots here are scratch under $env:TEMP -- this script never
resolves or touches the real project lake (tools\dsk-paths.ps1's
Resolve-LakeRoot default).
#>
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$contractsDir = Join-Path $repoRoot 'contracts'
$compatFullPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
$compatFwd = $compatFullPath -replace '\\', '/'
$materializePath = Join-Path $PSScriptRoot 'materialize.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$liveWorkbook = 'C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\Excel Exports Data Warehousing\Domo\Data Extracts.xlsm'
$liveWorkbookFwd = $liveWorkbook -replace '\\', '/'
$liveLiteral = "'$liveWorkbookFwd'"

$contractNames = @('All_Sales_Data', 'Clayco_Job_Costs_from_GL')

function Invoke-DuckdbBatch {
    param([string]$Sql)
    $scratchDir = Join-Path $env:TEMP "dsk-prove-requery-batch-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    try {
        $body = ".mode csv`r`n.headers off`r`n" + $Sql
        $f = Join-Path $scratchDir 'batch.sql'
        [System.IO.File]::WriteAllText($f, $body, $utf8NoBom)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & duckdb -f $f 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $lines = @($out | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $exit; Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-CsvField {
    param([string]$Line, [int]$Count)
    return $Line -split ',', $Count
}

function Fail {
    param([string]$Message)
    Write-Output "ERROR,$Message"
    exit 1
}

if (-not (Test-Path -LiteralPath $liveWorkbook -PathType Leaf)) {
    Fail "live workbook not found: $liveWorkbook"
}
if (-not (Test-Path -LiteralPath $materializePath -PathType Leaf)) {
    Fail "materialize.ps1 not found at: $materializePath"
}

# --- step 1: record the live workbook's hash/mtime, then copy it (read only) ----------
$liveHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveWorkbook).Hash.ToLowerInvariant()
$liveMtimeBefore = (Get-Item -LiteralPath $liveWorkbook).LastWriteTime

$scratch = Join-Path $env:TEMP "dsk-prove-requery-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$scratchWb = Join-Path $scratch 'Data Extracts.xlsm'
Copy-Item -LiteralPath $liveWorkbook -Destination $scratchWb
$scratchWbFwd = $scratchWb -replace '\\', '/'
$scratchLiteral = "'$scratchWbFwd'"

try {
    # --- step 2: scratch copies of both contracts, path rewritten ----------------------
    # The guard below checks the WRITTEN file, not the pre-write count, so a mutated
    # copy of this script that skips the .Replace() call is still caught here.
    $scratchContractsDir = Join-Path $scratch 'contracts'
    New-Item -ItemType Directory -Path $scratchContractsDir -Force | Out-Null
    $scratchContractPath = @{}
    foreach ($name in $contractNames) {
        $srcContract = Join-Path $contractsDir "$name.sql"
        $text = Get-Content -LiteralPath $srcContract -Raw
        $newText = $text.Replace($liveLiteral, $scratchLiteral)
        $dst = Join-Path $scratchContractsDir "$name.sql"
        [System.IO.File]::WriteAllText($dst, $newText, $utf8NoBom)

        $writtenText = Get-Content -LiteralPath $dst -Raw
        $liveOccurrencesAfter = ([regex]::Matches($writtenText, [regex]::Escape($liveLiteral))).Count
        $scratchOccurrencesAfter = ([regex]::Matches($writtenText, [regex]::Escape($scratchLiteral))).Count
        if ($liveOccurrencesAfter -ne 0 -or $scratchOccurrencesAfter -ne 1) {
            Fail "$name,expected exactly one occurrence of the live workbook path to be replaced by the scratch copy; found $liveOccurrencesAfter live and $scratchOccurrencesAfter scratch occurrences after rewrite"
        }
        $scratchContractPath[$name] = $dst
    }

    # --- step 3: source-side figures, read directly from $scratchWb, BEFORE removal ----
    $sourceRows = @{}
    $sourceSum = $null
    foreach ($name in $contractNames) {
        $cfFwd = $scratchContractPath[$name] -replace '\\', '/'
        $sql = "LOAD ducklake;`r`n.read '$compatFwd'`r`n.read '$cfFwd'`r`nSELECT 'SRC_ROWS', count(*) FROM contract_view;`r`n"
        if ($name -eq 'Clayco_Job_Costs_from_GL') {
            $sql += "SELECT 'SRC_SUM', CAST(sum(JOB_COSTS) AS VARCHAR) FROM contract_view;`r`n"
        }
        $r = Invoke-DuckdbBatch -Sql $sql
        $rowsLine = $r.Lines | Where-Object { $_ -like 'SRC_ROWS,*' } | Select-Object -First 1
        if ($r.ExitCode -ne 0 -or -not $rowsLine) {
            Fail "$name,could not read source-side figures from the scratch workbook: $($r.Lines -join ' | ')"
        }
        $sourceRows[$name] = (Get-CsvField -Line $rowsLine -Count 2)[1]
        if ($name -eq 'Clayco_Job_Costs_from_GL') {
            $sumLine = $r.Lines | Where-Object { $_ -like 'SRC_SUM,*' } | Select-Object -First 1
            $sourceSum = (Get-CsvField -Line $sumLine -Count 2)[1]
        }
    }

    # --- step 4: materialize both contracts into a fresh scratch lake ------------------
    $scratchLake = Join-Path $scratch 'lake'
    New-Item -ItemType Directory -Path $scratchLake -Force | Out-Null
    foreach ($name in $contractNames) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $matOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $materializePath -Contract $scratchContractPath[$name] -LakeRoot $scratchLake 2>&1
        $matExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $matLines = @($matOutput | ForEach-Object { [string]$_ })
        $refreshedLine = $matLines | Where-Object { $_ -like "MATERIALIZE,$name,REFRESHED*" }
        if ($matExit -ne 0 -or -not $refreshedLine) {
            Fail "$name,materialize did not REFRESH (exit=$matExit): $($matLines -join ' | ')"
        }
    }

    # --- step 5: remove $scratchWb -- asserted under $scratch, never derived from a
    # contract's read_xlsx text (F7): under AC2's second mutation that text is live. ----
    $scratchWbFull = [System.IO.Path]::GetFullPath($scratchWb)
    $scratchFull = [System.IO.Path]::GetFullPath($scratch)
    if (-not $scratchWbFull.StartsWith($scratchFull, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "refusing to remove a path not under scratch: $scratchWbFull"
    }
    Remove-Item -LiteralPath $scratchWb -Force

    # --- step 6: measure workbook_present, then re-read the lake in a FRESH process -----
    $workbookPresent = Test-Path -LiteralPath $scratchWb -PathType Leaf

    $lakeCatalog = Join-Path $scratchLake 'lake.ducklake'
    $lakeData = Join-Path $scratchLake 'data'
    $lakeCatalogFwd = $lakeCatalog -replace '\\', '/'
    $lakeDataFwd = $lakeData -replace '\\', '/'
    $lakeSql = "LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataFwd', READ_ONLY);`r`n"
    foreach ($name in $contractNames) {
        $lakeSql += "SELECT 'LAKE_ROWS_$name', count(*) FROM lake.$name;`r`n"
        $lakeSql += "SELECT 'MANIFEST_ROWS_$name', row_count FROM lake.manifest WHERE contract_name = '$name' ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1;`r`n"
    }
    $lakeSql += "SELECT 'LAKE_SUM', CAST(sum(JOB_COSTS) AS VARCHAR) FROM lake.Clayco_Job_Costs_from_GL;`r`n"
    $lakeResult = Invoke-DuckdbBatch -Sql $lakeSql
    if ($lakeResult.ExitCode -ne 0) {
        Fail "could not read the scratch lake in a fresh process: $($lakeResult.Lines -join ' | ')"
    }

    # --- step 7: print ------------------------------------------------------------------
    $anyFail = $false
    foreach ($name in $contractNames) {
        $lakeRowsLine = $lakeResult.Lines | Where-Object { $_ -like "LAKE_ROWS_$name,*" } | Select-Object -First 1
        $manifestRowsLine = $lakeResult.Lines | Where-Object { $_ -like "MANIFEST_ROWS_$name,*" } | Select-Object -First 1
        $lakeRows = if ($lakeRowsLine) { (Get-CsvField -Line $lakeRowsLine -Count 2)[1] } else { $null }
        $manifestRows = if ($manifestRowsLine) { (Get-CsvField -Line $manifestRowsLine -Count 2)[1] } else { $null }
        $srcRows = $sourceRows[$name]
        $pass = ($null -ne $lakeRows) -and ($null -ne $manifestRows) -and ($srcRows -eq $lakeRows) -and ($lakeRows -eq $manifestRows) -and (-not $workbookPresent)
        if (-not $pass) { $anyFail = $true }
        $verdict = if ($pass) { 'PASS' } else { 'FAIL' }
        Write-Output "REQUERY,$name,source_rows=$srcRows,lake_rows=$lakeRows,manifest_rows=$manifestRows,workbook_present=$($workbookPresent.ToString().ToLowerInvariant()),$verdict"
    }

    $lakeSumLine = $lakeResult.Lines | Where-Object { $_ -like 'LAKE_SUM,*' } | Select-Object -First 1
    $lakeSum = if ($lakeSumLine) { (Get-CsvField -Line $lakeSumLine -Count 2)[1] } else { $null }
    $sumPass = ($null -ne $lakeSum) -and ($sourceSum -eq $lakeSum)
    if (-not $sumPass) { $anyFail = $true }
    Write-Output "REQUERY_SUM,Clayco_Job_Costs_from_GL,source=$sourceSum,lake=$lakeSum,$(if ($sumPass) { 'PASS' } else { 'FAIL' })"

    # --- step 8: re-check the live workbook (item 6 AC20's rule) ------------------------
    $liveHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveWorkbook).Hash.ToLowerInvariant()
    $liveMtimeAfter = (Get-Item -LiteralPath $liveWorkbook).LastWriteTime

    if ($liveHashAfter -eq $liveHashBefore -and $liveMtimeAfter -eq $liveMtimeBefore) {
        Write-Output 'LIVE_WORKBOOK,unchanged'
    } elseif ($liveMtimeAfter -gt $liveMtimeBefore) {
        Write-Output "LIVE_WORKBOOK,SYNCED,$liveMtimeBefore->$liveMtimeAfter"
    } else {
        Write-Output 'LIVE_WORKBOOK,CHANGED'
        $anyFail = $true
    }

    if ($anyFail) { exit 1 }
    exit 0
} finally {
    # --- step 9: remove $scratch -------------------------------------------------------
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
