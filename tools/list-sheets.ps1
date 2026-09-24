<#
tools\list-sheets.ps1 <absolute-workbook-path>

Lists every sheet in an .xlsx/.xlsm workbook by reading xl/workbook.xml directly out of
the zip container via System.IO.Compression.ZipFile.OpenRead -- never via Excel (never
launched), never via read_xlsx (which has no sheet-listing function), and never opened
for write. The zip handle is opened read-only and disposed in a finally block; no byte
is ever written back to the workbook.

Emits, per sheet, in workbook.xml's own <sheets> document order (Excel's tab order):
    position=<1-based> name=<sheet name> contract_filename=<contracts\<name>.sql | REFUSED (...)>
then a trailing line:
    total_sheets=<n>

Sheet names are used verbatim in the suggested filename only when they match
^[A-Za-z0-9_]+$. Excel's own tab-name character set is far looser (spaces, parentheses,
punctuation), and mangling one of those into a filename would produce a name that does
not round-trip back to the sheet it came from -- so any other name is reported with
contract_filename=REFUSED (...) rather than silently guessed at.

The suggested filename is derived from the SHEET name, not the workbook name, so the
convention survives a workbook path carrying spaces and multiple dots (the pinned
workbook is "Data Extracts.xlsm", inside a folder containing a literal comma).

A missing file, or a zip with no xl/workbook.xml entry, exits non-zero and the error
message names the exact path it was given -- there are ~30 similarly-named
"Data Extracts*.xlsm" files on this machine (TASK.md), so a silent failure risks
reporting a clean run against the wrong file. Never falls back to another file.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$WorkbookPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) {
    Write-Output "ERROR: workbook not found: $WorkbookPath"
    exit 1
}

$fullPath = [System.IO.Path]::GetFullPath($WorkbookPath)

$zip = $null
$xmlText = $null
try {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($fullPath)
    } catch {
        Write-Output "ERROR: could not open as a zip archive: $fullPath ($($_.Exception.Message))"
        exit 1
    }

    $entry = $zip.GetEntry('xl/workbook.xml')
    if (-not $entry) {
        Write-Output "ERROR: no xl/workbook.xml entry found in zip: $fullPath"
        exit 1
    }

    $stream = $entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $xmlText = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
} finally {
    if ($zip) { $zip.Dispose() }
}

[xml]$xml = $xmlText
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$nsMgr.AddNamespace('main', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$sheetNodes = $xml.SelectNodes('/main:workbook/main:sheets/main:sheet', $nsMgr)

if (-not $sheetNodes -or $sheetNodes.Count -eq 0) {
    Write-Output "ERROR: xl/workbook.xml has no <sheet> entries: $fullPath"
    exit 1
}

$validNamePattern = '^[A-Za-z0-9_]+$'
$position = 0
foreach ($node in $sheetNodes) {
    $position++
    $nameAttr = $node.Attributes['name']
    $name = if ($nameAttr) { $nameAttr.Value } else { '' }
    if ($name -match $validNamePattern) {
        $suggestion = "contracts\$name.sql"
    } else {
        $suggestion = 'REFUSED (sheet name does not match ^[A-Za-z0-9_]+$)'
    }
    Write-Output "position=$position name=$name contract_filename=$suggestion"
}

Write-Output "total_sheets=$position"
exit 0
