-- checks/gl-facts.sql
--
-- Committed so the verifier runs exactly what the implementer ran (TASK.md Deliverable
-- 4). Invoked `duckdb -f checks/gl-facts.sql` from the repo root -- every relative path
-- below (the .read lines) resolves against that CWD, matching how every other command
-- in this task's acceptance section is given as a repo-root-relative path.
--
-- Emits one "check_id,value" line per check via .mode csv / .headers off, so a caller
-- can grep a line by its check_id without parsing box-drawing output.
--
-- Read-only throughout: contract_view and bare are both VIEWs, never materialized, so
-- AC5 and AC8 genuinely compare two independent read_xlsx invocations "in the same run"
-- rather than one cached scan compared against itself.

.headers off
.mode csv

.read 'skills/query/duckdb-compat.sql'
.read 'contracts/Clayco_Job_Costs_from_GL.sql'

-- A second view over the same read_xlsx(all_varchar=true) call, undecorated by any
-- cast -- used only to give AC5 and AC10 a "direct" read to compare the view against.
CREATE OR REPLACE VIEW direct_varchar AS
SELECT *
FROM read_xlsx(
    'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
    sheet = 'Clayco_Job_Costs_from_GL',
    all_varchar = true
);

-- bare: the same sheet with no all_varchar, letting DuckDB's own C++ decoder produce
-- GL_PERIOD as a native DATE -- the independent oracle AC8 checks contract_view's
-- xl_date() decoding against, row for row.
CREATE OR REPLACE VIEW bare AS
SELECT *
FROM read_xlsx(
    'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
    sheet = 'Clayco_Job_Costs_from_GL'
);

-- AC5: view row count vs. a direct read_xlsx(all_varchar=true) count, same run.
SELECT 'AC5_VIEW_ROWS', count(*) FROM contract_view;
SELECT 'AC5_DIRECT_ROWS', count(*) FROM direct_varchar;

-- AC6: contract_view's ordered header fingerprint -- compare against the committed
-- 13-name list in contracts/Clayco_Job_Costs_from_GL.sql's own header comment.
SELECT 'AC6_FINGERPRINT', string_agg(column_name, '|' ORDER BY column_index)
FROM duckdb_columns() WHERE table_name = 'contract_view';

-- AC8: the independent date check. Two unrelated decoders (xl_date's pure arithmetic
-- vs. DuckDB's own C++ serial decoder) must agree row for row -- not merely on
-- aggregates, which a remapped-but-aggregate-preserving decoder could still pass.
SELECT 'AC8_A_MINUS_B', count(*) FROM (
    (SELECT GL_PERIOD AS d FROM contract_view) EXCEPT ALL (SELECT GL_PERIOD AS d FROM bare)
);
SELECT 'AC8_B_MINUS_A', count(*) FROM (
    (SELECT GL_PERIOD AS d FROM bare) EXCEPT ALL (SELECT GL_PERIOD AS d FROM contract_view)
);
SELECT 'AC8_VIEW_MIN', min(GL_PERIOD) FROM contract_view;
SELECT 'AC8_VIEW_MAX', max(GL_PERIOD) FROM contract_view;
SELECT 'AC8_VIEW_NN', count(GL_PERIOD) FROM contract_view;
SELECT 'AC8_BARE_MIN', min(GL_PERIOD) FROM bare;
SELECT 'AC8_BARE_MAX', max(GL_PERIOD) FROM bare;
SELECT 'AC8_BARE_NN', count(GL_PERIOD) FROM bare;

-- AC9: DECIMAL sum (no floating-point tail, contract_view) vs. the same sum taken from
-- `bare`'s bare-inferred DOUBLE JOB_COSTS. Never assert the size of the difference --
-- see TASK.md's warning on the two differently-rounded printed forms.
SELECT 'AC9_DECIMAL_SUM', sum(JOB_COSTS) FROM contract_view;
SELECT 'AC9_DOUBLE_SUM', sum(JOB_COSTS) FROM bare;

-- AC10: cast-before-compare max vs. the lexicographic trap on the uncast VARCHAR path.
SELECT 'AC10_MAX_CAST', max(JOB_COSTS) FROM contract_view;
SELECT 'AC10_MAX_LEX', max(JOB_COSTS) FROM direct_varchar;

-- AC11: per-column non-null floors, measured individually -- never templated.
SELECT 'AC11_JOBCOSTS_NN', count(JOB_COSTS) FROM contract_view;
SELECT 'AC11_VENDORNAME_NN', count(VENDOR_NAME) FROM contract_view;
SELECT 'AC11_GLPERIOD_NN', count(GL_PERIOD) FROM contract_view;

-- AC12: (a) the declared type is BIGINT -- proof the cast happened, not just that the
-- rendered value looks clean. (b) no VENDOR_NUMBER renders with a trailing ".0". Part
-- (b) alone is not sufficient: an uncast all_varchar column already renders "0"/"1"/
-- "10", never "17054.0", so it would pass (b) even with no cast at all.
SELECT 'AC12_VENDORNUMBER_TYPE', any_value(typeof(VENDOR_NUMBER)) FROM contract_view;
SELECT 'AC12_DOT_ZERO_ROWS', count(*) FROM contract_view WHERE VENDOR_NUMBER::VARCHAR LIKE '%.0';
