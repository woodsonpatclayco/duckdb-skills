<#
tools\prove-no-snowflake.ps1 [-Forbid <names>] [-BudgetSeconds <n>] [-Only <label>]

TASK.md item 7, part B. Runs every entrypoint that can invoke `duckdb` with an
in-process probe injected through a temporary PATH shim, and reports what each
one actually loaded -- never trusting a query run in a separate, later process
(mutation 2 exists precisely because that would be a fake proof: an extension
loaded by the real call is invisible to a query that runs afterwards, in a new
process).

The shim: a `duckdb.cmd` (ASCII, no BOM) written to a fresh scratch directory
and prepended to $env:PATH in THIS process only -- child `powershell` and
nested `duckdb` processes inherit it; nothing is ever persisted. The real
`duckdb.exe` is resolved to an absolute path BEFORE the shim is prepended, so
the shim always calls the genuine binary, never itself.

Per call, the shim appends
  -c ".output <probe>" -c ".mode list" -c ".headers off"
  -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1;"
  -c ".output"
after the caller's own arguments -- confirmed (TASK.md's measured facts) that
the probe then runs AFTER whatever `-f`/`-init` file the caller supplied, in
the SAME process, and sees exactly what that file loaded; and that a
statement that errors stops `-f` before the probe ever runs, so a failed call
is always "no evidence", never "clean" (D4).

Probe paths never collide: the shim retries "if exist" before creating an
empty probe file, rather than trusting `%RANDOM%` alone (`cmd.exe` seeds it
from the clock, and `run-compat-tests.ps1` alone makes several calls a
second). The exit code is captured into a variable on the line immediately
after the `duckdb.exe` line, and the call log line is appended only after
that -- `<label>|<exit code>|<probe path>|<args>`, with literal pipes
(escaped as `^|` in the batch file so `cmd.exe` never treats them as its own
pipe operator).

D5: no entrypoint here relies on a default extract/lake root -- every one gets
an explicit scratch root, because `Resolve-ExtractRoot`/`Resolve-LakeRoot`
key their defaults on `git rev-parse --show-toplevel`, which in a
`git worktree add` checkout is a different, empty project directory, and
resolving it would create that directory as a side effect.
#>
# AC10 (call accounting -- distinct probe paths, which the pinned EXT line format
# has no field for) is exposed on the Verbose stream only, so a normal run's
# stdout still prints exactly the EXT/SUMMARY lines B specifies. Run with
# -Verbose to see one 'VERBOSE_AC10,<label>,calls=<n>,distinct_probes=<n>' line
# per entrypoint.
[CmdletBinding()]
param(
    [string]$Forbid = 'snowflake',
    [int]$BudgetSeconds = 120,
    [string]$Only
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$asciiNoBom = New-Object System.Text.ASCIIEncoding

$forbidList = @($Forbid -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

# --- resolve the real duckdb.exe BEFORE the shim is ever on PATH ---------------------
$realDuckdbCmd = Get-Command duckdb -ErrorAction SilentlyContinue
if (-not $realDuckdbCmd) {
    Write-Output 'ERROR,duckdb not found on PATH'
    exit 1
}
$realDuckdb = $realDuckdbCmd.Source

$runScratch = Join-Path $env:TEMP "dsk-prove-no-snowflake-$([guid]::NewGuid().ToString('N'))"
$shimDir = Join-Path $runScratch 'shim'
$probeDir = Join-Path $runScratch 'probes'
$fixtureRoot = Join-Path $runScratch 'xfx'
$scratchLake = Join-Path $runScratch 'lake'
$controlDir = Join-Path $runScratch 'ctrl'
$logFile = Join-Path $runScratch 'calls.log'
$truncPath = Join-Path $runScratch 'trunc'

New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
[System.IO.File]::WriteAllText($logFile, '', $utf8NoBom)

# --- write the shim (ASCII, no BOM). Probe dir/paths are guaranteed space-free
# (under $env:TEMP\dsk-prove-no-snowflake-<guid>\probes), so the SQL argument
# below needs no embedded-quote escaping. ----------------------------------------------
$shimPath = Join-Path $shimDir 'duckdb.cmd'
$shimLines = @(
    '@echo off',
    ':choose',
    'set "PROBE=%DSK_EXT_PROBE_DIR%\probe_%RANDOM%_%RANDOM%_%RANDOM%_%RANDOM%.txt"',
    'if exist "%PROBE%" goto choose',
    'type nul > "%PROBE%"',
    '"%DSK_EXT_REAL_DUCKDB%" %* -c ".output %PROBE:\=/%" -c ".mode list" -c ".headers off" -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1;" -c ".output"',
    'set RC=%ERRORLEVEL%',
    '>>"%DSK_EXT_LOG%" echo %DSK_EXT_LABEL%^|%RC%^|%PROBE%^|%*',
    'exit /b %RC%'
)
[System.IO.File]::WriteAllText($shimPath, ($shimLines -join "`r`n") + "`r`n", $asciiNoBom)

$env:DSK_EXT_REAL_DUCKDB = $realDuckdb
$env:DSK_EXT_PROBE_DIR = $probeDir
$env:DSK_EXT_LOG = $logFile

$originalPath = $env:PATH
$env:PATH = "$shimDir;$originalPath"

# --- helpers ---------------------------------------------------------------------------

function Get-DescendantProcessIds {
    param([int]$RootPid)
    $all = Get-CimInstance Win32_Process
    $result = New-Object System.Collections.Generic.List[int]
    $frontier = New-Object System.Collections.Generic.Queue[int]
    $frontier.Enqueue($RootPid)
    while ($frontier.Count -gt 0) {
        $p = $frontier.Dequeue()
        $children = @($all | Where-Object { $_.ParentProcessId -eq $p })
        foreach ($c in $children) {
            $cid = [int]$c.ProcessId
            $result.Add($cid)
            $frontier.Enqueue($cid)
        }
    }
    return $result
}

function Stop-ProcessTree {
    param([int]$RootPid)
    $descendants = Get-DescendantProcessIds -RootPid $RootPid
    foreach ($d in $descendants) {
        Stop-Process -Id $d -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
}

function Get-ProbeState {
    param([string]$ProbePath)
    if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) { return 'missing_file' }
    $len = (Get-Item -LiteralPath $ProbePath).Length
    if ($len -gt 0) { return 'nonempty' }
    return 'empty'
}

# Start-Process -PassThru, combined with -RedirectStandardOutput/-RedirectStandardError,
# does not reliably populate .ExitCode in PowerShell 5.1 (measured this session: exit
# code reads as empty even after WaitForExit(...) returns true and HasExited is true).
# A raw System.Diagnostics.Process with async output/error events does not have this
# defect -- used for every entrypoint below instead of Start-Process.
function ConvertTo-ArgumentString {
    param([string[]]$ArgList)
    $parts = foreach ($a in $ArgList) {
        if ($a -match '[\s"]') {
            '"' + ($a -replace '"', '\"') + '"'
        } else {
            $a
        }
    }
    return ($parts -join ' ')
}

function Start-Tracked {
    param([string]$FilePath, [string[]]$ArgList, [string]$WorkDir)
    $resolved = (Get-Command $FilePath -ErrorAction Stop).Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolved
    $psi.Arguments = ConvertTo-ArgumentString -ArgList $ArgList
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $outSb = New-Object System.Text.StringBuilder
    $errSb = New-Object System.Text.StringBuilder
    $outAction = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
    $errAction = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
    $outHandler = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $outAction -MessageData $outSb
    $errHandler = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action $errAction -MessageData $errSb
    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    return [pscustomobject]@{ Process = $p; Out = $outSb; Err = $errSb; OutHandler = $outHandler; ErrHandler = $errHandler }
}

function Stop-Tracked {
    param([pscustomobject]$T)
    Unregister-Event -SourceIdentifier $T.OutHandler.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $T.ErrHandler.Name -ErrorAction SilentlyContinue
    Remove-Job -Id $T.OutHandler.Id -Force -ErrorAction SilentlyContinue
    Remove-Job -Id $T.ErrHandler.Id -Force -ErrorAction SilentlyContinue
}

# Runs one entrypoint through the shim, classifies every logged call, and
# returns the EXT line's data (never prints it -- the caller decides ordering
# and whether to also dump scratch output on a non-PASS verdict).
function Invoke-Entrypoint {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$ArgList,
        [int]$Budget
    )

    $env:DSK_EXT_LABEL = $Label

    $logCountBefore = 0
    if (Test-Path -LiteralPath $logFile) { $logCountBefore = @(Get-Content -LiteralPath $logFile).Count }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $t = Start-Tracked -FilePath $FilePath -ArgList $ArgList -WorkDir $repoRoot

    $exited = $t.Process.WaitForExit($Budget * 1000)
    $hung = -not $exited
    $exitCode = $null
    if ($hung) {
        Stop-ProcessTree -RootPid $t.Process.Id
        Start-Sleep -Milliseconds 300
    } else {
        $exitCode = $t.Process.ExitCode
    }
    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    $outText = $t.Out.ToString()
    $errText = $t.Err.ToString()
    Stop-Tracked -T $t

    $allLogLines = @()
    if (Test-Path -LiteralPath $logFile) { $allLogLines = @(Get-Content -LiteralPath $logFile) }
    $logCountAfter = $allLogLines.Count
    $newLines = @()
    if ($logCountAfter -gt $logCountBefore) {
        $newLines = @($allLogLines[$logCountBefore..($logCountAfter - 1)])
    }

    $calls = 0
    $probed = 0
    $unprobed = 0
    $notASession = 0
    $probeMissing = 0
    $distinctProbes = New-Object 'System.Collections.Generic.HashSet[string]'
    $loaded = New-Object 'System.Collections.Generic.HashSet[string]'
    $forbiddenLoaded = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($line in $newLines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $parts = $line -split '\|', 4
        if ($parts.Count -lt 3) { continue }
        $calls++
        $lineExit = $parts[1]
        $linePath = $parts[2]
        $lineArgs = if ($parts.Count -ge 4) { $parts[3] } else { '' }
        [void]$distinctProbes.Add($linePath)

        if ($lineArgs -match '(^|\s)-version(\s|$)') {
            $notASession++
            continue
        }

        $state = Get-ProbeState -ProbePath $linePath
        if ($state -eq 'nonempty') {
            $probed++
            $extNames = @(Get-Content -LiteralPath $linePath | Where-Object { $_.Trim() -ne '' })
            foreach ($e in $extNames) {
                [void]$loaded.Add($e.Trim())
                if ($forbidList -contains $e.Trim()) { [void]$forbiddenLoaded.Add($e.Trim()) }
            }
        } elseif ($lineExit -ne '0') {
            $unprobed++
        } else {
            $probeMissing++
        }
    }

    $verdict = 'PASS'
    if ($hung) {
        $verdict = 'HUNG'
    } elseif ($forbiddenLoaded.Count -gt 0 -or $probeMissing -gt 0 -or ($null -ne $exitCode -and $exitCode -ne 0)) {
        $verdict = 'FAIL'
    } elseif ($probed -eq 0) {
        $verdict = 'NO_EVIDENCE'
    }

    $loadedText = if ($loaded.Count -gt 0) { ($loaded | Sort-Object) -join ';' } else { '' }
    $exitText = if ($null -ne $exitCode) { [string]$exitCode } else { 'null' }

    return [pscustomobject]@{
        Label            = $Label
        Exit             = $exitText
        Elapsed          = $elapsed
        Calls            = $calls
        DistinctProbes   = $distinctProbes.Count
        Probed           = $probed
        Unprobed         = $unprobed
        NotASession      = $notASession
        ProbeMissing     = $probeMissing
        Loaded           = $loadedText
        Verdict          = $verdict
        Out              = $outText
        Err              = $errText
    }
}

function Write-ExtLine {
    param([pscustomobject]$R)
    Write-Output "EXT,$($R.Label),exit=$($R.Exit),elapsed=$($R.Elapsed),calls=$($R.Calls),probed=$($R.Probed),unprobed=$($R.Unprobed),not_a_session=$($R.NotASession),probe_missing=$($R.ProbeMissing),loaded=$($R.Loaded),$($R.Verdict)"
    if ($R.Verdict -ne 'PASS') {
        $combined = @()
        if ($R.Out) { $combined += @($R.Out -split "`r?`n") }
        if ($R.Err) { $combined += @($R.Err -split "`r?`n") }
        $combined = @($combined | Where-Object { $_ -ne '' })
        $tail = $combined | Select-Object -Last 20
        foreach ($l in $tail) { Write-Output "  | $l" }
    }
}

function Invoke-UnshimmedMaterialize {
    param([string]$LakeRoot)
    $prevPath = $env:PATH
    $env:PATH = $originalPath
    try {
        $materializePath = Join-Path $repoRoot 'tools\materialize.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $materializePath -LakeRoot $LakeRoot 2>&1 | Out-Null
    } finally {
        $env:PATH = $prevPath
    }
}

# --- the 14 main entrypoints, in order (order is load-bearing for the lake rows) ------
function Get-MainEntrypoints {
    return @(
        [pscustomobject]@{ Label = 'check-contract:GL'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\check-contract.ps1', 'contracts\Clayco_Job_Costs_from_GL.sql') },
        [pscustomobject]@{ Label = 'check-contract:All_Sales_Data'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\check-contract.ps1', 'contracts\All_Sales_Data.sql') },
        [pscustomobject]@{ Label = 'run-assertions'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\run-assertions.ps1') },
        [pscustomobject]@{ Label = 'materialize:1'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\materialize.ps1', '-LakeRoot', $scratchLake) },
        [pscustomobject]@{ Label = 'materialize:2'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\materialize.ps1', '-LakeRoot', $scratchLake) },
        [pscustomobject]@{ Label = 'lake-status'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\lake-status.ps1', '-LakeRoot', $scratchLake) },
        [pscustomobject]@{ Label = 'lake-status:history'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\lake-status.ps1', '-History', 'Clayco_Job_Costs_from_GL', '-LakeRoot', $scratchLake) },
        [pscustomobject]@{ Label = 'list-extracts'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\list-extracts.ps1', '-ExtractRoot', (Join-Path $fixtureRoot 'ages')) },
        [pscustomobject]@{ Label = 'extract-status'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\extract-status.ps1', '-Name', 'parent_projects', '-ExtractRoot', (Join-Path $fixtureRoot 'ages')) },
        [pscustomobject]@{ Label = 'extract-decide'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\extract-decide.ps1', '-Name', 'parent_projects', '-ExtractRoot', (Join-Path $fixtureRoot 'ages')) },
        [pscustomobject]@{ Label = 'run-compat-tests'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\run-compat-tests.ps1') },
        [pscustomobject]@{ Label = 'make-truncation-fixtures'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools\make-truncation-fixtures.ps1', '-Path', $truncPath) },
        [pscustomobject]@{ Label = 'gl-facts'; FilePath = 'duckdb'; ArgList = @('-f', 'checks\gl-facts.sql') },
        [pscustomobject]@{ Label = 'read-memories:search'; FilePath = 'duckdb'; ArgList = @('-csv', '-f', 'skills\read-memories\search.sql') }
    )
}

function Get-Controls {
    $ftsFile = Join-Path $controlDir 'fts.sql'
    [System.IO.File]::WriteAllText($ftsFile, "LOAD fts;`r`nSELECT 1;`r`n", $utf8NoBom)

    $errorFile = Join-Path $controlDir 'error.sql'
    [System.IO.File]::WriteAllText($errorFile, "SELECT * FROM no_such_table;`r`n", $utf8NoBom)

    $errorPs1 = Join-Path $controlDir 'control_error.ps1'
    $errorPs1Body = "param()`r`n" +
        "`$prevEap = `$ErrorActionPreference`r`n" +
        "`$ErrorActionPreference = 'Continue'`r`n" +
        "& duckdb -f '$errorFile' 2>&1 | Out-Null`r`n" +
        "`$ErrorActionPreference = `$prevEap`r`n" +
        "exit 0`r`n"
    [System.IO.File]::WriteAllText($errorPs1, $errorPs1Body, $utf8NoBom)

    $hangFile = Join-Path $controlDir 'hang.sql'
    # TASK.md's literal text omits the range() alias; without one, range()'s
    # column is named "range", not "i", and the statement fails to bind
    # instantly instead of running long -- item 6 used the same expression
    # with `range(2000000000) t(i)` (RESULT-1.md:321); reused here unchanged.
    [System.IO.File]::WriteAllText($hangFile, "SELECT max(hash(i*7+1)) FROM range(2000000000) t(i);`r`n", $utf8NoBom)

    return @(
        [pscustomobject]@{ Label = 'control_load_fts'; FilePath = 'duckdb'; ArgList = @('-f', $ftsFile) },
        [pscustomobject]@{ Label = 'control_error'; FilePath = 'powershell'; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $errorPs1) },
        [pscustomobject]@{ Label = 'control_hang'; FilePath = 'duckdb'; ArgList = @('-f', $hangFile) }
    )
}

# --- run --------------------------------------------------------------------------------

$results = New-Object System.Collections.Generic.List[object]

try {
    $mainEntrypoints = Get-MainEntrypoints
    $controlEntrypoints = Get-Controls
    $controlLabels = @($controlEntrypoints | ForEach-Object { $_.Label })

    if ($Only -and ($controlLabels -contains $Only)) {
        # --- a pure control: no fixture/lake prep needed ---------------------------------
        $c = $controlEntrypoints | Where-Object { $_.Label -eq $Only } | Select-Object -First 1
        $r = Invoke-Entrypoint -Label $c.Label -FilePath $c.FilePath -ArgList $c.ArgList -Budget $BudgetSeconds
        $results.Add($r)
    } else {
        # --- setup: fixture tree (never launches duckdb itself) --------------------------
        $makeFixturesPath = Join-Path $repoRoot 'tools\make-extract-fixtures.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $makeFixturesPath -Root $fixtureRoot | Out-Null

        if ($Only) {
            $target = $mainEntrypoints | Where-Object { $_.Label -eq $Only } | Select-Object -First 1
            if (-not $target) {
                Write-Output "ERROR,unknown -Only label: $Only"
                exit 2
            }
            if ($target.Label -like 'lake-status*') {
                Invoke-UnshimmedMaterialize -LakeRoot $scratchLake
            }
            if ($target.Label -eq 'read-memories:search') {
                $env:DSK_KEYWORD = 'lakehouse'
                $env:DSK_CWD = ''
            }
            $r = Invoke-Entrypoint -Label $target.Label -FilePath $target.FilePath -ArgList $target.ArgList -Budget $BudgetSeconds
            $results.Add($r)
        } else {
            foreach ($ep in $mainEntrypoints) {
                if ($ep.Label -eq 'read-memories:search') {
                    $env:DSK_KEYWORD = 'lakehouse'
                    $env:DSK_CWD = ''
                }
                $r = Invoke-Entrypoint -Label $ep.Label -FilePath $ep.FilePath -ArgList $ep.ArgList -Budget $BudgetSeconds
                $results.Add($r)
            }
        }
    }

    foreach ($r in $results) {
        Write-ExtLine -R $r
        Write-Verbose "VERBOSE_AC10,$($r.Label),calls=$($r.Calls),distinct_probes=$($r.DistinctProbes),probed=$($r.Probed),unprobed=$($r.Unprobed),not_a_session=$($r.NotASession),probe_missing=$($r.ProbeMissing)"
    }

    $entrypoints = $results.Count
    $pass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
    $fail = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count
    $noEvidence = @($results | Where-Object { $_.Verdict -eq 'NO_EVIDENCE' }).Count
    $hungCount = @($results | Where-Object { $_.Verdict -eq 'HUNG' }).Count
    Write-Output "SUMMARY,entrypoints=$entrypoints,pass=$pass,fail=$fail,no_evidence=$noEvidence,hung=$hungCount,forbidden=$($forbidList -join ';')"

    if ($pass -eq $entrypoints) { exit 0 }
    exit 1
} finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $runScratch -Recurse -Force -ErrorAction SilentlyContinue
}
