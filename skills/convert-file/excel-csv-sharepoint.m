// Power Query for a DuckDB CSV export written by tools\export-excel-csv.ps1.
// Reads <FileName>.csv and types every column from <FileName>.types.csv, which
// DuckDB wrote next to it (DESCRIBE's column_name, column_type).
//
// Paste into Excel: Data > Get Data > From Other Sources > Blank Query > Advanced Editor.
// Set the three values below. FolderPath is the folder's full URL, ending in "/",
// exactly as SharePoint.Files shows it in its Folder Path column.
//
// Why not Parquet: Excel's Power Query has no Parquet.Document (it fails with
// "The import Parquet.Document matches no exports"); CSV is the fastest format Excel reads.
let
    SiteUrl    = "{{SITE_URL}}",
    FolderPath = "{{FOLDER_PATH}}",
    FileName   = "{{NAME}}",

    // SOURCE
    Files    = SharePoint.Files(SiteUrl, [ApiVersion = 15]),
    ReadFile = (name as text) as binary => Files{[Folder Path = FolderPath, Name = name]}[Content],
    // END SOURCE

    ReadCsv = (name as text) as table => Table.PromoteHeaders(
                  Csv.Document(ReadFile(name), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
                  [PromoteAllScalars = true]),

    // DuckDB type name (the part before any "(") -> Power Query type. Anything unlisted
    // (UUID, INTERVAL, BLOB, LIST, STRUCT, ...) stays text.
    TypeMap = [
        TINYINT = Int64.Type, SMALLINT = Int64.Type, INTEGER = Int64.Type, BIGINT = Int64.Type,
        UTINYINT = Int64.Type, USMALLINT = Int64.Type, UINTEGER = Int64.Type, UBIGINT = Int64.Type,
        DECIMAL = type number, DOUBLE = type number, FLOAT = type number,
        DATE = type date, TIME = type time,
        TIMESTAMP = type datetime, TIMESTAMP_S = type datetime, TIMESTAMP_MS = type datetime, TIMESTAMP_NS = type datetime,
        #"TIMESTAMP WITH TIME ZONE" = type datetimezone,
        BOOLEAN = type logical, VARCHAR = type text
    ],
    TypeList = List.Transform(Table.ToRecords(ReadCsv(FileName & ".types.csv")), each
                   {[column_name], Record.FieldOrDefault(TypeMap, Text.BeforeDelimiter([column_type], "("), type text)}),

    // A column named in the types file but missing from the CSV fails the refresh, loudly.
    Typed = Table.TransformColumnTypes(ReadCsv(FileName & ".csv"), TypeList, "en-US")
in
    Typed
