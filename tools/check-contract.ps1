<#
tools\check-contract.ps1 <contract.sql>

Single-contract runner for TASK.md's `-- @assert <name>: <expr>` grammar (item 4,
Decision 1). Parses and validates every directive in the file, THEN creates the view
and runs each assertion, reporting PASS/FAIL/ERROR per assertion by name. Exits
non-zero if either guard trips or any assertion is not PASS.

Boundary with item 5: this proves the grammar executes for one contract. It does not
own multi-contract aggregation, floor derivation, or tolerance rules -- that is item 5.
`check-contract.ps1` corresponds to no PLAN-4 step; it is deliberate expansion beyond
PLAN-4 sec3/sec4, so item 4 does not ship assertions that have never actually run.

Macro availability, stated explicitly (TASK.md: "must make xl_date available without
depending on any gitignored state"): skills/query/duckdb-compat.sql is resolved as
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
-- relative to THIS SCRIPT's own location, never as a hardcoded absolute path and never
via .duckdb-skills\state.sql (gitignored, so a fresh `git worktree add` checkout does
not have it -- AC0). This mirrors tools\ensure-duckdb-compat.ps1:51's existing pattern.

Grammar (TASK.md Decision 1), summarized:
  - A directive: a line whose first non-whitespace characters are `--`, optional
    whitespace, then `@assert`. `--@assert` (no space) counts.
  - Full grammar: `--[ ]@assert[ ]<name>[ ]:<expr>` where <name> matches
    ^[A-Za-z0-9_]+$, ends at the first `:`, and must be unique in the file. Everything
    after the first `:`, trimmed, is <expr>, which must not contain `;`.
  - Each <expr> runs verbatim as `SELECT <expr>;` (no FROM appended). The result must
    be exactly one row, one column, BOOLEAN, value true to PASS. NULL is a FAIL, not an
    error. A non-boolean type, more than one row/column, or a DuckDB error is an ERROR.
  - Guard 1: zero parsed assertions in the whole file is an error.
  - Guard 2: a line matching "is a directive" but not the full grammar (missing colon,
    invalid/duplicate name, or `;` in the expression) is an error, never silently
    skipped.
  - Both guards are evaluated BEFORE the view is created, so a malformed contract fails
    without paying the 68 MB workbook read.

Each assertion is evaluated in its own `duckdb -json -f <temp file>` invocation
(macros + contract + that one `SELECT <expr>;`), so one assertion's DuckDB error can
never abort evaluation of the others -- measured: the DuckDB CLI stops an `-f` script
at its first error, so a single shared session cannot report per-assertion results past
the first failure. -json output is parsed with ConvertFrom-Json so PASS/FAIL/ERROR is
decided from real JSON types (a JSON `true`/`false` literal vs. a number or string),
never by pattern-matching CSV text. This costs one extra 68 MB read per assertion
(no TEMP TABLE materialization) -- accepted for a single-contract runner; item 5's
multi-contract harness is the place to revisit compounding read cost across many
contracts.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ContractPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    Write-Output "ERROR: contract file not found: $ContractPath"
    exit 1
}

$contractFullPath = [System.IO.Path]::GetFullPath($ContractPath)
$contractFwd = $contractFullPath -replace '\\', '/'

$compatFullPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\query\duckdb-compat.sql'))
if (-not (Test-Path -LiteralPath $compatFullPath -PathType Leaf)) {
    Write-Output "ERROR: duckdb-compat.sql not found at: $compatFullPath"
    exit 1
}
$compatFwd = $compatFullPath -replace '\\', '/'

# --- parse directives (both guards run here, before any view is created) ----------

$directiveLinePattern = '^\s*--\s*@assert\b'
$fullGrammarPattern = '^\s*--\s*@assert\s*([A-Za-z0-9_]+)\s*:(.*)$'

$lines = Get-Content -LiteralPath $contractFullPath
$assertions = New-Object System.Collections.Generic.List[object]
$seenNames = New-Object System.Collections.Generic.HashSet[string]
$guardErrors = New-Object System.Collections.Generic.List[string]

$lineNumber = 0
foreach ($line in $lines) {
    $lineNumber++
    if ($line -notmatch $directiveLinePattern) {
        continue
    }
    $m = [regex]::Match($line, $fullGrammarPattern)
    if (-not $m.Success) {
        $guardErrors.Add("line ${lineNumber}: directive does not match grammar (missing ':' or invalid name): $line")
        continue
    }
    $name = $m.Groups[1].Value
    $expr = $m.Groups[2].Value.Trim()
    if ($seenNames.Contains($name)) {
        $guardErrors.Add("line ${lineNumber}: duplicate assertion name '$name'")
        continue
    }
    if ($expr.Contains(';')) {
        $guardErrors.Add("line ${lineNumber}: assertion '$name' expression contains ';'")
        continue
    }
    [void]$seenNames.Add($name)
    $assertions.Add([pscustomobject]@{ Name = $name; Expr = $expr })
}

if ($guardErrors.Count -gt 0) {
    Write-Output 'GUARD 2 FAILED: malformed @assert directive(s), not skipped:'
    foreach ($e in $guardErrors) { Write-Output "  $e" }
    exit 1
}

if ($assertions.Count -eq 0) {
    Write-Output "GUARD 1 FAILED: zero @assert directives parsed from: $contractFullPath"
    exit 1
}

# --- guards passed; now (and only now) does any assertion pay the 68 MB read ------

$scratchDir = Join-Path $env:TEMP "check-contract-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$results = New-Object System.Collections.Generic.List[object]

try {
    foreach ($a in $assertions) {
        $sqlFile = Join-Path $scratchDir "$($a.Name).sql"
        $body = ".read '$compatFwd'`r`n.read '$contractFwd'`r`nSELECT $($a.Expr);`r`n"
        [System.IO.File]::WriteAllText($sqlFile, $body, $utf8NoBom)

        # duckdb writes purely informational text to stderr on a clean run (see
        # tools\ensure-duckdb-compat.ps1 and PLAN-4's "never decide pass/fail by
        # matching stderr" rule), and PowerShell 5.1 turns any stderr line from a
        # native command into a terminating error when $ErrorActionPreference is
        # 'Stop' -- even when stderr is redirected to a file. 'Continue', scoped to
        # only this call, captures every line (stdout and stderr merged via 2>&1)
        # into $rawOutput without throwing and without printing to the console.
        # $LASTEXITCODE -- not the presence of stderr text -- is what is gated on.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $rawOutput = & duckdb -json -f $sqlFile 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEap

        $outputText = (($rawOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()

        $status = $null
        $detail = $null

        if ($exitCode -ne 0) {
            $status = 'ERROR'
            $detail = "duckdb exited ${exitCode}: $outputText"
        } elseif ([string]::IsNullOrWhiteSpace($outputText)) {
            $status = 'ERROR'
            $detail = 'no output from assertion query'
        } else {
            try {
                $parsed = ConvertFrom-Json -InputObject $outputText -ErrorAction Stop
            } catch {
                $status = 'ERROR'
                $detail = "could not parse JSON output: $($_.Exception.Message)"
            }
            if (-not $status) {
                $rows = @($parsed)
                if ($rows.Count -ne 1) {
                    $status = 'ERROR'
                    $detail = "expected exactly one row, got $($rows.Count)"
                } else {
                    $props = @($rows[0].PSObject.Properties)
                    if ($props.Count -ne 1) {
                        $status = 'ERROR'
                        $detail = "expected exactly one column, got $($props.Count)"
                    } else {
                        $value = $props[0].Value
                        if ($value -is [bool]) {
                            if ($value -eq $true) {
                                $status = 'PASS'
                            } else {
                                $status = 'FAIL'
                                $detail = 'value is false'
                            }
                        } elseif ($null -eq $value) {
                            $status = 'FAIL'
                            $detail = 'value is NULL'
                        } else {
                            $status = 'ERROR'
                            $detail = "non-boolean result type ($($value.GetType().Name)): $value"
                        }
                    }
                }
            }
        }

        $results.Add([pscustomobject]@{ Name = $a.Name; Status = $status; Detail = $detail })
    }
} finally {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

$anyFailure = $false
foreach ($r in $results) {
    if ($r.Detail) {
        Write-Output "$($r.Status) $($r.Name): $($r.Detail)"
    } else {
        Write-Output "$($r.Status) $($r.Name)"
    }
    if ($r.Status -ne 'PASS') { $anyFailure = $true }
}

Write-Output "assertion_count=$($assertions.Count)"

if ($anyFailure) {
    exit 1
}
exit 0
