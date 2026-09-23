<#
Runs skills/query/duckdb-compat-tests.csv in raw, macro, and/or polyglot mode and prints a
before/after table asserting both value and type. See skills/query/duckdb-compat.md.
#>
param(
    [string]$Fixture = 'skills\query\duckdb-compat-tests.csv',
    [string]$CompatFile = 'skills\query\duckdb-compat.sql',
    [ValidateSet('raw', 'macro', 'polyglot', 'all')]
    [string]$Mode = 'all',
    [string]$ExpectedDuckdbVersion = 'v1.5.5',
    [string]$ExpectedPolyglotVersion = '8f1666d'
)

$ErrorActionPreference = 'Continue'

$scratchDir = Join-Path (Get-Location) '.duckdb-skills\run-compat-tests'
if (Test-Path -LiteralPath $scratchDir) {
    Remove-Item -LiteralPath $scratchDir -Recurse -Force
}
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

$transpileFile = Join-Path $scratchDir 'polyglot_transpile.txt'
[IO.File]::WriteAllText($transpileFile, '')

$hadFailure = $false

# --- Assert the pins first ---
$dbVersionRaw = (& duckdb -version)
$actualDuckdbVersion = ($dbVersionRaw -split ' ')[0]

$pinScript = Join-Path $scratchDir 'pincheck.sql'
[IO.File]::WriteAllText($pinScript, "LOAD polyglot;`r`nSELECT 'PIN' AS tag, extension_version AS v FROM duckdb_extensions() WHERE extension_name='polyglot';`r`n")
$pinErr = Join-Path $scratchDir 'pincheck.err'
$pinOut = & duckdb -csv -f $pinScript 2>$pinErr
$actualPolyglotVersion = ''
foreach ($obj in ($pinOut | ConvertFrom-Csv)) {
    if ($obj.tag -eq 'PIN') { $actualPolyglotVersion = $obj.v }
}

Write-Output "PIN: duckdb=$actualDuckdbVersion polyglot=$actualPolyglotVersion"
if ($actualDuckdbVersion -ne $ExpectedDuckdbVersion -or $actualPolyglotVersion -ne $ExpectedPolyglotVersion) {
    Write-Output "PIN DRIFT: expected duckdb=$ExpectedDuckdbVersion polyglot=$ExpectedPolyglotVersion; actual duckdb=$actualDuckdbVersion polyglot=$actualPolyglotVersion"
    Write-Output 'Remedy: re-run the fixture and update the pin and the before/after table in skills/query/duckdb-compat.md.'
    exit 1
}

# --- Load fixture ---
if (-not (Test-Path -LiteralPath $Fixture)) {
    Write-Output "FIXTURE NOT FOUND: $Fixture"
    exit 1
}
$rows = @(Import-Csv -LiteralPath $Fixture)

$modesToRun = @()
if ($Mode -eq 'all') { $modesToRun = @('raw', 'macro', 'polyglot') } else { $modesToRun = @($Mode) }

function Get-ErrorClass([string]$stderrText) {
    if (-not $stderrText) { return $null }
    foreach ($line in ($stderrText -split "`r`n|`n")) {
        if ($line -match '^[A-Za-z ]+Error:') {
            return $line.Trim()
        }
    }
    return $null
}

function Get-FirstNonTagValue($csvRow) {
    if (-not $csvRow) { return $null }
    foreach ($prop in $csvRow.PSObject.Properties) {
        if ($prop.Name -ne 'tag') { return $prop.Value }
    }
    return $null
}

function Get-ModeLabel([string]$m) {
    if ($m -eq 'polyglot') { return 'polyglot (macros loaded)' }
    return $m
}

# Round 2 (C2): when both expected and actual parse as decimal, compare
# numerically -- Snowflake's fixed-point rendering (e.g. "1.000") and DuckDB's
# (e.g. "1.0") are the same number. Otherwise compare as exact strings. Type
# comparison is never touched by this -- it stays an exact string match.
function Test-ValueMatch([string]$expected, [string]$actual) {
    if ($null -eq $expected) { $expected = '' }
    if ($null -eq $actual) { $actual = '' }
    $expDec = [decimal]0
    $actDec = [decimal]0
    $ns = [System.Globalization.NumberStyles]::Float
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $expIsNum = [decimal]::TryParse($expected, $ns, $ci, [ref]$expDec)
    $actIsNum = [decimal]::TryParse($actual, $ns, $ci, [ref]$actDec)
    if ($expIsNum -and $actIsNum) {
        return ($expDec -eq $actDec)
    }
    return ($actual -ceq $expected)
}

function Invoke-FixtureRow {
    param(
        [string]$Name,
        [string]$Sql,
        [string]$RowMode,
        [string]$CompatFilePath,
        [string]$ScratchDir,
        [int]$Index
    )

    if ($RowMode -eq 'polyglot') {
        $escapedSql = $Sql -replace "'", "''"
        $statement = "SELECT * FROM polyglot_query('$escapedSql', 'snowflake')"
    } else {
        $statement = $Sql
    }

    $scriptLines = @()
    if ($RowMode -eq 'polyglot') {
        $scriptLines += 'LOAD polyglot;'
    }
    $scriptLines += "CREATE OR REPLACE TEMP TABLE _r AS $statement;"
    $scriptLines += "SELECT 'META' AS tag, count(*) AS n, (SELECT count(*) FROM (DESCRIBE _r)) AS cols FROM _r;"
    $scriptLines += "SELECT 'VAL' AS tag, * FROM _r;"
    $scriptLines += "SELECT 'TYP' AS tag, typeof(COLUMNS(*)) FROM _r LIMIT 1;"

    $scriptFile = Join-Path $ScratchDir "row_${Index}_$RowMode.sql"
    [IO.File]::WriteAllText($scriptFile, ($scriptLines -join "`r`n"))

    $errFile = Join-Path $ScratchDir "row_${Index}_$RowMode.err"

    $duckArgs = @()
    if ($RowMode -ne 'raw') {
        $duckArgs += '-init'
        $duckArgs += $CompatFilePath
    }
    $duckArgs += '-csv'
    $duckArgs += '-f'
    $duckArgs += $scriptFile

    $stdout = & duckdb @duckArgs 2>$errFile
    $exitCode = $LASTEXITCODE
    $stderrText = ''
    if (Test-Path -LiteralPath $errFile) { $stderrText = Get-Content -LiteralPath $errFile -Raw }
    $errorClass = Get-ErrorClass $stderrText

    # Split stdout lines into blocks bounded by header lines starting with "tag,".
    $blocks = @()
    $current = $null
    foreach ($line in $stdout) {
        if ($line -match '^tag,') {
            if ($current) { $blocks += (, $current) }
            $current = @($line)
        } elseif ($null -ne $current) {
            $current += $line
        }
    }
    if ($current) { $blocks += (, $current) }

    $n = -1
    $cols = -1
    $actualValue = $null
    $actualType = $null

    if ($blocks.Count -ge 1) {
        $metaRows = @($blocks[0] | ConvertFrom-Csv)
        if ($metaRows.Count -ge 1 -and $metaRows[0].tag -eq 'META') {
            $n = [int]$metaRows[0].n
            $cols = [int]$metaRows[0].cols
        }
    }
    if ($blocks.Count -ge 2) {
        $valRows = @($blocks[1] | ConvertFrom-Csv)
        if ($valRows.Count -ge 1) {
            $actualValue = Get-FirstNonTagValue $valRows[0]
        }
    }
    if ($blocks.Count -ge 3) {
        $typRows = @($blocks[2] | ConvertFrom-Csv)
        if ($typRows.Count -ge 1) {
            $actualType = Get-FirstNonTagValue $typRows[0]
        }
    }

    return [PSCustomObject]@{
        Name        = $Name
        Mode        = $RowMode
        ExitCode    = $exitCode
        ErrorClass  = $errorClass
        N           = $n
        Cols        = $cols
        ActualValue = $actualValue
        ActualType  = $actualType
        Malformed   = ($n -ge 0 -and $cols -ne 1)
    }
}

$allResults = @{}
$index = 0
foreach ($row in $rows) {
    $index++
    $allResults[$row.name] = @{}
    foreach ($m in $modesToRun) {
        $r = Invoke-FixtureRow -Name $row.name -Sql $row.sql -RowMode $m -CompatFilePath $CompatFile -ScratchDir $scratchDir -Index $index

        if ($r.Malformed) {
            Write-Output "MALFORMED ROW: $($row.name) (mode=$m): expected 1 column, got $($r.Cols)"
            $hadFailure = $true
        }

        $typeOk = ($r.ActualType -ceq $row.expected_type)
        $valueOk = $true
        if ($row.check_mode -ne 'type_only') {
            $valueOk = Test-ValueMatch $row.expected_value $r.ActualValue
        }

        $pass = ($r.ExitCode -eq 0) -and (-not $r.ErrorClass) -and ($r.N -eq 1) -and ($r.Cols -eq 1) -and $typeOk -and $valueOk

        # C4: a pass is "verified" only when the expectation is Snowflake's own
        # answer (source=snowflake). A pass on a deviation/duckdb-native row is
        # real but on a relaxed (type-kind) expectation, so it is counted
        # separately and never inflates the verified count. A row that does not
        # pass is "fail" regardless of source -- source is never an input to
        # pass/fail, only to how a pass is classified.
        $category = 'fail'
        if ($pass) {
            if ($row.source -eq 'snowflake') { $category = 'verified' } else { $category = 'deviation' }
        }

        $allResults[$row.name][$m] = [PSCustomObject]@{
            Pass        = $pass
            Category    = $category
            ExitCode    = $r.ExitCode
            ErrorClass  = $r.ErrorClass
            N           = $r.N
            Cols        = $r.Cols
            ActualValue = $r.ActualValue
            ActualType  = $r.ActualType
        }

        if ($m -eq 'polyglot') {
            $escapedForTranspile = $row.sql -replace "'", "''"
            $transpileScript = Join-Path $scratchDir "transpile_${index}.sql"
            [IO.File]::WriteAllText($transpileScript, "LOAD polyglot;`r`nSELECT polyglot_transpile('$escapedForTranspile', 'snowflake') AS transpiled;")
            $transpileErr = Join-Path $scratchDir "transpile_${index}.err"
            $transpileOut = & duckdb -csv -f $transpileScript 2>$transpileErr
            $transpileText = ($transpileOut -join "`r`n")
            Add-Content -LiteralPath $transpileFile -Value ("=== $($row.name) ($(if ($pass) { 'PASS' } else { 'FAIL' })) ===`r`n$transpileText`r`n")
        }
    }
}

# --- Before/after table ---
Write-Output ''
Write-Output 'BEFORE/AFTER TABLE'
$header = @('name') + ($modesToRun | ForEach-Object { Get-ModeLabel $_ })
Write-Output ($header -join ',')
foreach ($row in $rows) {
    $cells = @($row.name)
    foreach ($m in $modesToRun) {
        $cells += if ($allResults[$row.name][$m].Pass) { 'PASS' } else { 'FAIL' }
    }
    Write-Output ($cells -join ',')
}

# --- Three-way split: verified / deviation / fail (C4) ---
Write-Output ''
foreach ($m in $modesToRun) {
    $verifiedCount = @($rows | Where-Object { $allResults[$_.name][$m].Category -eq 'verified' }).Count
    $deviationCount = @($rows | Where-Object { $allResults[$_.name][$m].Category -eq 'deviation' }).Count
    $failCount = @($rows | Where-Object { $allResults[$_.name][$m].Category -eq 'fail' }).Count
    $label = Get-ModeLabel $m
    $passCount = $verifiedCount + $deviationCount
    Write-Output "$label pass count: $passCount / $($rows.Count)  (verified: $verifiedCount  deviation: $deviationCount  fail: $failCount)"
}

# --- Residual list (only meaningful when all three modes ran) ---
if ($modesToRun -contains 'raw' -and $modesToRun -contains 'macro' -and $modesToRun -contains 'polyglot') {
    $residuals = @($rows | Where-Object {
        -not $allResults[$_.name]['raw'].Pass -and
        -not $allResults[$_.name]['macro'].Pass -and
        -not $allResults[$_.name]['polyglot'].Pass
    } | ForEach-Object { $_.name })
    Write-Output ''
    Write-Output "RESIDUAL (no mode reaches, $($residuals.Count) of $($rows.Count)): $($residuals -join ', ')"

    $regressions = @($rows | Where-Object {
        $allResults[$_.name]['raw'].Pass -and
        -not $allResults[$_.name]['macro'].Pass -and
        -not $allResults[$_.name]['polyglot'].Pass
    } | ForEach-Object { $_.name })
    if ($regressions.Count -gt 0) {
        Write-Output "REGRESSION (passes raw, fails macro AND polyglot): $($regressions -join ', ')"
    } else {
        Write-Output 'REGRESSION: none (zero regressions holds)'
    }
}

if ($modesToRun -contains 'polyglot') {
    Write-Output ''
    Write-Output "polyglot_transpile output for every row written to: $transpileFile"
}

if ($hadFailure) {
    exit 1
} else {
    exit 0
}
