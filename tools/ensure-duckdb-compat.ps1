<#
Idempotently delivers skills/query/duckdb-compat.sql into a session's state.sql
via a ".read" line, never a second -init file. See skills/query/duckdb-compat.md.

The line is `.read '<forward-slash absolute path>'` (single-quoted: DuckDB rejects an
unquoted path containing spaces). It REPLACES any earlier compat line (quoted or
legacy unquoted, any plugin install folder) rather than adding a second one, so a
plugin update that moves the install folder leaves exactly one line. Every other
line in the file is left untouched and in order.

With the default project state file (no -StateFile), it also makes sure
.duckdb-skills/ is git-ignored in the project, appending it to .gitignore if not
(LF only, no BOM) and printing "NOTE: added ...".
#>
param(
    [string]$StateFile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsk-paths.ps1')

# Project resolution (item 1): the shared resolver; no current-folder fallback.
# Outside a git repo -StateFile is required (refusal: exit 2, nothing created).
try {
    if ($StateFile) {
        $null = Get-ProjectRootOrNull
        $repoRoot = $null
    } else {
        $repoRoot = Get-ProjectRoot -Hint '-StateFile'
    }
} catch {
    Write-Output $_.Exception.Message
    exit 2
}
Write-ProjectNote

if ($StateFile) {
    $resolvedStateFile = [System.IO.Path]::GetFullPath($StateFile)
} else {
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
$readLine = ".read '$compatFileFwd'"

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

# Drop every earlier compat .read line (any path, quoted or not), keep all else in order.
function Get-ReadArg([string]$line) {
    $arg = ($line.Trim() -replace '^\.read\s+', '').Trim()
    if ($arg.Length -ge 2 -and (($arg[0] -eq "'" -and $arg[-1] -eq "'") -or ($arg[0] -eq '"' -and $arg[-1] -eq '"'))) {
        $arg = $arg.Substring(1, $arg.Length - 2)
    }
    return ($arg -replace '\\', '/').ToLowerInvariant()
}

$keptLines = @()
foreach ($line in $existingLines) {
    if ($line -match '^\s*\.read\s' -and (Get-ReadArg $line).EndsWith('/skills/query/duckdb-compat.sql')) {
        continue
    }
    $keptLines += $line
}

if ($keptLines.Count -gt 0) {
    $newText = "$readLine`r`n" + ($keptLines -join "`r`n")
} else {
    $newText = "$readLine`r`n"
}
[System.IO.File]::WriteAllText($resolvedStateFile, $newText)

# Keep .duckdb-skills/ out of the project's git (default state file only).
if (-not $StateFile) {
    & git -C $repoRoot check-ignore -q $resolvedStateFile 2>$null
    if ($LASTEXITCODE -eq 1) {
        $gi = Join-Path $repoRoot '.gitignore'
        $prefix = ''
        if (Test-Path -LiteralPath $gi) {
            $giBytes = [System.IO.File]::ReadAllBytes($gi)
            if ($giBytes.Length -gt 0 -and $giBytes[$giBytes.Length - 1] -ne 0x0A) { $prefix = "`n" }
        }
        [System.IO.File]::AppendAllText($gi, $prefix + ".duckdb-skills/`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "NOTE: added .duckdb-skills/ to $gi"
    }
}