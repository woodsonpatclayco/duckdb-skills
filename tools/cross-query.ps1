<#
tools\cross-query.ps1 -Sql <path to .sql> [-Save <table>] [-Limit <n>]
                      [-ExtractRoot <dir>] [-LakeRoot <dir>]

TASK.md item 8: runs a single SELECT that joins a Snowflake extract
(`extract_table('<name>')`) to a workbook sheet materialized in the DuckLake
lakehouse (`lake.<table>`), printing the age of every input before the answer.
Freshness is reported, never enforced (D4) -- a stale extract or a lake table
whose workbook has changed prints loudly and is recorded, never refused.

D1: this is a runner, not a macro a session loads by hand -- it computes ages
from the registry and the lake manifest BEFORE running the query, and nothing
about invoking it lets a caller skip that. D2: extracts are referenced as
extract_table('<name>'), resolved from the registry at run time -- the query
text never contains a path. D3: every input must be dateable, so the parser
below refuses anything it cannot date (a quoted path, read_parquet/read_csv/
read_xlsx/read_json, any table function other than an unqualified
extract_table, or a BASE_TABLE that is not exactly a lake input or a CTE).
D5: a saved join is a TABLE (never a VIEW -- a view loses its macro in a new
process), with its inputs' versions recorded in a new lake.join_manifest;
lake.manifest itself is never touched by this script.

The allow-list is by EXACT parse-tree shape, never by "looks like a path" --
a quoted file path and a CTE name are the same BASE_TABLE shape (catalog and
schema both empty), so CTE names are collected first (every cte_map.map[]
entry, at any depth) and only a BASE_TABLE whose unqualified name matches a
collected CTE is treated as one. Every other BASE_TABLE must be exactly
`lake.<table>` (catalog empty, schema=lake) or `lake.main.<table>` (catalog=
lake, schema=main) -- anything else is refused, including a qualified node
that merely happens to be schema/catalog-tagged with something other than
those two shapes (e.g. `lake.x.parquet`, which is catalog=lake schema=x
table=parquet -- neither shape -- refused by the same "not a lake table or an
extract" rule as a quoted path, not by the lake-table-missing rule; see
RESULT-1.md's disagreement note, since TASK.md's own prose claims this exact
case is caught by the missing-table rule, which is not what the parse tree
measured here produces).

Every DuckDB invocation is a fresh `duckdb -f <file>` process -- there is no
persistent session across them (same rule as materialize.ps1/lake-status.ps1).
Parsing uses `.mode json` (never the label/CSV convention those two scripts
use) because the parse tree and the query text itself may contain commas and
quotes; the actual result rows printed to the user are plain passthrough CSV
from a `.mode csv` block DuckDB itself formats, never reparsed.

A trailing `--` comment in the query text would otherwise swallow an appended
`;` when the text is embedded directly as SQL (not as a quoted string literal)
-- see step 3's embedding, which always puts a newline before the following
`;`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Sql,
    [string]$Save,
    [int]$Limit = 20,
    [string]$ExtractRoot,
    [string]$LakeRoot
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsk-paths.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$registrySql = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\skills\snowflake-extract\registry.sql'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- usage errors (exit 2) -----------------------------------------------------------

if (-not $Sql) {
    Write-Output 'ERROR,usage,-Sql is required'
    exit 2
}
if (-not (Test-Path -LiteralPath $Sql -PathType Leaf)) {
    Write-Output "ERROR,usage,file not found: $Sql"
    exit 2
}

# --- small helpers --------------------------------------------------------------------

function Invoke-DuckdbCsv {
    # `.mode csv` / `.headers off` batch, label-first-field convention -- safe only
    # for fields that are by construction comma-free and quote-free (hashes,
    # timestamps, booleans, integers, UUIDs, row counts).
    param([string]$SqlText)
    $scratchDir = Join-Path $env:TEMP "dsk-crossquery-csv-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    try {
        $body = ".mode csv`r`n.headers off`r`n" + $SqlText
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

function Invoke-DuckdbJsonScalar {
    # Runs a single `SELECT <expr> AS js;` in `.mode json`, returns the PARSED
    # object graph of the js column's own text (double-JSON: DuckDB's json mode
    # wraps the row as a JSON object; the js column's value is itself JSON text,
    # decoded a second time here) -- avoids CSV escaping entirely for content
    # that contains commas, quotes or newlines (a parse tree, a query's own text).
    param([string]$SelectExpr)
    $scratchDir = Join-Path $env:TEMP "dsk-crossquery-json-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    try {
        $body = ".mode json`r`n.headers off`r`n$SelectExpr`r`n"
        $f = Join-Path $scratchDir 'batch.sql'
        [System.IO.File]::WriteAllText($f, $body, $utf8NoBom)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & duckdb -f $f 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $rawText = ($out | ForEach-Object { [string]$_ }) -join "`n"
        if ($exit -ne 0) {
            return [pscustomobject]@{ ExitCode = $exit; RawText = $rawText; Value = $null }
        }
        $outer = $null
        try { $outer = $rawText | ConvertFrom-Json } catch { $outer = $null }
        if (-not $outer -or $outer.Count -eq 0) {
            return [pscustomobject]@{ ExitCode = $exit; RawText = $rawText; Value = $null }
        }
        $firstRow = $outer[0]
        $propName = ($firstRow.PSObject.Properties | Select-Object -First 1).Name
        $innerText = $firstRow.$propName
        $value = $null
        if ($null -ne $innerText) {
            try { $value = $innerText | ConvertFrom-Json } catch { $value = $innerText }
        }
        return [pscustomobject]@{ ExitCode = $exit; RawText = $rawText; Value = $value }
    } finally {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DuckdbJsonBatch {
    # Runs several labelled `SELECT '<LBL>', ... ;` statements in ONE `.mode json`
    # process and flattens every row from every statement into one list -- each
    # DuckDB CLI statement under `.mode json` prints its own JSON array on its
    # own line, so this is real, comma/quote-safe JSON parsing throughout
    # (never the label/CSV naive-split convention, which breaks the moment a
    # field can contain a comma -- e.g. this repo's own workbook path,
    # "...\Clayco, Inc\...", read back via source_path).
    param([string]$SqlText)
    $scratchDir = Join-Path $env:TEMP "dsk-crossquery-jsonbatch-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    try {
        $body = ".mode json`r`n.headers off`r`n" + $SqlText
        $f = Join-Path $scratchDir 'batch.sql'
        [System.IO.File]::WriteAllText($f, $body, $utf8NoBom)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & duckdb -f $f 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $lines = @($out | ForEach-Object { [string]$_ })
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($line in $lines) {
            $trimmed = $line.Trim().TrimStart([char]0xFEFF)
            if ($trimmed.StartsWith('[')) {
                try {
                    $arr = $trimmed | ConvertFrom-Json
                    foreach ($r in @($arr)) { $rows.Add($r) }
                } catch { }
            }
        }
        return [pscustomobject]@{ ExitCode = $exit; Rows = $rows; Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-SqlLiteral {
    param($Value)
    if ($null -eq $Value) { return 'NULL' }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function ConvertFrom-SqlNull {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq 'NULL') { return $null }
    return $Text
}

function Get-CsvField {
    param([string]$Line, [int]$Count)
    return $Line -split ',', $Count
}

function Assert-UnderTemp {
    # Every -Save / mutation / Remove-Item target must be proven scratch before
    # it is touched -- prints the assertion so the run's own log carries it.
    param([string]$Path, [string]$Label)
    $full = [System.IO.Path]::GetFullPath($Path)
    $tempFull = [System.IO.Path]::GetFullPath($env:TEMP)
    $ok = $full.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)
    Write-Verbose "ASSERT_UNDER_TEMP,$Label,$full,$ok"
    if (-not $ok) {
        Write-Output "ERROR,safety,$Label is not under `$env:TEMP -- refusing to touch it: $full"
        exit 1
    }
}

function Get-AllNodes {
    # Flattens the entire parsed object graph into a list of every
    # PSCustomObject node encountered, at any depth, through objects and arrays.
    param($Obj)
    $result = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($Obj)
    while ($stack.Count -gt 0) {
        $o = $stack.Pop()
        if ($null -eq $o) { continue }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $result.Add($o)
            foreach ($prop in $o.PSObject.Properties) { $stack.Push($prop.Value) }
        } elseif (($o -is [System.Collections.IEnumerable]) -and -not ($o -is [string])) {
            foreach ($item in $o) { $stack.Push($item) }
        }
    }
    return $result
}

function Get-CteNames {
    # Every cte_map.map[] entry's key, at any depth -- a scope-blind collection
    # by design (D3 finding 1: a CTE referenced outside its own scope is still
    # a CTE name for allow-list purposes; a name containing path characters is
    # refused separately, which is what closes that hole).
    param($AllNodes)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($node in $AllNodes) {
        if ($node.PSObject.Properties.Name -contains 'cte_map') {
            $cm = $node.cte_map
            if ($cm -and ($cm.PSObject.Properties.Name -contains 'map') -and $cm.map) {
                foreach ($entry in @($cm.map)) {
                    if ($entry.PSObject.Properties.Name -contains 'key') {
                        $names.Add([string]$entry.key)
                    }
                }
            }
        }
    }
    return $names
}

function Get-BaseTableDisplayName {
    param($Node)
    $parts = @()
    if ($Node.catalog_name) { $parts += $Node.catalog_name }
    if ($Node.schema_name) { $parts += $Node.schema_name }
    $parts += $Node.table_name
    return ($parts -join '.')
}

function Fail-Refusal {
    param([string]$Line)
    Write-Output $Line
    exit 1
}

function Write-LakeDatingLine {
    # Prints the LAKE/SAVED/provenance=NONE line for one table and records its
    # provenance in $LakeInputInfos / $LakeStaleFlags (both hashtables, mutated
    # in place). Shared by the -Save path (dating resolved in its own process,
    # before the save script is built) and the read-only path (dating rows
    # read out of the SAME process as the run itself).
    param(
        [string]$Table,
        $ContractRow,
        $RefusedRow,
        $SavedRow,
        [datetime]$NowUtc,
        $Window,
        [hashtable]$LakeInputInfos,
        [hashtable]$LakeStaleFlags
    )
    if ($ContractRow) {
        $runId = [string]$ContractRow.run_id
        $materializedAt = [string]$ContractRow.materialized_at
        $sourceMtime = [string]$ContractRow.source_mtime
        $sourcePathFwd = if ($ContractRow.source_path) { [string]$ContractRow.source_path } else { $null }
        $rowCount = [string]$ContractRow.row_count

        $refusedCount = 0
        if ($RefusedRow) { [void][int64]::TryParse([string]$RefusedRow.n, [ref]$refusedCount) }

        $workbookChangedSuffix = $null
        if ($sourcePathFwd) {
            $sourcePathWin = $sourcePathFwd -replace '/', '\'
            if (Test-Path -LiteralPath $sourcePathWin -PathType Leaf) {
                $currentMtimeText = (Get-Item -LiteralPath $sourcePathWin).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                $changed = ($currentMtimeText -ne $sourceMtime)
                $workbookChangedSuffix = "workbook_changed_since=$($changed.ToString().ToLowerInvariant())"
                $LakeStaleFlags[$Table] = $changed
            } else {
                $workbookChangedSuffix = 'workbook_present=false'
            }
        } else {
            $workbookChangedSuffix = 'workbook_present=false'
        }

        $matAtParsed = [datetime]::Parse($materializedAt, [System.Globalization.CultureInfo]::InvariantCulture)
        $ageMinutes = [string][int64][Math]::Floor(($NowUtc - $matAtParsed).TotalMinutes)

        $refusedSuffix = if ($refusedCount -gt 0) { ",refused_since=$refusedCount" } else { '' }
        Write-Output "LAKE,$Table,age_minutes=$ageMinutes,materialized_at=$materializedAt,$workbookChangedSuffix$refusedSuffix"

        $LakeInputInfos[$Table] = [pscustomobject]@{
            Kind           = 'contract'
            Version        = $runId
            MaterializedAt = $materializedAt
            RowCount       = $rowCount
        }
    } elseif ($SavedRow) {
        $runId = [string]$SavedRow.run_id
        $savedAt = [string]$SavedRow.saved_at
        $inputsParsed = @()
        if ($SavedRow.inputs) {
            try {
                # NOTE: `@(<pipeline> | ConvertFrom-Json)` wrapped directly around
                # the pipeline silently collapses a multi-element JSON array into
                # ONE object whose properties become parallel arrays, on this
                # PowerShell 5.1 build -- measured directly. Assigning the
                # ConvertFrom-Json result to a variable FIRST, then wrapping that
                # variable with @(), is unaffected and is required here.
                $inputsParsedRaw = [string]$SavedRow.inputs | ConvertFrom-Json
                $inputsParsed = @($inputsParsedRaw)
            } catch { $inputsParsed = @() }
        }

        $oldestMaterializedAt = $null
        $inputPairs = New-Object System.Collections.Generic.List[string]
        foreach ($inp in $inputsParsed) {
            $inputPairs.Add("$($inp.name)@$($inp.version)")
            if ($inp.materialized_at) {
                if (-not $oldestMaterializedAt -or ([datetime]$inp.materialized_at) -lt ([datetime]$oldestMaterializedAt)) {
                    $oldestMaterializedAt = $inp.materialized_at
                }
            }
        }
        if (-not $oldestMaterializedAt) { $oldestMaterializedAt = $savedAt }

        $oldestParsed = [datetime]::Parse($oldestMaterializedAt, [System.Globalization.CultureInfo]::InvariantCulture)
        $ageMinutesNum = ($NowUtc - $oldestParsed).TotalMinutes
        $ageMinutes = [string][int64][Math]::Floor($ageMinutesNum)
        $ageIsStale = ($ageMinutesNum -gt [double]$Window)
        $LakeStaleFlags[$Table] = $ageIsStale

        $inputsDisplay = if ($inputPairs.Count -gt 0) { $inputPairs -join ';' } else { 'none' }
        Write-Output "SAVED,$Table,age_minutes=$ageMinutes,saved_at=$savedAt,inputs=$inputsDisplay"

        $LakeInputInfos[$Table] = [pscustomobject]@{
            Kind           = 'saved'
            Version        = $runId
            MaterializedAt = $oldestMaterializedAt
            RowCount       = $null
        }
    } else {
        Write-Output "LAKE,$Table,provenance=NONE"
    }
}

# --- 1. parse and refuse ---------------------------------------------------------------

$rawQueryText = Get-Content -LiteralPath $Sql -Raw
$queryText = $rawQueryText.TrimEnd()
if ($queryText.EndsWith(';')) {
    $queryText = $queryText.Substring(0, $queryText.Length - 1).TrimEnd()
}
if (-not $queryText) {
    Write-Output 'ERROR,parse,query file is empty'
    exit 1
}

$queryLiteral = ConvertTo-SqlLiteral $queryText
$parseResult = Invoke-DuckdbJsonScalar -SelectExpr "SELECT json_serialize_sql($queryLiteral) AS js;"
if ($parseResult.ExitCode -ne 0) {
    Write-Output "ERROR,parse,could not invoke the parser: $($parseResult.RawText)"
    exit 1
}
$tree = $parseResult.Value
if (-not $tree) {
    Write-Output "ERROR,parse,empty parse result: $($parseResult.RawText)"
    exit 1
}
if ($tree.PSObject.Properties.Name -contains 'error' -and $tree.error -eq $true) {
    Fail-Refusal "ERROR,parse,$($tree.error_message)"
}
$statements = @($tree.statements)
if ($statements.Count -ne 1) {
    Fail-Refusal "ERROR,parse,expected exactly 1 SELECT statement, found $($statements.Count)"
}

$allNodes = Get-AllNodes -Obj $statements[0]
$cteNamesLower = @(Get-CteNames -AllNodes $allNodes | ForEach-Object { $_.ToLowerInvariant() })

$baseTableNodes = @($allNodes | Where-Object { $_.PSObject.Properties.Name -contains 'type' -and $_.type -eq 'BASE_TABLE' })
$tableFunctionNodes = @($allNodes | Where-Object { $_.PSObject.Properties.Name -contains 'type' -and $_.type -eq 'TABLE_FUNCTION' })

# -- extract_table(...) argument must be a single string constant; any other
# table function (including a qualified extract_table) is refused outright. --
$extractNamesOrdered = New-Object System.Collections.Generic.List[string]
$extractNamesSeen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($tf in $tableFunctionNodes) {
    $fn = $tf.function
    $fname = [string]$fn.function_name
    $isUnqualifiedExtractTable = ($fname.ToLowerInvariant() -eq 'extract_table') -and (-not $fn.schema) -and (-not $fn.catalog)
    if ($fname.ToLowerInvariant() -eq 'extract_table') {
        $children = @($fn.children)
        $literalOk = ($children.Count -eq 1) -and ($children[0].class -eq 'CONSTANT') -and ($children[0].value.type.id -eq 'VARCHAR')
        if (-not $literalOk) {
            Fail-Refusal "ERROR,input,extract_table,argument must be a single string constant naming the extract"
        }
    }
    if (-not $isUnqualifiedExtractTable) {
        Fail-Refusal "ERROR,input,$fname,table function not permitted -- use lake.<table> or extract_table('<name>')"
    }
    $name = [string]$fn.children[0].value.value
    if ($extractNamesSeen.Add($name.ToLowerInvariant())) {
        $extractNamesOrdered.Add($name)
    }
}

# -- CTE names may not contain path characters (closes the scope-blind hole). --
foreach ($cteName in (Get-CteNames -AllNodes $allNodes)) {
    if ($cteName -match '[./\\:]') {
        Fail-Refusal "ERROR,input,$cteName,CTE name may not contain path characters"
    }
}

# -- classify every BASE_TABLE node by exact shape. ------------------------------------
$lakeNamesOrdered = New-Object System.Collections.Generic.List[string]
$lakeNamesSeen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($bt in $baseTableNodes) {
    $catalog = [string]$bt.catalog_name
    $schema = [string]$bt.schema_name
    $table = [string]$bt.table_name
    $isLakeMain = ($catalog.ToLowerInvariant() -eq 'lake') -and ($schema.ToLowerInvariant() -eq 'main')
    $isBareLake = (-not $catalog) -and ($schema.ToLowerInvariant() -eq 'lake')
    $isCte = (-not $catalog) -and (-not $schema) -and ($cteNamesLower -contains $table.ToLowerInvariant())
    if ($isLakeMain -or $isBareLake) {
        if ($lakeNamesSeen.Add($table.ToLowerInvariant())) { $lakeNamesOrdered.Add($table) }
    } elseif ($isCte) {
        # ignored
    } else {
        $displayName = Get-BaseTableDisplayName -Node $bt
        Fail-Refusal "ERROR,input,$displayName,not a lake table or an extract -- use lake.<table> or extract_table('<name>')"
    }
}

if ($extractNamesOrdered.Count -eq 0 -and $lakeNamesOrdered.Count -eq 0) {
    Fail-Refusal 'ERROR,input,query references no extract_table and no lake table'
}

# -- -Save name rules (independent of the query's own inputs). -------------------------
$reservedSaveNames = @('manifest', 'check_history', 'join_manifest')
if ($Save) {
    if ($Save -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Fail-Refusal "ERROR,save,$Save,invalid table name -- must match ^[A-Za-z_][A-Za-z0-9_]*`$"
    }
    if ($reservedSaveNames -contains $Save.ToLowerInvariant()) {
        Fail-Refusal "ERROR,save,$Save,reserved name -- may not be used for a saved join"
    }
}

# --- 2. date every input, before running anything ---------------------------------------

$window = $env:DSK_WINDOW_MINUTES
if (-not $window) { $window = 60 }

$extractInfos = @{}   # name -> pscustomobject{ ParquetGlob, MaterializedAt, RowCount, AgeText, Stale }
$lakeStaleFlags = @{}   # table name -> bool (workbook_changed_since / saved-oldest-input stale)

if ($extractNamesOrdered.Count -gt 0) {
    $extractRootResolved, $usedDefaultExtractRoot = Resolve-ExtractRoot $ExtractRoot
    foreach ($name in $extractNamesOrdered) {
        $extractDir = Join-Path $extractRootResolved $name
        $sidecarPath = Join-Path $extractDir '_extract.json'
        if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
            Fail-Refusal "ERROR,extract,$name,not in the registry at $extractRootResolved"
        }
        $env:DSK_EXTRACT_DIR = $extractDir
        $env:DSK_EXTRACT_NAME = $name
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $csvLines = & duckdb -csv -f $registrySql 2>&1
        $regExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($regExit -ne 0) {
            Fail-Refusal "ERROR,extract,$name,$($csvLines -join ' | ')"
        }
        if (-not $csvLines -or $csvLines.Count -lt 2) {
            Fail-Refusal "ERROR,extract,$name,registry.sql returned no row"
        }
        $row = (($csvLines -join "`n") | ConvertFrom-Csv) | Select-Object -First 1
        $reason = if ($row.reason) { [string]$row.reason } else { '' }
        if ($reason) {
            Fail-Refusal "ERROR,extract,$name,$reason"
        }
        $ageRaw = $row.age_minutes
        $ageMinutes = $null
        if ($ageRaw -and $ageRaw -ne 'NULL' -and $ageRaw -ne '') {
            $parsedAge = 0.0
            if ([double]::TryParse($ageRaw, [ref]$parsedAge)) { $ageMinutes = $parsedAge }
        }
        $ageText = $null
        $isStale = $false
        if ($null -eq $ageMinutes) {
            $ageText = 'UNKNOWN'
            $isStale = $true
        } elseif ($ageMinutes -lt 0) {
            $ageText = 'UNKNOWN'
            $isStale = $true
        } else {
            $ageText = [string][int64]$ageMinutes
            $isStale = ($ageMinutes -gt [double]$window)
        }
        if ($isStale) { }
        $rowCount = ConvertFrom-SqlNull ([string]$row.row_count)
        $materializedAt = ConvertFrom-SqlNull ([string]$row.materialized_at)
        $parquetGlob = [string]$row.parquet_glob

        $extractInfos[$name] = [pscustomobject]@{
            ParquetGlob    = $parquetGlob
            MaterializedAt = $materializedAt
            RowCount       = $rowCount
            AgeText        = $ageText
            Stale          = $isStale
        }
        Write-Output "EXTRACT,$name,age_minutes=$ageText,window=$window,stale=$($isStale.ToString().ToLowerInvariant()),rows=$rowCount,materialized_at=$materializedAt"
    }
}

# -- lake inputs: contract vs saved join vs neither. Resolve the lake root only
# if the query has a lake input or -Save is set. -----------------------------------------
$lakeCatalogFile = $null
$lakeDataDir = $null
$lakeRootResolved = $null
$lakeExists = $false
if ($lakeNamesOrdered.Count -gt 0 -or $Save) {
    $lakeRootResolved, $usedDefaultLakeRoot = Resolve-LakeRoot -ExplicitRoot $LakeRoot
    $lakeCatalogFile = Join-Path $lakeRootResolved 'lake.ducklake'
    $lakeDataDir = Join-Path $lakeRootResolved 'data'
    $lakeExists = Test-Path -LiteralPath $lakeCatalogFile -PathType Leaf
}

if ($lakeNamesOrdered.Count -gt 0 -and -not $lakeExists) {
    Fail-Refusal "ERROR,lake,no lake at $lakeRootResolved -- run tools\materialize.ps1 first"
}

$lakeCatalogFwd = if ($lakeCatalogFile) { $lakeCatalogFile -replace '\\', '/' } else { $null }
$lakeDataDirFwd = if ($lakeDataDir) { $lakeDataDir -replace '\\', '/' } else { $null }

$lakeInputInfos = @{}   # name -> pscustomobject{ Kind ('contract'|'saved'), Version, MaterializedAt, RowCount }

# -- Dating strategy: for the -Save path, dating must fully resolve BEFORE the
# run/save script is built (its own inputs JSON needs every input's version),
# so each table is dated via its own small process below. For the read-only
# path (the common, latency-sensitive case -- AC1's 2s budget), dating is
# read-only and race-free, so it is instead merged into the SAME process as
# the run itself (built further down) -- this section only handles the -Save
# case; $deferredDatingTables carries the read-only case's table list past
# this point untouched. ------------------------------------------------------------
$deferredDatingTables = @()

if ($Save) {
    foreach ($table in $lakeNamesOrdered) {
        $tableLit = ConvertTo-SqlLiteral $table
        $attachRo = "LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd', READ_ONLY);`r`n"

        # -- one combined process for this table's dating: contract row, count of
        # newer REFUSED contract rows, the current UTC instant, and whether
        # lake.join_manifest exists at all (referencing it directly when it does
        # not exist yet -- true before this repo's first-ever -Save -- would abort
        # the whole statement and lose the CONTRACT row too, since `duckdb -f`
        # stops at the first error). JSON mode throughout: source_path and inputs
        # can both contain literal commas (e.g. this repo's own workbook path,
        # "...\Clayco, Inc\..."), so the label/CSV naive-split convention is not
        # safe here. A second, SAVED-only call follows only if no contract row was
        # found and join_manifest actually exists. -------------------------------------
        $combinedSql = $attachRo + @"
SELECT 'CONTRACT' AS lbl, run_id, materialized_at, source_mtime, source_path, row_count, lake_snapshot_id
FROM lake.manifest
WHERE lower(contract_name) = lower($tableLit) AND (checks_passed OR forced)
ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC
LIMIT 1;
SELECT 'REFUSED_COUNT' AS lbl, count(*) AS n
FROM lake.manifest
WHERE lower(contract_name) = lower($tableLit)
  AND NOT (checks_passed OR forced)
  AND materialized_at > coalesce((SELECT materialized_at FROM lake.manifest WHERE lower(contract_name) = lower($tableLit) AND (checks_passed OR forced) ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1), '1900-01-01'::TIMESTAMP);
SELECT 'NOW_UTC' AS lbl, timezone('UTC', now()) AS now_utc;
SELECT 'JM_EXISTS' AS lbl, count(*) AS n FROM duckdb_tables() WHERE database_name = 'lake' AND lower(table_name) = 'join_manifest';
"@
        $combinedResult = Invoke-DuckdbJsonBatch -SqlText $combinedSql
        $rows = $combinedResult.Rows
        $contractRow = $rows | Where-Object { $_.lbl -eq 'CONTRACT' } | Select-Object -First 1
        $refusedRow = $rows | Where-Object { $_.lbl -eq 'REFUSED_COUNT' } | Select-Object -First 1
        $nowUtcRow = $rows | Where-Object { $_.lbl -eq 'NOW_UTC' } | Select-Object -First 1
        $jmExistsRow = $rows | Where-Object { $_.lbl -eq 'JM_EXISTS' } | Select-Object -First 1
        $nowUtcText = if ($nowUtcRow) { [string]$nowUtcRow.now_utc } else { $null }
        $nowUtc = if ($nowUtcText) { [datetime]::Parse($nowUtcText, [System.Globalization.CultureInfo]::InvariantCulture) } else { [datetime]::UtcNow }
        $jmExists = $false
        if ($jmExistsRow) { $jmN = 0; [void][int]::TryParse([string]$jmExistsRow.n, [ref]$jmN); $jmExists = ($jmN -gt 0) }

        $savedRow = $null
        if (-not $contractRow -and $jmExists) {
            $savedSql = $attachRo + @"
SELECT 'SAVED' AS lbl, run_id, saved_at, inputs, lake_snapshot_id
FROM lake.join_manifest
WHERE lower(table_name) = lower($tableLit)
ORDER BY saved_at DESC
LIMIT 1;
"@
            $savedResult = Invoke-DuckdbJsonBatch -SqlText $savedSql
            $savedRow = $savedResult.Rows | Where-Object { $_.lbl -eq 'SAVED' } | Select-Object -First 1
        }

        Write-LakeDatingLine -Table $table -ContractRow $contractRow -RefusedRow $refusedRow -SavedRow $savedRow -NowUtc $nowUtc -Window $window -LakeInputInfos $lakeInputInfos -LakeStaleFlags $lakeStaleFlags
    }
} else {
    $deferredDatingTables = @($lakeNamesOrdered)
}

# -- -Save collision checks (need the lake root; skip cleanly if no catalog yet). -------
if ($Save -and $lakeExists) {
    $saveLit = ConvertTo-SqlLiteral $Save
    $attachRo = "LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd', READ_ONLY);`r`n"
    # join_manifest may not exist yet (first-ever save) -- referencing it
    # directly would error the whole statement, so its own existence is
    # checked via duckdb_tables() first, never by querying it blind.
    $existsSql = $attachRo + @"
SELECT (SELECT count(*) FROM duckdb_tables() WHERE database_name = 'lake' AND lower(table_name) = lower($saveLit)) AS table_exists,
       (SELECT count(*) FROM duckdb_tables() WHERE database_name = 'lake' AND lower(table_name) = 'join_manifest') AS jm_exists;
"@
    $existsResult = Invoke-DuckdbCsv -SqlText $existsSql
    $tableExists = $false
    $joinManifestTableExists = $false
    if ($existsResult.ExitCode -eq 0 -and $existsResult.Lines.Count -gt 0) {
        $f = Get-CsvField -Line $existsResult.Lines[0] -Count 2
        $n = 0; $n2 = 0
        [void][int]::TryParse($f[0], [ref]$n)
        [void][int]::TryParse($f[1], [ref]$n2)
        $tableExists = ($n -gt 0)
        $joinManifestTableExists = ($n2 -gt 0)
    }
    $hasJoinManifestRow = $false
    if ($tableExists -and $joinManifestTableExists) {
        $rowExistsSql = $attachRo + "SELECT count(*) FROM lake.join_manifest WHERE lower(table_name) = lower($saveLit);`r`n"
        $rowExistsResult = Invoke-DuckdbCsv -SqlText $rowExistsSql
        if ($rowExistsResult.ExitCode -eq 0 -and $rowExistsResult.Lines.Count -gt 0) {
            $n3 = 0
            [void][int]::TryParse($rowExistsResult.Lines[0], [ref]$n3)
            $hasJoinManifestRow = ($n3 -gt 0)
        }
    }
    if ($tableExists -and -not $hasJoinManifestRow) {
        Fail-Refusal "ERROR,save,$Save,a saved join may only replace a saved join, never a contract table"
    }
}

# --- 3 & 4. run (and optionally save), in one fresh duckdb process ---------------------

if ($extractNamesOrdered.Count -gt 0 -or $lakeNamesOrdered.Count -gt 0 -or $Save) {
    if (-not $lakeRootResolved -and ($lakeNamesOrdered.Count -gt 0 -or $Save)) {
        $lakeRootResolved, $null = Resolve-LakeRoot -ExplicitRoot $LakeRoot
        $lakeCatalogFile = Join-Path $lakeRootResolved 'lake.ducklake'
        $lakeDataDir = Join-Path $lakeRootResolved 'data'
        $lakeCatalogFwd = $lakeCatalogFile -replace '\\', '/'
        $lakeDataDirFwd = $lakeDataDir -replace '\\', '/'
    }
}

if ($Save) {
    Assert-UnderTemp -Path $lakeRootResolved -Label 'LakeRoot (save)'
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("LOAD ducklake;`r`n")
if ($lakeRootResolved) {
    $attachOpts = if ($Save) { "DATA_PATH '$lakeDataDirFwd'" } else { "DATA_PATH '$lakeDataDirFwd', READ_ONLY" }
    [void]$sb.Append("ATTACH 'ducklake:$lakeCatalogFwd' AS lake ($attachOpts);`r`n")
}

# -- deferred (read-only-path) dating: merged into this SAME process rather
# than a separate one, since it is read-only and race-free here (D1's "before
# running" requirement is about the printed ages being unconditional, not
# about literal process ordering -- see the header comment). --------------------
if ($deferredDatingTables.Count -gt 0) {
    [void]$sb.Append(".mode json`r`n.headers off`r`n")
    foreach ($table in $deferredDatingTables) {
        $tableLit = ConvertTo-SqlLiteral $table
        [void]$sb.Append(@"
SELECT 'CONTRACT' AS lbl, $tableLit AS tbl, run_id, materialized_at, source_mtime, source_path, row_count, lake_snapshot_id
FROM lake.manifest
WHERE lower(contract_name) = lower($tableLit) AND (checks_passed OR forced)
ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC
LIMIT 1;
SELECT 'REFUSED_COUNT' AS lbl, $tableLit AS tbl, count(*) AS n
FROM lake.manifest
WHERE lower(contract_name) = lower($tableLit)
  AND NOT (checks_passed OR forced)
  AND materialized_at > coalesce((SELECT materialized_at FROM lake.manifest WHERE lower(contract_name) = lower($tableLit) AND (checks_passed OR forced) ORDER BY lake_snapshot_id DESC NULLS LAST, materialized_at DESC LIMIT 1), '1900-01-01'::TIMESTAMP);
"@)
    }
    [void]$sb.Append("SELECT 'NOW_UTC' AS lbl, '' AS tbl, timezone('UTC', now()) AS now_utc;`r`n")
    [void]$sb.Append("SELECT 'JM_EXISTS' AS lbl, '' AS tbl, count(*) AS n FROM duckdb_tables() WHERE database_name = 'lake' AND lower(table_name) = 'join_manifest';`r`n")
}

if ($extractNamesOrdered.Count -gt 0) {
    $mapEntries = @($extractNamesOrdered | ForEach-Object {
        $glob = $extractInfos[$_].ParquetGlob
        "$(ConvertTo-SqlLiteral $_): $(ConvertTo-SqlLiteral $glob)"
    })
    [void]$sb.Append("SET VARIABLE dsk_extract_globs = MAP {$($mapEntries -join ', ')};`r`n")
    [void]$sb.Append("CREATE MACRO extract_table(n) AS TABLE SELECT * FROM read_parquet(coalesce(getvariable('dsk_extract_globs')[n], error('unknown extract: ' || n || ' (not in the registry)')));`r`n")
}
[void]$sb.Append(".timer on`r`n")
[void]$sb.Append("CREATE TEMP TABLE _r AS`r`n$queryText`r`n;`r`n")
[void]$sb.Append(".timer off`r`n")
[void]$sb.Append("SET VARIABLE dsk_rows = (SELECT count(*) FROM _r);`r`n")

$runId = [guid]::NewGuid().ToString()
if ($Save) {
    $inputsList = New-Object System.Collections.Generic.List[object]
    foreach ($name in $extractNamesOrdered) {
        $info = $extractInfos[$name]
        $inputsList.Add([ordered]@{ kind = 'extract'; name = $name; version = $info.MaterializedAt; materialized_at = $info.MaterializedAt; row_count = $info.RowCount })
    }
    foreach ($table in $lakeNamesOrdered) {
        $info = $lakeInputInfos[$table]
        if ($info) {
            $inputsList.Add([ordered]@{ kind = $info.Kind; name = $table; version = $info.Version; materialized_at = $info.MaterializedAt; row_count = $info.RowCount })
        }
    }
    $inputsJson = ($inputsList | ConvertTo-Json -Depth 10 -Compress)
    $querySha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($queryText))).Replace('-', '').ToLowerInvariant()

    [void]$sb.Append("CREATE TABLE IF NOT EXISTS lake.join_manifest (run_id UUID, saved_at TIMESTAMP, table_name VARCHAR, query VARCHAR, query_sha256 VARCHAR, row_count BIGINT, inputs VARCHAR, lake_snapshot_id BIGINT);`r`n")
    [void]$sb.Append("CREATE OR REPLACE TABLE lake." + '"' + $Save + '"' + " AS SELECT * FROM _r;`r`n")
    [void]$sb.Append("SET VARIABLE dsk_snap = (SELECT max(snapshot_id) FROM lake.snapshots());`r`n")
    [void]$sb.Append("INSERT INTO lake.join_manifest VALUES ($(ConvertTo-SqlLiteral $runId)::UUID, timezone('UTC', now())::TIMESTAMP, $(ConvertTo-SqlLiteral $Save), $(ConvertTo-SqlLiteral $queryText), $(ConvertTo-SqlLiteral $querySha256), getvariable('dsk_rows'), $(ConvertTo-SqlLiteral $inputsJson), getvariable('dsk_snap'));`r`n")
}

[void]$sb.Append(".mode csv`r`n.headers off`r`n")
[void]$sb.Append("SELECT 'ROWCOUNT', getvariable('dsk_rows');`r`n")
[void]$sb.Append(".mode csv`r`n.headers on`r`n")
[void]$sb.Append("SELECT * FROM _r LIMIT $Limit;`r`n")

$fullScript = $sb.ToString()
Write-Verbose "GENERATED_SQL:`r`n$fullScript"

$scratchDir = Join-Path $env:TEMP "dsk-crossquery-run-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
$scriptFile = Join-Path $scratchDir 'run.sql'
[System.IO.File]::WriteAllText($scriptFile, $fullScript, $utf8NoBom)

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$runOutput = & duckdb -f $scriptFile 2>&1
$runExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue

$runLines = @($runOutput | ForEach-Object { [string]$_ })

if ($runExit -ne 0) {
    foreach ($l in $runLines) { Write-Output $l }
    exit 1
}

# -- pull out the deferred dating JSON rows (each `.mode json` statement prints
# its own JSON array on its own line) before touching anything else, then
# print LAKE/SAVED/provenance=NONE lines -- still strictly before RESULT. ------------
if ($deferredDatingTables.Count -gt 0) {
    $datingRows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $runLines) {
        $trimmed = $line.Trim().TrimStart([char]0xFEFF)
        if ($trimmed.StartsWith('[')) {
            try {
                $arr = $trimmed | ConvertFrom-Json
                foreach ($r in @($arr)) { $datingRows.Add($r) }
            } catch { }
        }
    }
    $nowUtcRow = $datingRows | Where-Object { $_.lbl -eq 'NOW_UTC' } | Select-Object -First 1
    $jmExistsRow = $datingRows | Where-Object { $_.lbl -eq 'JM_EXISTS' } | Select-Object -First 1
    $nowUtcText = if ($nowUtcRow) { [string]$nowUtcRow.now_utc } else { $null }
    $nowUtc = if ($nowUtcText) { [datetime]::Parse($nowUtcText, [System.Globalization.CultureInfo]::InvariantCulture) } else { [datetime]::UtcNow }
    $jmExists = $false
    if ($jmExistsRow) { $jmN = 0; [void][int]::TryParse([string]$jmExistsRow.n, [ref]$jmN); $jmExists = ($jmN -gt 0) }

    foreach ($table in $deferredDatingTables) {
        $contractRow = $datingRows | Where-Object { $_.lbl -eq 'CONTRACT' -and $_.tbl -eq $table } | Select-Object -First 1
        $refusedRow = $datingRows | Where-Object { $_.lbl -eq 'REFUSED_COUNT' -and $_.tbl -eq $table } | Select-Object -First 1
        $savedRow = $null
        if (-not $contractRow -and $jmExists) {
            # -- a table that is not a contract and join_manifest exists: one
            # small follow-up, read-only call, purely for the printed provenance
            # line -- it cannot affect anything already run or saved above. -----------
            $tableLit = ConvertTo-SqlLiteral $table
            $attachRo = "LOAD ducklake;`r`nATTACH 'ducklake:$lakeCatalogFwd' AS lake (DATA_PATH '$lakeDataDirFwd', READ_ONLY);`r`n"
            $savedSql = $attachRo + @"
SELECT 'SAVED' AS lbl, run_id, saved_at, inputs, lake_snapshot_id
FROM lake.join_manifest
WHERE lower(table_name) = lower($tableLit)
ORDER BY saved_at DESC
LIMIT 1;
"@
            $savedResult = Invoke-DuckdbJsonBatch -SqlText $savedSql
            $savedRow = $savedResult.Rows | Where-Object { $_.lbl -eq 'SAVED' } | Select-Object -First 1
        }
        Write-LakeDatingLine -Table $table -ContractRow $contractRow -RefusedRow $refusedRow -SavedRow $savedRow -NowUtc $nowUtc -Window $window -LakeInputInfos $lakeInputInfos -LakeStaleFlags $lakeStaleFlags
    }
}

$timerLine = $runLines | Where-Object { $_ -match '^Run Time \(s\): real (\S+)' } | Select-Object -First 1
$elapsed = if ($timerLine -and $timerLine -match '^Run Time \(s\): real (\S+)') { $Matches[1] } else { 'UNKNOWN' }

$rowCountIdx = -1
for ($i = 0; $i -lt $runLines.Count; $i++) {
    if ($runLines[$i] -like 'ROWCOUNT,*') { $rowCountIdx = $i; break }
}
if ($rowCountIdx -lt 0) {
    Write-Output "ERROR,run,could not find ROWCOUNT marker in output:"
    foreach ($l in $runLines) { Write-Output $l }
    exit 1
}
$resultRowCount = (Get-CsvField -Line $runLines[$rowCountIdx] -Count 2)[1]

$stateInputsCount = 0
$extractAgesParts = @()
foreach ($name in $extractNamesOrdered) {
    $info = $extractInfos[$name]
    $extractAgesParts += "$name`:$($info.AgeText)"
    if ($info.Stale) { $stateInputsCount++ }
}
$extractAgesText = if ($extractAgesParts.Count -gt 0) { $extractAgesParts -join ';' } else { 'none' }

# stale_inputs: extracts with stale=true, contract tables with
# workbook_changed_since=true, and saved joins whose oldest input is stale.
# Recomputed here from the same booleans used when the EXTRACT/LAKE/SAVED
# lines were printed, tracked in $staleCountTotal below.
$staleCountTotal = 0
foreach ($name in $extractNamesOrdered) { if ($extractInfos[$name].Stale) { $staleCountTotal++ } }
foreach ($table in $lakeNamesOrdered) {
    if ($lakeStaleFlags.ContainsKey($table) -and $lakeStaleFlags[$table]) { $staleCountTotal++ }
}

Write-Output "RESULT,rows=$resultRowCount,elapsed=$elapsed,extract_ages=$extractAgesText,stale_inputs=$staleCountTotal"

$csvBlock = $runLines[($rowCountIdx + 1)..($runLines.Count - 1)]
foreach ($l in $csvBlock) { Write-Output $l }

if ($Save) {
    Write-Output "SAVED_AS,$Save,rows=$resultRowCount,run_id=$runId"
}

exit 0
