<#
tests\prove-xlsx-arrays.ps1 [-Baseline <commit>]

0.6.3 proof: two gaps in the formula view (tools\xlsx_meta.py, read_xlsx_formulas).
  - Spill placeholders: Excel writes an empty <f ca="1"/> into every spilled child cell of a
    VOLATILE dynamic array. The code at -Baseline listed each one as a formula (kind normal,
    empty formula text). Now a placeholder is read as a non-formula cell: dropped unless it
    shows an error (then kind none, with the error) or sits in a table column that has formulas
    (then kind none, with its cached value) -- exactly as any typed value. Shared dependents
    (<f t="shared" si="0"/>), data tables and array masters are empty too and stay formulas.
  - array_ref: a new last column, an array formula's ref rectangle exactly as stored (legacy CSE
    and dynamic arrays; "A1" for a one-cell array), empty on every other row.

The code at -Baseline is extracted from git into %TEMP% (never checked out over this folder).

  1. Fixture (tests\make-array-fixture.py, in %TEMP%): the old code lists the seven placeholders
     as formulas with no text; the new view equals the expected file row for row; every row that
     differs between old and new is a placeholder; shared dependents keep their translated
     formula; array_ref is exactly as stored on each array master and empty elsewhere. Two
     placeholders (Arrays!D5, Tab!C9) have the shape Project Profit stores, t="str" with an
     empty <v/>; tests\recount-formulas.py agrees with the new view kind by kind.
  2. Project Profit 26-10 October (a %TEMP% copy of risk-reserve's .dq copy -- never the live
     file, and nothing is written in risk-reserve). risk-reserve's tools\check-pp.ps1 replaces
     that .dq copy from the live, co-authored file on every run, so no expected number here is
     fixed: each is taken from the same %TEMP% copy at run time, by code that shares nothing
     with tools\xlsx_meta.py. Formula rows old vs new (new must equal tests\recount-formulas.py's
     regex count over the raw XML, kind by kind), the same every-difference-is-a-placeholder
     check, placeholders outside every array rectangle, multi-cell array masters, array_ref of
     '10002556'!I128 against the <c> stored in the sheet XML (tests\raw-cell.py), the same for
     the 2026-11-05 I128 incident planted into a copy by risk-reserve's tests\plant_cycles.py,
     and risk-reserve's Project Profit contract: no row its formula checks read differs old vs
     new (that contract is not run here). Old and new extraction are timed.
  3. Regression: every contract in this repo (contracts\ and tests\contracts\) whose workbook is
     on this machine prints the same lines, old and new (case-sensitive); comparing none is a
     FAIL. The extension route (xlsx_meta.py tables / names / macros without --formulas, what
     extension\xlsx_meta\test\parity.sh compares) prints the same bytes, old and new.
#>
param(
    # The last commit before the change (0.6.2).
    [string]$Baseline = 'be128bb',
    [string]$ProjectProfit = 'C:\Users\woodsonp\Claude\Dev\risk-reserve\.dq\Project_Profit_26-10_October\Project Profit 26-10 October.xlsm',
    [string]$RiskReserve = 'C:\Users\woodsonp\Claude\Dev\risk-reserve',
    # risk-reserve's contract on that workbook; read only, for the tables and sheets its formula checks read.
    [string]$PPContract = 'C:\Users\woodsonp\Claude\Dev\risk-reserve\contracts\Project_Profit_26-10_October.sql'
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$work = Join-Path ([IO.Path]::GetTempPath()) "prove-xlsx-arrays-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$old = Join-Path $work 'old'
New-Item -ItemType Directory -Force $old | Out-Null
$fail = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)
$oldMeta = Join-Path $old 'tools\xlsx_meta.py'
$newMeta = Join-Path $repo 'tools\xlsx_meta.py'

& git archive --format=tar -o "$work\old.tar" $Baseline tools skills extension/bin
# Windows' own tar: a GNU tar first on PATH (Git Bash) reads C: as a remote host.
& "$env:SystemRoot\System32\tar.exe" -xf "$work\old.tar" -C $old
if (-not (Test-Path $oldMeta)) { Write-Output "ERROR: could not extract $Baseline"; exit 1 }

function Run($script, [string[]]$argList) {
    @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>$null | ForEach-Object { [string]$_ })
}
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Output "   PASS  $what" } else { $script:fail++; Write-Output "   FAIL  $what" }
}
function Fwd($p) { $p.Replace('\', '/') }
function Duck([string[]]$lines) {
    $f = Join-Path $work 'q.sql'
    [IO.File]::WriteAllText($f, (@('.mode csv') + $lines) -join "`n", $utf8)
    @(& duckdb -f $f | ConvertFrom-Csv)
}
function Table($rows) {
    $rows | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { $_ -split "`r?`n" } |
        ForEach-Object { $_.TrimEnd() } | Where-Object { $_ } | ForEach-Object { "      $_" }
}
function Sha($p) {
    $fs = [IO.File]::Open($p, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
    try { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fs)) -replace '-', '' }
    finally { $fs.Dispose() }
}
# Extract with one code version's xlsx_meta.py formulas; returns seconds.
function Extract($meta, $wb, $csv) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & py -3.12 $meta formulas $wb -o $csv | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $csv)) { Write-Host "ERROR: $meta formulas failed on $wb"; exit 1 }
    [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
# tests\recount-formulas.py (regex over the raw XML, no code shared with xlsx_meta.py): metric -> count.
function Recount($wb) {
    $h = @{}
    & py -3.12 -I (Join-Path $PSScriptRoot 'recount-formulas.py') $wb | ConvertFrom-Csv | ForEach-Object { $h[$_.metric] = [int64]$_.value }
    $h
}
$kinds = 'normal', 'shared', 'array', 'data-table'
# Compares the new view's formula rows by kind ($m: Compare-OldNew metrics) with a recount.
function KindsAgree($m, $rc) {
    $parts = @(); $ok = $rc.ContainsKey('formula_cells') -and (N $m 'new_formula_rows') -eq $rc['formula_cells']
    foreach ($k in $kinds) {
        $a = [int64]$m["new_kind_$k"]; $b = [int64]$rc["kind_$k"]
        if ($a -ne $b) { $ok = $false }
        $parts += ('{0} {1:N0}{2}{3:N0}' -f $k, $a, $(if ($a -eq $b) { ' = ' } else { ' <> ' }), $b)
    }
    @{ Ok = $ok; Text = $parts -join ', ' }
}
# A cell's <c> element as stored in the sheet XML (tests\raw-cell.py), and the ref of its array formula.
function RawCell($wb, $sheet, $cell) {
    $r = @(& py -3.12 -I (Join-Path $PSScriptRoot 'raw-cell.py') $wb $sheet $cell | ConvertFrom-Csv)
    if ($r.Count -eq 1) { [string]$r[0].xml } else { '' }
}
function RawArrayRef([string]$xml) {
    $m = [regex]::Match($xml, '<f\b(?=[^>]*\bt="array")[^>]*?\bref="([^"]+)"')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}
function Short([string]$s) { if ($s.Length -gt 150) { $s.Substring(0, 150) + '...' } else { $s } }

# Old vs new CSV, compared on the old code's 12 columns. 'gone' = old rows the new code no longer
# prints as they were; 'came' = new rows the old code did not print. Every one of both must be a
# spill placeholder (old: kind normal, no formula text). $scope: a predicate on rows; the scope_*
# metrics count the rows it holds and the gone / came rows inside it.
$cols = 'workbook_key, sheet, cell, "row", col, table_name, table_column, kind, formula_a1, formula_r1c1, cached_value, error'
$isPh = "kind = 'normal' AND coalesce(formula_a1, '') = ''"
function Compare-OldNew($oldCsv, $newCsv, [string]$scope = 'false') {
    $opts = "header = true, quote = '""', escape = '""', delim = ',', strict_mode = true, all_varchar = true"
    $m = Duck @(
        "CREATE TEMP TABLE o AS FROM read_csv('$(Fwd $oldCsv)', $opts);",
        "CREATE TEMP TABLE n AS FROM read_csv('$(Fwd $newCsv)', $opts);",
        "CREATE TEMP TABLE gone AS SELECT $cols FROM o EXCEPT ALL SELECT $cols FROM n;",
        "CREATE TEMP TABLE came AS SELECT $cols FROM n EXCEPT ALL SELECT $cols FROM o;",
        "CREATE MACRO coln(s) AS list_reduce(list_transform(string_split(s, ''), lambda x: ascii(x) - 64), lambda a, b: a * 26 + b);",
        "CREATE TEMP TABLE rects AS SELECT workbook_key, sheet, a, coalesce(nullif(split_part(array_ref, ':', 2), ''), a) AS b FROM (SELECT workbook_key, sheet, split_part(array_ref, ':', 1) AS a, array_ref FROM n WHERE coalesce(array_ref, '') <> '');",
        "CREATE TEMP TABLE r AS SELECT workbook_key, sheet, coln(regexp_extract(a, '^([A-Z]+)', 1)) AS c1, regexp_extract(a, '(\d+)$', 1)::INT AS r1, coln(regexp_extract(b, '^([A-Z]+)', 1)) AS c2, regexp_extract(b, '(\d+)$', 1)::INT AS r2 FROM rects;",
        "SELECT 'old_rows' AS metric, count(*)::VARCHAR AS value FROM o",
        "UNION ALL SELECT 'new_rows', count(*)::VARCHAR FROM n",
        "UNION ALL SELECT 'old_formula_rows', count(*)::VARCHAR FROM o WHERE kind <> 'none'",
        "UNION ALL SELECT 'new_formula_rows', count(*)::VARCHAR FROM n WHERE kind <> 'none'",
        "UNION ALL SELECT 'old_by_kind', string_agg(kind || ' ' || k, ', ' ORDER BY kind) FROM (SELECT kind, count(*) AS k FROM o GROUP BY 1)",
        "UNION ALL SELECT 'new_by_kind', string_agg(kind || ' ' || k, ', ' ORDER BY kind) FROM (SELECT kind, count(*) AS k FROM n GROUP BY 1)",
        "UNION ALL SELECT 'old_placeholders', count(*)::VARCHAR FROM o WHERE $isPh",
        "UNION ALL SELECT 'new_placeholders', count(*)::VARCHAR FROM n WHERE $isPh",
        "UNION ALL SELECT 'new_formula_rows_empty_text', count(*)::VARCHAR FROM n WHERE kind <> 'none' AND coalesce(formula_a1, '') = ''",
        "UNION ALL SELECT 'gone', count(*)::VARCHAR FROM gone",
        "UNION ALL SELECT 'gone_not_placeholder', count(*)::VARCHAR FROM gone WHERE NOT ($isPh)",
        "UNION ALL SELECT 'gone_with_error', count(*)::VARCHAR FROM gone WHERE coalesce(error, '') <> ''",
        "UNION ALL SELECT 'gone_in_table', count(*)::VARCHAR FROM gone WHERE coalesce(table_name, '') <> ''",
        "UNION ALL SELECT 'gone_example_sheet', (SELECT sheet FROM gone ORDER BY sheet, ""row""::INT, col::INT LIMIT 1)",
        "UNION ALL SELECT 'gone_example_cell', (SELECT cell FROM gone ORDER BY sheet, ""row""::INT, col::INT LIMIT 1)",
        "UNION ALL SELECT 'gone_outside_arrays', count(*)::VARCHAR FROM gone g WHERE NOT EXISTS (SELECT 1 FROM r WHERE r.workbook_key = g.workbook_key AND r.sheet = g.sheet AND g.""row""::INT BETWEEN r.r1 AND r.r2 AND g.col::INT BETWEEN r.c1 AND r.c2)",
        "UNION ALL SELECT 'gone_outside_arrays_cells', coalesce(string_agg(sheet || '!' || cell, ' ' ORDER BY sheet, cell), '') FROM (SELECT * FROM gone g WHERE NOT EXISTS (SELECT 1 FROM r WHERE r.workbook_key = g.workbook_key AND r.sheet = g.sheet AND g.""row""::INT BETWEEN r.r1 AND r.r2 AND g.col::INT BETWEEN r.c1 AND r.c2) ORDER BY sheet, cell LIMIT 10)",
        "UNION ALL SELECT 'came', count(*)::VARCHAR FROM came",
        "UNION ALL SELECT 'came_is_placeholder', count(*)::VARCHAR FROM came c JOIN gone g USING (workbook_key, sheet, cell, ""row"", col) WHERE g.kind = 'normal' AND coalesce(g.formula_a1, '') = '' AND c.kind = 'none' AND coalesce(c.formula_a1, '') = '' AND coalesce(c.formula_r1c1, '') = '' AND c.cached_value IS NOT DISTINCT FROM g.cached_value AND c.error IS NOT DISTINCT FROM g.error AND c.table_name IS NOT DISTINCT FROM g.table_name AND c.table_column IS NOT DISTINCT FROM g.table_column",
        "UNION ALL SELECT 'came_with_error', count(*)::VARCHAR FROM came WHERE coalesce(error, '') <> ''",
        "UNION ALL SELECT 'array_rows', count(*)::VARCHAR FROM n WHERE kind = 'array'",
        "UNION ALL SELECT 'array_ref_rows', count(*)::VARCHAR FROM n WHERE coalesce(array_ref, '') <> ''",
        "UNION ALL SELECT 'array_ref_on_array_rows', count(*)::VARCHAR FROM n WHERE kind = 'array' AND coalesce(array_ref, '') <> ''",
        "UNION ALL SELECT 'array_ref_multi', count(*)::VARCHAR FROM n WHERE contains(array_ref, ':')",
        "UNION ALL SELECT 'new_kind_' || kind, count(*)::VARCHAR FROM n GROUP BY kind",
        "UNION ALL SELECT 'scope_old_rows', count(*)::VARCHAR FROM o WHERE $scope",
        "UNION ALL SELECT 'scope_new_rows', count(*)::VARCHAR FROM n WHERE $scope",
        "UNION ALL SELECT 'scope_gone', count(*)::VARCHAR FROM gone WHERE $scope",
        "UNION ALL SELECT 'scope_came', count(*)::VARCHAR FROM came WHERE $scope;")
    $h = @{}
    foreach ($row in $m) { $h[$row.metric] = [string]$row.value }
    $h
}
function N($h, $k) { [int64]$h[$k] }

# --- 1. fixture ------------------------------------------------------------------------------
$fx = Join-Path $work 'arrays.xlsx'
& py -3.12 (Join-Path $PSScriptRoot 'make-array-fixture.py') $fx | Out-Null
if (-not (Test-Path -LiteralPath $fx)) { Write-Output 'ERROR: tests\make-array-fixture.py wrote no workbook'; exit 1 }
Write-Output "Fixture: $fx"
Write-Output "Baseline: $Baseline (old code), against the code in $repo (new code)"
Write-Output ''
Write-Output '1. Fixture: CSE array B2:B4, volatile dynamic array D2:D6 (children <f ca="1"/>, D4 #DIV/0!), non-volatile'
Write-Output '   dynamic array F2:F4, shared H2:H4, one-cell array J2, table Tbl[Calc] with placeholders in C8 and C9,'
Write-Output '   Edge: empty array master A1, placeholder C5 outside every array, data table E2'
Write-Output '   the two placeholders in the shape Project Profit stores (t="str", empty <v/>), as written in the file:'
$shapeOk = 0
foreach ($sc in @(@('Arrays', 'D5'), @('Tab', 'C9'))) {
    $x = RawCell $fx $sc[0] $sc[1]
    Write-Output "      $($sc[0])!$($sc[1]): $x"
    if ($x -ceq "<c r=`"$($sc[1])`" t=`"str`"><f ca=`"1`"/><v/></c>") { $shapeOk++ }
}
Check ($shapeOk -eq 2) "both are exactly <c r=`"..`" t=`"str`"><f ca=`"1`"/><v/></c> ($shapeOk of 2; section 2 shows one from Project Profit)"
$null = Extract $oldMeta $fx "$work\fx-old.csv"
& py -3.12 $newMeta macros $fx --formulas -o "$work\fx-new.sql" | Out-Null
$sel = "SELECT sheet, cell, kind, coalesce(formula_a1, '') AS formula_a1, coalesce(formula_r1c1, '') AS formula_r1c1, coalesce(cached_value, '') AS cached_value, coalesce(error, '') AS error, coalesce(array_ref, '') AS array_ref"
$newRows = Duck @(".read '$(Fwd "$work\fx-new.sql")'", "$sel FROM read_xlsx_formulas('$(Fwd $fx)') ORDER BY CASE sheet WHEN 'Arrays' THEN 1 WHEN 'Tab' THEN 2 ELSE 3 END, ""row"", col;")
$viewCols = Duck @(".read '$(Fwd "$work\fx-new.sql")'", "SELECT column_name, column_type FROM (DESCRIBE xlsx_formulas);")
$oldRows = @(Import-Csv "$work\fx-old.csv")
$ph = @(Import-Csv "$fx.placeholders.csv")
$exp = @(Import-Csv "$fx.expected.csv")

Write-Output "   old code, the $($ph.Count) placeholder cells:"
$oldPh = @(foreach ($p in $ph) {
    $o = $oldRows | Where-Object { $_.sheet -ceq $p.sheet -and $_.cell -ceq $p.cell }
    [pscustomobject]@{ cell = "$($p.sheet)!$($p.cell)"; kind = $o.kind; formula_a1 = "[$($o.formula_a1)]"; cached_value = $o.cached_value; error = $o.error; where = $p.where }
})
Table $oldPh
$oldBug = @($oldPh | Where-Object { $_.kind -ceq 'normal' -and $_.formula_a1 -ceq '[]' }).Count
Check ($ph.Count -eq 7 -and $oldBug -eq 7) "old code: all $oldBug of $($ph.Count) placeholders listed as formulas, kind normal with empty formula text (the bug)"

Write-Output '   new code, every row of read_xlsx_formulas:'
Table ($newRows | Select-Object @{n='cell'; e={ "$($_.sheet)!$($_.cell)" }}, kind, formula_a1, cached_value, error, array_ref)
$byCell = @{}
foreach ($r in $newRows) { $byCell["$($r.sheet)!$($r.cell)"] = $r }
$f = 'kind', 'formula_a1', 'formula_r1c1', 'cached_value', 'error', 'array_ref'
$bad = @()
foreach ($e in $exp) {
    $g = $byCell["$($e.sheet)!$($e.cell)"]
    if (-not $g) { $bad += "MISSING $($e.sheet)!$($e.cell)"; continue }
    # [string]: Import-Csv reads an empty LAST field as $null, not ''.
    foreach ($c in $f) { if ([string]$g.$c -cne [string]$e.$c) { $bad += "$($e.sheet)!$($e.cell) $c got [$($g.$c)] expected [$($e.$c)]" } }
}
foreach ($k in $byCell.Keys) { if (-not ($exp | Where-Object { "$($_.sheet)!$($_.cell)" -ceq $k })) { $bad += "EXTRA $k" } }
$bad | ForEach-Object { Write-Output "         $_" }
Check ($exp.Count -gt 0 -and $newRows.Count -eq $exp.Count -and $bad.Count -eq 0) ("new view equals tests\make-array-fixture.py's expected rows: {0} of {1}, {2} differences, no row missing or extra" -f $newRows.Count, $exp.Count, $bad.Count)
$lastCol = $viewCols[-1]
Check ($lastCol.column_name -ceq 'array_ref' -and $lastCol.column_type -ceq 'VARCHAR') "the xlsx_formulas view's last column is array_ref VARCHAR ($($viewCols.Count) columns)"

$fm = Compare-OldNew "$work\fx-old.csv" (Join-Path $work 'fx-new.sql.formulas.csv')
Write-Output ("   old vs new on the 12 old columns: {0} old rows gone, {1} new rows came; old formula rows {2}, new {3}" -f $fm.gone, $fm.came, $fm.old_formula_rows, $fm.new_formula_rows)
Check ((N $fm 'gone') -eq 7 -and (N $fm 'gone_not_placeholder') -eq 0) "every old row that changed is a placeholder: $($fm.gone) gone, $($fm.gone_not_placeholder) of them not a placeholder"
Check ((N $fm 'came') -eq 3 -and (N $fm 'came_is_placeholder') -eq 3) "every new row is unchanged or a placeholder now read as a value: $($fm.came) came (D4 with its error, Tbl's C8 with its value, Tbl's C9 blank), $($fm.came_is_placeholder) match a placeholder's cell, value and error"
$fxRc = Recount $fx
$fxK = KindsAgree $fm $fxRc
Check ($fxK.Ok -and $fxRc['formula_cells'] -eq 13) ("tests\recount-formulas.py on the fixture: {0} formula cells = the new view's {1}, by kind (new = recount): {2}" -f $fxRc['formula_cells'], $fm.new_formula_rows, $fxK.Text)
Check ((N $fm 'new_placeholders') -eq 0) "new code: no row of kind normal with empty formula text ($($fm.new_placeholders))"
$empty = @($newRows | Where-Object { $_.kind -cne 'none' -and $_.formula_a1 -ceq '' } | ForEach-Object { "$($_.sheet)!$($_.cell) $($_.kind)" })
Check (($empty -join ', ') -ceq 'Edge!A1 array, Edge!E2 data-table') "new code: the only formula rows with empty text are the empty array master and the data table, kept by design: $($empty -join ', ')"
$h3 = $byCell['Arrays!H3']; $h4 = $byCell['Arrays!H4']
Check ($h3.kind -ceq 'shared' -and $h3.formula_a1 -ceq 'A3+1' -and $h4.kind -ceq 'shared' -and $h4.formula_a1 -ceq 'A4+1' -and $h3.formula_r1c1 -ceq 'RC[-7]+1') "shared dependents (empty <f t=`"shared`" si=`"0`"/>) still formulas: H3 =$($h3.formula_a1), H4 =$($h4.formula_a1), R1C1 $($h3.formula_r1c1)"
$refs = @($newRows | Where-Object { $_.array_ref } | ForEach-Object { "$($_.sheet)!$($_.cell)=$($_.array_ref)" }) -join ' '
Check ($refs -ceq 'Arrays!B2=B2:B4 Arrays!D2=D2:D6 Arrays!F2=F2:F4 Arrays!J2=J2 Edge!A1=A1:A2' -and (N $fm 'array_ref_rows') -eq (N $fm 'array_rows')) "array_ref as stored on each array master, empty on every other row: $refs"
$d4 = $byCell['Arrays!D4']
Check ($d4.kind -ceq 'none' -and $d4.error -ceq '#DIV/0!' -and $d4.cached_value -ceq '#DIV/0!') "the placeholder showing an error is still reported: Arrays!D4 kind $($d4.kind), error $($d4.error)"
$c8 = $byCell['Tab!C8']
$c9 = $byCell['Tab!C9']
Check ($c8.kind -ceq 'none' -and $c8.cached_value -ceq '14' -and (N $fm 'gone_in_table') -eq 2) "a placeholder in a table formula column reads as a typed value: Tab!C8 kind $($c8.kind), value $($c8.cached_value); Tbl's other rows unchanged"
Check ($c9 -and $c9.kind -ceq 'none' -and $c9.formula_a1 -ceq '' -and $c9.cached_value -ceq '' -and $c9.error -ceq '') "one in Project Profit's shape (t=`"str`", empty <v/>) reads as a blank: Tab!C9 kind $($c9.kind), value [$($c9.cached_value)]; Arrays!D5 has no row: $(-not $byCell.ContainsKey('Arrays!D5'))"
Check (-not $byCell.ContainsKey('Edge!C5') -and $fm.gone_outside_arrays_cells -ceq 'Edge!C5 Tab!C8 Tab!C9') "placeholders outside every array rectangle ($($fm.gone_outside_arrays_cells)) are read like any other: Edge!C5 has no row"

# --- 2. Project Profit -----------------------------------------------------------------------
Write-Output ''
Write-Output "2. Project Profit 26-10 October (a copy in %TEMP%; source: $ProjectProfit)"
if (-not (Test-Path -LiteralPath $ProjectProfit)) {
    Check $false "Project Profit copy not found: $ProjectProfit"
} else {
    $srcSha = Sha $ProjectProfit
    $rrBefore = @(& git -C $RiskReserve status --porcelain --untracked-files=all 2>$null)
    $pp = Join-Path $work 'Project Profit 26-10 October.xlsm'
    Copy-Item -LiteralPath $ProjectProfit -Destination $pp
    Write-Output ("   copy taken {0:yyyy-MM-dd HH:mm:ss}; the source was last written {1:yyyy-MM-dd HH:mm:ss} (risk-reserve's check-pp.ps1 replaces it each run)" -f (Get-Date), (Get-Item -LiteralPath $ProjectProfit).LastWriteTime)

    # The tables and sheets risk-reserve's Project Profit contract's formula checks read (their
    # scopes, as tools\contract-xlsx.ps1 parses them). A bare name or a scope this cannot place
    # is listed and fails the check below rather than being guessed at.
    $ppTables = @(); $ppSheets = @(); $ppAll = $false; $ppOther = @(); $ppChecks = 0; $ppPlaced = 0; $ppReads = ''
    $cellRx = '(\$?[A-Za-z]{1,3}\$?\d+)?$'      # optional cell after Sheet!; single quotes keep $? literal
    if (Test-Path -LiteralPath $PPContract) {
        $ctext = [IO.File]::ReadAllText($PPContract)
        $mr = [regex]::Match($ctext, "read_xlsx(?:_table|_name)?\(\s*'([^']+)'", 'IgnoreCase')
        if ($mr.Success) { $ppReads = $mr.Groups[1].Value }
        foreach ($m in [regex]::Matches($ctext, '(?m)^\s*--\s*@formula_(consistent|errors_max|fingerprint)\s+[A-Za-z0-9_]+\s*:\s*(.+?)\s*$')) {
            $ppChecks++
            $v = $m.Groups[2].Value
            $sep = @{ errors_max = ' <= '; fingerprint = ' == ' }[$m.Groups[1].Value]
            if ($sep -and $v.IndexOf($sep) -ge 0) { $v = $v.Substring(0, $v.IndexOf($sep)) }
            $v = $v.Trim()
            if ($v -eq '*') { $ppAll = $true; $ppPlaced++ }
            elseif ($v -match ("^'((?:[^']|'')+)'!" + $cellRx)) { $ppSheets += ($Matches[1] -replace "''", "'"); $ppPlaced++ }
            elseif ($v -match ("^([^'!\[\]]+)!" + $cellRx)) { $ppSheets += $Matches[1]; $ppPlaced++ }
            elseif ($v -match '^([A-Za-z_\\][A-Za-z0-9_.\\]*)\[[^\[\]]+\]$') { $ppTables += $Matches[1]; $ppPlaced++ }
            else { $ppOther += $v }
        }
    }
    $ppTables = @($ppTables | Sort-Object -Unique); $ppSheets = @($ppSheets | Sort-Object -Unique)
    function SqlList($xs) { ($xs | ForEach-Object { "'" + ($_.ToLower() -replace "'", "''") + "'" }) -join ', ' }
    $scopeParts = @()
    if ($ppAll) { $scopeParts += 'true' }
    if ($ppTables) { $scopeParts += "lower(coalesce(table_name, '')) IN ($(SqlList $ppTables))" }
    if ($ppSheets) { $scopeParts += "lower(sheet) IN ($(SqlList $ppSheets))" }
    $ppScope = if ($scopeParts) { '(' + ($scopeParts -join ' OR ') + ')' } else { 'false' }

    $tOld = Extract $oldMeta $pp "$work\pp-old.csv"
    $tNew = Extract $newMeta $pp "$work\pp-new.csv"
    $pm = Compare-OldNew "$work\pp-old.csv" "$work\pp-new.csv" $ppScope
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ppRc = Recount $pp
    $tRc = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Output "   extraction time: old $tOld s, new $tNew s; tests\recount-formulas.py $tRc s"
    Write-Output "   old rows by kind: $($pm.old_by_kind)"
    Write-Output "   new rows by kind: $($pm.new_by_kind)"
    Write-Output ("   formula rows (kind <> 'none'): old {0:N0}, new {1:N0}; old placeholders (kind normal, no text) {2:N0}" -f (N $pm 'old_formula_rows'), (N $pm 'new_formula_rows'), (N $pm 'old_placeholders'))
    $ppK = KindsAgree $pm $ppRc
    Check $ppK.Ok ("new formula rows {0:N0} = {1:N0}, tests\recount-formulas.py's count on the same copy (regex over the raw XML, no code shared); by kind (new = recount): {2}" -f (N $pm 'new_formula_rows'), $ppRc['formula_cells'], $ppK.Text)
    Check ((N $pm 'old_formula_rows') - (N $pm 'new_formula_rows') -eq (N $pm 'old_placeholders') -and (N $pm 'new_placeholders') -eq 0) ("old - new = {0:N0} = the old placeholder rows; new has {1} rows of kind normal with no text" -f ((N $pm 'old_formula_rows') - (N $pm 'new_formula_rows')), $pm.new_placeholders)
    Check ((N $pm 'gone') -eq (N $pm 'old_placeholders') -and (N $pm 'gone_not_placeholder') -eq 0) ("every old row that changed is a placeholder: {0:N0} gone, {1} not a placeholder" -f (N $pm 'gone'), $pm.gone_not_placeholder)
    Check ((N $pm 'came') -eq (N $pm 'came_is_placeholder') -and (N $pm 'came') -eq (N $pm 'gone_with_error') -and (N $pm 'came_with_error') -eq (N $pm 'came')) ("placeholders showing an error: {0:N0} old, {1:N0} reported by the new code as kind none with the same cell, value and error (none in a table: {2})" -f (N $pm 'gone_with_error'), (N $pm 'came_is_placeholder'), $pm.gone_in_table)
    Check ((N $pm 'gone_outside_arrays') -eq 0) ("placeholders outside every array rectangle on their sheet: {0} (each placeholder lies inside an array master's array_ref)" -f $pm.gone_outside_arrays)
    $exXml = if ($pm.gone_example_cell) { RawCell $pp $pm.gone_example_sheet $pm.gone_example_cell } else { '' }
    Write-Output "   first placeholder by sheet and position, as stored: '$($pm.gone_example_sheet)'!$($pm.gone_example_cell) $(Short $exXml)"
    Check ($exXml -match '<f(?![^>]*\bt=)[^>]*/>') "it is an empty <f> with no t in the file itself (tests\raw-cell.py), the placeholder the fixture copies"

    Write-Output "   risk-reserve's Project Profit contract ($PPContract), not run here:"
    $readsThis = $ppReads -and ([IO.Path]::GetFullPath($ppReads.Replace('/', '\')) -eq [IO.Path]::GetFullPath($ProjectProfit))
    $scopeText = (@($ppTables | ForEach-Object { "table $_" }) + @($ppSheets | ForEach-Object { "sheet '$_'" }) + @($(if ($ppAll) { 'every cell (*)' }))) -join ', '
    Check ($readsThis -and $ppChecks -gt 0 -and $ppPlaced -eq $ppChecks) ("it reads this workbook ({0}) and has {1} formula checks, {2} of them placed, reading {3}{4}" -f $readsThis, $ppChecks, $ppPlaced, $scopeText, $(if ($ppOther) { ' -- scope not placed: ' + ($ppOther -join '; ') } else { '' }))
    $arRefs = @(Select-String -Path "$repo\tools\contract-xlsx.ps1", "$repo\tools\run-assertions.ps1", "$repo\tools\check-contract.ps1" -Pattern 'array_ref' -SimpleMatch).Count
    $scopeSame = (N $pm 'scope_old_rows') -gt 0 -and (N $pm 'scope_gone') -eq 0 -and (N $pm 'scope_came') -eq 0 -and $arRefs -eq 0
    Check $scopeSame ("rows in those tables and sheets: {0:N0} old, {1:N0} new; differ on the 12 old columns: {2:N0} gone, {3:N0} came; array_ref named in the contract runner: {4} times -- {5}" -f (N $pm 'scope_old_rows'), (N $pm 'scope_new_rows'), (N $pm 'scope_gone'), (N $pm 'scope_came'), $arRefs, $(if ($scopeSame) { 'so its formula checks cannot print anything new' } else { 'so its formula checks may print something new: run it old and new' }))
    Check ((N $pm 'array_ref_rows') -eq (N $pm 'array_rows') -and (N $pm 'array_ref_on_array_rows') -eq (N $pm 'array_rows')) ("array_ref on every array row and no other: {0:N0} array rows, {1:N0} rows with array_ref" -f (N $pm 'array_rows'), (N $pm 'array_ref_rows'))
    $multi = Duck @("SELECT sheet, count(*) AS masters, min(cell || '=' || array_ref) AS example FROM read_csv('$(Fwd "$work\pp-new.csv")', all_varchar = true) WHERE contains(array_ref, ':') GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 5;")
    Write-Output ("   array masters with a multi-cell array_ref: {0:N0} of {1:N0} (top sheets below)" -f (N $pm 'array_ref_multi'), (N $pm 'array_rows'))
    Table $multi
    $q128 = "SELECT sheet, cell, kind, left(formula_a1, 60) AS formula_a1, coalesce(array_ref, '') AS array_ref FROM read_csv('{0}', all_varchar = true) WHERE sheet = '10002556' AND cell = 'I128';"
    $i128 = @(Duck @(($q128 -f (Fwd "$work\pp-new.csv"))))
    Write-Output "   '10002556'!I128, clean file:"
    Table $i128
    $rawI = RawCell $pp '10002556' 'I128'
    $refI = RawArrayRef $rawI
    Write-Output "      as stored: $(Short $rawI)"
    Check ($i128.Count -eq 1 -and $i128[0].array_ref -ceq $refI -and ($refI -eq '' -or $i128[0].kind -ceq 'array')) "clean file: '10002556'!I128 kind $($i128[0].kind), array_ref [$($i128[0].array_ref)] = the ref stored in the sheet XML [$refI]"

    $planted = Join-Path $work 'Project Profit incident.xlsm'
    $plantPy = Join-Path $RiskReserve 'tests\plant_cycles.py'
    Write-Output "   planting the I128 incident with $plantPy (-B: no bytecode written in risk-reserve):"
    $env:DUCKDB_SKILLS_TOOLS = Join-Path $repo 'tools'
    & py -3.12 -B $plantPy $pp $planted incident 2>&1 | ForEach-Object { "      $_" } | ForEach-Object { if ($_.Length -gt 200) { $_.Substring(0, 200) + '...' } else { $_ } }
    Remove-Item Env:\DUCKDB_SKILLS_TOOLS
    if (-not (Test-Path -LiteralPath $planted)) {
        Check $false 'plant_cycles.py wrote no planted copy'
    } else {
        $tPl = Extract $newMeta $planted "$work\pp-incident.csv"
        $p128 = @(Duck @(($q128 -f (Fwd "$work\pp-incident.csv"))))
        Write-Output "   '10002556'!I128, planted copy (new code, $tPl s):"
        Table $p128
        $rawP = RawCell $planted '10002556' 'I128'
        $refP = RawArrayRef $rawP
        Write-Output "      as stored: $(Short $rawP)"
        Check ($p128.Count -eq 1 -and $p128[0].kind -ceq 'array' -and $refP.Contains(':') -and $p128[0].array_ref -ceq $refP) "planted incident: '10002556'!I128 array_ref [$($p128[0].array_ref)] = the multi-cell ref stored in the planted copy [$refP]"
    }
    Check ((Sha $ProjectProfit) -eq $srcSha) 'the source workbook is unchanged (SHA-256 before = after)'
    $rrAfter = @(& git -C $RiskReserve status --porcelain --untracked-files=all 2>$null)
    Check (($rrBefore -join "`n") -ceq ($rrAfter -join "`n")) "risk-reserve's git status is the same before and after ($($rrAfter.Count) lines): nothing written there"
}

# --- 3. regression -----------------------------------------------------------------------------
Write-Output ''
Write-Output "3. Regression: code at $Baseline vs code now"
Write-Output '   a. the extension route: xlsx_meta.py tables / names / macros (no --formulas), as parity.sh runs them'
$routeWbs = @($fx)
if ($pp -and (Test-Path -LiteralPath $pp)) { $routeWbs += $pp }
foreach ($wb in $routeWbs) {
    $same = 0; $diffs = @()
    foreach ($cmd in 'tables', 'names', 'macros') {
        $cmdArgs = @($cmd, $wb)
        if ($cmd -ne 'macros') { $cmdArgs += @('--format', 'csv') }
        $a = @(& py -3.12 -X utf8 $oldMeta @cmdArgs | ForEach-Object { [string]$_ })
        $b = @(& py -3.12 -X utf8 $newMeta @cmdArgs | ForEach-Object { [string]$_ })
        if ($a.Count -gt 0 -and ($a -join "`n") -ceq ($b -join "`n")) { $same++ } else { $diffs += "$cmd ($($a.Count) vs $($b.Count) lines)" }
    }
    Check ($same -eq 3) ("{0}: tables, names, macros identical ({1} of 3){2}" -f (Split-Path $wb -Leaf), $same, $(if ($diffs) { ' -- differ: ' + ($diffs -join ', ') } else { '' }))
}
Write-Output '   b. every contract in this repo (contracts\ and tests\contracts\) whose workbook is on this machine;'
Write-Output "      risk-reserve's Project Profit contract is covered in section 2 by the rows its formula checks read"
$contracts = @(Get-ChildItem "$repo\contracts\*.sql", "$repo\tests\contracts\*.sql" | Sort-Object FullName)
$compared = 0
foreach ($cf in $contracts) {
    $rel = $cf.FullName.Substring($repo.Length + 1)
    $raw = [IO.File]::ReadAllText($cf.FullName)
    $m1 = [regex]::Match($raw, "read_xlsx(?:_table|_name)?\(\s*'([^']+)'", 'IgnoreCase')
    if (-not $m1.Success -or -not (Test-Path -LiteralPath $m1.Groups[1].Value)) {
        Write-Output "   SKIP  ${rel}: workbook not on this machine"
        continue
    }
    $a = Run "$old\tools\run-assertions.ps1" @('-Contract', $cf.FullName)
    $b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $cf.FullName)
    $compared++
    $nf = @($b | Where-Object { $_ -match '^ASSERT,' }).Count
    $diff = if ($a.Count -and $b.Count) { @(Compare-Object $a $b -SyncWindow 0 -CaseSensitive) } else { @('empty') }
    $formulaNote = if ($raw -match '(?m)^\s*--\s*@formula_') { ', has formula checks' } else { '' }
    Check ($a.Count -gt 0 -and $diff.Count -eq 0) ("{0}: {1} lines old, {2} new, {3} ({4} ASSERT lines{5})" -f $rel, $a.Count, $b.Count, $(if ($diff.Count) { "$($diff.Count) differ" } else { 'identical' }), $nf, $formulaNote)
    if ($diff.Count) { $diff | ForEach-Object { Write-Output "         $($_.SideIndicator) $($_.InputObject)" } }
}
Check ($compared -gt 0) "compared $compared of this repo's $($contracts.Count) contracts (none compared would prove nothing)"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (spill placeholders are values, not formulas; array_ref as stored; existing contracts print the same lines)'
