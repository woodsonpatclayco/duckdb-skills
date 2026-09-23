<#
tools\make-extract-fixtures.ps1 [-Root <path>]

Regenerates the fixture tree used by every acceptance check in the item-2a TASK.md.
Test scaffolding, not a plan deliverable in its own right -- named as a deliverable
only so it is not read as unasked-for scope.

Deletes and recreates <Root>\ages, <Root>\damaged, and <Root>\empty every run, so it
is idempotent. Deletes <Root>\absent if present and never recreates it -- AC2 needs
that path to stay absent across reruns, and an explicitly passed -ExtractRoot is
never created by the read tools either.

Stamps come from [DateTime]::UtcNow, never Get-Date. This is load-bearing: this
machine is UTC-5, so a locally-stamped fixture would let a broken naive-local
implementation report a clean 0/90/1500 and pass AC3 while being wrong against every
real sidecar -- see SIDECAR.md and registry.sql for the UTC trap this exists to catch.

Every JSON and filler file is written with an explicit no-BOM UTF8 encoding, never
Set-Content -Encoding UTF8 (which emits a UTF-8 BOM).
#>
param(
    [string]$Root = '.duckdb-skills\fixtures'
)

$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($Root)
$agesRoot = Join-Path $resolvedRoot 'ages'
$damagedRoot = Join-Path $resolvedRoot 'damaged'
$emptyRoot = Join-Path $resolvedRoot 'empty'
$absentRoot = Join-Path $resolvedRoot 'absent'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$now = [DateTime]::UtcNow

function Reset-Directory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Remove-IfPresent([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

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

# Builds one extract directory. $Fields is the full sidecar payload (already
# resolved -- no defaulting here, every call site states every field it needs so
# the fixture set stays legible from this file alone.
function New-Extract {
    param(
        [string]$RootDir,
        [string]$Name,
        [System.Collections.Specialized.OrderedDictionary]$Fields,
        [int]$FillerBytes = 2048,
        [string]$FillerName = 'data_0_0_0.snappy.parquet'
    )
    $dir = Join-Path $RootDir $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($FillerBytes -gt 0) {
        New-FillerFile -Path (Join-Path $dir $FillerName) -Bytes $FillerBytes
    }
    $json = $Fields | ConvertTo-Json -Depth 6
    Write-Utf8NoBom -Path (Join-Path $dir '_extract.json') -Text $json
    return $dir
}

function New-DefaultFields([string]$Name, [DateTime]$MaterializedAt, [int]$WindowMinutes, [DateTime]$ExpiresAt, [int]$RowCount, [int]$OutputBytes) {
    return [ordered]@{
        sidecar_version     = 1
        name                = $Name
        query               = "SELECT * FROM $Name"
        source_objects      = @("DB.SCH.$($Name.ToUpperInvariant())")
        materialized_at     = (Format-Utc $MaterializedAt)
        window_minutes      = $WindowMinutes
        expires_at          = (Format-Utc $ExpiresAt)
        row_count           = $RowCount
        output_bytes        = $OutputBytes
        connection          = 'DATAHUB'
        role                = 'ANALYST'
        database            = 'DB'
        warehouse           = 'WH_ANALYST'
        source_rows         = @($RowCount)
        source_bytes        = @($OutputBytes)
        source_last_altered = @((Format-Utc $MaterializedAt.AddDays(-1)))
        runtime_seconds     = 0.5
    }
}

# --- reset the tree -------------------------------------------------------

Reset-Directory $agesRoot
Reset-Directory $damagedRoot
Reset-Directory $emptyRoot
Remove-IfPresent $absentRoot

# --- fixtures\ages ---------------------------------------------------------
# AC3/AC4/AC5: three clean ages, stamped now / -90 min / -1500 min.

New-Extract -RootDir $agesRoot -Name 'now' `
    -Fields (New-DefaultFields -Name 'now' -MaterializedAt $now -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 10 -OutputBytes 2048) `
    -FillerBytes 2048 | Out-Null

New-Extract -RootDir $agesRoot -Name 'minus90' `
    -Fields (New-DefaultFields -Name 'minus90' -MaterializedAt $now.AddMinutes(-90) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 20 -OutputBytes 2048) `
    -FillerBytes 2048 | Out-Null

New-Extract -RootDir $agesRoot -Name 'minus1500' `
    -Fields (New-DefaultFields -Name 'minus1500' -MaterializedAt $now.AddMinutes(-1500) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 30 -OutputBytes 2048) `
    -FillerBytes 2048 | Out-Null

# AC6: two fixtures both aged 90 minutes, whose window_minutes/expires_at would
# invert the verdict if a wrong implementation consulted them instead of the
# reader's $env:DSK_WINDOW_MINUTES.

$ac6a = New-DefaultFields -Name 'ac6_far_window' -MaterializedAt $now.AddMinutes(-90) -WindowMinutes 1440 -ExpiresAt $now.AddYears(1) -RowCount 40 -OutputBytes 2048
New-Extract -RootDir $agesRoot -Name 'ac6_far_window' -Fields $ac6a -FillerBytes 2048 | Out-Null

$ac6b = New-DefaultFields -Name 'ac6_short_window' -MaterializedAt $now.AddMinutes(-90) -WindowMinutes 30 -ExpiresAt $now.AddYears(-1) -RowCount 50 -OutputBytes 2048
New-Extract -RootDir $agesRoot -Name 'ac6_short_window' -Fields $ac6b -FillerBytes 2048 | Out-Null

# AC8/AC9: the two pinned row counts from a real extract cycle, so 2b's real
# output is directly comparable. parent_projects' filler is exactly 380,104
# bytes and its output_bytes agrees, for AC9's AGREES case. It is also the
# "complete fixture" AC12 point 1 describes -- every field present.

$parentProjects = New-DefaultFields -Name 'parent_projects' -MaterializedAt $now.AddMinutes(-90) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 15314 -OutputBytes 380104
$parentProjects['query'] = 'SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS'
$parentProjects['source_objects'] = @('DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS')
$parentProjects['source_rows'] = @(15314)
$parentProjects['source_bytes'] = @(1037312)
$parentProjects['runtime_seconds'] = 0.32
New-Extract -RootDir $agesRoot -Name 'parent_projects' -Fields $parentProjects -FillerBytes 380104 | Out-Null

# dt_projects omits runtime_seconds -- AC12 point 2's "fixture omitting runtime_seconds".
$dtProjects = New-DefaultFields -Name 'dt_projects' -MaterializedAt $now.AddMinutes(-45) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 42161 -OutputBytes 500000
$dtProjects['query'] = 'SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS'
$dtProjects['source_objects'] = @('DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS')
$dtProjects['source_rows'] = @(42161)
$dtProjects['source_bytes'] = @(7430144)
$dtProjects.Remove('runtime_seconds')
New-Extract -RootDir $agesRoot -Name 'dt_projects' -Fields $dtProjects -FillerBytes 500000 | Out-Null

# AC9's DISAGREES case: a filler the same size as parent_projects' (380,104 bytes)
# but a sidecar that declares a different output_bytes.
$sizeMismatch = New-DefaultFields -Name 'size_mismatch' -MaterializedAt $now.AddMinutes(-10) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 1 -OutputBytes 999999
New-Extract -RootDir $agesRoot -Name 'size_mismatch' -Fields $sizeMismatch -FillerBytes 380104 | Out-Null

# --- fixtures\damaged -------------------------------------------------------
# Six damaged cases plus two healthy ones, so the healthy two prove a damaged
# neighbour never brings the listing down. (The task text's directory count for
# this root is inconsistent with its own six numbered cases -- see RESULT-1.md.)

# 1. .parquet files, no _extract.json.
$noSidecarDir = Join-Path $damagedRoot 'no_sidecar'
New-Item -ItemType Directory -Force -Path $noSidecarDir | Out-Null
New-FillerFile -Path (Join-Path $noSidecarDir 'data_0_0_0.snappy.parquet') -Bytes 2048

# 2. _extract.json that is not valid JSON.
$badJsonDir = Join-Path $damagedRoot 'bad_json'
New-Item -ItemType Directory -Force -Path $badJsonDir | Out-Null
New-FillerFile -Path (Join-Path $badJsonDir 'data_0_0_0.snappy.parquet') -Bytes 2048
Write-Utf8NoBom -Path (Join-Path $badJsonDir '_extract.json') -Text '{not valid json'

# 3. valid JSON, materialized_at missing entirely.
$missingMat = New-DefaultFields -Name 'missing_materialized_at' -MaterializedAt $now.AddMinutes(-15) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 5 -OutputBytes 2048
$missingMat.Remove('materialized_at')
New-Extract -RootDir $damagedRoot -Name 'missing_materialized_at' -Fields $missingMat -FillerBytes 2048 | Out-Null

# 4. source_rows has fewer elements than source_objects.
$arrayMismatch = New-DefaultFields -Name 'array_mismatch' -MaterializedAt $now.AddMinutes(-15) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 5 -OutputBytes 2048
$arrayMismatch['source_objects'] = @('DB.SCH.A', 'DB.SCH.B')
$arrayMismatch['source_rows'] = @(5)
$arrayMismatch['source_bytes'] = @(2048, 2048)
$arrayMismatch['source_last_altered'] = @((Format-Utc $now.AddDays(-1)), (Format-Utc $now.AddDays(-1)))
New-Extract -RootDir $damagedRoot -Name 'array_mismatch' -Fields $arrayMismatch -FillerBytes 2048 | Out-Null

# 5. materialized_at unparseable -- a different failure path from case 3: this one
# hard-fails the pinned TIMESTAMP read (exit 1), case 3 reads through as NULL (exit 0).
$unparseable = New-DefaultFields -Name 'unparseable_timestamp' -MaterializedAt $now.AddMinutes(-15) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 5 -OutputBytes 2048
$unparseable['materialized_at'] = 'yesterday'
New-Extract -RootDir $damagedRoot -Name 'unparseable_timestamp' -Fields $unparseable -FillerBytes 2048 | Out-Null

# 6. name does not match its directory name.
$nameMismatch = New-DefaultFields -Name 'name_mismatch' -MaterializedAt $now.AddMinutes(-15) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 5 -OutputBytes 2048
$nameMismatch['name'] = 'not_the_directory_name'
New-Extract -RootDir $damagedRoot -Name 'name_mismatch' -Fields $nameMismatch -FillerBytes 2048 | Out-Null

# Two healthy neighbours, to prove the damaged six don't break their listing.
$healthyA = New-DefaultFields -Name 'healthy_a' -MaterializedAt $now.AddMinutes(-10) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 7 -OutputBytes 2048
New-Extract -RootDir $damagedRoot -Name 'healthy_a' -Fields $healthyA -FillerBytes 2048 | Out-Null

$healthyB = New-DefaultFields -Name 'healthy_b' -MaterializedAt $now.AddMinutes(-500) -WindowMinutes 60 -ExpiresAt $now.AddMinutes(60) -RowCount 9 -OutputBytes 2048
New-Extract -RootDir $damagedRoot -Name 'healthy_b' -Fields $healthyB -FillerBytes 2048 | Out-Null

# --- fixtures\empty ---------------------------------------------------------
# Already created empty by Reset-Directory above -- an existing root with zero
# extracts is an ordinary outcome (AC2), distinct from fixtures\absent which
# does not exist at all.

Write-Output "fixtures regenerated under $resolvedRoot"
