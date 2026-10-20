-- read_xlsx_table / read_xlsx_name on top of the xlsx_meta extension (PLAN-7).
-- LOAD the extension first (duckdb -unsigned); these macros work for any workbook path, so,
-- unlike tools/xlsx_meta.py's generated file, nothing here is per-workbook or regenerated.
-- Same text as the generic lines tools/xlsx_meta.py writes; keep the two in step.
-- The extension's scalars must stay non-volatile: the macros rely on them folding at bind time.
CREATE OR REPLACE MACRO xlsx__q(s) AS '''' || replace(s, '''', '''''') || '''';
CREATE OR REPLACE MACRO xlsx__read_range(r) AS CASE WHEN contains(r, ':') THEN r ELSE r || ':' || r END;
CREATE OR REPLACE MACRO read_xlsx_table(p, t) AS TABLE FROM query('SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_table_sheet(p, t)) || ', range = ' || xlsx__q(xlsx_table_range(p, t)) || ', header = true, all_varchar = true)');
CREATE OR REPLACE MACRO read_xlsx_name(p, n, header := NULL) AS TABLE FROM query('SELECT * FROM read_xlsx(' || xlsx__q(p) || ', sheet = ' || xlsx__q(xlsx_name_sheet(p, n)) || ', range = ' || xlsx__q(xlsx__read_range(xlsx_name_range(p, n))) || ', header = ' || coalesce(header, xlsx__name_header(p, n))::VARCHAR || ', all_varchar = true)');
CREATE OR REPLACE MACRO read_xlsx_formulas(p) AS TABLE SELECT error('read_xlsx_formulas: formulas were not extracted -- run tools/xlsx_meta.py macros with --formulas') AS error;
