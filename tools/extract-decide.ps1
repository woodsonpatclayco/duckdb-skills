<#
tools\extract-decide.ps1 -Name <extract> [-ExtractRoot <path>]
                         [-CurrentRows <string[]>] [-CurrentLastAltered <string[]>]

Decides FRESH / REFRESH / SKIPPED / STALE (probe required) for one extract and
prints exactly one verdict line. Never pulls, writes, or mutates anything --
this script decides an action; publish-extract.ps1 and the Snowflake calls in
skills/snowflake-extract/SKILL.md carry it out.

The two-call protocol, which is what makes checking free: call once with no
-CurrentRows/-CurrentLastAltered. If the age is inside the window the answer is
FRESH and Snowflake is never touched. Only when the answer is
"STALE (probe required) age=<n> window=<w> objects=<comma-separated>" does the
caller need to probe Snowflake -- for exactly the objects printed, in that
order -- and call again supplying -CurrentRows and/or -CurrentLastAltered
positionally against that same object list.

-CurrentRows takes STRINGS, not [int[]]: [int[]] would coerce $null to 0, and
SIDECAR.md requires null (no metadata row count available) never to read as 0
(the table emptied). The literal token "null" (case-insensitive) means no
count was available for that object; anything else must parse as [long] or the
call is a usage error, exit 2.

Verdicts (exactly one printed, exit 0 for every one of them):
  FRESH
  STALE (probe required) age=<n> window=<w> objects=<comma-separated>
  REFRESH (stale, source moved)
  SKIPPED (source unchanged)
  SKIPPED (ambiguous: last_altered moved, rows unchanged) age=<n>
  REFRESH (ambiguous past ceiling)
  REFRESH (clock skew) age=<n>
  REFRESH (forced)
  REFRESH (no sidecar)
  REFRESH (unreadable sidecar)
  REFRESH (malformed sidecar: <reason>)

Exit 2 is reserved for parameter/usage errors only (a -CurrentRows element that
is neither "null" nor parseable as an integer, or an array whose length does
not match source_objects). Exit 0 covers every verdict above, including an
absent extract directory -- unlike extract-status.ps1, which *reports state*
and exits 2 for a missing -Name, this script *decides an action*, and "not
there yet" has a perfectly good action (REFRESH (no sidecar)).

DSK_FORCE must be exactly the string "1" to force a refresh; any other value,
"0" included, is not forced. DSK_WINDOW_MINUTES (unset means 60) is the
freshness window; DSK_MAX_AGE_MINUTES (unset means 1440) bounds the ambiguous
branch only -- an unchanged last_altered is never bounded, since it means
genuinely unaltered.
#>
param(
    [string]$Name,
    [string]$ExtractRoot,
    [string[]]$CurrentRows,
    [string[]]$CurrentLastAltered
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$registrySql = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..\skills\snowflake-extract\registry.sql'))
. (Join-Path $scriptRoot 'dsk-paths.ps1')

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

# Parses a UTC ISO-8601-ish timestamp string to the second. Returns $null if it
# will not parse -- callers treat a $null as an abstention, never as "moved".
function ConvertTo-UtcSecond([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $dto = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dto)) {
        return [DateTimeOffset]::new($dto.Year, $dto.Month, $dto.Day, $dto.Hour, $dto.Minute, $dto.Second, [TimeSpan]::Zero)
    }
    return $null
}

# Stage 1: any comparable pair that differs makes the whole stage say "moved".
# If nothing is comparable (every pair has a $null on either side), the stage
# abstains and stage 2 decides. Never touches bytes -- there is no bytes
# parameter at all.
function Test-RowsStage {
    param([object[]]$Baseline, [string[]]$Current)
    $sawComparable = $false
    $moved = $false
    for ($i = 0; $i -lt $Baseline.Count; $i++) {
        $b = $Baseline[$i]
        $cRaw = $Current[$i]
        if ($null -eq $cRaw -or $cRaw.ToLowerInvariant() -eq 'null') { continue }
        if ($null -eq $b) { continue }
        $sawComparable = $true
        if ([long]$b -ne [long]$cRaw) { $moved = $true }
    }
    if ($moved) { return 'moved' }
    if ($sawComparable) { return 'unchanged' }
    return 'abstain'
}

# Stage 2: parses both sides as UTC timestamps and compares to the second --
# never string equality (CONVERT_TIMEZONE renders differently from the
# sidecar's own yyyy-MM-ddTHH:mm:ssZ, so a string compare would make
# "unchanged" permanently unreachable).
function Test-LastAlteredStage {
    param([object[]]$Baseline, [string[]]$Current)
    $sawComparable = $false
    $moved = $false
    for ($i = 0; $i -lt $Baseline.Count; $i++) {
        $b = ConvertTo-UtcSecond ([string]$Baseline[$i])
        $c = ConvertTo-UtcSecond $Current[$i]
        if ($null -eq $b -or $null -eq $c) { continue }
        $sawComparable = $true
        if ($b -ne $c) { $moved = $true }
    }
    if ($moved) { return 'moved' }
    if ($sawComparable) { return 'unchanged' }
    return 'abstain'
}

# --- parameter validation -------------------------------------------------

if (-not $Name) {
    Write-Output '-Name is required'
    exit 2
}

try {
    $root = (Resolve-ExtractRoot $ExtractRoot)[0]
} catch {
    Write-Output $_.Exception.Message
    exit 2
}

$window = Get-EffectiveWindowMinutes
$ceiling = Get-EffectiveCeilingMinutes
$forced = ($env:DSK_FORCE -ceq '1')

$extractDir = Join-Path $root $Name
$sidecarPath = Join-Path $extractDir '_extract.json'

if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    Write-Output 'REFRESH (no sidecar)'
    exit 0
}

# --- read the sidecar via registry.sql, the only reader of _extract.json ---

$env:DSK_EXTRACT_DIR = $extractDir
$env:DSK_EXTRACT_NAME = $Name
$csvLines = & duckdb -csv -f $registrySql 2>$null
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0 -or -not $csvLines -or $csvLines.Count -lt 2) {
    Write-Output 'REFRESH (unreadable sidecar)'
    exit 0
}
$row = (($csvLines -join "`n") | ConvertFrom-Csv) | Select-Object -First 1

$reason = ConvertFrom-DuckValue $row.reason
if ($reason) {
    Write-Output "REFRESH (malformed sidecar: $reason)"
    exit 0
}

$ageRaw = ConvertFrom-DuckValue $row.age_minutes
if ($null -eq $ageRaw) {
    Write-Output 'REFRESH (unreadable sidecar)'
    exit 0
}
$age = [double]$ageRaw
$ageInt = [int][Math]::Round($age)

if ($forced) {
    Write-Output 'REFRESH (forced)'
    exit 0
}

if ($age -lt 0) {
    Write-Output "REFRESH (clock skew) age=$ageInt"
    exit 0
}

if ($age -le $window) {
    Write-Output 'FRESH'
    exit 0
}

# --- past the window: two-stage invalidation ------------------------------

$sourceObjectsRaw = ConvertFrom-DuckValue $row.source_objects
$sourceObjectsList = @()
if ($sourceObjectsRaw) { $sourceObjectsList = $sourceObjectsRaw | ConvertFrom-Json }

if (-not $PSBoundParameters.ContainsKey('CurrentRows')) {
    $objectsJoined = ($sourceObjectsList -join ',')
    Write-Output "STALE (probe required) age=$ageInt window=$window objects=$objectsJoined"
    exit 0
}

if ($CurrentRows.Count -ne $sourceObjectsList.Count) {
    Write-Output "expected $($sourceObjectsList.Count) values for $($sourceObjectsList.Count) source objects, got $($CurrentRows.Count)"
    exit 2
}
foreach ($v in $CurrentRows) {
    if ($v.ToLowerInvariant() -eq 'null') { continue }
    $parsed = [long]0
    if (-not [long]::TryParse($v, [ref]$parsed)) {
        Write-Output "invalid -CurrentRows value '$v': expected an integer or the literal 'null'"
        exit 2
    }
}

if ($PSBoundParameters.ContainsKey('CurrentLastAltered') -and $CurrentLastAltered.Count -ne $sourceObjectsList.Count) {
    Write-Output "expected $($sourceObjectsList.Count) values for $($sourceObjectsList.Count) source objects, got $($CurrentLastAltered.Count)"
    exit 2
}

$baselineRowsRaw = ConvertFrom-DuckValue $row.source_rows
$baselineRows = @()
if ($baselineRowsRaw) { $baselineRows = $baselineRowsRaw | ConvertFrom-Json }

$baselineLastAlteredRaw = ConvertFrom-DuckValue $row.source_last_altered
$baselineLastAltered = @()
if ($baselineLastAlteredRaw) { $baselineLastAltered = $baselineLastAlteredRaw | ConvertFrom-Json }

$stage1 = Test-RowsStage -Baseline $baselineRows -Current $CurrentRows

if ($stage1 -eq 'moved') {
    Write-Output 'REFRESH (stale, source moved)'
    exit 0
}

# Stage 1 said "unchanged" or "abstain" -- stage 2 decides either way.
$currentLastAltered = if ($PSBoundParameters.ContainsKey('CurrentLastAltered')) { $CurrentLastAltered } else { [object[]]::new($sourceObjectsList.Count) }
$stage2 = Test-LastAlteredStage -Baseline $baselineLastAltered -Current $currentLastAltered

if ($stage2 -eq 'moved') {
    if ($age -gt $ceiling) {
        Write-Output 'REFRESH (ambiguous past ceiling)'
    } else {
        Write-Output "SKIPPED (ambiguous: last_altered moved, rows unchanged) age=$ageInt"
    }
    exit 0
}

Write-Output 'SKIPPED (source unchanged)'
exit 0
