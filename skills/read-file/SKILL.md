---
name: read-file
description: >
  Read any data file (CSV, JSON, Parquet, Avro, Excel, spatial, SQLite) or remote URL (S3, HTTPS).
  Use when user references a data file, asks "what's in this file", or wants to preview/profile a dataset.
  Not for source code.
argument-hint: <filename or URL> [question about the data]
allowed-tools: Bash
---

You are helping the user read and analyze a data file using DuckDB.

Filename given: `$0`
Question: `${1:-describe the data}`

## Excel workbooks

**If a contract covers the workbook and sheet, answer from the lake, not the
workbook.** Contracts are `contracts\*.sql`; each names its workbook in
`read_xlsx('<path>', sheet='<sheet>', …)`. Query `lake.<contract>` per the
`lakehouse` skill, and check freshness with `tools\lake-status.ps1`.

**If none does:** list sheets with `tools\list-sheets.ps1 <absolute path>` (the
first sheet may be metadata — `Data Extracts.xlsm`'s is a 2-row `MetaData`);
read the named sheet with `sheet=`, `all_varchar = true` and
`stop_at_empty = false`; cast money explicitly to `DECIMAL` before summing; and
**tell Phil the types are unverified.** Never `ignore_errors = true`.

**Why:** an inferred read sums GL `JOB_COSTS` as DOUBLE (`22498718519.95991`)
where the contract returns `22498718519.96`, and which columns infer correctly
changes as the sheet's contents change.

A contract is added only when Phil asks — this section is guidance, not an
instruction to write one.

This is guidance a session is asked to follow, not a check anything enforces.

## Step 1 — Read it

`RESOLVED_PATH` is `$0`. If the user gave a bare filename (no `/`), resolve it to a full path with `find` first.

Run a single DuckDB command that defines the `read_any` macro inline and reads the file.

For **remote files**, prepend the necessary LOAD/SECRET before the macro:

| Protocol | Prepend |
|---|---|
| `https://` / `http://` | `LOAD httpfs;` |
| `s3://` | `LOAD httpfs; CREATE SECRET (TYPE S3, PROVIDER credential_chain);` |
| `gs://` / `gcs://` | `LOAD httpfs; CREATE SECRET (TYPE GCS, PROVIDER credential_chain);` |
| `az://` / `azure://` / `abfss://` | `LOAD httpfs; LOAD azure; CREATE SECRET (TYPE AZURE, PROVIDER credential_chain);` |

For **local files**, no prefix needed.

```bash
duckdb -csv -c "
CREATE OR REPLACE MACRO read_any(file_name) AS TABLE
  WITH json_case AS (FROM read_json_auto(file_name))
     , csv_case AS (FROM read_csv(file_name))
     , parquet_case AS (FROM read_parquet(file_name))
     , avro_case AS (FROM read_avro(file_name))
     , blob_case AS (FROM read_blob(file_name))
     , spatial_case AS (FROM st_read(file_name))
     , excel_case AS (FROM read_xlsx(file_name))
     , sqlite_case AS (FROM sqlite_scan(file_name, (SELECT name FROM sqlite_master(file_name) LIMIT 1)))
     , ipynb_case AS (
         WITH nb AS (FROM read_json_auto(file_name))
         SELECT cell_idx, cell.cell_type,
                array_to_string(cell.source, '') AS source,
                cell.execution_count
         FROM nb, UNNEST(cells) WITH ORDINALITY AS t(cell, cell_idx)
         ORDER BY cell_idx
     )
  FROM query_table(
    CASE
      WHEN file_name ILIKE '%.json' OR file_name ILIKE '%.jsonl' OR file_name ILIKE '%.ndjson' OR file_name ILIKE '%.geojson' OR file_name ILIKE '%.geojsonl' OR file_name ILIKE '%.har' THEN 'json_case'
      WHEN file_name ILIKE '%.csv' OR file_name ILIKE '%.tsv' OR file_name ILIKE '%.tab' OR file_name ILIKE '%.txt' THEN 'csv_case'
      WHEN file_name ILIKE '%.parquet' OR file_name ILIKE '%.pq' THEN 'parquet_case'
      WHEN file_name ILIKE '%.avro' THEN 'avro_case'
      WHEN file_name ILIKE '%.xlsx' OR file_name ILIKE '%.xls' OR file_name ILIKE '%.xlsm' THEN 'excel_case'
      WHEN file_name ILIKE '%.shp' OR file_name ILIKE '%.gpkg' OR file_name ILIKE '%.fgb' OR file_name ILIKE '%.kml' THEN 'spatial_case'
      WHEN file_name ILIKE '%.ipynb' THEN 'ipynb_case'
      WHEN file_name ILIKE '%.db' OR file_name ILIKE '%.sqlite' OR file_name ILIKE '%.sqlite3' THEN 'sqlite_case'
      ELSE 'blob_case'
    END
  );

DESCRIBE FROM read_any('RESOLVED_PATH');
SELECT count(*) AS row_count FROM read_any('RESOLVED_PATH');
FROM read_any('RESOLVED_PATH') LIMIT 20;
"
```

**If this fails:**
- **`duckdb: command not found`** → invoke `/duckdb-skills:install-duckdb` and retry.
- **Missing extension** (e.g. spatial files, xlsx, sqlite) → retry with `INSTALL spatial; LOAD spatial;` or `INSTALL sqlite_scanner; LOAD sqlite_scanner;` prepended before the macro.
- **Wrong reader / parse error** → use the correct `read_*` function directly instead of `read_any`.

## Step 2 — Answer

Using the schema, row count, and sample rows, answer:

`${1:-describe the data: summarize column types, row count, and any notable patterns.}`
