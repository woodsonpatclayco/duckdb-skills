<#
tools\make-ac16-fixture.ps1 [-Path <path>]

Builds a minimal .xlsx-shaped zip whose xl/workbook.xml declares exactly one sheet
named "Q1 Sales (draft)" -- for TASK.md AC16, exercising tools\list-sheets.ps1's
filename-refusal rule against a sheet name that fails ^[A-Za-z0-9_]+$ (a space and
parentheses). Test scaffolding, not a plan deliverable in its own right.

-Path defaults to $env:TEMP\dsk-ac16-fixture.xlsx, per TASK.md AC16's instruction to
build the fixture "in $env:TEMP". Idempotent: deletes any existing file at -Path first,
then writes a fresh one, so reruns never fail on "file already exists".

Writes only to -Path, never to the pinned workbook or anywhere in the repo. The single
xl/workbook.xml entry is written with an explicit no-BOM UTF8 encoding
(System.Text.UTF8Encoding($false)), matching the rest of this repo's convention for
avoiding a BOM that later tooling would choke on.
#>
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

if (-not $Path) {
    $Path = Join-Path $env:TEMP 'dsk-ac16-fixture.xlsx'
}
$resolvedPath = [System.IO.Path]::GetFullPath($Path)

if (Test-Path -LiteralPath $resolvedPath) {
    Remove-Item -LiteralPath $resolvedPath -Force
}

$workbookXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Q1 Sales (draft)" sheetId="1" r:id="rId1"/></sheets></workbook>'

$zip = [System.IO.Compression.ZipFile]::Open($resolvedPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $zip.CreateEntry('xl/workbook.xml')
    $stream = $entry.Open()
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        try {
            $writer.Write($workbookXml)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
} finally {
    $zip.Dispose()
}

Write-Output $resolvedPath
exit 0
