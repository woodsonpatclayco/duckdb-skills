<#
tools\make-decide-fixtures.ps1 [-Root <path>]

Regenerates the fixture tree used by TASK.md's AC4 and AC5 -- test scaffolding,
not a plan deliverable in its own right, named as a deliverable only so it is
not read as unasked-for scope.

Writes to its OWN root, .duckdb-skills\fixtures\decide -- never to the roots
tools\make-extract-fixtures.ps1 owns (ages/damaged/empty), because that script
resets those three on every run and would destroy anything hand-built there.

One directory per AC4 row, named a_fresh .. n_malformed. Row l ("directory
absent") is deliberately never created: its subdirectory is removed if present
and left absent, exactly as tools\make-extract-fixtures.ps1 treats
fixtures\absent.

Stamps come from [DateTime]::UtcNow, never Get-Date -- this machine is UTC-5,
so a locally-stamped fixture would silently rescue a naive-local
implementation. Every file is written with an explicit no-BOM UTF8 encoding,
never Set-Content -Encoding UTF8.

Every row's baseline source_rows is 100 (except the null-baseline and absent
rows), and every fixture has exactly one source object, DB.SCH.A, so a single
-CurrentRows/-CurrentLastAltered value is always positional against it.
#>
param(
    [string]$Root = '.duckdb-skills\fixtures\decide'
)

$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($Root)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$now = [DateTime]::UtcNow

function Format-Utc([DateTime]$dt) {
    return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function New-FillerFile([string]$Path, [int]$Bytes) {
    $buffer = [System.Byte[]]::new($Bytes)
    [System.IO.File]::WriteAllBytes($Path, $buffer)
}

# $Fields is the full sidecar payload, already resolved -- no defaulting here,
# every call site states every field it needs.
function New-DecideExtract {
    param(
        [string]$Name,
        [System.Collections.Specialized.OrderedDictionary]$Fields
    )
    $dir = Join-Path $resolvedRoot $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-FillerFile -Path (Join-Path $dir 'data_0_0_0.snappy.parquet') -Bytes 2048
    $json = $Fields | ConvertTo-Json -Depth 6
    Write-Utf8NoBom -Path (Join-Path $dir '_extract.json') -Text $json
}

# Baseline fields shared by every row except the malformed one (n) and the
# absent one (l, never created). $RowsBaseline is [object] so $null can be
# passed for row g's null-baseline case without PowerShell coercing it.
function New-DecideFields {
    param(
        [DateTime]$MaterializedAt,
        [object]$RowsBaseline,
        [DateTime]$LastAlteredBaseline,
        [int]$SourceBytesBaseline = 2048
    )
    return [ordered]@{
        sidecar_version     = 1
        name                = '__placeholder__'
        query               = 'SELECT * FROM DB.SCH.A'
        source_objects      = @('DB.SCH.A')
        materialized_at     = (Format-Utc $MaterializedAt)
        window_minutes      = 60
        expires_at          = (Format-Utc $MaterializedAt.AddMinutes(60))
        row_count           = 100
        output_bytes        = 2048
        connection          = 'DATAHUB'
        role                = 'ANALYST'
        database            = 'DB'
        warehouse           = 'WH_ANALYST'
        source_rows         = @($RowsBaseline)
        source_bytes        = @($SourceBytesBaseline)
        source_last_altered = @((Format-Utc $LastAlteredBaseline))
        runtime_seconds     = 0.5
    }
}

# --- reset the tree, leaving l_absent absent --------------------------------

if (Test-Path -LiteralPath $resolvedRoot) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $resolvedRoot | Out-Null

$lastAlteredSame = $now.AddDays(-1)

# a -- age 30, rows 100 (baseline only consulted if not FRESH; included for
# completeness), last_altered same, window 60 -> FRESH.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-30) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'a_fresh'
New-DecideExtract -Name 'a_fresh' -Fields $f

# b -- age 90, rows 100 baseline (current 101 supplied at call time), last_altered
# moved -> REFRESH (stale, source moved); stage 1 short-circuits.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'b_moved'
New-DecideExtract -Name 'b_moved' -Fields $f

# c -- age 90, rows 100 (current 100), last_altered same -> SKIPPED (source unchanged).
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'c_unchanged'
New-DecideExtract -Name 'c_unchanged' -Fields $f

# d -- age 90, rows 100 (current 100), last_altered moved -> SKIPPED (ambiguous ...) age=90.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'd_ambiguous'
New-DecideExtract -Name 'd_ambiguous' -Fields $f

# e -- age 1500 (past the 1440 ceiling), rows 100 (current 100), last_altered moved
# -> REFRESH (ambiguous past ceiling).
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-1500) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'e_past_ceiling'
New-DecideExtract -Name 'e_past_ceiling' -Fields $f

# f -- age 30, rows 100 (current 100), same, DSK_FORCE=1 at call time -> REFRESH (forced).
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-30) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'f_forced'
New-DecideExtract -Name 'f_forced' -Fields $f

# g -- age 90, rows baseline NULL (current 100 supplied), last_altered same ->
# stage 1 abstains, stage 2 decides -> SKIPPED (source unchanged).
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline $null -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'g_null_baseline'
New-DecideExtract -Name 'g_null_baseline' -Fields $f

# h -- age 90, rows 100 (current 100), last_altered moved, source_bytes baseline
# deliberately different from every other row -- bytes are never compared.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame -SourceBytesBaseline 999000
$f['name'] = 'h_bytes_irrelevant'
New-DecideExtract -Name 'h_bytes_irrelevant' -Fields $f

# i -- age 90, no current values supplied at call time -> STALE (probe required)
# age=90 window=60 objects=DB.SCH.A.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'i_probe'
New-DecideExtract -Name 'i_probe' -Fields $f

# j -- age -45 (future-dated, clock skew), rows 100 (current 100, irrelevant --
# clock skew short-circuits before rows are consulted) -> REFRESH (clock skew) age=-45.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(45) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'j_clock_skew'
New-DecideExtract -Name 'j_clock_skew' -Fields $f

# k -- age 90, rows 100 (current 101, moved), last_altered SAME -> REFRESH (stale,
# source moved); stage 1 short-circuits without ever consulting stage 2.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'k_short_circuit'
New-DecideExtract -Name 'k_short_circuit' -Fields $f

# l -- absent. Never created; removed if a previous run left it.
$absentDir = Join-Path $resolvedRoot 'l_absent'
if (Test-Path -LiteralPath $absentDir) {
    Remove-Item -LiteralPath $absentDir -Recurse -Force
}

# m -- age 90, rows 100 baseline (current supplied as the literal "null"),
# last_altered same -> stage 1 abstains (current side null, not baseline),
# stage 2 decides -> SKIPPED (source unchanged), never REFRESH.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'm_null_current'
New-DecideExtract -Name 'm_null_current' -Fields $f

# n -- name mismatch: the sidecar's own 'name' field does not match its directory
# name -> REFRESH (malformed sidecar: name mismatch), regardless of age.
$f = New-DecideFields -MaterializedAt $now.AddMinutes(-90) -RowsBaseline 100 -LastAlteredBaseline $lastAlteredSame
$f['name'] = 'not_the_directory_name'
New-DecideExtract -Name 'n_malformed' -Fields $f

Write-Output "decide fixtures regenerated under $resolvedRoot"
