<#
Idempotently delivers skills/query/duckdb-compat.sql into a session's state.sql
via a ".read" line, never a second -init file. See skills/query/duckdb-compat.md.
#>
param(
    [string]$StateFile
)

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $root = $null
    try {
        $root = & git rev-parse --show-toplevel 2>$null
    } catch {
        $root = $null
    }
    if ($LASTEXITCODE -eq 0 -and $root) {
        return ($root -replace '/', '\')
    }
    return (Get-Location).Path
}

if ($StateFile) {
    $resolvedStateFile = [System.IO.Path]::GetFullPath($StateFile)
} else {
    $repoRoot = Get-RepoRoot
    $resolvedStateFile = Join-Path (Join-Path $repoRoot '.duckdb-skills') 'state.sql'
    $resolvedStateFile = [System.IO.Path]::GetFullPath($resolvedStateFile)
}

$parentDir = Split-Path -Parent $resolvedStateFile
if (-not (Test-Path -LiteralPath $parentDir)) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
}

# First output line: the resolved absolute state-file path, always.
Write-Output $resolvedStateFile

# Informational note about home-side state files. Never changes exit code.
$homeDuckdbSkills = Join-Path $HOME '.duckdb-skills'
if (Test-Path -LiteralPath $homeDuckdbSkills) {
    $homeStateFiles = Get-ChildItem -LiteralPath $homeDuckdbSkills -Recurse -Filter 'state.sql' -File -ErrorAction SilentlyContinue
    if ($homeStateFiles) {
        $paths = ($homeStateFiles | ForEach-Object { $_.FullName }) -join ', '
        Write-Output "NOTE: home-side state files exist: $paths. If this session uses one, re-run with -StateFile."
    }
}

# Resolve the compat macro file relative to this script, forward slashes required by .read.
$compatFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
$compatFileFwd = $compatFile -replace '\\', '/'
$readLine = ".read $compatFileFwd"

function Normalize-Line([string]$line) {
    return ($line.Trim() -replace '\\', '/').ToLowerInvariant()
}

# Read existing content, stripping a leading UTF-8 BOM if present. Never write one back.
$existingText = ''
if (Test-Path -LiteralPath $resolvedStateFile) {
    $bytes = [System.IO.File]::ReadAllBytes($resolvedStateFile)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $existingText = [System.Text.Encoding]::UTF8.GetString($bytes)
}

$existingLines = @()
if ($existingText -ne '') {
    $existingLines = $existingText -split "\r\n|\n"
}

$targetNormalized = Normalize-Line $readLine
$alreadyPresent = $false
foreach ($line in $existingLines) {
    if ($line -match '^\s*\.read\s') {
        if ((Normalize-Line $line) -eq $targetNormalized) {
            $alreadyPresent = $true
            break
        }
    }
}

if ($alreadyPresent) {
    $newText = $existingText
} else {
    $newText = "$readLine`r`n$existingText"
}

[System.IO.File]::WriteAllText($resolvedStateFile, $newText)
