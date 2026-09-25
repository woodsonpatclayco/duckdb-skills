<#
tools\run-assertions.ps1 [-Contract <path>]

Multi-contract assertion harness (TASK.md item 5). No argument: discovers and runs
every *.sql directly under contracts\ (fixture contracts built by
make-truncation-fixtures.ps1 live in $env:TEMP, so they are never picked up here).
With -Contract: runs exactly one file, and accepts a path OUTSIDE contracts\ so a
fixture can be checked without becoming a discoverable "third contract".

SUPERSEDES vs CALLS check-contract.ps1: this script CALLS check-contract.ps1 for the
`-- @assert` results, run as a genuinely separate `powershell.exe -File` process (never
`&` in-process and never dot-sourced) -- check-contract.ps1 ends with `exit N`, which
would terminate THIS script's own host process if invoked any other way. Running it
unmodified, exactly as tools\check-contract.ps1 <file> would be run directly, is also
how item 4's grammar and both its guards are inherited VERBATIM rather than
re-implemented here: there is exactly one place that code exists.

This script owns everything item 4 did not: multi-contract discovery/aggregation, four
new additive directives it parses itself (see below), the truncation/orphan-column
detector, the anchor and rows-floor gates, and the fingerprint drift report.

Additive directives (deliverable 1) -- same comment form as `-- @assert`, same
before-any-heavy-read guard timing, same "missing or duplicated is an error, never
skipped" rule, but they do not alter item 4's `-- @assert` grammar or its two guards in
any way:
    -- @sheet: <sheet name>            (used for this script's OWN raw-sheet reads;
                                         the workbook PATH is never duplicated here --
                                         it is read out of the contract's own
                                         read_xlsx(...) call by regex, per the spec)
    -- @anchor: <bare column name>      (double-quoted by this script when building SQL,
                                         so a hostile name like `Job #` is written plain)
    -- @rows_floor: <integer>
    -- @fingerprint: <col1>|<col2>|...  (pipe-joined, in order, exactly as item 4's own
                                         committed header comment already does)
Each of the four is required exactly once; zero or more-than-one is an ERROR line for
that contract, and (matching item 4's Guard 2) a line that starts like a directive but
does not match the grammar is an ERROR too, never silently skipped.

Macro availability: skills/query/duckdb-compat.sql is resolved relative to
$PSScriptRoot (Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'), exactly
like tools\check-contract.ps1 -- never a hardcoded absolute path, so this also works
inside a `git worktree add` checkout at a different path, where .duckdb-skills\
(gitignored) does not exist.

Performance (deliverable 2): per contract, after the @assert results come back from
check-contract.ps1 (which pays its own one read per assertion -- unchanged, inherited),
this script pays exactly two more full reads: one to materialize contract_view into a
TEMP TABLE (so every check that queries contract_view afterwards is cheap, rather than
re-triggering the contract's own read_xlsx call each time) and one independent raw
all-columns read (also a TEMP TABLE) used ONLY for the orphan-column / truncation
detector, kept deliberately separate from contract_view's own data so that detector
never trusts the contract's own filter. A third, cheap, bind-only DESCRIBE-style probe
discovers the raw column list before either heavy read, so the all-null predicate can
be generated as literal SQL text naming every column (never the "COLUMNS(*) IS NULL"
shorthand -- see the predicate-generation block below, which is intentionally isolated
so each TASK.md mutation is a single-line edit).

Output contract (TASK.md deliverable 2, pinned so a caller can grep a line by its
label rather than parse prose): one CONTRACT,<name> per contract; one
ASSERT,<name>,<status>[,<detail>] per `-- @assert` (status is PASS/FAIL/ERROR, inherited
verbatim from check-contract.ps1); TRUNCATION_DEFAULT_ROWS / TRUNCATION_WITHDATA_ROWS /
TRUNCATION_ROWS_LOST; CONSISTENCY_VIEW_ROWS; ANCHOR,<name>,<nonnull>,<PASS|FAIL>;
ROWS_FLOOR,<floor>,<observed>,<PASS|FAIL>; FINGERPRINT,MATCH or FINGERPRINT,DRIFT
followed by FINGERPRINT_COMMITTED,<list> and FINGERPRINT_OBSERVED,<list> (drift is
reported, never a failure -- items 3+4's policy, retained); a directive or grammar
problem for a contract is ERROR,<contract>,<message> and that contract's heavy checks
are skipped entirely (guards run before any 68 MB read); and a final
SUMMARY,contracts=<n>,assertions=<n>,failures=<n> line. `failures` counts every
individual failing signal across the whole run (each non-PASS assertion, each ERROR,
each truncation/consistency/anchor/floor problem) -- not just failing contracts.
Exit code is non-zero iff failures > 0.
#>
param(
    [string]$Contract
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$contractsDir = Join-Path $repoRoot 'contracts'
$checkContractPath = Join-Path $PSScriptRoot 'check-contract.ps1'
$compatFullPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
$compatFwd = $compatFullPath -replace '\\', '/'

if (-not (Test-Path -LiteralPath $checkContractPath -PathType Leaf)) {
    Write-Output "ERROR: check-contract.ps1 not found at: $checkContractPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $compatFullPath -PathType Leaf)) {
    Write-Output "ERROR: duckdb-compat.sql not found at: $compatFullPath"
    exit 1
}

# --- discover contracts -------------------------------------------------------------

if ($Contract) {
    if (-not (Test-Path -LiteralPath $Contract -PathType Leaf)) {
        Write-Output "ERROR: contract file not found: $Contract"
        exit 1
    }
    $contractFiles = @([System.IO.Path]::GetFullPath($Contract))
} else {
    if (-not (Test-Path -LiteralPath $contractsDir -PathType Container)) {
        Write-Output "ERROR: contracts directory not found: $contractsDir"
        exit 1
    }
    $contractFiles = @(
        Get-ChildItem -LiteralPath $contractsDir -Filter '*.sql' -File |
            Sort-Object Name |
            ForEach-Object { $_.FullName }
    )
    if ($contractFiles.Count -eq 0) {
        Write-Output "ERROR: no contract files found in: $contractsDir"
        exit 1
    }
}

# --- helper: parse a single required additive directive family (e.g. @sheet) --------
# Same comment form and same before-any-heavy-read guard timing as item 4's @assert;
# does not touch or re-implement @assert's own grammar (that stays in check-contract.ps1).
function Get-DirectiveOccurrences {
    param([string[]]$Lines, [string]$Keyword)
    $linePattern = "^\s*--\s*@$Keyword\b"
    $fullPattern = "^\s*--\s*@$Keyword\s*:(.*)$"
    $values = New-Object System.Collections.Generic.List[string]
    $malformed = New-Object System.Collections.Generic.List[string]
    $ln = 0
    foreach ($line in $Lines) {
        $ln++
        if ($line -notmatch $linePattern) { continue }
        $m = [regex]::Match($line, $fullPattern)
        if (-not $m.Success) {
            $malformed.Add("line ${ln}: '@$Keyword' directive does not match grammar (missing ':'): $line")
            continue
        }
        $values.Add($m.Groups[1].Value.Trim())
    }
    [pscustomobject]@{ Values = $values; Malformed = $malformed }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$totalAssertions = 0
$totalFailures = 0
$contractCount = 0

foreach ($cf in $contractFiles) {
    $contractCount++
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($cf)
    Write-Output "CONTRACT,$baseName"

    # --- parse the four additive directives; BOTH guard families (missing/duplicate,
    # malformed line) run before anything heavy, same discipline as item 4's guards ---
    $lines = Get-Content -LiteralPath $cf
    $dirErrors = New-Object System.Collections.Generic.List[string]
    $dirValues = @{}

    foreach ($kw in @('sheet', 'anchor', 'rows_floor', 'fingerprint')) {
        $res = Get-DirectiveOccurrences -Lines $lines -Keyword $kw
        foreach ($e in $res.Malformed) { $dirErrors.Add($e) }
        if ($res.Malformed.Count -eq 0) {
            if ($res.Values.Count -eq 0) {
                $dirErrors.Add("missing required directive: -- @$kw")
            } elseif ($res.Values.Count -gt 1) {
                $dirErrors.Add("duplicate directive: -- @$kw (found $($res.Values.Count) times)")
            } else {
                $dirValues[$kw] = $res.Values[0]
            }
        }
    }

    $rowsFloorInt = 0
    if ($dirValues.ContainsKey('rows_floor') -and -not [int]::TryParse($dirValues['rows_floor'], [ref]$rowsFloorInt)) {
        $dirErrors.Add("'@rows_floor' value is not an integer: $($dirValues['rows_floor'])")
    }

    if ($dirErrors.Count -gt 0) {
        foreach ($e in $dirErrors) {
            Write-Output "ERROR,$baseName,$e"
            $totalFailures++
        }
        continue
    }

    $sheetName = $dirValues['sheet']
    $anchorExpr = $dirValues['anchor']
    $rowsFloor = $rowsFloorInt
    $committedFingerprint = $dirValues['fingerprint']

    # Workbook path is read from the contract's OWN read_xlsx(...) call -- never
    # duplicated into a directive, per the spec ("the two could disagree").
    $rawText = Get-Content -LiteralPath $cf -Raw
    $pathMatch = [regex]::Match($rawText, "read_xlsx\(\s*'([^']+)'", 'IgnoreCase')
    if (-not $pathMatch.Success) {
        Write-Output "ERROR,$baseName,could not find read_xlsx(<path>, ...) in contract file"
        $totalFailures++
        continue
    }
    $workbookPathFwd = ($pathMatch.Groups[1].Value) -replace '\\', '/'
    $cfFwd = ([System.IO.Path]::GetFullPath($cf)) -replace '\\', '/'

    # --- ASSERT results: delegate to check-contract.ps1 verbatim, as a genuinely
    # separate process (see header comment: it calls `exit`). ---------------------------
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ccOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $checkContractPath $cf 2>&1
    $ccExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    $ccLines = @($ccOutput | ForEach-Object { [string]$_ })
    $sawBlockingError = $false
    $assertionsThisContract = 0

    foreach ($line in $ccLines) {
        if ($line -match '^(PASS|FAIL|ERROR)\s+([A-Za-z0-9_]+)(:\s*(.*))?$') {
            $status = $Matches[1]
            $name = $Matches[2]
            $detail = $Matches[4]
            if ($detail) {
                Write-Output "ASSERT,$name,$status,$detail"
            } else {
                Write-Output "ASSERT,$name,$status"
            }
            $totalAssertions++
            $assertionsThisContract++
            if ($status -ne 'PASS') { $totalFailures++ }
        } elseif ($line -match '^GUARD [12] FAILED') {
            Write-Output "ERROR,$baseName,$line"
            $sawBlockingError = $true
            $totalFailures++
        } elseif ($line -match '^ERROR:') {
            Write-Output "ERROR,$baseName,$line"
            $sawBlockingError = $true
            $totalFailures++
        }
        # lines like "assertion_count=N" and the guard's indented detail lines are
        # informational only and are not re-emitted -- the ASSERT/ERROR lines above
        # already carry everything a caller needs.
    }

    if ($ccExitCode -ne 0 -and -not $sawBlockingError -and $assertionsThisContract -eq 0) {
        Write-Output "ERROR,$baseName,check-contract.ps1 exited $ccExitCode with no parsed assertions"
        $totalFailures++
        $sawBlockingError = $true
    }

    if ($sawBlockingError) {
        # A guard failure means the file is malformed at the @assert level. Per items
        # 3+4's own rule ("both guards run before the view is created, so a malformed
        # contract fails without paying the 68 MB read"), this script's own heavy reads
        # below are skipped too -- there is nothing reliable left to check.
        continue
    }

    # --- Phase 1: cheap, bind-only discovery of every column the RAW sheet returns.
    # MUTATION POINT (TASK.md: "narrow the all-null predicate to the contract's
    # projected columns"): replacing the $rawColumns assignment below with
    # ($committedFingerprint -split '\|') is exactly that mutation -- sourcing the
    # predicate from the contract's own declared columns instead of an independent
    # read of the sheet, which is the orphan-column defect this script must not have. --
    $scratchDir = Join-Path $env:TEMP "run-assertions-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

    try {
        $describeSql = ".mode csv`r`n.headers off`r`n" +
            "CREATE OR REPLACE VIEW _raw_probe AS SELECT * FROM read_xlsx('$workbookPathFwd', sheet = '$sheetName', all_varchar = true, stop_at_empty = false);`r`n" +
            "SELECT column_name FROM duckdb_columns() WHERE table_name = '_raw_probe' ORDER BY column_index;`r`n"
        $describeFile = Join-Path $scratchDir 'describe.sql'
        [System.IO.File]::WriteAllText($describeFile, $describeSql, $utf8NoBom)

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $describeOutput = & duckdb -f $describeFile 2>&1
        $describeExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap

        if ($describeExit -ne 0) {
            $msg = (($describeOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
            Write-Output "ERROR,$baseName,duckdb exited ${describeExit} while discovering raw columns: $msg"
            $totalFailures++
            continue
        }

        $rawColumns = @($describeOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })
        # ---- MUTATION POINT ends here: $rawColumns is "every column read_xlsx
        # returns", discovered independently of the contract's own projection. ----

        if ($rawColumns.Count -eq 0) {
            Write-Output "ERROR,$baseName,no columns discovered for sheet '$sheetName'"
            $totalFailures++
            continue
        }

        # --- Generate the all-null predicate EXPLICITLY over every raw column above.
        # MUTATION POINT (TASK.md: "swap the generated predicate for
        # NOT (COLUMNS(*) IS NULL)"): replacing the $withDataWhere assignment below
        # with the literal string 'NOT (COLUMNS(*) IS NULL)' is exactly that mutation --
        # that shorthand means "no column is null" (keep only fully-populated rows),
        # not "at least one column is non-null", and is banned by the spec for exactly
        # that reason. ---------------------------------------------------------------
        $quotedCols = $rawColumns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }
        $allNullPredicate = ($quotedCols | ForEach-Object { "$_ IS NULL" }) -join ' AND '
        $withDataWhere = "NOT ($allNullPredicate)"
        # ---- MUTATION POINT ends here. ----

        $anchorSql = 'count("' + ($anchorExpr -replace '"', '""') + '")'

        # --- Phase 2: one heavy invocation per contract. Materializes contract_view
        # once (so every later reference to it is cheap) and separately materializes
        # an independent raw with-data read (also once) for the orphan-column /
        # truncation detector. MUTATION POINT (TASK.md: "remove stop_at_empty = false
        # from the fixture-A check path"): change `stop_at_empty = false` to
        # `stop_at_empty = true` (or drop the option) on the _raw_withdata line below.
        # MUTATION POINT (TASK.md: "remove the all-null filter"): drop the
        # "WHERE $withDataWhere" clause from the same line. ----------------------------
        $body = New-Object System.Text.StringBuilder
        [void]$body.Append(".mode csv`r`n.headers off`r`n")
        [void]$body.Append(".read '$compatFwd'`r`n")
        [void]$body.Append(".read '$cfFwd'`r`n")
        [void]$body.Append("CREATE OR REPLACE TEMP TABLE _contract_data AS SELECT * FROM contract_view;`r`n")
        [void]$body.Append("CREATE OR REPLACE VIEW contract_view AS SELECT * FROM _contract_data;`r`n")
        [void]$body.Append("CREATE OR REPLACE TEMP TABLE _raw_withdata AS SELECT * FROM read_xlsx('$workbookPathFwd', sheet = '$sheetName', all_varchar = true, stop_at_empty = false) WHERE $withDataWhere;`r`n")
        # ---- MUTATION POINT ends here (the _raw_withdata line above). ----
        [void]$body.Append("SELECT 'DEFAULT_ROWS', count(*) FROM read_xlsx('$workbookPathFwd', sheet = '$sheetName');`r`n")
        [void]$body.Append("SELECT 'WITHDATA_ROWS', count(*) FROM _raw_withdata;`r`n")
        [void]$body.Append("SELECT 'VIEW_ROWS', count(*) FROM contract_view;`r`n")
        [void]$body.Append("SELECT 'ANCHOR_TOTAL', count(*) FROM contract_view;`r`n")
        [void]$body.Append("SELECT 'ANCHOR_NONNULL', $anchorSql FROM contract_view;`r`n")
        [void]$body.Append("SELECT 'FINGERPRINT_OBSERVED', string_agg(column_name, '|' ORDER BY column_index) FROM duckdb_columns() WHERE table_name = 'contract_view';`r`n")

        $bodyFile = Join-Path $scratchDir 'phase2.sql'
        [System.IO.File]::WriteAllText($bodyFile, $body.ToString(), $utf8NoBom)

        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $phase2Output = & duckdb -f $bodyFile 2>&1
        $phase2Exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap

        if ($phase2Exit -ne 0) {
            $msg = (($phase2Output | ForEach-Object { [string]$_ }) -join ' | ').Trim()
            Write-Output "ERROR,$baseName,duckdb exited ${phase2Exit}: $msg"
            $totalFailures++
            continue
        }

        $values = @{}
        foreach ($line in ($phase2Output | ForEach-Object { [string]$_ })) {
            $m2 = [regex]::Match($line, '^([^,]+),(.*)$')
            if ($m2.Success) {
                $values[$m2.Groups[1].Value] = $m2.Groups[2].Value
            }
        }

        foreach ($k in @('DEFAULT_ROWS', 'WITHDATA_ROWS', 'VIEW_ROWS', 'ANCHOR_TOTAL', 'ANCHOR_NONNULL', 'FINGERPRINT_OBSERVED')) {
            if (-not $values.ContainsKey($k)) {
                Write-Output "ERROR,$baseName,expected value '$k' missing from phase 2 output"
                $totalFailures++
                continue
            }
        }
        if (-not ($values.ContainsKey('DEFAULT_ROWS') -and $values.ContainsKey('WITHDATA_ROWS') -and $values.ContainsKey('VIEW_ROWS') -and $values.ContainsKey('ANCHOR_TOTAL') -and $values.ContainsKey('ANCHOR_NONNULL') -and $values.ContainsKey('FINGERPRINT_OBSERVED'))) {
            continue
        }

        $defaultRows = [int64]$values['DEFAULT_ROWS']
        $withDataRows = [int64]$values['WITHDATA_ROWS']
        $viewRows = [int64]$values['VIEW_ROWS']
        $anchorTotal = [int64]$values['ANCHOR_TOTAL']
        $anchorNonNull = [int64]$values['ANCHOR_NONNULL']
        $observedFingerprint = $values['FINGERPRINT_OBSERVED']

        $rowsLost = $withDataRows - $defaultRows
        Write-Output "TRUNCATION_DEFAULT_ROWS,$defaultRows"
        Write-Output "TRUNCATION_WITHDATA_ROWS,$withDataRows"
        Write-Output "TRUNCATION_ROWS_LOST,$rowsLost"
        if ($rowsLost -ne 0) { $totalFailures++ }

        Write-Output "CONSISTENCY_VIEW_ROWS,$viewRows"
        if ($viewRows -ne $withDataRows) { $totalFailures++ }

        $anchorStatus = if ($anchorNonNull -eq $anchorTotal) { 'PASS' } else { 'FAIL' }
        Write-Output "ANCHOR,$anchorExpr,$anchorNonNull,$anchorStatus"
        if ($anchorStatus -ne 'PASS') { $totalFailures++ }

        $floorStatus = if ($viewRows -ge $rowsFloor) { 'PASS' } else { 'FAIL' }
        Write-Output "ROWS_FLOOR,$rowsFloor,$viewRows,$floorStatus"
        if ($floorStatus -ne 'PASS') { $totalFailures++ }

        if ($observedFingerprint -eq $committedFingerprint) {
            Write-Output 'FINGERPRINT,MATCH'
        } else {
            Write-Output 'FINGERPRINT,DRIFT'
            Write-Output "FINGERPRINT_COMMITTED,$committedFingerprint"
            Write-Output "FINGERPRINT_OBSERVED,$observedFingerprint"
        }
    } finally {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "SUMMARY,contracts=$contractCount,assertions=$totalAssertions,failures=$totalFailures"

if ($totalFailures -gt 0) {
    exit 1
}
exit 0
