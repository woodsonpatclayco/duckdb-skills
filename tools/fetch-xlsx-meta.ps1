<#
tools\fetch-xlsx-meta.ps1 [-Branch <name>] [-RunId <id>]

Downloads the Windows build of the xlsx_meta extension from the newest successful run of
.github\workflows\xlsx-meta-windows.yml and puts it where the plugin ships it:

    extension\bin\<duckdb version>\windows_amd64\xlsx_meta.duckdb_extension

The DuckDB version comes from the artifact's name (xlsx_meta-v1.5.5-extension-windows_amd64),
so a rebuild for a new DuckDB lands in its own folder. Commit the file afterwards; that is how
it reaches the installed plugin.

-Branch picks the newest successful run on that branch (default: main). -RunId takes one run
exactly. The GitHub token comes from git's credential store (`git credential fill`), the same
one `git push` uses; gh isn't needed.

Then it loads the file in the local DuckDB and prints the extension's version, which is the
commit the run built. Exits 1 if there is no such run, the download fails, or it won't load
(e.g. the local DuckDB isn't the version it was built for).
#>
param(
    [string]$Branch = 'main',
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
$repo = 'woodsonpatclayco/duckdb-skills'
$api = "https://api.github.com/repos/$repo"
$root = Split-Path -Parent $PSScriptRoot

# PowerShell 5.1 pipes CRLF to native commands, which git credential rejects; feed it a LF file.
$credIn = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllText($credIn, "protocol=https`nhost=github.com`n`n")
$token = (cmd /c "git credential fill < `"$credIn`"") |
    Where-Object { $_ -like 'password=*' } | ForEach-Object { $_.Substring(9) }
Remove-Item $credIn
if (-not $token) { Write-Output 'No GitHub credential in git''s store.'; exit 1 }
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json' }

if ($RunId) {
    $run = Invoke-RestMethod -Headers $headers "$api/actions/runs/$RunId"
} else {
    $runs = Invoke-RestMethod -Headers $headers `
        "$api/actions/workflows/xlsx-meta-windows.yml/runs?branch=$Branch&status=success&per_page=1"
    $run = $runs.workflow_runs | Select-Object -First 1
    if (-not $run) { Write-Output "No successful xlsx_meta Windows build on branch '$Branch'."; exit 1 }
}
$commit = $run.head_sha.Substring(0, 7)
Write-Output "run:       $($run.id) ($($run.head_branch) @ $commit, $($run.created_at))"

$artifact = (Invoke-RestMethod -Headers $headers "$api/actions/runs/$($run.id)/artifacts").artifacts |
    Where-Object { $_.name -match '^xlsx_meta-(v[\d.]+)-extension-windows_amd64$' } | Select-Object -First 1
if (-not $artifact) { Write-Output "Run $($run.id) has no windows_amd64 artifact."; exit 1 }
if ($artifact.expired) { Write-Output "Run $($run.id)'s artifact has expired; re-run the workflow."; exit 1 }
$version = ($artifact.name -split '-')[1]

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("xlsx-meta-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
    # curl.exe, because it drops the token when GitHub redirects to blob storage.
    & curl.exe -sSfL -H "Authorization: Bearer $token" -o "$tmp\a.zip" "$api/actions/artifacts/$($artifact.id)/zip"
    if ($LASTEXITCODE -ne 0) { Write-Output 'Artifact download failed.'; exit 1 }
    Expand-Archive "$tmp\a.zip" $tmp

    $dest = Join-Path $root "extension\bin\$version\windows_amd64"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item "$tmp\xlsx_meta.duckdb_extension" $dest -Force
} finally {
    Remove-Item -Recurse -Force $tmp
}
$file = Join-Path $dest 'xlsx_meta.duckdb_extension'
Write-Output "saved:     $file ($((Get-Item $file).Length) bytes)"

$sqlPath = $file.Replace("'", "''")
$loaded = & duckdb -unsigned -noheader -list -c "LOAD '$sqlPath'; SELECT extension_version FROM duckdb_extensions() WHERE extension_name = 'xlsx_meta' AND loaded" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "LOAD failed: $loaded"; exit 1 }
Write-Output "loaded:    xlsx_meta $loaded in DuckDB $(& duckdb -noheader -list -c 'SELECT version()')"
