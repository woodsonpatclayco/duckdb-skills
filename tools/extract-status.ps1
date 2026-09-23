<#
tools\extract-status.ps1 [-Name <extract>] [-ExtractRoot <path>]

One extract's age, freshness verdict, and size. With -Name given, the first line of
output is the age in minutes and nothing else -- no header, no banner -- so a caller
can consume it directly. Without -Name, reports on every extract found under the
root, one line each.

The verdict is exactly one of FRESH, EXPIRED, UNKNOWN (<reason>). A same-line
PAST-CEILING suffix is added whenever the age exceeds $env:DSK_MAX_AGE_MINUTES
(unset means 1440) -- reported only, never acted on. The window governing FRESH vs
EXPIRED is $env:DSK_WINDOW_MINUTES (unset means 60); window_minutes and expires_at in
the sidecar are provenance only and never consulted for this decision -- see
SIDECAR.md and registry.sql for the freshness rule and the reasons this reads each
sidecar in its own `duckdb -csv -f registry.sql` invocation.

-ExtractRoot defaults to ~\.duckdb-skills\<project-id>\extracts and is created if
absent. An explicitly passed -ExtractRoot is never created.

Exit codes: 0 for any successful report, whatever the verdict -- including EXPIRED,
UNKNOWN, and zero extracts. 2 only for -Name <x> where no extract <x> exists under
the root.
#>
param(
    [string]$Name,
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
        return [System.IO.Path]::GetFullPath($ExplicitRoot)
    }
    $projectId = Get-ProjectId
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\extracts"))
    if (-not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default
}

function Get-EffectiveWindowMinutes {
    $raw = $env:DSK_WINDOW_MINUTES
    if ([string]::IsNullOrEmpty($raw)) { return 60 }
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) { return $parsed }
    return 60
}

function Get-EffectiveCeilingMinutes {
    $raw = $env:DSK_MAX_AGE_MINUTES
    if ([string]::IsNullOrEmpty($raw)) { return 1440 }
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) { return $parsed }
    return 1440
}

function ConvertFrom-DuckValue($value) {
    if ($null -eq $value -or $value -eq 'NULL' -or $value -eq '') { return $null }
    return $value
}

function Read-ExtractSidecar {
    param([string]$Dir, [string]$ExtractName)
    $sidecarPath = Join-Path $Dir '_extract.json'
    if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no sidecar'; Row = $null }
    }
    $env:DSK_EXTRACT_DIR = $Dir
    $env:DSK_EXTRACT_NAME = $ExtractName
    $csvLines = & duckdb -csv -f $registrySql 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not $csvLines -or $csvLines.Count -lt 2) {
        return [pscustomobject]@{ Ok = $false; Reason = 'unreadable sidecar'; Row = $null }
    }
    $row = ($csvLines | ConvertFrom-Csv) | Select-Object -First 1
    return [pscustomobject]@{ Ok = $true; Reason = $null; Row = $row }
}

function Get-DirectoryBytes([string]$Dir) {
    $files = Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    return ($files | Measure-Object -Sum Length).Sum
}

# Returns @{ AgeText = <string for line 1>; Verdict = <string>; SizeBytes = <int> }
function Get-ExtractStatus {
    param([string]$Dir, [string]$ExtractName, [int]$Window, [int]$Ceiling)

    $sidecar = Read-ExtractSidecar -Dir $Dir -ExtractName $ExtractName
    $sizeBytes = Get-DirectoryBytes -Dir $Dir

    if (-not $sidecar.Ok) {
        return [pscustomobject]@{ AgeText = ''; Verdict = "UNKNOWN ($($sidecar.Reason))"; SizeBytes = $sizeBytes }
    }

    $row = $sidecar.Row
    $reason = ConvertFrom-DuckValue $row.reason
    if ($reason) {
        return [pscustomobject]@{ AgeText = ''; Verdict = "UNKNOWN ($reason)"; SizeBytes = $sizeBytes }
    }

    $ageRaw = ConvertFrom-DuckValue $row.age_minutes
    if ($null -eq $ageRaw) {
        return [pscustomobject]@{ AgeText = ''; Verdict = 'UNKNOWN'; SizeBytes = $sizeBytes }
    }

    $age = [double]$ageRaw
    if ($age -lt 0) {
        return [pscustomobject]@{ AgeText = [string]$ageRaw; Verdict = 'UNKNOWN (clock skew)'; SizeBytes = $sizeBytes }
    }

    $stale = $age -gt $Window
    $pastCeiling = $age -gt $Ceiling
    $verdict = if ($stale) { 'EXPIRED' } else { 'FRESH' }
    if ($pastCeiling) { $verdict = "$verdict PAST-CEILING" }

    return [pscustomobject]@{ AgeText = [string]$ageRaw; Verdict = $verdict; SizeBytes = $sizeBytes }
}

# --- main ---------------------------------------------------------------

$resolvedRoot = Resolve-ExtractRoot $ExtractRoot
$window = Get-EffectiveWindowMinutes
$ceiling = Get-EffectiveCeilingMinutes

if ($Name) {
    $extractDir = Join-Path $resolvedRoot $Name
    if (-not (Test-Path -LiteralPath $extractDir -PathType Container)) {
        Write-Output "extract $Name not found under $resolvedRoot"
        exit 2
    }
    $status = Get-ExtractStatus -Dir $extractDir -ExtractName $Name -Window $window -Ceiling $ceiling
    Write-Output $status.AgeText
    Write-Output "window: $window"
    Write-Output "verdict: $($status.Verdict)"
    Write-Output "size: $($status.SizeBytes) bytes"
    exit 0
}

# No -Name: report on every extract under the root.
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    Write-Output "no extracts registered under $resolvedRoot"
    exit 0
}
$dirs = Get-ChildItem -LiteralPath $resolvedRoot -Directory -ErrorAction SilentlyContinue
if (-not $dirs -or $dirs.Count -eq 0) {
    Write-Output "no extracts registered under $resolvedRoot"
    exit 0
}
Write-Output "window: $window"
foreach ($dir in $dirs) {
    $status = Get-ExtractStatus -Dir $dir.FullName -ExtractName $dir.Name -Window $window -Ceiling $ceiling
    $ageText = if ($status.AgeText -ne '') { $status.AgeText } else { '-' }
    Write-Output "name=$($dir.Name) age_minutes=$ageText verdict=$($status.Verdict) size_bytes=$($status.SizeBytes)"
}
exit 0
