<#
tools\export-excel-csv.ps1 -Source <data file | .sql file | SQL text> -OutDir <folder>
                           [-Name <stem>] [-SiteUrl <url> -FolderPath <url>] [-Local]

Writes a CSV that Excel's Power Query reads with the right column types, for a file
that lives on SharePoint. Three files land in -OutDir:

    <Name>.csv        the data (UTF-8, header row, DuckDB's ISO dates and timestamps)
    <Name>.types.csv  column_name,column_type -- DuckDB's DESCRIBE of the same table
    <Name>.pq.m       the Power Query to paste into Excel, filled from
                      skills\convert-file\excel-csv-sharepoint.m

Why CSV with a types file: Excel's Power Query has no Parquet.Document, so Parquet is
out. CSV is the fastest format it reads (500k rows: ~1.6 s, against ~6 s for xlsx and
~9 s for JSON), but CSV carries no types. The types file supplies them, so the query
never hard-codes a column list and a new column needs no query edit.

-Source is one of:
    an existing data file   anything DuckDB reads: FROM '<path>'
    an existing .sql file   its text is the query
    anything else           taken as SQL text (SELECT / FROM / WITH ...)

-SiteUrl and -FolderPath fill the M template's parameters. FolderPath is the folder's
full URL ending in "/", as SharePoint.Files shows it. Leave them off and the .pq.m keeps
{{SITE_URL}} / {{FOLDER_PATH}} placeholders to fill by hand.

-Local writes a .pq.m that reads -OutDir with File.Contents instead of SharePoint.Files.
Everything after the source step is identical; it exists so the typing can be proven in
Excel without SharePoint credentials (tests\prove-excel-csv.ps1).

The data and the types file come from one TEMP TABLE in one DuckDB process, so the CSV
header and the types file cannot disagree. Exits 1 with DuckDB's message on any failure.
#>
param(
    [Parameter(Mandatory = $true)] [string]$Source,
    [Parameter(Mandatory = $true)] [string]$OutDir,
    [string]$Name,
    [string]$SiteUrl,
    [string]$FolderPath,
    [switch]$Local
)

$ErrorActionPreference = 'Stop'

$template = Join-Path $PSScriptRoot '..\skills\convert-file\excel-csv-sharepoint.m'
if (-not (Test-Path -LiteralPath $template)) {
    Write-Output "ERROR: M template not found: $template"
    exit 1
}

# Work out what the source is. A path that exists wins over SQL text.
$isFile = $false
try { $isFile = Test-Path -LiteralPath $Source -PathType Leaf } catch { $isFile = $false }
if ($isFile -and $Source -match '\.sql$') {
    $query = (Get-Content -Raw -LiteralPath $Source).Trim()
    $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($Source)
} elseif ($isFile) {
    $full = [System.IO.Path]::GetFullPath($Source)
    $query = "FROM '" + $full.Replace("'", "''") + "'"
    $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($Source)
} else {
    $query = $Source.Trim()
    $defaultName = $null
}
$query = $query.TrimEnd(';').Trim()

if (-not $Name) { $Name = $defaultName }
if (-not $Name) {
    Write-Output "ERROR: -Name is required when -Source is SQL text"
    exit 1
}
if ($Name -match '[\\/:*?"<>|]') {
    Write-Output "ERROR: -Name must be a bare file stem, not a path: $Name"
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outFull   = [System.IO.Path]::GetFullPath($OutDir)
$csvPath   = Join-Path $outFull "$Name.csv"
$typesPath = Join-Path $outFull "$Name.types.csv"
$mPath     = Join-Path $outFull "$Name.pq.m"

function SqlStr([string]$s) { "'" + $s.Replace("'", "''") + "'" }

$sql = @"
CREATE TEMP TABLE __export AS $query;
COPY __export TO $(SqlStr $csvPath) (FORMAT csv, HEADER);
COPY (SELECT column_name, column_type FROM (DESCRIBE __export)) TO $(SqlStr $typesPath) (FORMAT csv, HEADER);
.mode json
SELECT (SELECT count(*) FROM __export) AS row_count;
SELECT column_name, column_type FROM (DESCRIBE __export);
"@

$sqlFile = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $sqlFile -Value $sql -Encoding ascii
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & duckdb -f $sqlFile 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
} finally {
    Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
}
if ($exit -ne 0) {
    Write-Output "ERROR: DuckDB failed (exit $exit):"
    $out | ForEach-Object { Write-Output "  $_" }
    exit 1
}

# Two JSON arrays come back, one per SELECT.
$text = ($out | ForEach-Object { "$_" }) -join "`n"
$arrays = [regex]::Matches($text, '(?s)\[\s*\{.*?\}\s*\]') | ForEach-Object { $_.Value | ConvertFrom-Json }
$rowCount = $arrays[0].row_count
$columns  = @($arrays[1])

# Fill the M template.
$m = Get-Content -Raw -LiteralPath $template
function MStr([string]$s) { $s.Replace('"', '""') }
$m = $m.Replace('{{NAME}}', (MStr $Name))
if ($Local) {
    $folder = $outFull.TrimEnd('\') + '\'
    $m = $m.Replace('{{SITE_URL}}', '(not used: -Local reads FolderPath with File.Contents)')
    $m = $m.Replace('{{FOLDER_PATH}}', (MStr $folder))
    $m = [regex]::Replace($m, '(?s)(// SOURCE\r?\n).*?(\s*// END SOURCE)',
        '${1}    ReadFile = (name as text) as binary => File.Contents(FolderPath & name),${2}')
} else {
    if ($SiteUrl)    { $m = $m.Replace('{{SITE_URL}}', (MStr $SiteUrl)) }
    if ($FolderPath) {
        $fp = if ($FolderPath.EndsWith('/')) { $FolderPath } else { "$FolderPath/" }
        $m = $m.Replace('{{FOLDER_PATH}}', (MStr $fp))
    }
}
Set-Content -LiteralPath $mPath -Value $m -Encoding utf8

# Which DuckDB types the M maps; anything else loads as text. Read from the template
# itself so this list cannot drift from what the query actually does.
$mapBlock = [regex]::Match((Get-Content -Raw -LiteralPath $template), '(?s)TypeMap = \[(.*?)\]').Groups[1].Value
$mapped = [regex]::Matches($mapBlock, '(?:#"([^"]+)"|([A-Z_]+))\s*=') | ForEach-Object {
    if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
}

Write-Output "rows=$rowCount columns=$($columns.Count)"
foreach ($c in $columns) {
    $base = ($c.column_type -split '\(')[0]
    $note = if ($mapped -contains $base) { '' } else { '   (not in TypeMap: loads as text)' }
    Write-Output ("  {0,-24} {1}{2}" -f $c.column_name, $c.column_type, $note)
}
Write-Output "csv=$csvPath"
Write-Output "types=$typesPath"
Write-Output "m=$mPath"
if ($m -match '\{\{(SITE_URL|FOLDER_PATH)\}\}') {
    Write-Output "NOTE: $Name.pq.m still has {{SITE_URL}} / {{FOLDER_PATH}} placeholders; pass -SiteUrl and -FolderPath or fill them by hand."
}
exit 0
