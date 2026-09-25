<#
tools\lake-status.ps1 [-History <contract>] [-AsOf <date> -Contract <name>] [-LakeRoot <absolute path>]

TASK.md item 6, deliverable 2. Read-only: every query below attaches with
`READ_ONLY` (confirmed this session that DuckLake accepts that ATTACH option),
and the catalog file's existence is checked with Test-Path BEFORE any ATTACH is
attempted -- a plain (read-write) ATTACH auto-creates a missing ducklake catalog,
which a status tool must never do as a side effect of being asked "what's here".
If the catalog file does not exist, this prints "no lake" and exits 0, in every
mode, without touching DuckDB at all.

-LakeRoot is accepted for testability/symmetry with tools\materialize.ps1 (same
Resolve-LakeRoot helper, same default) even though TASK.md's own deliverable text
does not name it for this tool -- no acceptance check requires its absence, and
every acceptance flow uses the default project lake, so this is additive, not a
substitute for the default resolution.

Three modes:
  (no switch)              one line per contract: its LATEST manifest row (by
                            lake_snapshot_id, materialized_at DESC -- the same
                            "latest" definition tools\materialize.ps1 itself uses
                            to decide freshness, via a QUALIFY row_number() window
                            rather than a plain MAX() self-join, because two
                            consecutive REFUSED attempts with no materialization
                            in between carry the SAME carried-forward
                            lake_snapshot_id and a plain MAX() tie would return
                            both rows for one contract).
  -History <contract>      every check_history row for that contract, joined to
                            manifest for materialized_at, ordered by time then
                            check_id -- the trend view AC11 exercises.
  -AsOf <date> -Contract   the dated question. TASK.md's own wording ("prints the
                <name>      newest manifest row at or before that date and states
                            that any LATER REFUSED runs did not change the data")
                            only parses if "the newest manifest row" means the
                            newest row that actually LANDED data, not literally
                            the newest row of any outcome -- so this finds the
                            newest row at-or-before the date with
                            (checks_passed OR forced), prints it as the effective
                            state, then separately reports any REFUSED rows for
                            the same contract strictly after that effective row's
                            timestamp and at-or-before the queried date, stating
                            plainly that they changed nothing. outcome itself is
                            never read from check_history here -- it is exactly
                            reconstructible from manifest's own checks_passed/
                            forced columns (forced -> FORCED; elif checks_passed
                            -> MATERIALIZED; else -> REFUSED), the same formula
                            tools\materialize.ps1 uses to decide it in the first
                            place, so this never needs a join for it.
#>
param(
    [string]$History,
    [string]$AsOf,
    [string]$Contract,
    [string]$LakeRoot
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsk-paths.ps1')

$lakeRootResolved, $usedDefaultLakeRoot = Resolve-LakeRoot -ExplicitRoot $LakeRoot
$lakeCatalogFile = Join-Path $lakeRootResolved 'lake.ducklake'
$lakeDataDir = Join-Path $lakeRootResolved 'data'
$lakeCatalogFwd = $lakeCatalogFile -replace '\\', '/'
$lakeDataDirFwd = $lakeDataDir -replace '\\', '/'

if (-not (Test-Path -LiteralPath $lakeCatalogFile -PathType Leaf)) {
    Write-Output 'no lake'
    exit 0
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-DuckdbBatch {
    param([string]$Sql)
    $scratchDir = Join-Path $env:TEMP "dsk-lake-status-$([guid]::NewGuid().ToString('N'))"
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

function ConvertTo-SqlLiteral {
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function ConvertFrom-SqlNull {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq 'NULL') { return $null }
    return $Text
}

function Get-Outcome([string]$ChecksPassed, [string]$Forced) {
    if ($Forced -eq 'true') { return 'FORCED' }
    if ($ChecksPassed -eq 'true') { return 'MATERIALIZED' }
    return 'REFUSED'
}

$attachPreamble = "LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd', READ_ONLY);`r`n"

if ($History) {
    $sql = $attachPreamble + @"
SELECT m.materialized_at, ch.check_id, ch.kind, ch.status, ch.observed, ch.committed, ch.outcome
FROM lake.check_history ch
JOIN lake.manifest m ON m.run_id = ch.run_id
WHERE ch.contract_name = $(ConvertTo-SqlLiteral $History)
ORDER BY m.materialized_at, ch.check_id;
"@
    $result = Invoke-DuckdbBatch -Sql $sql
    if ($result.ExitCode -ne 0) {
        foreach ($l in $result.Lines) { Write-Output $l }
        exit 1
    }
    if ($result.Lines.Count -eq 0) {
        Write-Output "no history for contract: $History"
        exit 0
    }
    foreach ($line in $result.Lines) {
        $f = $line -split ',', 7
        $checkId = $f[1]
        $kind = $f[2]
        # AC11: an @assert-derived row (kind floor/invariant, and not one of the
        # five synthetic check_ids this script itself knows the harness computes
        # directly) carries no real measured value -- the harness emits only the
        # PASS/FAIL/ERROR verdict for `-- @assert` lines, never the expression's
        # own ratio/date/sum (items 3+4's Decision 1: only the verdict survives).
        $syntheticIds = @('ANCHOR', 'ROWS_FLOOR', 'TRUNCATION_ROWS_LOST', 'CONSISTENCY_VIEW_ROWS', 'FINGERPRINT')
        Write-Output "HISTORY,$History,$line"
        if (($kind -eq 'floor' -or $kind -eq 'invariant') -and ($syntheticIds -notcontains $checkId)) {
            Write-Output "NOTE,$History,$checkId has no measured observed value -- the harness emits only PASS/FAIL/ERROR for -- @assert lines, never the underlying ratio/date/sum"
        }
    }
    exit 0
}

if ($AsOf) {
    if (-not $Contract) {
        Write-Output 'ERROR: -AsOf requires -Contract'
        exit 1
    }
    $sql = $attachPreamble + @"
SELECT run_id, materialized_at, source_mtime, row_count, checks_passed, forced, lake_snapshot_id
FROM lake.manifest
WHERE contract_name = $(ConvertTo-SqlLiteral $Contract)
  AND materialized_at <= $(ConvertTo-SqlLiteral $AsOf)::TIMESTAMP
  AND (checks_passed OR forced)
ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC
LIMIT 1;
"@
    $result = Invoke-DuckdbBatch -Sql $sql
    if ($result.ExitCode -ne 0) {
        foreach ($l in $result.Lines) { Write-Output $l }
        exit 1
    }
    if ($result.Lines.Count -eq 0) {
        Write-Output "no materialization landed data for contract '$Contract' at or before $AsOf"
        exit 0
    }
    $f = $result.Lines[0] -split ',', 7
    $effRunId = $f[0]; $effMaterializedAt = $f[1]; $effSourceMtime = $f[2]; $effRowCount = $f[3]
    $effChecksPassed = $f[4]; $effForced = $f[5]; $effSnapshotId = ConvertFrom-SqlNull $f[6]
    $effOutcome = Get-Outcome $effChecksPassed $effForced

    Write-Output "ASOF,$Contract,$AsOf,effective_run_id=$effRunId,materialized_at=$effMaterializedAt,source_mtime=$effSourceMtime,rows=$effRowCount,checks_passed=$effChecksPassed,forced=$effForced,snapshot_id=$effSnapshotId,outcome=$effOutcome"

    $refusedSql = $attachPreamble + @"
SELECT 'REFUSED_AT', materialized_at FROM lake.manifest
WHERE contract_name = $(ConvertTo-SqlLiteral $Contract)
  AND materialized_at <= $(ConvertTo-SqlLiteral $AsOf)::TIMESTAMP
  AND NOT (checks_passed OR forced)
  AND materialized_at > $(ConvertTo-SqlLiteral $effMaterializedAt)::TIMESTAMP
ORDER BY materialized_at;
"@
    $refusedResult = Invoke-DuckdbBatch -Sql $refusedSql
    $refusedTimes = @($refusedResult.Lines | Where-Object { $_ -like 'REFUSED_AT,*' } | ForEach-Object { ($_ -split ',', 2)[1] })
    if ($refusedTimes.Count -gt 0) {
        Write-Output "ASOF_LATER_REFUSED,$Contract,count=$($refusedTimes.Count),times=$($refusedTimes -join ';')"
        Write-Output "NOTE,$Contract,the $($refusedTimes.Count) refused run(s) above did not change the data -- the effective state as of $AsOf is still the materialized_at=$effMaterializedAt run printed above"
    } else {
        Write-Output "NOTE,$Contract,no refused runs between materialized_at=$effMaterializedAt and $AsOf"
    }

    $historySql = $attachPreamble + @"
SELECT check_id, kind, status, observed, committed, outcome
FROM lake.check_history
WHERE run_id = $(ConvertTo-SqlLiteral $effRunId)
ORDER BY check_id;
"@
    $historyResult = Invoke-DuckdbBatch -Sql $historySql
    foreach ($l in $historyResult.Lines) { Write-Output "ASOF_CHECK,$Contract,$l" }
    exit 0
}

# --- default mode: latest manifest row per contract ---------------------------------
$sql = $attachPreamble + @"
SELECT contract_name, materialized_at, source_mtime, row_count, checks_passed, forced, lake_snapshot_id
FROM lake.manifest
QUALIFY row_number() OVER (PARTITION BY contract_name ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC) = 1
ORDER BY contract_name;
"@
$result = Invoke-DuckdbBatch -Sql $sql
if ($result.ExitCode -ne 0) {
    foreach ($l in $result.Lines) { Write-Output $l }
    exit 1
}
if ($result.Lines.Count -eq 0) {
    Write-Output 'no lake'
    exit 0
}
foreach ($line in $result.Lines) {
    $f = $line -split ',', 7
    $name = $f[0]; $materializedAt = $f[1]; $sourceMtime = $f[2]; $rowCount = $f[3]
    $checksPassed = $f[4]; $forced = $f[5]; $snapshotId = ConvertFrom-SqlNull $f[6]
    $outcome = Get-Outcome $checksPassed $forced
    Write-Output "STATUS,$name,materialized_at=$materializedAt,source_mtime=$sourceMtime,rows=$rowCount,checks_passed=$checksPassed,forced=$forced,snapshot_id=$snapshotId,outcome=$outcome"
}
exit 0
