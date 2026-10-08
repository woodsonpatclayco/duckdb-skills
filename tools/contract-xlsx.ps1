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

$FormulaCheckKeywords = @('formula_consistent', 'formula_errors_max', 'formula_fingerprint')
$ContractDirectiveKeywords = @(
    'sheet', 'table', 'name',
    'fingerprint', 'anchor', 'rows_floor',
    'assert', 'snapshot', 'snapshot_committed'
) + $FormulaCheckKeywords

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
           ($RawText -match '(?i)read_xlsx_(table|name)\(') -or
           (Test-ContractNeedsFormulas $RawText)
}

# The formula view (PLAN-6 item 3) streams every sheet of the workbook, so it is built only
# when a contract uses it: a formula check directive, an @assert over xlsx_formulas, or a
# read_xlsx_formulas( call.
function Test-ContractNeedsFormulas([string]$RawText) {
    return ($RawText -match '(?m)^\s*--\s*@formula_(consistent|errors_max|fingerprint)\b') -or
           ($RawText -match '(?im)^\s*--\s*@assert\b.*\bxlsx_formulas\b') -or
           ($RawText -match '(?i)read_xlsx_formulas\(')
}

# Runs `py -3.12 xlsx_meta.py macros <workbooks...> -o <OutFile> [--formulas]`. Returns $null
# on success, else the generator's own error text (it names the workbook it could not read).
function New-XlsxMacrosFile([string[]]$WorkbookPaths, [string]$OutFile, [switch]$Formulas) {
    $winPaths = @($WorkbookPaths | ForEach-Object { $_ -replace '/', '\' })
    $extra = @(); if ($Formulas) { $extra = @('--formulas') }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & py -3.12 $XlsxMetaPath macros @winPaths -o $OutFile @extra 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        $text = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
        return "tools/xlsx_meta.py macros failed (exit $code): $text"
    }
    return $null
}

# ---------------------------------------------------------------------------------------
# Formula checks (PLAN-6 item 4), evaluated by run-assertions.ps1 against the xlsx_formulas
# view. Each one becomes an ASSERT,<name>,PASS|FAIL,<detail> line, so materialize.ps1 files
# it in check history as an invariant with no new parsing. Every detail names a sample cell
# and shows its A1 formula beside the R1C1 form.
#
#   -- @formula_consistent <name>: <Tbl>[<Col>]
#   -- @formula_errors_max <name>: <scope> <= <n>
#   -- @formula_fingerprint <name>: <scope> == <R1C1 text>
#
# <scope>: *  |  Sheet!  'Sheet name'!  |  Tbl  |  Tbl[Col]  |  Sheet!A1  |  a one-cell name.
# The value is split at the FIRST ' <= ' / ' == ' (spaces required): ':' already ends the
# name, and R1C1 text itself contains ':'.
# ---------------------------------------------------------------------------------------

function Format-SqlString([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function ConvertFrom-FormulaScope([string]$Scope) {
    $s = $Scope.Trim()
    $q = '''((?:[^'']|'''')+)'''           # 'quoted sheet name', '' inside
    $u = '([^''!\[\]]+)'                  # unquoted sheet name
    $cell = '\$?([A-Za-z]{1,3})\$?(\d+)'
    $id = '[A-Za-z_\\][A-Za-z0-9_.\\]*'
    if ($s -eq '*') { return @{ Kind = 'all' } }
    $m = [regex]::Match($s, "^(?:$q|$u)!$")
    if ($m.Success) {
        $sheet = if ($m.Groups[1].Success) { $m.Groups[1].Value -replace "''", "'" } else { $m.Groups[2].Value }
        return @{ Kind = 'sheet'; Sheet = $sheet }
    }
    $m = [regex]::Match($s, "^(?:$q|$u)!$cell$")
    if ($m.Success) {
        $sheet = if ($m.Groups[1].Success) { $m.Groups[1].Value -replace "''", "'" } else { $m.Groups[2].Value }
        return @{ Kind = 'cell'; Sheet = $sheet; Cell = ($m.Groups[3].Value.ToUpper() + $m.Groups[4].Value) }
    }
    $m = [regex]::Match($s, "^($id)\[([^\[\]]+)\]$")
    if ($m.Success) { return @{ Kind = 'column'; Table = $m.Groups[1].Value; Column = $m.Groups[2].Value } }
    if ($s -match "^$id$") { return @{ Kind = 'bare'; Name = $s } }
    return $null
}

# Returns @{ Error = <text> } for a malformed directive value, else @{ Sql = <one query that
# prints a status,detail CSV row> }. A scope naming a sheet, table, column or named range that
# does not exist makes the query itself fail with a DuckDB error naming it -- never zero rows.
function Get-FormulaCheckSql([string]$Keyword, [string]$Value, [string]$WorkbookPath) {
    $wb = Format-SqlString ($WorkbookPath -replace '\\', '/')
    $scopeText = $Value; $limit = $null; $expected = $null
    if ($Keyword -eq 'formula_errors_max') {
        $i = $Value.IndexOf(' <= ')
        if ($i -lt 0) { return @{ Error = "@formula_errors_max needs '<scope> <= <n>' (spaces around <=): $Value" } }
        $scopeText = $Value.Substring(0, $i)
        $n = 0
        if (-not [int]::TryParse($Value.Substring($i + 4).Trim(), [ref]$n) -or $n -lt 0) {
            return @{ Error = "@formula_errors_max limit is not a whole number >= 0: $($Value.Substring($i + 4).Trim())" }
        }
        $limit = $n
    } elseif ($Keyword -eq 'formula_fingerprint') {
        $i = $Value.IndexOf(' == ')
        if ($i -lt 0) { return @{ Error = "@formula_fingerprint needs '<scope> == <R1C1 formula>' (spaces around ==): $Value" } }
        $scopeText = $Value.Substring(0, $i)
        $expected = $Value.Substring($i + 4).Trim() -replace '^=', ''
        if (-not $expected) { return @{ Error = "@formula_fingerprint has no committed R1C1 formula after ' == '" } }
    }
    $sc = ConvertFrom-FormulaScope $scopeText
    if (-not $sc) { return @{ Error = "not a formula-check scope: '$scopeText' (use *, Sheet!, Tbl, Tbl[Col], Sheet!A1, or a one-cell name)" } }
    if ($Keyword -eq 'formula_consistent' -and $sc.Kind -ne 'column') {
        return @{ Error = "@formula_consistent scope must be a table column, Tbl[Col]: '$scopeText'" }
    }
    if ($Keyword -eq 'formula_fingerprint' -and $sc.Kind -notin @('column', 'cell', 'bare')) {
        return @{ Error = "@formula_fingerprint scope must be a table column Tbl[Col] or one cell: '$scopeText'" }
    }

    $pred = "workbook_key = xlsx__norm($wb)"
    $valid = 'true'
    switch ($sc.Kind) {
        'sheet' {
            $S = Format-SqlString $sc.Sheet
            $pred += " AND lower(sheet) = lower($S)"; $valid = "xlsx__has_sheet($wb, $S)"
        }
        'cell' {
            $S = Format-SqlString $sc.Sheet
            $pred += " AND lower(sheet) = lower($S) AND cell = '$($sc.Cell)'"; $valid = "xlsx__has_sheet($wb, $S)"
        }
        'column' {
            $T = Format-SqlString $sc.Table; $C = Format-SqlString $sc.Column
            $pred += " AND lower(table_name) = lower($T) AND lower(table_column) = lower($C)"
            $valid = "CASE WHEN list_contains(xlsx_table_columns($wb, $T), lower($C)) THEN true " +
                     "ELSE error('no column ' || $C || ' in table ' || $T) END"
        }
        'bare' {
            $X = Format-SqlString $sc.Name
            $asName = "lower(sheet) = lower(xlsx_name_sheet($wb, $X)) AND cell = xlsx__one_cell($X, xlsx_name_range($wb, $X))"
            $pred += " AND CASE WHEN xlsx__is_table($wb, $X) THEN lower(table_name) = lower($X) ELSE ($asName) END"
            $tableOk = if ($Keyword -eq 'formula_fingerprint') {
                "error('@formula_fingerprint scope ' || $X || ' is a whole table; name a column, ' || $X || '[Col], or one cell')"
            } else { 'true' }
            $valid = "CASE WHEN xlsx__is_table($wb, $X) THEN $tableOk ELSE xlsx__one_cell($X, xlsx_name_range($wb, $X)) IS NOT NULL END"
        }
    }

    $forms = "SELECT formula_r1c1, count(*) AS n, min_by(cell, row) AS sample, min_by(formula_a1, row) AS sample_a1 FROM c WHERE kind <> 'none' GROUP BY 1"
    switch ($Keyword) {
        'formula_consistent' {
            $sql = @"
WITH c AS (SELECT * FROM xlsx_formulas WHERE $pred),
f AS ($forms),
b AS (SELECT cell, row, coalesce(cached_value, '') AS v FROM c WHERE kind = 'none'),
s AS (SELECT (SELECT count(*) FROM c) AS nrows, (SELECT count(*) FROM f) AS nforms,
             (SELECT count(*) FROM b WHERE v <> '') AS ntyped, (SELECT count(*) FROM b WHERE v = '') AS nblank)
SELECT CASE WHEN nforms = 1 AND ntyped + nblank = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
  'rows ' || nrows || ', formulas ' || nforms || ', typed values ' || ntyped || ', blanks ' || nblank
  || CASE WHEN nforms = 0 THEN ' -- no formula in this column' ELSE '' END
  || CASE WHEN nforms = 1 THEN ' -- ' || (SELECT any_value(sample || ' =' || sample_a1 || ' [' || formula_r1c1 || ']') FROM f) ELSE '' END
  || CASE WHEN nforms > 1 THEN ' -- formulas: ' || (SELECT string_agg(n || ' like ' || sample || ' =' || sample_a1 || ' [' || formula_r1c1 || ']', '; ' ORDER BY n DESC, sample)
                                                     FROM (SELECT * FROM f ORDER BY n DESC, sample LIMIT 4)) ELSE '' END
  || CASE WHEN ntyped + nblank > 0 THEN ' -- not a formula: ' || (SELECT string_agg(cell || CASE WHEN v = '' THEN ' (blank)' ELSE ' (' || v || ')' END, ', ' ORDER BY row)
                                                                  FROM (SELECT * FROM b ORDER BY row LIMIT 5)) ELSE '' END AS detail
FROM s WHERE $valid;
"@
        }
        'formula_errors_max' {
            $sql = @"
WITH c AS (SELECT * FROM xlsx_formulas WHERE $pred AND coalesce(error, '') <> ''),
s AS (SELECT count(*) AS n, count(*) FILTER (WHERE kind <> 'none') AS nf, count(*) FILTER (WHERE kind = 'none') AS nv FROM c)
SELECT CASE WHEN n <= $limit THEN 'PASS' ELSE 'FAIL' END AS status,
  'errors ' || n || ' (max $limit)'
  || CASE WHEN n > 0 THEN ': ' || (SELECT string_agg(error || ' ' || k, ', ' ORDER BY k DESC, error) FROM (SELECT error, count(*) AS k FROM c GROUP BY 1))
                          || '; in formulas ' || nf || ', plain values ' || nv ELSE '' END
  || CASE WHEN n > $limit THEN ' -- first by position: ' || (SELECT string_agg(sheet || '!' || cell || ' ' || error || CASE WHEN kind <> 'none' THEN ' =' || formula_a1 ELSE '' END, ', ' ORDER BY sheet, row, col)
                                               FROM (SELECT * FROM c ORDER BY sheet, row, col LIMIT 5)) ELSE '' END AS detail
FROM s WHERE $valid;
"@
        }
        'formula_fingerprint' {
            $E = Format-SqlString $expected
            $sql = @"
WITH c AS (SELECT * FROM xlsx_formulas WHERE $pred),
f AS ($forms),
s AS (SELECT count(*) AS nforms, any_value(formula_r1c1) AS r1c1, any_value(sample) AS sample, any_value(sample_a1) AS a1 FROM f)
SELECT CASE WHEN nforms = 1 AND r1c1 = $E THEN 'PASS' ELSE 'FAIL' END AS status,
  CASE WHEN nforms = 0 THEN 'no formula in scope'
       WHEN nforms > 1 THEN nforms || ' different formulas in scope -- @formula_consistent lists them'
       WHEN r1c1 = $E THEN 'unchanged: ' || sample || ' =' || a1 || ' [' || r1c1 || ']'
       ELSE 'CHANGED: ' || sample || ' is now =' || a1 || ' [' || r1c1 || '], committed [' || $E || ']' END AS detail
FROM s WHERE $valid;
"@
        }
    }
    return @{ Sql = $sql }
}
