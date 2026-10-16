<#
tests\prove-excel-csv.ps1 [-Rows 100000] [-XlsxRefresh <path to xlsx-refresh.exe>]

Proves tools\export-excel-csv.ps1 end to end in real Excel:

  1. DuckDB builds a table with one column of each type the M maps (BIGINT, INTEGER,
     DECIMAL, DOUBLE, DATE, TIMESTAMP, TIMESTAMP WITH TIME ZONE, BOOLEAN, VARCHAR) plus one
     it does not (UUID), with a NULL in every column on every 7th row.
  2. export-excel-csv.ps1 -Local writes <name>.csv, <name>.types.csv and <name>.pq.m.
  3. A hidden Excel (xlsx-refresh probe-m) runs two candidates:
       pq      the generated .pq.m exactly as written -- it must load every row
       schema  the same M, ending in one row instead: rows, rows with an error in any
               cell, and every column's Power Query TypeName
  4. The schema row is compared with the expected one. PASS or FAIL, exit 0 or 1.

-Local swaps only the SharePoint.Files source step for File.Contents; the typing that
follows is the shipped template byte for byte. The SharePoint source itself is not
exercised here (it needs a site and a sign-in).
#>
param(
    [int]$Rows = 100000,
    [string]$XlsxRefresh = 'C:\Users\woodsonp\Claude\Dev\xlsx-refresh\.venv\Scripts\xlsx-refresh.exe'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("prove-excel-csv-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$sql = @"
SELECT
    i::BIGINT                                                         AS id,
    CASE WHEN i % 7 = 0 THEN NULL ELSE (i % 1000)::INTEGER END       AS qty,
    CASE WHEN i % 7 = 0 THEN NULL ELSE 'JOB-' || (i % 5000) END       AS job,
    CASE WHEN i % 7 = 0 THEN NULL ELSE (i * 1.37)::DECIMAL(18,2) END  AS amount,
    CASE WHEN i % 7 = 0 THEN NULL ELSE i / 3.0 END::DOUBLE            AS ratio,
    CASE WHEN i % 7 = 0 THEN NULL ELSE DATE '2020-01-01' + (i % 2000)::INT END AS gl_date,
    CASE WHEN i % 7 = 0 THEN NULL ELSE TIMESTAMP '2020-01-01 08:00:00' + to_minutes(i) END AS posted_at,
    CASE WHEN i % 7 = 0 THEN NULL ELSE TIMESTAMPTZ '2020-01-01 08:00:00+00' + to_minutes(i) END AS posted_tz,
    CASE WHEN i % 7 = 0 THEN NULL ELSE i % 2 = 0 END                  AS is_even,
    CASE WHEN i % 7 = 0 THEN NULL ELSE uuid() END                     AS row_uuid
FROM range($Rows) r(i)
"@

Write-Output "== export-excel-csv.ps1 -Local"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\export-excel-csv.ps1') `
    -Source $sql -Name 'prove_types' -OutDir $work -Local
if ($LASTEXITCODE -ne 0) { Write-Output "FAIL: export exited $LASTEXITCODE"; exit 1 }

$pqPath = Join-Path $work 'prove_types.pq.m'
$pq = Get-Content -Raw -LiteralPath $pqPath
$schemaM = [regex]::Replace($pq, '(?s)\bin\s+Typed\s*$', @'
,
    Types   = Table.TransformRows(Table.Schema(Typed), each [Name] & "=" & [TypeName]),
    Summary = #table({"rows", "error_rows", "types"},
                  {{Table.RowCount(Typed), Table.RowCount(Table.SelectRowsWithErrors(Typed)), Text.Combine(Types, ", ")}})
in
    Summary
'@)
$schemaPath = Join-Path $work 'schema.m'
Set-Content -LiteralPath $schemaPath -Value $schemaM -Encoding utf8
Copy-Item -LiteralPath $pqPath -Destination (Join-Path $work 'pq.m')

Write-Output ""
Write-Output "== xlsx-refresh probe-m (hidden Excel)"
& $XlsxRefresh probe-m --m-file (Join-Path $work 'pq.m') --m-file $schemaPath --timeout 300
$probeExit = $LASTEXITCODE

$json = & $XlsxRefresh probe-m --m-file $schemaPath --timeout 300 --quiet --json | Out-String
$result = $json | ConvertFrom-Json
$row = if ($result.sample) { $result.sample[0] } else { $null }

$expectedTypes = 'id=Int64.Type, qty=Int64.Type, job=Text.Type, amount=Number.Type, ratio=Number.Type, ' +
                 'gl_date=Date.Type, posted_at=DateTime.Type, posted_tz=DateTimeZone.Type, ' +
                 'is_even=Logical.Type, row_uuid=Text.Type'

Write-Output ""
Write-Output "== result"
if (-not $row) {
    Write-Output "FAIL: could not read the schema row from probe-m --json"
    Write-Output $json
    exit 1
}
$gotRows = [int64]$row[0]; $gotErr = [int64]$row[1]; $gotTypes = [string]$row[2]
Write-Output "rows       expected=$Rows got=$gotRows"
Write-Output "error_rows expected=0 got=$gotErr"
Write-Output "types      expected=$expectedTypes"
Write-Output "           got=     $gotTypes"

$ok = ($probeExit -eq 0) -and ($gotRows -eq $Rows) -and ($gotErr -eq 0) -and ($gotTypes -eq $expectedTypes)
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($ok) { Write-Output "PASS"; exit 0 } else { Write-Output "FAIL"; exit 1 }
