---
name: convert-file
description: >
  Convert any data file to another format: CSV, Parquet, JSON, Excel, GeoJSON, and more.
  Use when the user says "convert to parquet", "save as xlsx", "export as JSON", "make this a CSV",
  "turn into parquet", or any variation of format-to-format conversion for data files.
  Also triggers when the user wants to write Parquet, Excel, or other binary formats that Claude cannot produce natively,
  and when the output is for Excel Power Query or a SharePoint share ("export for Excel", "so Power Query can read it") --
  that writes a CSV plus a types file and a ready Power Query.
argument-hint: <input-file> [output-file]
allowed-tools: Bash
---

You are helping the user convert a data file from one format to another using DuckDB.

Input file: `$0`
Output file: `${1:-}`

## Step 1 — Resolve input and output

**Input**: `$0`. If it's a bare filename (no `/`), resolve to a full path with `find "$PWD" -name "$0" -not -path '*/.git/*' 2>/dev/null | head -1`.

**Output**: If `$1` is provided, use it as the output path. If not, default to the same stem as the input with a `.parquet` extension (e.g., `data.csv` → `data.parquet`).

Infer the output format from the output file extension:

| Extension | Format clause |
|---|---|
| `.parquet`, `.pq` | *(default, no clause needed)* |
| `.csv` | `(FORMAT csv, HEADER)` |
| `.tsv` | `(FORMAT csv, HEADER, DELIMITER '\t')` |
| `.json` | `(FORMAT json, ARRAY true)` |
| `.jsonl`, `.ndjson` | `(FORMAT json, ARRAY false)` |
| `.xlsx` | `(FORMAT xlsx)` — requires `INSTALL excel; LOAD excel;` |
| `.geojson` | `(FORMAT GDAL, DRIVER 'GeoJSON')` — requires `LOAD spatial;` |
| `.gpkg` | `(FORMAT GDAL, DRIVER 'GPKG')` — requires `LOAD spatial;` |
| `.shp` | `(FORMAT GDAL, DRIVER 'ESRI Shapefile')` — requires `LOAD spatial;` |

### Output for Excel / Power Query (SharePoint)

If the output is meant to be read by Excel's Power Query — the user says Excel, Power
Query, a workbook will pull it, or it goes to a SharePoint share for Excel — do **not**
use the table above. Run the Excel export tool instead and skip to Step 3:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/tools/export-excel-csv.ps1" \
  -Source '<INPUT_PATH or .sql file or SQL text>' -OutDir '<folder>' [-Name <stem>] \
  [-SiteUrl 'https://claycorp.sharepoint.com/sites/<site>' -FolderPath 'https://claycorp.sharepoint.com/sites/<site>/Shared Documents/<folder>/']
```

It writes `<stem>.csv`, `<stem>.types.csv` (DuckDB's `DESCRIBE`: column name and type) and
`<stem>.pq.m`, the Power Query to paste into Excel's Advanced Editor. The query reads both
files with `SharePoint.Files` and types every column from the types file, so it never
hard-codes a column list. The template is `${CLAUDE_PLUGIN_ROOT}/skills/convert-file/excel-csv-sharepoint.m`.
Upload the two CSVs to the SharePoint folder; the `.pq.m` is for the person building the workbook.

Why this and not Parquet or xlsx: Excel's Power Query has no `Parquet.Document` (it fails
with "The import Parquet.Document matches no exports"), and CSV loads fastest of what it
can read (500k rows: CSV ~1.6 s, xlsx ~6 s, JSON array ~9 s). Tell the user two CSV limits:
a NULL text value arrives as an empty string, and `TIMESTAMP WITH TIME ZONE` is written in
the exporting machine's time zone. Types the M does not map (UUID, HUGEINT, INTERVAL, LIST, ...)
load as text, and the tool's output names each one.

## Step 2 — Convert

Run a single DuckDB command. Prepend extension loads as needed based on both the input and output formats.

```bash
duckdb -c "
<EXTENSION_LOADS>
COPY (FROM '<INPUT_PATH>') TO '<OUTPUT_PATH>' <FORMAT_CLAUSE>;
"
```

For remote inputs (`s3://`, `https://`, etc.), prepend the same protocol setup as `read-file`:

| Protocol | Prepend |
|---|---|
| `s3://` | `LOAD httpfs; CREATE SECRET (TYPE S3, PROVIDER credential_chain);` |
| `gs://` / `gcs://` | `LOAD httpfs; CREATE SECRET (TYPE GCS, PROVIDER credential_chain);` |
| `https://` / `http://` | `LOAD httpfs;` |

**If the user mentions partitioning** (e.g., "partition by year"), add `PARTITION_BY (col)` to the format clause. This only works with Parquet and CSV output.

**If the user mentions compression** (e.g., "use zstd"), add `CODEC 'zstd'` for Parquet output.

## Step 3 — Report

On success, report:
- Input file and detected format
- Output file, format, and size (`ls -lh`)
- Row count if quick to compute

On failure:
- **`duckdb: command not found`** → delegate to `/duckdb-skills:install-duckdb`
- **Missing extension** → install it and retry
- **Input parse error** → suggest the user check the input format or try `/duckdb-skills:read-file` first to inspect it
