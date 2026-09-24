<#
tools\list-extracts.ps1 [-ExtractRoot <path>]

Every local Snowflake extract under -ExtractRoot, newest first, with its age, row
count, and on-disk size -- plus a size-report total. A view over the sidecars, not a
second copy: nothing here is cached, so a deleted extract directory is gone from the
very next run.

Enumeration is Get-ChildItem -Directory, and each extract's _extract.json is read in
a separate `duckdb -csv -f registry.sql` invocation -- never a single glob over every
sidecar, which lets one malformed sidecar take the whole listing down. A directory
with no _extract.json is reported UNKNOWN (no sidecar) without invoking duckdb at
all; a non-zero exit from registry.sql is reported UNKNOWN (unreadable sidecar).

-ExtractRoot defaults to ~\.duckdb-skills\<project-id>\extracts. The default root is
created if it does not exist; an explicitly passed -ExtractRoot is never created --
it is a fixture or verification path, and creating it would make the absent-root
check in AC2 unrepeatable across reruns.

Window is $env:DSK_WINDOW_MINUTES (unset means 60); ceiling is $env:DSK_MAX_AGE_MINUTES
(unset means 1440) -- see registry.sql for the freshness rule these feed. This tool
itself never uses them for a verdict: the pinned registry columns have no FRESH/
EXPIRED column, only age_minutes. See extract-status.ps1 for the per-extract verdict.

Zero extracts is an ordinary outcome: prints "no extracts registered under <root>"
and exits 0, whether the root is merely empty or does not exist at all.
#>
param(
    [string]$ExtractRoot
)

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$registrySql = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..\skills\snowflake-extract\registry.sql'))

function Get-ProjectId {
    $gitRoot = $null
    try { $gitRoot = & git rev-parse --show-toplevel 2>$null } catch { $gitRoot = $null }
    if ($LASTEXITCODE -eq 0 -and $gitRoot) {
        $root = ($gitRoot | Select-Object -First 1) -replace '/', '\'
    } else {
        $root = (Get-Location).Path
    }
    $full = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $lower = $full.ToLowerInvariant()
    $id = ($lower -replace '[\\/]', '-') -replace ':', ''
    return $id
}

function Resolve-ExtractRoot([string]$ExplicitRoot) {
    if ($ExplicitRoot) {
        return [System.IO.Path]::GetFullPath($ExplicitRoot), $false
    }
    $projectId = Get-ProjectId
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\extracts"))
    if (-not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default, $true
}

function Read-ExtractSidecar {
    param([string]$Dir, [string]$Name)
    $sidecarPath = Join-Path $Dir '_extract.json'
    if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
        return [pscustomobject]@{ Name = $Name; Ok = $false; Reason = 'no sidecar'; Row = $null }
    }
    $env:DSK_EXTRACT_DIR = $Dir
    $env:DSK_EXTRACT_NAME = $Name
    $csvLines = & duckdb -csv -f $registrySql 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not $csvLines -or $csvLines.Count -lt 2) {
        return [pscustomobject]@{ Name = $Name; Ok = $false; Reason = 'unreadable sidecar'; Row = $null }
    }
    $row = ($csvLines | ConvertFrom-Csv) | Select-Object -First 1
    return [pscustomobject]@{ Name = $Name; Ok = $true; Reason = $null; Row = $row }
}

function ConvertFrom-DuckValue($value) {
    if ($null -eq $value -or $value -eq 'NULL' -or $value -eq '') { return $null }
    return $value
}

function Get-DirectoryBytes([string]$Dir, [string]$Filter) {
    $files = if ($Filter) {
        Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue
    }
    if (-not $files) { return 0 }
    return ($files | Measure-Object -Sum Length).Sum
}

# --- resolve root, guard the zero-extracts case -----------------------------

$resolvedRoot, $usingDefault = Resolve-ExtractRoot $ExtractRoot

if ($usingDefault) {
    Write-Output "project-id: $(Get-ProjectId)"
    Write-Output "extract root: $resolvedRoot"
}

if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    Write-Output "no extracts registered under $resolvedRoot"
    exit 0
}

$dirs = Get-ChildItem -LiteralPath $resolvedRoot -Directory -ErrorAction SilentlyContinue
if (-not $dirs -or $dirs.Count -eq 0) {
    Write-Output "no extracts registered under $resolvedRoot"
    exit 0
}

# --- read every extract ------------------------------------------------------

$results = @()
foreach ($dir in $dirs) {
    $sidecar = Read-ExtractSidecar -Dir $dir.FullName -Name $dir.Name
    $sizeBytes = Get-DirectoryBytes -Dir $dir.FullName
    $parquetBytes = Get-DirectoryBytes -Dir $dir.FullName -Filter '*.parquet'

    $ageMinutes = $null
    $rowCount = $null
    $outputBytes = $null
    $reasonText = $sidecar.Reason

    if ($sidecar.Ok) {
        $row = $sidecar.Row
        $rowReason = ConvertFrom-DuckValue $row.reason
        if ($rowReason) { $reasonText = $rowReason }
        $ageRaw = ConvertFrom-DuckValue $row.age_minutes
        if ($null -ne $ageRaw) { $ageMinutes = [double]$ageRaw }
        $rowCountRaw = ConvertFrom-DuckValue $row.row_count
        if ($null -ne $rowCountRaw) { $rowCount = [int64]$rowCountRaw }
        $outputBytesRaw = ConvertFrom-DuckValue $row.output_bytes
        if ($null -ne $outputBytesRaw) { $outputBytes = [int64]$outputBytesRaw }
    }

    $bytesCheck = 'n/a'
    if ($null -ne $outputBytes) {
        if ($outputBytes -eq $parquetBytes) {
            $bytesCheck = 'AGREES'
        } else {
            $bytesCheck = "DISAGREES (declared $outputBytes, on disk $parquetBytes)"
        }
    }

    $results += [pscustomobject]@{
        Name        = $dir.Name
        AgeMinutes  = $ageMinutes
        Reason      = $reasonText
        RowCount    = $rowCount
        SizeBytes   = $sizeBytes
        BytesCheck  = $bytesCheck
    }
}

# A structural reason (name mismatch, parallel array mismatch, no/unreadable
# sidecar) always wins over a numeric age -- SIDECAR.md: "No sidecar, malformed
# sidecar, or NULL age = UNKNOWN, never FRESH." A sidecar can compute a perfectly
# valid age and still be UNKNOWN.
foreach ($r in $results) {
    $r | Add-Member -NotePropertyName IsUnknown -NotePropertyValue ([bool]$r.Reason -or $null -eq $r.AgeMinutes)
    $ageText = if ($r.Reason) {
        "UNKNOWN ($($r.Reason))"
    } elseif ($null -ne $r.AgeMinutes) {
        [string]$r.AgeMinutes
    } else {
        'UNKNOWN'
    }
    $r | Add-Member -NotePropertyName AgeText -NotePropertyValue $ageText
}

# Newest first: valid ages ascending, then damaged/unknown entries last by name.
$ordered = $results | Sort-Object -Property `
    @{ Expression = { if ($_.IsUnknown) { 1 } else { 0 } } }, `
    @{ Expression = { if ($_.IsUnknown) { 0 } else { $_.AgeMinutes } } }, `
    @{ Expression = { $_.Name } }

$total = 0
foreach ($r in $ordered) {
    $rowCountText = if ($null -ne $r.RowCount) { [string]$r.RowCount } else { 'NULL' }
    Write-Output "name=$($r.Name) age_minutes=$($r.AgeText) row_count=$rowCountText size_bytes=$($r.SizeBytes) bytes_check=$($r.BytesCheck)"
    $total += $r.SizeBytes
}
Write-Output "total_size_bytes=$total"
exit 0
