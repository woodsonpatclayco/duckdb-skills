<#
tools\dsk-paths.ps1

The single copy of <project-id> and extract-root resolution, shared by
tools\list-extracts.ps1, tools\extract-status.ps1, tools\extract-decide.ps1 and
tools\publish-extract.ps1. Dot-source with
`. (Join-Path $PSScriptRoot 'dsk-paths.ps1')` -- never a relative `. .\dsk-paths.ps1`,
because PowerShell's `cd` does not update .NET's Environment.CurrentDirectory,
which [System.IO.Path]::GetFullPath() resolves a relative path against.

Sets no $ErrorActionPreference and no Set-StrictMode at file scope -- both would
leak into every dot-sourcing caller.

Get-ProjectId: git rev-parse --show-toplevel if inside a work tree, else the
current directory; resolved to a full path; lowercased; trailing separator
removed; then every \ and / replaced by - and every : deleted.

Resolve-ExtractRoot returns a (string, bool) TUPLE -- (<resolved root>, <used
default>). extract-status.ps1's original copy returned a bare string;
list-extracts.ps1's returned the tuple, whose bool gates the "project-id:" /
"extract root:" header lines 2a's AC1 asserts. This shared version keeps the
tuple form; extract-status.ps1 takes element [0] and discards the flag.

A relative -ExtractRoot is rejected with "-ExtractRoot must be an absolute
path". [System.IO.Path]::GetFullPath() resolves against .NET's
CurrentDirectory, which PowerShell's `cd` does not keep in sync -- this bit a
verifier mid-run in item 2a. Rejecting relative paths outright is the fix;
callers must pass absolute paths (e.g. via (Resolve-Path ...).Path or a
$PWD-based Join-Path).

Resolve-LakeRoot (item 6): same shape and same relative-path rejection as
Resolve-ExtractRoot, for tools\materialize.ps1 and tools\lake-status.ps1. The
default root is ~\.duckdb-skills\<project-id>\lake -- a sibling of
extracts\ under the same per-project home directory, never inside the git
repo itself (the repo's own .duckdb-skills\ stays reserved for
ensure-duckdb-compat.ps1's state.sql). Returns a (string, bool) tuple: the
resolved lake root directory, and whether the default was used. Callers derive
the catalog file as "$root\lake.ducklake" and DATA_PATH as "$root\data"
themselves -- this function only resolves and creates the root directory.
#>

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
        if (-not [System.IO.Path]::IsPathRooted($ExplicitRoot)) {
            throw '-ExtractRoot must be an absolute path'
        }
        return [System.IO.Path]::GetFullPath($ExplicitRoot), $false
    }
    $projectId = Get-ProjectId
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\extracts"))
    if (-not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default, $true
}

function Resolve-LakeRoot([string]$ExplicitRoot) {
    if ($ExplicitRoot) {
        if (-not [System.IO.Path]::IsPathRooted($ExplicitRoot)) {
            throw '-LakeRoot must be an absolute path'
        }
        $resolved = [System.IO.Path]::GetFullPath($ExplicitRoot)
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $resolved | Out-Null
        }
        return $resolved, $false
    }
    $projectId = Get-ProjectId
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\lake"))
    if (-not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default, $true
}
