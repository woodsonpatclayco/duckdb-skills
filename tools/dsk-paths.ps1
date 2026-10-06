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

Resolve-ExtractRoot [-Create] [-Hint] returns a (string, bool) TUPLE -- (<resolved root>, <used
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
themselves -- this function only resolves the root directory (and creates it with -Create).
#>

function Get-ProjectRootOrNull {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $gitRoot = $null
    try { $gitRoot = & git rev-parse --show-toplevel 2>$null } catch { $gitRoot = $null }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -eq 0 -and $gitRoot) {
        $root = ($gitRoot | Select-Object -First 1) -replace '/', '\'
        return [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    }
    return $null
}

function Get-ProjectRoot([string]$Hint = 'the explicit root options this tool accepts') {
    $root = Get-ProjectRootOrNull
    if (-not $root) {
        throw "ERROR: not inside a git repository: $((Get-Location).Path). Nothing was read. Run this from the project's own git folder; $Hint is only for a folder the user names."
    }
    return $root
}

function Get-ProjectId([string]$Hint = 'the explicit root options this tool accepts') {
    $full = Get-ProjectRoot -Hint $Hint
    $lower = $full.ToLowerInvariant()
    $id = ($lower -replace '[\\/]', '-') -replace ':', ''
    return $id
}

function Write-ProjectNote {
    $root = Get-ProjectRootOrNull
    if ($root) {
        $id = (($root.ToLowerInvariant() -replace '[\\/]', '-') -replace ':', '')
        [Console]::Error.WriteLine("project: $id ($root)")
    } else {
        [Console]::Error.WriteLine('project: none (explicit roots)')
    }
}

function Resolve-ExtractRoot([string]$ExplicitRoot, [switch]$Create, [string]$Hint = '-ExtractRoot') {
    if ($ExplicitRoot) {
        if (-not [System.IO.Path]::IsPathRooted($ExplicitRoot)) {
            throw '-ExtractRoot must be an absolute path'
        }
        $resolved = [System.IO.Path]::GetFullPath($ExplicitRoot)
        if ($Create -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $resolved | Out-Null
        }
        return $resolved, $false
    }
    $projectId = Get-ProjectId -Hint $Hint
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\extracts"))
    if ($Create -and -not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default, $true
}

function Resolve-LakeRoot([string]$ExplicitRoot, [switch]$Create, [string]$Hint = '-LakeRoot') {
    if ($ExplicitRoot) {
        if (-not [System.IO.Path]::IsPathRooted($ExplicitRoot)) {
            throw '-LakeRoot must be an absolute path'
        }
        $resolved = [System.IO.Path]::GetFullPath($ExplicitRoot)
        if ($Create -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $resolved | Out-Null
        }
        return $resolved, $false
    }
    $projectId = Get-ProjectId -Hint $Hint
    $default = [System.IO.Path]::GetFullPath((Join-Path $HOME ".duckdb-skills\$projectId\lake"))
    if ($Create -and -not (Test-Path -LiteralPath $default -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $default | Out-Null
    }
    return $default, $true
}