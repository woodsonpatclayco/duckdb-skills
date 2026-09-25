<#
tools\materialize.ps1 [-Contract <path>] [-Force] [-LakeRoot <absolute path>]

TASK.md item 6: materializes contracts into a DuckLake lakehouse, with a four-way
freshness key and a check history. Default: every contract in contracts\. Lake at
~\.duckdb-skills\<project-id>\lake\lake.ducklake, DATA_PATH at ...\lake\data
alongside it -- resolved via tools\dsk-paths.ps1's Resolve-LakeRoot, same shape and
same absolute-path rejection as Resolve-ExtractRoot.

Per contract: decide (four-way freshness: workbook mtime, workbook SHA-256, contract
SHA-256, compat SHA-256, plus a target-still-exists check that overrides a clean
hash match) -> SKIP, or run tools\run-assertions.ps1 -Contract <file> as a genuinely
separate process (it calls `exit`, same reason tools\run-assertions.ps1 itself calls
tools\check-contract.ps1 that way) -> gate on ITS exit code, never a re-derived rule
-> REFUSE (leave the lake table untouched, write check_history rows with
outcome=REFUSED) or MATERIALIZE (CREATE OR REPLACE TABLE, then write manifest +
check_history rows sharing one run_id, outcome=MATERIALIZED, or FORCED if -Force
overrode a checks failure).

Why the workbook hash goes through DuckDB, never Get-FileHash: measured this
session, Get-FileHash's exception on a FileShare.None-locked file is a plain
.NET message with no process name or PID ("The process cannot access the file
because it is being used by another process."). DuckDB's own file layer enriches
the identical Win32 error with the holder's name and PID ("File is already open
in ...powershell.exe (PID 189248)") -- the exact shape TASK.md's measured facts
pin and AC18 requires verbatim. So the workbook is hashed via
`SELECT sha256(content) FROM read_blob('<path>')`, confirmed this session to equal
Get-FileHash's own SHA-256 (case aside) on an unlocked file. This read happens
BEFORE the lake is touched at all, so a locked workbook fails loudly with zero
lake interaction -- trivially satisfying "the previous lake table ... unchanged".

Why DuckLake's catalog lock gets no retry loop: PLAN-4's first draft built one on
a false premise (a constant-folded delay that never produced real overlap). Re-
measured with a non-foldable delay, DuckLake's own file lock on lake.ducklake is
the serializer -- the losing ATTACH fails immediately with the same PID-naming
shape. This script reports that error verbatim and names ducklake_max_retry_count
as the tuning knob; it does not retry, and it does not process further contracts
in the same invocation once this happens (the lock is a whole-lake condition, not
a per-contract one).

Every DuckDB invocation is a fresh `duckdb -f <file>` process -- there is no
persistent session across them, so every one re-issues its own `LOAD ducklake;`
and `ATTACH ...;`. Bundled queries use `.mode csv` / `.headers off` with a literal
label as the first field per result line (the same idiom tools\run-assertions.ps1
uses for its own phase-2 batch), parsed with a fixed-count `-split ',', n` --
never a full CSV parser -- because every field this script asks DuckDB to print
back (hashes, timestamps, booleans, integers, PASS/FAIL/DRIFT/MATCH tokens) is by
construction comma-free and quote-free. Fields that are NOT guaranteed comma-free
(an assertion's error detail, a snapshot's textual value) are only ever written
INTO the lake as SQL string literals, never read back through this label/CSV
convention.

Compat-macro and contract-directive access mirrors tools\check-contract.ps1 and
tools\run-assertions.ps1: skills\query\duckdb-compat.sql is resolved relative to
$PSScriptRoot, never a hardcoded absolute path, so this also works inside a
`git worktree add` checkout where .duckdb-skills\ (gitignored) does not exist.

check_history population, one design choice not fully pinned by TASK.md's own
"assigning kind and status" table (which only pins status, not observed/committed):
  - ASSERT rows: observed = the emitted status, committed = NULL. TASK.md is
    explicit here -- the harness emits no value for @assert lines, and this
    script must not recompute an assertion's expression (a second evaluation is
    a second source of truth).
  - ANCHOR: observed = the emitted non-null count; committed = the row total,
    read from the CONSISTENCY_VIEW_ROWS line already parsed earlier in the same
    stream (ANCHOR_TOTAL is never itself printed by the harness).
  - ROWS_FLOOR: observed = the emitted row count; committed = the emitted floor
    -- both already in the harness's own ROWS_FLOOR line, no re-derivation.
  - TRUNCATION_ROWS_LOST: observed = the emitted count; committed = the literal
    "0" it is compared against.
  - CONSISTENCY_VIEW_ROWS: observed = the emitted view-row count; committed =
    the TRUNCATION_WITHDATA_ROWS value already parsed earlier in the same stream.
  - FINGERPRINT: on MATCH, the harness prints no fingerprint text at all (only
    on DRIFT does it print FINGERPRINT_COMMITTED / FINGERPRINT_OBSERVED) -- so on
    MATCH this script reads the contract's own committed `-- @fingerprint:`
    directive text (a static literal already required to exist by the harness's
    own guard, not a recomputation) and uses it for both columns, since MATCH
    proves them equal by construction. On DRIFT it uses the two lines verbatim.
  - SNAPSHOT,<name>: observed = the emitted value; committed = the contract's own
    `-- @snapshot_committed <name>:` literal, read the same way as the
    fingerprint case above -- always available, whether or not this run drifted.
  - A harness-level ERROR,<contract>,<message> line (a guard failure, or a
    DuckDB error inside run-assertions.ps1's own reads) is recorded as a single
    check_history row per ERROR line: check_id=HARNESS_ERROR, kind=invariant,
    status=ERROR, observed=<message>, committed=NULL. TASK.md's kind-assignment
    table does not cover this line shape (it is not an @assert/@snapshot/etc
    line at all); without recording it, a guard failure would refuse
    materialization (correctly) but leave no trace in check_history of why.

Manifest rows are written for every attempt that reaches a decision -- REFUSED
included, not just MATERIALIZED/FORCED -- because check_history carries no
materialized_at of its own (only manifest does), and tools\lake-status.ps1's
-AsOf/-History views need to date a refused attempt to answer "did a later
REFUSED run change the data" at all. Only SKIPPED writes no rows to either
table, exactly as TASK.md specifies.

lake_snapshot_id semantics: for a MATERIALIZED/FORCED row, it is captured in the
SAME invocation as the CREATE OR REPLACE TABLE, immediately after it, via
`SELECT max(snapshot_id) FROM lake.snapshots()` -- literally "the snapshot this
write produced". The manifest and check_history INSERTs happen in a SEPARATE,
later invocation (each is its own snapshot in turn), so they never overwrite
that captured value -- this is why AC8 must read lake_snapshot_id from the
manifest row rather than assuming a version literal. For a REFUSED row, no table
write happens, so the value carried forward is whatever the previous manifest
row for this contract already recorded (NULL if there has never been a
successful run) -- this is what makes AC12's "unchanged max snapshot_id for that
contract" provable: the refusal's own manifest row records the identical value.
#>
param(
    [string]$Contract,
    [switch]$Force,
    [string]$LakeRoot
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsk-paths.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$contractsDir = Join-Path $repoRoot 'contracts'
$runAssertionsPath = Join-Path $PSScriptRoot 'run-assertions.ps1'
$compatFullPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
$compatFwd = $compatFullPath -replace '\\', '/'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $runAssertionsPath -PathType Leaf)) {
    Write-Output "ERROR: run-assertions.ps1 not found at: $runAssertionsPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $compatFullPath -PathType Leaf)) {
    Write-Output "ERROR: duckdb-compat.sql not found at: $compatFullPath"
    exit 1
}

$lakeRootResolved, $usedDefaultLakeRoot = Resolve-LakeRoot -ExplicitRoot $LakeRoot
$lakeCatalogFile = Join-Path $lakeRootResolved 'lake.ducklake'
$lakeDataDir = Join-Path $lakeRootResolved 'data'
if (-not (Test-Path -LiteralPath $lakeDataDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $lakeDataDir | Out-Null
}
$lakeCatalogFwd = $lakeCatalogFile -replace '\\', '/'
$lakeDataDirFwd = $lakeDataDir -replace '\\', '/'
Write-Output "LAKE_ROOT,$lakeRootResolved"

$compatSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $compatFullPath).Hash.ToLowerInvariant()

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

# --- small helpers -------------------------------------------------------------------

function Invoke-DuckdbBatch {
    # Runs a fresh `duckdb -f <file>` process (never a persistent session --
    # confirmed this project has no such thing). Caller supplies the statements;
    # this helper prepends `.mode csv` / `.headers off` so every labelled SELECT
    # in the caller's text prints as one plain comma-joined line.
    param([string]$Sql)
    $scratchDir = Join-Path $env:TEMP "dsk-materialize-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    try {
        $body = ".mode csv`r`n.headers off`r`n" + $Sql
        $f = Join-Path $scratchDir 'batch.sql'
        [System.IO.File]::WriteAllText($f, $body, $utf8NoBom)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & duckdb -f $f 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $lines = @($out | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $exit; Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-SqlLiteral {
    # VARCHAR literal, single-quote-doubled. $null -> the bare word NULL (unquoted).
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function Get-CsvField {
    # Splits a labelled `.mode csv` line into exactly $Count comma-separated parts.
    # Safe ONLY for the label/value shapes this script generates itself -- every
    # field involved (hashes, timestamps, booleans, integers, tokens) is by
    # construction comma-free and quote-free (see header comment).
    param([string]$Line, [int]$Count)
    $parts = $Line -split ',', $Count
    return $parts
}

function ConvertFrom-SqlNull {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq 'NULL') { return $null }
    return $Text
}

function Get-ContractDirectiveLiteral {
    # Reads a single required directive's raw text (e.g. @fingerprint) straight
    # from the contract file -- a literal already required to exist by
    # run-assertions.ps1's own guards, never a recomputation of anything.
    param([string[]]$Lines, [string]$Keyword)
    $pattern = "^\s*--\s*@$Keyword\s*:(.*)$"
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return $null
}

function Get-ContractSnapshotCommitted {
    # Reads every `-- @snapshot_committed <name>: <literal>` directive from the
    # contract file into a name -> literal map. Same non-recomputation rationale.
    param([string[]]$Lines)
    $map = @{}
    $pattern = '^\s*--\s*@snapshot_committed\s+([A-Za-z0-9_]+)\s*:(.*)$'
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    }
    return $map
}

# --- per-contract processing ----------------------------------------------------------

$summaryRefreshed = 0
$summarySkipped = 0
$summaryRefused = 0
$summaryForced = 0
$anyRefused = $false

foreach ($cf in $contractFiles) {
    $contractName = [System.IO.Path]::GetFileNameWithoutExtension($cf)
    $contractLines = Get-Content -LiteralPath $cf
    $contractRawText = Get-Content -LiteralPath $cf -Raw

    $pathMatch = [regex]::Match($contractRawText, "read_xlsx\(\s*'([^']+)'", 'IgnoreCase')
    if (-not $pathMatch.Success) {
        Write-Output "ERROR,$contractName,could not find read_xlsx(<path>, ...) in contract file"
        $anyRefused = $true
        continue
    }
    $workbookPathFwd = $pathMatch.Groups[1].Value -replace '\\', '/'
    $workbookPathWin = $pathMatch.Groups[1].Value -replace '/', '\'

    $committedFingerprint = Get-ContractDirectiveLiteral -Lines $contractLines -Keyword 'fingerprint'
    $snapshotCommittedMap = Get-ContractSnapshotCommitted -Lines $contractLines

    # --- Hash the workbook via DuckDB, never Get-FileHash (see header comment).
    # This happens BEFORE the lake is touched at all, so a lock here means zero
    # lake interaction -- and it happens on every invocation, unconditionally,
    # because the decision needs it regardless of what else has or hasn't
    # changed (AC2: this is required by the decision, not a defect). ------------
    $hashSql = "SELECT 'WBHASH', sha256(content) FROM read_blob('$workbookPathFwd');`r`n"
    $hashResult = Invoke-DuckdbBatch -Sql $hashSql
    $wbHashLine = $hashResult.Lines | Where-Object { $_ -like 'WBHASH,*' } | Select-Object -First 1
    if (-not $wbHashLine) {
        Write-Output "MATERIALIZE,$contractName,ERROR"
        foreach ($l in $hashResult.Lines) { Write-Output $l }
        Write-Output "ERROR,$contractName,could not read workbook at $workbookPathWin (see output above)"
        exit 1
    }
    $sourceSha256 = (Get-CsvField -Line $wbHashLine -Count 2)[1]

    if (-not (Test-Path -LiteralPath $workbookPathWin -PathType Leaf)) {
        Write-Output "ERROR,$contractName,workbook path does not exist: $workbookPathWin"
        $anyRefused = $true
        continue
    }
    $sourceMtime = (Get-Item -LiteralPath $workbookPathWin).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')

    $contractSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $cf).Hash.ToLowerInvariant()

    # --- decide: attach the lake, ensure the two tables exist, read the latest
    # manifest row for this contract, and check the target's own existence/row
    # count. A DuckLake catalog lock surfaces here (ATTACH is the very first
    # statement) -- report it verbatim, name ducklake_max_retry_count, and stop
    # the whole run without retrying (the lock is a whole-lake condition). -------
    $decideSql = @"
LOAD ducklake;
ATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd');
CREATE TABLE IF NOT EXISTS lake.manifest (run_id UUID, materialized_at TIMESTAMP, contract_name VARCHAR, source_path VARCHAR, source_mtime TIMESTAMP, source_sha256 VARCHAR, contract_sha256 VARCHAR, compat_sha256 VARCHAR, row_count BIGINT, lake_snapshot_id BIGINT, checks_passed BOOLEAN, forced BOOLEAN);
CREATE TABLE IF NOT EXISTS lake.check_history (run_id UUID, contract_name VARCHAR, check_id VARCHAR, kind VARCHAR, status VARCHAR, observed VARCHAR, committed VARCHAR, outcome VARCHAR);
SELECT 'ATTACHED', 1;
SELECT 'LATEST', source_mtime, source_sha256, contract_sha256, compat_sha256, checks_passed, lake_snapshot_id FROM lake.manifest WHERE contract_name = $(ConvertTo-SqlLiteral $contractName) ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1;
SELECT 'TARGET_ROWS', count(*) FROM lake.$contractName;
"@
    $decideResult = Invoke-DuckdbBatch -Sql $decideSql
    $attachedLine = $decideResult.Lines | Where-Object { $_ -like 'ATTACHED,*' } | Select-Object -First 1
    $latestLine = $decideResult.Lines | Where-Object { $_ -like 'LATEST,*' } | Select-Object -First 1
    $targetRowsLine = $decideResult.Lines | Where-Object { $_ -like 'TARGET_ROWS,*' } | Select-Object -First 1

    if (-not $attachedLine) {
        # The ATTACHED marker never printed: LOAD/ATTACH/CREATE TABLE never
        # completed -- a DuckLake catalog lock (or some other attach-time
        # failure). Report verbatim, name the retry knobs, do not retry.
        Write-Output "MATERIALIZE,$contractName,ERROR"
        foreach ($l in $decideResult.Lines) { Write-Output $l }
        Write-Output "NOTE: DuckLake's own catalog lock is the serializer; see ducklake_max_retry_count / ducklake_retry_backoff / ducklake_retry_wait_ms. No retry attempted."
        exit 1
    }

    $prevMtime = $null; $prevSha = $null; $prevContractSha = $null; $prevCompatSha = $null
    $prevChecksPassed = $null; $prevSnapshotId = $null
    if ($latestLine) {
        $f = Get-CsvField -Line $latestLine -Count 7
        $prevMtime = ConvertFrom-SqlNull $f[1]
        $prevSha = ConvertFrom-SqlNull $f[2]
        $prevContractSha = ConvertFrom-SqlNull $f[3]
        $prevCompatSha = ConvertFrom-SqlNull $f[4]
        $prevChecksPassedText = ConvertFrom-SqlNull $f[5]
        if ($null -ne $prevChecksPassedText) { $prevChecksPassed = ($prevChecksPassedText -eq 'true') }
        $prevSnapshotIdText = ConvertFrom-SqlNull $f[6]
        if ($null -ne $prevSnapshotIdText) { $prevSnapshotId = [int64]$prevSnapshotIdText }
    }
    $targetRowCount = 0
    if ($targetRowsLine) { $targetRowCount = [int64](Get-CsvField -Line $targetRowsLine -Count 2)[1] }
    $targetExists = [bool]$targetRowsLine

    # --- the decision itself, in priority order (see header + TASK.md deliverable 1) ---
    $decision = 'SKIP'
    $reason = $null
    if ($null -eq $latestLine) {
        $decision = 'REFRESH'; $reason = 'no_manifest'
    } elseif ($prevChecksPassed -eq $false) {
        $decision = 'REFRESH'; $reason = 'previous_checks_failed'
    } elseif (-not $targetExists -or $targetRowCount -le 0) {
        $decision = 'REFRESH'; $reason = 'target_missing'
    } else {
        $changed = New-Object System.Collections.Generic.List[string]
        if ($prevMtime -ne $sourceMtime) { $changed.Add('workbook_mtime') }
        if ($prevSha -ne $sourceSha256) { $changed.Add('workbook_sha256') }
        if ($prevContractSha -ne $contractSha256) { $changed.Add('contract_sha256') }
        if ($prevCompatSha -ne $compatSha256) { $changed.Add('compat_sha256') }
        if ($changed.Count -gt 0) {
            $decision = 'REFRESH'; $reason = ($changed -join '+')
        }
    }

    if ($decision -eq 'SKIP') {
        Write-Output "MATERIALIZE,$contractName,SKIPPED"
        $summarySkipped++
        continue
    }

    # --- run the checks: a genuinely separate process, exactly as run-assertions.ps1
    # itself does for check-contract.ps1 (it calls `exit`, which would otherwise
    # terminate THIS script). Gate on ITS exit code, never a re-derived rule. --------
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $harnessOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $runAssertionsPath -Contract $cf 2>&1
    $harnessExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $harnessLines = @($harnessOutput | ForEach-Object { [string]$_ })
    $checksPassed = ($harnessExitCode -eq 0)

    # --- parse the harness's own output into check_history row candidates ----------
    $checkRows = New-Object System.Collections.Generic.List[object]
    $withDataRows = $null
    $viewRows = $null
    $fingerprintStatus = $null
    $fingerprintCommittedObs = $null
    $fingerprintObservedObs = $null
    $snapshotValues = @{}
    $snapshotDrift = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($line in $harnessLines) {
        if ($line -match '^ASSERT,([^,]+),([^,]+)(?:,(.*))?$') {
            $name = $Matches[1]; $status = $Matches[2]
            $kind = if ($name -like '*_floor') { 'floor' } else { 'invariant' }
            $checkRows.Add([pscustomobject]@{ CheckId = $name; Kind = $kind; Status = $status; Observed = $status; Committed = $null })
        } elseif ($line -match '^TRUNCATION_WITHDATA_ROWS,(\d+)$') {
            $withDataRows = $Matches[1]
        } elseif ($line -match '^TRUNCATION_ROWS_LOST,(\d+)$') {
            $n = $Matches[1]
            $status = if ([int64]$n -eq 0) { 'PASS' } else { 'FAIL' }
            $checkRows.Add([pscustomobject]@{ CheckId = 'TRUNCATION_ROWS_LOST'; Kind = 'invariant'; Status = $status; Observed = $n; Committed = '0' })
        } elseif ($line -match '^CONSISTENCY_VIEW_ROWS,(\d+)$') {
            $viewRows = $Matches[1]
            $status = if ($viewRows -eq $withDataRows) { 'PASS' } else { 'FAIL' }
            $checkRows.Add([pscustomobject]@{ CheckId = 'CONSISTENCY_VIEW_ROWS'; Kind = 'invariant'; Status = $status; Observed = $viewRows; Committed = $withDataRows })
        } elseif ($line -match '^ANCHOR,(.*),(\d+),(PASS|FAIL)$') {
            $obs = $Matches[2]; $status = $Matches[3]
            $checkRows.Add([pscustomobject]@{ CheckId = 'ANCHOR'; Kind = 'invariant'; Status = $status; Observed = $obs; Committed = $viewRows })
        } elseif ($line -match '^ROWS_FLOOR,(\d+),(\d+),(PASS|FAIL)$') {
            $floor = $Matches[1]; $obs = $Matches[2]; $status = $Matches[3]
            $checkRows.Add([pscustomobject]@{ CheckId = 'ROWS_FLOOR'; Kind = 'floor'; Status = $status; Observed = $obs; Committed = $floor })
        } elseif ($line -match '^FINGERPRINT,(MATCH|DRIFT)$') {
            $fingerprintStatus = if ($Matches[1] -eq 'MATCH') { 'PASS' } else { 'DRIFT' }
        } elseif ($line -match '^FINGERPRINT_COMMITTED,(.*)$') {
            $fingerprintCommittedObs = $Matches[1]
        } elseif ($line -match '^FINGERPRINT_OBSERVED,(.*)$') {
            $fingerprintObservedObs = $Matches[1]
        } elseif ($line -match '^SNAPSHOT,([A-Za-z0-9_]+),(.*)$') {
            $snapshotValues[$Matches[1]] = $Matches[2]
        } elseif ($line -match '^SNAPSHOT_DRIFT,([A-Za-z0-9_]+),') {
            [void]$snapshotDrift.Add($Matches[1])
        } elseif ($line -match '^ERROR,([^,]+),(.*)$') {
            Write-Output $line
            $checkRows.Add([pscustomobject]@{ CheckId = 'HARNESS_ERROR'; Kind = 'invariant'; Status = 'ERROR'; Observed = $Matches[2]; Committed = $null })
        }
    }
    if ($fingerprintStatus) {
        if ($fingerprintStatus -eq 'PASS') {
            $checkRows.Add([pscustomobject]@{ CheckId = 'FINGERPRINT'; Kind = 'snapshot'; Status = 'PASS'; Observed = $committedFingerprint; Committed = $committedFingerprint })
        } else {
            $checkRows.Add([pscustomobject]@{ CheckId = 'FINGERPRINT'; Kind = 'snapshot'; Status = 'DRIFT'; Observed = $fingerprintObservedObs; Committed = $fingerprintCommittedObs })
        }
    }
    foreach ($sn in $snapshotValues.Keys) {
        $status = if ($snapshotDrift.Contains($sn)) { 'DRIFT' } else { 'PASS' }
        $committed = $snapshotCommittedMap[$sn]
        $checkRows.Add([pscustomobject]@{ CheckId = $sn; Kind = 'snapshot'; Status = $status; Observed = $snapshotValues[$sn]; Committed = $committed })
    }

    $runId = [guid]::NewGuid().ToString()
    $forced = [bool]($Force -and -not $checksPassed)

    if (-not $checksPassed -and -not $Force) {
        # --- REFUSE: leave the lake table untouched; write manifest + check_history
        # rows so the attempt is dated and visible, but no new table snapshot. ------
        $outcome = 'REFUSED'
        $rowCountLiteral = 'NULL'
        $snapshotLiteral = if ($null -ne $prevSnapshotId) { $prevSnapshotId } else { 'NULL' }

        $insertSql = New-Object System.Text.StringBuilder
        [void]$insertSql.Append("LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd');`r`n")
        [void]$insertSql.Append("INSERT INTO lake.manifest VALUES ('$runId'::UUID, timezone('UTC', now())::TIMESTAMP, $(ConvertTo-SqlLiteral $contractName), $(ConvertTo-SqlLiteral $workbookPathFwd), '$sourceMtime'::TIMESTAMP, $(ConvertTo-SqlLiteral $sourceSha256), $(ConvertTo-SqlLiteral $contractSha256), $(ConvertTo-SqlLiteral $compatSha256), $rowCountLiteral, $snapshotLiteral, false, false);`r`n")
        if ($checkRows.Count -gt 0) {
            [void]$insertSql.Append("INSERT INTO lake.check_history VALUES`r`n")
            $tuples = @($checkRows | ForEach-Object {
                "  ('$runId'::UUID, $(ConvertTo-SqlLiteral $contractName), $(ConvertTo-SqlLiteral $_.CheckId), $(ConvertTo-SqlLiteral $_.Kind), $(ConvertTo-SqlLiteral $_.Status), $(ConvertTo-SqlLiteral $_.Observed), $(ConvertTo-SqlLiteral $_.Committed), $(ConvertTo-SqlLiteral $outcome))"
            })
            [void]$insertSql.Append(($tuples -join ",`r`n"))
            [void]$insertSql.Append(";`r`n")
        }
        $writeResult = Invoke-DuckdbBatch -Sql $insertSql.ToString()
        if ($writeResult.ExitCode -ne 0) {
            Write-Output "ERROR,$contractName,failed to write manifest/check_history for a refused run:"
            foreach ($l in $writeResult.Lines) { Write-Output $l }
            exit 1
        }

        Write-Output "MATERIALIZE,$contractName,REFUSED,reason=checks_failed"
        Write-Output "MANIFEST_SNAPSHOT_ID,$(if ($null -ne $prevSnapshotId) { $prevSnapshotId } else { 'none' })"
        Write-Output "CHECKS_PASSED,false"
        $summaryRefused++
        $anyRefused = $true
        continue
    }

    # --- MATERIALIZE (checks passed, or -Force overriding a failure): replace the
    # table, capture ITS OWN snapshot id in the same invocation, then write
    # manifest + check_history in a separate, later invocation. ---------------------
    $materializeSql = @"
LOAD ducklake;
ATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd');
.read '$compatFwd'
.read '$($cf -replace '\\', '/')'
CREATE OR REPLACE TABLE lake.$contractName AS SELECT * FROM contract_view;
SELECT 'ROWCOUNT', count(*) FROM lake.$contractName;
SELECT 'SNAPSHOT', max(snapshot_id) FROM lake.snapshots();
"@
    $matResult = Invoke-DuckdbBatch -Sql $materializeSql
    $rowCountLine = $matResult.Lines | Where-Object { $_ -like 'ROWCOUNT,*' } | Select-Object -First 1
    $snapshotLine = $matResult.Lines | Where-Object { $_ -like 'SNAPSHOT,*' } | Select-Object -First 1
    if ($matResult.ExitCode -ne 0 -or -not $rowCountLine -or -not $snapshotLine) {
        Write-Output "ERROR,$contractName,materialize failed:"
        foreach ($l in $matResult.Lines) { Write-Output $l }
        exit 1
    }
    $newRowCount = (Get-CsvField -Line $rowCountLine -Count 2)[1]
    $newSnapshotId = (Get-CsvField -Line $snapshotLine -Count 2)[1]

    $outcome = if ($forced) { 'FORCED' } else { 'MATERIALIZED' }

    $insertSql = New-Object System.Text.StringBuilder
    [void]$insertSql.Append("LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd');`r`n")
    [void]$insertSql.Append("INSERT INTO lake.manifest VALUES ('$runId'::UUID, timezone('UTC', now())::TIMESTAMP, $(ConvertTo-SqlLiteral $contractName), $(ConvertTo-SqlLiteral $workbookPathFwd), '$sourceMtime'::TIMESTAMP, $(ConvertTo-SqlLiteral $sourceSha256), $(ConvertTo-SqlLiteral $contractSha256), $(ConvertTo-SqlLiteral $compatSha256), $newRowCount, $newSnapshotId, $($checksPassed.ToString().ToLowerInvariant()), $($forced.ToString().ToLowerInvariant()));`r`n")
    if ($checkRows.Count -gt 0) {
        [void]$insertSql.Append("INSERT INTO lake.check_history VALUES`r`n")
        $tuples = @($checkRows | ForEach-Object {
            "  ('$runId'::UUID, $(ConvertTo-SqlLiteral $contractName), $(ConvertTo-SqlLiteral $_.CheckId), $(ConvertTo-SqlLiteral $_.Kind), $(ConvertTo-SqlLiteral $_.Status), $(ConvertTo-SqlLiteral $_.Observed), $(ConvertTo-SqlLiteral $_.Committed), $(ConvertTo-SqlLiteral $outcome))"
        })
        [void]$insertSql.Append(($tuples -join ",`r`n"))
        [void]$insertSql.Append(";`r`n")
    }
    $writeResult = Invoke-DuckdbBatch -Sql $insertSql.ToString()
    if ($writeResult.ExitCode -ne 0) {
        Write-Output "ERROR,$contractName,materialized the table but failed to write manifest/check_history:"
        foreach ($l in $writeResult.Lines) { Write-Output $l }
        exit 1
    }

    $reasonSuffix = if ($reason) { ",reason=$reason" } else { '' }
    Write-Output "MATERIALIZE,$contractName,REFRESHED,$newRowCount$reasonSuffix"
    Write-Output "MANIFEST_SNAPSHOT_ID,$newSnapshotId"
    Write-Output "CHECKS_PASSED,$($checksPassed.ToString().ToLowerInvariant())"
    $summaryRefreshed++
    if ($forced) { $summaryForced++ }
}

Write-Output "SUMMARY,contracts=$($contractFiles.Count),refreshed=$summaryRefreshed,skipped=$summarySkipped,refused=$summaryRefused,forced=$summaryForced"

if ($anyRefused) {
    exit 1
}
exit 0
