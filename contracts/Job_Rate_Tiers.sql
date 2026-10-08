-- contracts/Job_Rate_Tiers.sql
--
-- One CREATE OR REPLACE VIEW over the Job_Rate_Tiers Excel TABLE (ListObject) in the pinned
-- workbook (PLAN-6 item 2) -- the first contract that reads a table by name instead of a sheet.
-- Sheet Job_Internal_Rates holds three tables side by side (Job_Base_Rate A2:D37,
-- Job_Rate_Tiers G2:J107, Project_Rate_Tiers L2:N112), so no sheet-level read can produce this
-- one: read_xlsx_table reads exactly the table's rectangle, wherever the table currently ends.
--
-- read_xlsx_table() is generated from the workbook by tools/xlsx_meta.py on every run; the
-- runners load it for any contract with `-- @table:`. xl_date() comes from
-- skills/query/duckdb-compat.sql. Neither exists in a bare `duckdb` session -- running this
-- file there fails loudly with "macro does not exist", never silently.
--
-- Casts (measured 2026-10-08, 105 rows): Job_Tier is 1/2/3 in every row; Effective_Date is
-- an Excel serial (45931 = 2025-10-01) in every row. Tier_Rate is DOUBLE on purpose: it is a
-- calculated hourly rate carrying up to 15 decimals (87.7241128548077), stored by Excel as a
-- double -- not money, so a DECIMAL(18,2) cast would round away what the workbook holds.
--
-- @table: Job_Rate_Tiers
-- @anchor: Job_Type_Code
-- @fingerprint: Job_Type_Code|Job_Tier|Tier_Rate|Effective_Date

CREATE OR REPLACE VIEW contract_view AS
SELECT
    Job_Type_Code::VARCHAR AS Job_Type_Code,
    Job_Tier::INTEGER AS Job_Tier,
    Tier_Rate::DOUBLE AS Tier_Rate,
    xl_date(Effective_Date::BIGINT) AS Effective_Date
FROM read_xlsx_table(
    'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
    'Job_Rate_Tiers'
)
WHERE NOT (Job_Type_Code IS NULL AND Job_Tier IS NULL AND Tier_Rate IS NULL AND Effective_Date IS NULL);

-- One row per job type and tier.
-- @assert key_unique: (SELECT count(*) = count(DISTINCT (Job_Type_Code, Job_Tier)) FROM contract_view)
-- Every job type has exactly the three tiers.
-- @assert three_tiers_each: (SELECT bool_and(n = 3) FROM (SELECT count(*) AS n FROM contract_view GROUP BY Job_Type_Code))
-- @assert rate_positive: (SELECT bool_and(Tier_Rate > 0) FROM contract_view)
