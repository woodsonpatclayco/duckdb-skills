<#
tests\prove-linebreak-headers.ps1 [-Baseline <commit>]

0.6.2 proof: a contract over an Excel table whose header cells hold a line break (Alt+Enter --
Project Profit's Risk_Reserve_Summary has 19) now runs every check, where the code at
-Baseline ended in a Binder Error that skipped every check after it, formula checks included.

Builds a fixture workbook in %TEMP% (tests\make-linebreak-fixture.py), writes fixture contracts
beside it, and runs the code at -Baseline (extracted from git into %TEMP%, never checked out over
this folder) and the code now:

  1. The line-break table: the old code shows the Binder Error; the new code has no ERROR line,
     FINGERPRINT,MATCH against a fingerprint written with \n, the formula check FAILs naming
     exactly the one typed cell, the @assert PASSes, the completeness check sees every row.
  2. The Sparse table: rows whose only value sits under Job<LF>Number or Note<CR><LF>Text, and a
     blank row. The with-data count is exactly 3, so leaving any column out of the all-null
     predicate (or dropping it) fails this check. An @anchor written Note\nText counts that column.
  3. A drifted fingerprint prints the observed names on one line, line breaks as \n.
  4. Multi-line details arrive whole on one line: an @assert's non-boolean value, an @assert's
     DuckDB error, and a formula check whose formula is written over two lines. The old code cut
     each at its first line break. No detail carries PowerShell's RemoteException filler.
  5. A non-ASCII header (Cafe with an acute e): old and new print the same lines, in this console and under
     code page 437 (a Windows PowerShell console's default).
  6. @snapshot values that are NULL or empty: old and new print the same lines (NULL as NULL),
     and a committed NULL still matches.
  7. materialize.ps1 writes the line-break table into a scratch lake with its real column
     names, and check history records the \n fingerprint. The real lake is never touched.
  8. Regression: every contract in contracts\ and tests\contracts\ whose workbook is on this
     machine prints the same lines, old and new, compared case-sensitively. The workbooks are
     only read. Comparing no contract at all is a FAIL, not a pass.
#>
param(
    # The last commit before the fix (0.6.1).
    [string]$Baseline = 'cc9fd5f'
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$work = Join-Path ([IO.Path]::GetTempPath()) "prove-linebreak-headers-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$old = Join-Path $work 'old'
New-Item -ItemType Directory -Force $old | Out-Null
$fail = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)

& git archive --format=tar -o "$work\old.tar" $Baseline tools skills extension/bin
# Windows' own tar: a GNU tar first on PATH (Git Bash) reads C: as a remote host.
& "$env:SystemRoot\System32\tar.exe" -xf "$work\old.tar" -C $old
if (-not (Test-Path "$old\tools\run-assertions.ps1")) { Write-Output "ERROR: could not extract $Baseline"; exit 1 }

function Run($script, [string[]]$argList) {
    @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>$null | ForEach-Object { [string]$_ })
}
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Output "   PASS  $what" } else { $script:fail++; Write-Output "   FAIL  $what" }
}
function Show([string]$label, [string[]]$lines) {
    Write-Output "   $label"
    $lines | ForEach-Object { Write-Output "      $_" }
}
function Detail([string[]]$lines, [string]$name) {
    $l = $lines | Where-Object { $_ -like "ASSERT,$name,*" } | Select-Object -First 1
    if ($l) { ($l -split ',', 4)[3] } else { $null }
}

# --- fixture workbook and contracts ----------------------------------------------------------
$wb = Join-Path $work 'linebreaks.xlsx'
& py -3.12 (Join-Path $PSScriptRoot 'make-linebreak-fixture.py') $wb | Out-Null
if (-not (Test-Path -LiteralPath $wb)) { Write-Output 'ERROR: tests\make-linebreak-fixture.py wrote no workbook'; exit 1 }
$wbFwd = $wb -replace '\\', '/'
function Contract([string]$name, [string]$text) {
    $p = Join-Path $work "$name.sql"
    [IO.File]::WriteAllText($p, $text.Replace('<WB>', $wbFwd), $utf8)
    $p
}
$fp = 'Job\nNumber|Cost "Code",\nType|Amount|Note\nText|Calc'
$view = "CREATE OR REPLACE VIEW contract_view AS`r`nSELECT * FROM read_xlsx_table('<WB>', 'Breaks');`r`n"
$lh = Contract 'Linebreak_Headers' (@'
-- Fixture: the Breaks table's headers are Job<LF>Number, Cost "Code",<LF>Type, Amount,
-- Note<CR><LF>Text and Calc. A line break in a fingerprint name is written \n.
-- @table: Breaks
-- @fingerprint: <FP>
-- @anchor: Amount
-- @rows_floor: 4
-- @formula_consistent calc_consistent: Breaks[Calc]
-- @assert four_jobs: (SELECT count(DISTINCT COLUMNS('^Job\sNumber$')) = 4 FROM contract_view)
-- @snapshot note_min: (SELECT min(COLUMNS('^Note\s+Text$')) FROM contract_view)
-- @snapshot_committed note_min: line one\nline two

'@.Replace('<FP>', $fp) + $view)
$drift = Contract 'Linebreak_Drift' (@'
-- @table: Breaks
-- @fingerprint: Job\nNumber|Cost "Code",\nType|Amount|Note\nText

'@ + $view)
$ml = Contract 'Multiline_Details' @'
-- @table: Plain
-- @fingerprint: Code|Qty
-- @assert multiline_value: (SELECT 'first line' || chr(10) || 'second line')
-- @assert missing_col: (SELECT count("No Such Column") = 0 FROM contract_view)
-- @formula_consistent calc_consistent: Breaks[Calc]

CREATE OR REPLACE VIEW contract_view AS
SELECT * FROM read_xlsx_table('<WB>', 'Plain');
'@
$sparse = Contract 'Sparse_Rows' @'
-- Fixture: table Sparse, headers Job<LF>Number | Amount | Note<CR><LF>Text. Row 2 has only
-- Job<LF>Number, row 3 is blank, row 4 has only Note<CR><LF>Text, row 5 Amount and the note.
-- @table: Sparse
-- @fingerprint: Job\nNumber|Amount|Note\nText
-- @anchor: Note\nText

CREATE OR REPLACE VIEW contract_view AS
SELECT * FROM read_xlsx_table('<WB>', 'Sparse');
'@
$nulls = Contract 'Null_Snapshots' @'
-- @table: Plain
-- @fingerprint: Code|Qty
-- @snapshot none_max: (SELECT max(Code) FROM contract_view WHERE Code = 'zzz')
-- @snapshot_committed none_max: NULL
-- @snapshot empty_text: (SELECT '')
-- @snapshot_committed empty_text:

CREATE OR REPLACE VIEW contract_view AS
SELECT * FROM read_xlsx_table('<WB>', 'Plain');
'@
$acc = Contract 'Accents' @'
-- The Accents table's first header is Caf<e-acute>; this file itself is plain ASCII.
-- @table: Accents
-- @fingerprint: Cafe|Plain
-- @snapshot cafe_max: (SELECT max(COLUMNS('^Caf.$')) FROM contract_view)
-- @snapshot_committed cafe_max: naive
-- @assert two_rows: (SELECT count(COLUMNS('^Caf.$')) = 2 FROM contract_view)

CREATE OR REPLACE VIEW contract_view AS
SELECT * FROM read_xlsx_table('<WB>', 'Accents');
'@
Write-Output "Fixture: $wb"
Write-Output "Baseline: $Baseline (old code), against the code in $repo (new code)"

# --- 1. the line-break table ------------------------------------------------------------------
Write-Output ''
Write-Output '1. Excel table Breaks, headers Job<LF>Number | Cost "Code",<LF>Type | Amount | Note<CR><LF>Text | Calc'
Write-Output "   committed fingerprint: $fp"
$a = Run "$old\tools\run-assertions.ps1" @('-Contract', $lh)
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $lh)
Show "old code ($Baseline):" $a
Check ([bool]($a | Where-Object { $_ -like 'ERROR,*' -and $_ -like '*Binder Error*' })) 'old code: ERROR with a Binder Error (the bug)'
Check (-not ($a | Where-Object { $_ -like 'ASSERT,calc_consistent,*' })) 'old code: the formula check never ran'
Show 'new code:' $b
Check (-not ($b | Where-Object { $_ -like 'ERROR,*' })) 'new code: no ERROR line'
Check ($b -contains 'FINGERPRINT,MATCH') 'new code: FINGERPRINT,MATCH'
$d = Detail $b 'calc_consistent'
Check (($b | Where-Object { $_ -like 'ASSERT,calc_consistent,FAIL,*' }) -and $d -match 'typed values 1, blanks 0' -and $d -match '-- not a formula: E4 \(99\)$') 'new code: calc_consistent FAILs, naming exactly E4 (the one typed cell)'
Check ($b -contains 'ASSERT,four_jobs,PASS') 'new code: @assert four_jobs PASSes'
Check (($b -contains 'TRUNCATION_ROWS_LOST,0') -and ($b -contains 'TRUNCATION_WITHDATA_ROWS,4') -and ($b -contains 'CONSISTENCY_VIEW_ROWS,4')) 'new code: the completeness check counts 4 rows, 0 lost'
Check (($b -contains 'SNAPSHOT,note_min,line one\nline two') -and -not ($b | Where-Object { $_ -like 'SNAPSHOT_DRIFT,*' })) 'new code: a value with a line break prints as \n and matches its committed value'

# --- 2. sparse rows: every column reaches the all-null predicate --------------------------------
Write-Output ''
Write-Output '2. Table Sparse: row 2 only Job<LF>Number, row 3 blank, row 4 only Note<CR><LF>Text, row 5 Amount + Note'
$a = Run "$old\tools\run-assertions.ps1" @('-Contract', $sparse)
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $sparse)
Show "old code ($Baseline):" $a
Check ([bool]($a | Where-Object { $_ -like 'ERROR,*' -and $_ -like '*Binder Error*' })) 'old code: ERROR with a Binder Error (the bug)'
Show 'new code:' $b
Check (-not ($b | Where-Object { $_ -like 'ERROR,*' })) 'new code: no ERROR line'
Check (($b -contains 'TRUNCATION_WITHDATA_ROWS,3') -and ($b -contains 'TRUNCATION_DEFAULT_ROWS,1') -and ($b -contains 'TRUNCATION_ROWS_LOST,2')) 'new code: with-data rows exactly 3 (rows 2, 4, 5; not the blank row 3), so both line-break columns are in the all-null predicate; the default read stops at the blank row, 2 lost'
Check ($b -contains 'ANCHOR,Note\nText,2,FAIL') 'new code: @anchor Note\nText finds the CR<LF> column and counts its 2 values (Job and Amount have 1 each)'

# --- 3. fingerprint drift prints one line ------------------------------------------------------
Write-Output ''
Write-Output '3. A fingerprint that left out Calc: the drift report, one line per item'
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $drift)
$b | Where-Object { $_ -like 'FINGERPRINT*' } | ForEach-Object { Write-Output "      $_" }
Check (($b -contains 'FINGERPRINT,DRIFT') -and ($b -contains "FINGERPRINT_OBSERVED,$fp")) "FINGERPRINT_OBSERVED,$fp"

# --- 4. multi-line details ---------------------------------------------------------------------
Write-Output ''
Write-Output '4. Multi-line details (contract over table Plain; its formula check names Breaks[Calc], whose formula spans two lines)'
$a = Run "$old\tools\run-assertions.ps1" @('-Contract', $ml)
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $ml)
Show "old code ($Baseline):" @($a | Where-Object { $_ -like 'ASSERT,*' })
Show 'new code:' @($b | Where-Object { $_ -like 'ASSERT,*' })
$cases = @(
    @{ name = 'multiline_value'; whole = 'first line \| second line$'; what = "an @assert's non-boolean value 'first line<LF>second line'" },
    @{ name = 'missing_col'; whole = '\| LINE 1: '; what = "an @assert's DuckDB error (its LINE 1: context is on a later line)" },
    @{ name = 'calc_consistent'; whole = '-- not a formula: E4 \(99\)$'; what = 'a formula check whose sample formula holds a line break' }
)
foreach ($c in $cases) {
    $da = Detail $a $c.name; $db = Detail $b $c.name
    Check (($da -notmatch $c.whole) -and ($db -match $c.whole)) "$($c.what): old cut at the line break, new whole ($($da.Length) -> $($db.Length) chars)"
}
Check (-not ($b | Where-Object { $_ -like 'ASSERT,*' -and $_ -like '*RemoteException*' })) 'new code: no detail carries System.Management.Automation.RemoteException (a blank stderr line)'

# --- 5. non-ASCII header -----------------------------------------------------------------------
Write-Output ''
Write-Output "5. Non-ASCII header Caf$([char]0xE9) (table Accents): old and new print the same lines"
$a = Run "$old\tools\run-assertions.ps1" @('-Contract', $acc)
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $acc)
$b | Where-Object { $_ -like 'FINGERPRINT_OBSERVED,*' -or $_ -like 'SNAPSHOT*' } | ForEach-Object { Write-Output "      $_" }
$diff = if ($a.Count -and $b.Count) { @(Compare-Object $a $b -SyncWindow 0 -CaseSensitive) } else { @('empty') }
Check ($a.Count -gt 0 -and $diff.Count -eq 0) ("this console (code page {0}): {1} lines old, {2} new, {3}" -f [Console]::OutputEncoding.CodePage, $a.Count, $b.Count, $(if ($diff.Count) { "$($diff.Count) differ" } else { 'identical' }))
$orig = $null
try { $orig = [Console]::OutputEncoding.CodePage } catch { }
if ($orig) {
    try {
        $a = @(cmd /c "chcp 437 >nul & powershell -NoProfile -ExecutionPolicy Bypass -File `"$old\tools\run-assertions.ps1`" -Contract `"$acc`" 2>nul" | ForEach-Object { [string]$_ })
        $b = @(cmd /c "chcp 437 >nul & powershell -NoProfile -ExecutionPolicy Bypass -File `"$repo\tools\run-assertions.ps1`" -Contract `"$acc`" 2>nul" | ForEach-Object { [string]$_ })
    } finally { cmd /c "chcp $orig >nul" }
    $diff = if ($a.Count -and $b.Count) { @(Compare-Object $a $b -SyncWindow 0 -CaseSensitive) } else { @('empty') }
    $verdict = ($b | Where-Object { $_ -like 'ERROR,*' -or $_ -like 'FINGERPRINT,*' } | Select-Object -First 1)
    if ($verdict.Length -gt 90) { $verdict = $verdict.Substring(0, 90) + '...' }
    Check ($a.Count -gt 0 -and $diff.Count -eq 0) ("code page 437: {0} lines old, {1} new, {2} (new: {3})" -f $a.Count, $b.Count, $(if ($diff.Count) { "$($diff.Count) differ" } else { 'identical' }), $verdict)
} else {
    Write-Output '   SKIP  code page 437: this process has no console to switch'
}

# --- 6. NULL and empty @snapshot values --------------------------------------------------------
Write-Output ''
Write-Output '6. @snapshot values that are NULL (max over no rows) and empty (''''): old and new print the same lines'
$a = Run "$old\tools\run-assertions.ps1" @('-Contract', $nulls)
$b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $nulls)
Show "old code ($Baseline):" @($a | Where-Object { $_ -like 'SNAPSHOT*' })
Show 'new code:' @($b | Where-Object { $_ -like 'SNAPSHOT*' })
$diff = if ($a.Count -and $b.Count) { @(Compare-Object $a $b -SyncWindow 0 -CaseSensitive) } else { @('empty') }
Check ($a.Count -gt 0 -and $diff.Count -eq 0) ("{0} lines old, {1} new, {2}" -f $a.Count, $b.Count, $(if ($diff.Count) { "$($diff.Count) differ" } else { 'identical' }))
Check (($b -ccontains 'SNAPSHOT,none_max,NULL') -and ($b -ccontains 'SNAPSHOT,empty_text,') -and -not ($b | Where-Object { $_ -like 'SNAPSHOT_DRIFT,*' })) 'new code: NULL prints as NULL, empty as empty, and neither drifts from its committed value'

# --- 7. materialize ----------------------------------------------------------------------------
Write-Output ''
Write-Output '7. materialize.ps1: the line-break table into a scratch lake (Linebreak_Drift, so the checks pass)'
$lake = Join-Path $work 'lake'
$m = Run "$repo\tools\materialize.ps1" @('-Contract', $drift, '-LakeRoot', $lake) | Where-Object { $_ -like 'MATERIALIZE,*' }
Write-Output "      $m"
$q = Join-Path $work 'lake.sql'
[IO.File]::WriteAllText($q, (@(
    'LOAD ducklake;',
    "ATTACH 'ducklake:$($lake.Replace('\','/'))/lake.ducklake' AS lake (DATA_PATH '$($lake.Replace('\','/'))/data', READ_ONLY);",
    '.mode list', '.headers off',
    "SELECT to_json(list(column_name ORDER BY column_index)) FROM duckdb_columns() WHERE table_name = 'Linebreak_Drift';",
    "SELECT observed FROM lake.check_history WHERE check_id = 'FINGERPRINT';") -join "`r`n") + "`r`n", $utf8)
$r = @(& duckdb -f $q 2>&1 | ForEach-Object { [string]$_ })
$r | ForEach-Object { Write-Output "      $_" }
Check ($m -like 'MATERIALIZE,Linebreak_Drift,REFRESHED,4*') 'materialized 4 rows'
Check ($r -contains '["Job\nNumber","Cost \"Code\",\nType","Amount","Note\r\nText","Calc"]') 'the lake table keeps the real names (JSON above: \n and \r\n are the real line breaks)'
Check ($r -contains "Job\nNumber|Cost `"Code`",\nType|Amount|Note\nText|Calc") 'check_history.observed holds the fingerprint on one line, line breaks as \n'

# --- 8. regression -----------------------------------------------------------------------------
Write-Output ''
Write-Output "8. Every contract whose workbook is on this machine: code at $Baseline vs code now"
$contracts = @(Get-ChildItem "$repo\contracts\*.sql", "$repo\tests\contracts\*.sql" | Sort-Object FullName)
$compared = 0
foreach ($cf in $contracts) {
    $rel = $cf.FullName.Substring($repo.Length + 1)
    $m1 = [regex]::Match([IO.File]::ReadAllText($cf.FullName), "read_xlsx(?:_table|_name)?\(\s*'([^']+)'", 'IgnoreCase')
    if (-not $m1.Success -or -not (Test-Path -LiteralPath $m1.Groups[1].Value)) {
        Write-Output "   SKIP  ${rel}: workbook not on this machine"
        continue
    }
    $a = Run "$old\tools\run-assertions.ps1" @('-Contract', $cf.FullName)
    $b = Run "$repo\tools\run-assertions.ps1" @('-Contract', $cf.FullName)
    $compared++
    $diff = if ($a.Count -and $b.Count) { @(Compare-Object $a $b -SyncWindow 0 -CaseSensitive) } else { @('empty') }
    Check ($a.Count -gt 0 -and $diff.Count -eq 0) ("{0}: {1} lines old, {2} new, {3}" -f $rel, $a.Count, $b.Count, $(if ($diff.Count) { "$($diff.Count) differ" } else { 'identical' }))
    if ($diff.Count) { $diff | ForEach-Object { Write-Output "         $($_.SideIndicator) $($_.InputObject)" } }
}
Check ($compared -gt 0) "compared $compared of $($contracts.Count) contracts (none compared would prove nothing)"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
if ($fail) { Write-Output "RESULT: FAIL ($fail check(s) failed)"; exit 1 }
Write-Output 'RESULT: PASS (line-break headers run every check; details arrive whole; existing contracts print the same lines)'
