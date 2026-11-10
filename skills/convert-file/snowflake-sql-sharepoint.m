// Power Query for {{TABLE}}: runs {{TABLE}}.snowflake.sql, the Snowflake query kept next to
// {{TABLE}}.csv in the CSV lake, through the ODBC DSN "Snowflake". Written by duckdb-skills
// tools\snowflake_pq_sql.py; the next export overwrites it.
//
// Paste into Excel: Data > Get Data > From Other Sources > Blank Query > Advanced Editor.
// Projects: {} returns every project. To return only some, list them, e.g. {"10002556", "10005145"}.
// The rows are live from Snowflake with your own sign-in; {{TABLE}}.csv is the copy that passed
// the lake contract's checks.
// If a refresh stops with Formula.Firewall: Data > Get Data > Query Options > Current Workbook >
// Privacy > Ignore the Privacy Levels.
let
    SiteUrl       = "{{SITE_URL}}",
    FolderPath    = "{{FOLDER_PATH}}",
    FileName      = "{{TABLE}}.snowflake.sql",
    ProjectColumn = "{{PROJECT_COLUMN}}",
    Projects      = {},

    // SOURCE
    Files    = SharePoint.Files(SiteUrl, [ApiVersion = 15]),
    ReadFile = (name as text) as binary => Files{[Folder Path = FolderPath, Name = name]}[Content],
    // END SOURCE

    QuerySql  = Text.FromBinary(ReadFile(FileName), TextEncoding.Utf8),
    FilterOff = "/* WHERE lake_table." & ProjectColumn & " IN ('<project>', '<project>') */",
    FilterOn  = "WHERE lake_table." & ProjectColumn & " IN ("
                & Text.Combine(List.Transform(Projects, each "'" & Text.Replace(Text.From(_), "'", "''") & "'"), ", ")
                & ")",
    // A file without the filter line stops the refresh instead of returning every project.
    Sql       = if List.IsEmpty(Projects) then QuerySql
                else if ProjectColumn <> "" and Text.Contains(QuerySql, FilterOff) then Text.Replace(QuerySql, FilterOff, FilterOn)
                else error Error.Record("Expression.Error", FileName & " has no PROJECT FILTER line; set Projects = {}"),
    Source    = Odbc.Query("dsn=Snowflake", Sql)
in
    Source
