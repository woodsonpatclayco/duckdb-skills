<#
tools\publish-extract.ps1 -Name <extract> -StagingDir <path>
                          (-SidecarPath <path> | -SidecarJson <string>)
                          [-ExtractRoot <path>]

Validates a sidecar against SIDECAR.md, stamps the four fields only this
script may set, writes the sidecar into the staging directory, and publishes
it into place with a rename-aside sequence -- never Move-Item, which silently
nests staging INSIDE an existing live directory instead of replacing it
(reproduced: live Parquet keeps reading STALE, and a nested
<live>\<name>.new\ holds the fresh copy, exit 0, no warning).

Two mutually exclusive sidecar parameters, not one overloaded one, because a
JSON document on a PowerShell 5.1 command line is a quoting minefield.
-SidecarPath is the expected route; -SidecarJson exists for callers that
already have the document as a string.

The script stamps four fields itself and REJECTS them if the caller supplies
them -- a clock reading is a decision, and an agent is a poor clock:
  sidecar_version = 1
  materialized_at = [DateTime]::UtcNow, formatted yyyy-MM-ddTHH:mm:ssZ
  window_minutes  = $env:DSK_WINDOW_MINUTES, unset means 60
  expires_at      = materialized_at + window_minutes

Publish sequence (rename-aside):
  1. If <live> exists: [IO.Directory]::Move(<live>, <live>.old)
  2. [IO.Directory]::Move(<StagingDir>, <live>)
  3. Delete <live>.old
If step 2 throws, <live>.old is moved back to <live> (restoring the previous
extract), the failure is reported, and the script exits 1 -- the extract is
never left absent, and <live>.old is never left behind on the restore path.

A leftover <live>.old or <live>.new found at the START of a publish (i.e. not
the -StagingDir this call is about to consume) is evidence of an interrupted
prior publish. It is reported and the script refuses to proceed -- it is
never silently deleted.

Post-condition asserted after a successful publish: <live> contains no
subdirectory -- the check that would catch the Move-Item nesting bug if it
ever crept back in.

Exit codes: 0 success. 2 parameter/usage error (both or neither of
-SidecarPath/-SidecarJson, missing -Name/-StagingDir, a leftover .old/.new
found). 3 invalid sidecar -- refused, <live> left unchanged. 1 a publish
failure at the second move (restored from <live>.old, reported).
#>
param(
    [string]$Name,
    [string]$StagingDir,
    [string]$SidecarPath,
    [string]$SidecarJson,
    [string]$ExtractRoot
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'dsk-paths.ps1')

function Get-EffectiveWindowMinutes {
    $raw = $env:DSK_WINDOW_MINUTES
    if ([string]::IsNullOrEmpty($raw)) { return 60 }
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) { return $parsed }
    return 60
}

$requiredFields = @(
    'name', 'query', 'source_objects', 'row_count', 'output_bytes',
    'connection', 'role', 'database', 'warehouse',
    'source_rows', 'source_bytes', 'source_last_altered'
)
$stampedFields = @('sidecar_version', 'materialized_at', 'window_minutes', 'expires_at')

# --- parameter validation --------------------------------------------------

if (-not $Name) { Write-Output '-Name is required'; exit 2 }
if (-not $StagingDir) { Write-Output '-StagingDir is required'; exit 2 }
$havePath = [bool]$SidecarPath
$haveJson = [bool]$SidecarJson
if ($havePath -eq $haveJson) {
    Write-Output 'exactly one of -SidecarPath or -SidecarJson is required'
    exit 2
}

try {
    $root = (Resolve-ExtractRoot $ExtractRoot)[0]
} catch {
    Write-Output $_.Exception.Message
    exit 2
}

if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
    Write-Output "-StagingDir does not exist: $StagingDir"
    exit 2
}
$stagingFull = [System.IO.Path]::GetFullPath($StagingDir)

$live = Join-Path $root $Name
$liveOld = "$live.old"
$liveNew = "$live.new"

# --- refuse to proceed over evidence of an interrupted prior publish -------

if (Test-Path -LiteralPath $liveOld) {
    Write-Output "leftover $liveOld found -- an earlier publish was interrupted; not deleting automatically"
    exit 2
}
if ((Test-Path -LiteralPath $liveNew) -and ($liveNew -ne $stagingFull)) {
    Write-Output "leftover $liveNew found -- an earlier publish was interrupted; not deleting automatically"
    exit 2
}

# --- read and validate the sidecar -----------------------------------------

$rawJson = if ($havePath) {
    if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        Write-Output "-SidecarPath does not exist: $SidecarPath"
        exit 2
    }
    Get-Content -LiteralPath $SidecarPath -Raw
} else {
    $SidecarJson
}

try {
    $sidecar = $rawJson | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Output "invalid sidecar: not valid JSON ($($_.Exception.Message))"
    exit 3
}

$props = @{}
foreach ($p in $sidecar.PSObject.Properties) { $props[$p.Name] = $p.Value }

foreach ($f in $stampedFields) {
    if ($props.ContainsKey($f)) {
        Write-Output "invalid sidecar: '$f' is stamped by publish-extract.ps1 and must not be supplied"
        exit 3
    }
}

foreach ($f in $requiredFields) {
    if (-not $props.ContainsKey($f) -or $null -eq $props[$f]) {
        Write-Output "invalid sidecar: missing required field '$f'"
        exit 3
    }
}

if ([string]$props['name'] -ne $Name) {
    Write-Output "invalid sidecar: name '$($props['name'])' does not match target directory name '$Name'"
    exit 3
}

$sourceObjects = @($props['source_objects'])
$sourceRows = @($props['source_rows'])
$sourceBytes = @($props['source_bytes'])
$sourceLastAltered = @($props['source_last_altered'])

if ($sourceRows.Count -ne $sourceObjects.Count) {
    Write-Output "invalid sidecar: source_rows has $($sourceRows.Count) elements, source_objects has $($sourceObjects.Count)"
    exit 3
}
if ($sourceBytes.Count -ne $sourceObjects.Count) {
    Write-Output "invalid sidecar: source_bytes has $($sourceBytes.Count) elements, source_objects has $($sourceObjects.Count)"
    exit 3
}
if ($sourceLastAltered.Count -ne $sourceObjects.Count) {
    Write-Output "invalid sidecar: source_last_altered has $($sourceLastAltered.Count) elements, source_objects has $($sourceObjects.Count)"
    exit 3
}

# --- stamp the four fields this script alone controls ----------------------

$windowMinutes = Get-EffectiveWindowMinutes
$materializedAt = [DateTime]::UtcNow
$materializedAtText = $materializedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
$expiresAtText = $materializedAt.AddMinutes($windowMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ')

$ordered = [ordered]@{
    sidecar_version     = 1
    name                = $props['name']
    query               = $props['query']
    source_objects      = $sourceObjects
    materialized_at     = $materializedAtText
    window_minutes      = $windowMinutes
    expires_at          = $expiresAtText
    row_count           = $props['row_count']
    output_bytes        = $props['output_bytes']
    connection          = $props['connection']
    role                = $props['role']
    database            = $props['database']
    warehouse           = $props['warehouse']
    source_rows         = $sourceRows
    source_bytes        = $sourceBytes
    source_last_altered = $sourceLastAltered
}
if ($props.ContainsKey('runtime_seconds') -and $null -ne $props['runtime_seconds']) {
    $ordered['runtime_seconds'] = $props['runtime_seconds']
}

$finalJson = $ordered | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $stagingFull '_extract.json'), $finalJson, $utf8NoBom)

# --- publish: rename-aside, never Move-Item --------------------------------

$movedLiveAside = $false
if (Test-Path -LiteralPath $live) {
    [System.IO.Directory]::Move($live, $liveOld)
    $movedLiveAside = $true
}

try {
    [System.IO.Directory]::Move($stagingFull, $live)
} catch {
    if ($movedLiveAside) {
        [System.IO.Directory]::Move($liveOld, $live)
    }
    Write-Output "publish failed, restored previous extract: $($_.Exception.Message)"
    exit 1
}

if ($movedLiveAside) {
    Remove-Item -LiteralPath $liveOld -Recurse -Force
}

$leftoverDirs = @(Get-ChildItem -LiteralPath $live -Directory -ErrorAction SilentlyContinue)
if ($leftoverDirs.Count -gt 0) {
    Write-Output "WARNING: $live contains a subdirectory after publish -- $($leftoverDirs[0].FullName)"
}

Write-Output "published $live"
exit 0
