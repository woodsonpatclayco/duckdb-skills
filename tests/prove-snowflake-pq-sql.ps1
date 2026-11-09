<#
tests\prove-snowflake-pq-sql.ps1 [-Query <Snowflake query file>] [-Table job_milestone]
                                 [-ProjectColumn PROJECT_NUMBER] [-Projects 10002556,10005145]
                                 [-NoExcel] [-XlsxRefresh <path to xlsx-refresh.exe>]

Proves tools\snowflake_pq_sql.py on a real lake table, by default Schedule-Data's job_milestone
(its query is read, never changed; nothing is written to SharePoint):

  1. write builds <table>.snowflake.sql in a temp folder; its header and its end are printed.
     A second write prints "unchanged".
  2. write refuses a two-statement query (exit 2).
  3. check runs the file in Snowflake as written, runs the source query, and runs the file with
     the PROJECT FILTER line switched on as its comment says. Both comparisons must be SAME.
  4. A hidden Excel runs the file's exact text through Odbc.Query("dsn=Snowflake"), as written
     and with the filter on. Its row counts must equal step 3's. -NoExcel skips this step.

PASS or FAIL, exit 0 or 1.
#>
param(
    [string]$Query = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Schedule-Data\queries\job_milestone.sql'),
    [string]$Table = 'job_milestone',
    [string]$ProjectColumn = 'PROJECT_NUMBER',
    [string]$Projects = '10002556,10005145',
    [switch]$NoExcel,
    [string]$XlsxRefresh = 'C:\Users\woodsonp\Claude\Dev\xlsx-refresh\.venv\Scripts\xlsx-refresh.exe'
)

# Continue, not Stop: on PowerShell 5.1 a native command's stderr line would end the script.
# Every native call's exit code is checked instead.
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$tool = Join-Path $repo 'tools\snowflake_pq_sql.py'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("prove-snowflake-pq-sql-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fails = @()

Write-Output "== 1. write from $Query"
& py -3.12 $tool write --query $Query --table $Table --dest $work --project-column $ProjectColumn
if ($LASTEXITCODE -ne 0) { Write-Output "FAIL: write exited $LASTEXITCODE"; exit 1 }
$file = Join-Path $work "$Table.snowflake.sql"
$lines = Get-Content -LiteralPath $file
$lines | Select-Object -First 14
Write-Output "   ... ($($lines.Count) lines) ..."
$lines | Select-Object -Last 4
$again = & py -3.12 $tool write --query $Query --table $Table --dest $work --project-column $ProjectColumn
Write-Output "second write: $again"
if ($again -notlike 'unchanged *') { $fails += 'second write rewrote the file' }

Write-Output ""
Write-Output "== 2. write refuses a two-statement query"
$two = Join-Path $work 'two.sql'
Set-Content -Encoding ascii -LiteralPath $two -Value "SELECT 1 AS a;`nSELECT 2 AS b;"
& py -3.12 $tool write --query $two --table two --dest $work 2>&1 |
    ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
$code = $LASTEXITCODE
Write-Output "exit=$code"
if ($code -ne 2) { $fails += "two-statement query: exit $code, expected 2" }

Write-Output ""
Write-Output "== 3. check in Snowflake (file as written, source query, filter on for $Projects)"
$check = & py -3.12 $tool check --file $file --query $Query --projects $Projects 2>$null
$check | ForEach-Object { if ($_ -like 'columns:*' -and $_.Length -gt 120) { $_.Substring(0, 117) + '...' } else { $_ } }
if ($LASTEXITCODE -ne 0) { $fails += "check exited $LASTEXITCODE" }
$fullRows = [int]([regex]::Match(($check -join "`n"), 'as written: (\d+) rows').Groups[1].Value)
$filterRows = [int]([regex]::Match(($check -join "`n"), 'filter on: (\d+) rows').Groups[1].Value)

if (-not $NoExcel) {
    Write-Output ""
    Write-Output "== 4. Excel Power Query runs the file's text through ODBC dsn=Snowflake"
    $list = ($Projects -split ',' | ForEach-Object { "'" + $_.Trim() + "'" }) -join ', '
    $mFile = $file.Replace('"', '""')
    $read = "Text.FromBinary(File.Contents(""$mFile""), TextEncoding.Utf8)"
    $off = "/* WHERE lake_table.$ProjectColumn IN ('<project>', '<project>') */"
    $on = "WHERE lake_table.$ProjectColumn IN ($list)"
    Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'as_written.m') -Value @"
let
    Source = Odbc.Query("dsn=Snowflake", $read),
    Count  = #table({"rows", "columns"}, {{Table.RowCount(Source), Table.ColumnCount(Source)}})
in
    Count
"@
    Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'filter_on.m') -Value @"
let
    Sql    = Text.Replace($read, "$off", "$on"),
    Source = Odbc.Query("dsn=Snowflake", Sql),
    Count  = #table({"rows", "projects"}, {{Table.RowCount(Source), Text.Combine(List.Sort(List.Distinct(Source[$ProjectColumn])), ", ")}})
in
    Count
"@
    $probe = & $XlsxRefresh probe-m --m-file (Join-Path $work 'as_written.m') --m-file (Join-Path $work 'filter_on.m') --timeout 300 2>$null
    $probe | ForEach-Object { $_ }
    $text = $probe -join "`n"
    $xlFull = [regex]::Match($text, '(?s)as_written.*?\[(\d+)(?:\.0)?, (\d+)(?:\.0)?\]')
    $xlFilter = [regex]::Match($text, "(?s)filter_on.*?\[(\d+)(?:\.0)?, '([^']*)'\]")
    if (-not $xlFull.Success -or [int]$xlFull.Groups[1].Value -ne $fullRows) {
        $fails += "Excel as written: expected $fullRows rows" }
    if (-not $xlFilter.Success -or [int]$xlFilter.Groups[1].Value -ne $filterRows) {
        $fails += "Excel filter on: expected $filterRows rows" }
    Write-Output "Excel rows as written: $($xlFull.Groups[1].Value) (Snowflake check: $fullRows); filter on: $($xlFilter.Groups[1].Value) (check: $filterRows), projects $($xlFilter.Groups[2].Value)"
}

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Output ""
if ($fails.Count -eq 0) { Write-Output "RESULT: PASS"; exit 0 }
$fails | ForEach-Object { Write-Output "FAIL: $_" }
Write-Output "RESULT: FAIL"
exit 1
