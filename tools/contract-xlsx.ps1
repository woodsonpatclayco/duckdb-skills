<#
tools\contract-xlsx.ps1

Shared by tools\check-contract.ps1, tools\run-assertions.ps1 and tools\materialize.ps1
(PLAN-6 item 2). Dot-source with `. (Join-Path $PSScriptRoot 'contract-xlsx.ps1')`.

1. $ContractDirectiveKeywords -- the ONE list of known `-- @<keyword>` directives. Both
   unknown-directive guards read it, so adding a keyword is a one-line edit here instead
   of two edits that can drift apart.

2. The by-name workbook reads. A contract that says `-- @table: X` / `-- @name: X`, or
   calls read_xlsx_table( / read_xlsx_name(, needs the SQL macros that
   tools\xlsx_meta.py generates from the workbook on every run. Contracts that do neither
   never touch Python or the generator, so they run exactly as before.

Sets no $ErrorActionPreference and no Set-StrictMode at file scope -- both would leak
into every dot-sourcing caller.
#>

$ContractDirectiveKeywords = @(
    'sheet', 'table', 'name',
    'fingerprint', 'anchor', 'rows_floor',
    'assert', 'snapshot', 'snapshot_committed'
)

$XlsxMetaPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'xlsx_meta.py'))

# Every workbook path a contract reads, in order of appearance, from its own
# read_xlsx( / read_xlsx_table( / read_xlsx_name( calls. The first one is "the" workbook
# for freshness and the truncation reads, as it was when only read_xlsx( existed.
function Get-ContractWorkbookPaths([string]$RawText) {
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($RawText, "read_xlsx(?:_table|_name)?\(\s*'([^']+)'", 'IgnoreCase')) {
        $p = $m.Groups[1].Value
        if (-not ($seen | Where-Object { $_ -eq $p })) { $seen.Add($p) }
    }
    , $seen.ToArray()
}

function Test-ContractNeedsXlsxMacros([string]$RawText) {
    return ($RawText -match '(?m)^\s*--\s*@(table|name)\s*:') -or
           ($RawText -match '(?i)read_xlsx_(table|name)\(')
}

# Runs `py -3.12 xlsx_meta.py macros <workbooks...> -o <OutFile>`. Returns $null on
# success, else the generator's own error text (it names the workbook it could not read).
function New-XlsxMacrosFile([string[]]$WorkbookPaths, [string]$OutFile) {
    $winPaths = @($WorkbookPaths | ForEach-Object { $_ -replace '/', '\' })
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & py -3.12 $XlsxMetaPath macros @winPaths -o $OutFile 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        $text = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
        return "tools/xlsx_meta.py macros failed (exit $code): $text"
    }
    return $null
}
