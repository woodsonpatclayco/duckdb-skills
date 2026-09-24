-- contracts/Clayco_Job_Costs_from_GL.sql
--
-- One CREATE OR REPLACE VIEW over the Clayco_Job_Costs_from_GL sheet of the pinned
-- workbook (TASK.md "items 3+4"). Reads via read_xlsx with all_varchar = true and casts
-- every column explicitly -- never ignore_errors, never normalize_names (Decisions 1/2).
--
-- Why all_varchar = true (type fidelity, not parse errors -- measured 2026-09-24):
--   bare inference silently loses data: JOB_COSTS -> DOUBLE (binary float money),
--   VENDOR_NUMBER -> DOUBLE (renders 17054.0, breaks a join to a Snowflake integer
--   VENDOR_NUMBER), ACCRUAL_FLAG -> DOUBLE. GL_PERIOD alone infers correctly (DATE) --
--   all_varchar throws that away, which is why xl_date() rebuilds it below.
--
-- Safety condition for the two casts that could otherwise throw (measured 2026-09-24,
-- non-null rows only): GL_PERIOD is all-digits in 18,764 of 18,764 -> ::BIGINT cannot
-- fail. JOB_COSTS is castable in 62,110 of 62,110 -> ::DECIMAL(18,2) cannot fail.
-- xl_date() is itself null-safe and accepts a VARCHAR serial directly, so the explicit
-- ::BIGINT below is belt-and-braces, not load-bearing. If a future refresh of this
-- workbook introduces a non-digit GL_PERIOD or a non-numeric JOB_COSTS, one of these
-- casts will throw -- which is the intended failure mode: loud, not a silent NULL.
--
-- Committed header fingerprint (order matters -- see AC6; a workbook column reorder
-- or rename shows up here as drift, not a failure to silently absorb):
--   PARENT_PROJECT_NUMBER|PROJECT_COMPANY|COST_TYPE_CODE|PHASE_DIVISION|PHASE|DIVISION|ACCRUAL_FLAG|VENDOR_NUMBER|VENDOR_NAME|GL_PERIOD|MONTH_OFFSET|MONTH_OFFSET_LABEL|JOB_COSTS
--
-- xl_date() comes from skills/query/duckdb-compat.sql and must already be loaded in
-- this session before this file runs -- tools/check-contract.ps1 and checks/gl-facts.sql
-- both do that themselves; this file does not load it, so it stays exactly one view.

CREATE OR REPLACE VIEW contract_view AS
SELECT
    PARENT_PROJECT_NUMBER::VARCHAR AS PARENT_PROJECT_NUMBER,
    PROJECT_COMPANY::VARCHAR AS PROJECT_COMPANY,
    COST_TYPE_CODE::VARCHAR AS COST_TYPE_CODE,
    PHASE_DIVISION::VARCHAR AS PHASE_DIVISION,
    PHASE::VARCHAR AS PHASE,
    DIVISION::VARCHAR AS DIVISION,
    ACCRUAL_FLAG::VARCHAR AS ACCRUAL_FLAG,
    VENDOR_NUMBER::BIGINT AS VENDOR_NUMBER,
    VENDOR_NAME::VARCHAR AS VENDOR_NAME,
    xl_date(GL_PERIOD::BIGINT) AS GL_PERIOD,
    MONTH_OFFSET::VARCHAR AS MONTH_OFFSET,
    MONTH_OFFSET_LABEL::VARCHAR AS MONTH_OFFSET_LABEL,
    JOB_COSTS::DECIMAL(18,2) AS JOB_COSTS
FROM read_xlsx(
    'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
    sheet = 'Clayco_Job_Costs_from_GL',
    all_varchar = true
);

-- Row count. Committed 2026-09-24: 62,110. A live, SharePoint-synced workbook can move
-- this -- see TASK.md "How pinned figures are to be treated": a mismatch here is
-- drift to report, not a defect to fix by editing this number.
-- @assert row_count: (SELECT count(*) FROM contract_view) = 62110

-- Per-column non-null floors, measured individually -- never templated from another
-- column. Committed 2026-09-24.
-- @assert jobcosts_nn: (SELECT count(JOB_COSTS) FROM contract_view) = 62110
-- @assert vendorname_nn: (SELECT count(VENDOR_NAME) FROM contract_view) = 51928
-- @assert glperiod_nn: (SELECT count(GL_PERIOD) FROM contract_view) = 18764

-- GL_PERIOD type and range. any_value() is required: an un-aggregated typeof() would
-- return one row per record and trip the one-row assertion rule.
-- @assert glperiod_is_date: (SELECT any_value(typeof(GL_PERIOD)) FROM contract_view) = 'DATE'
-- @assert glperiod_range: (SELECT min(GL_PERIOD) = DATE '2026-07-01' AND max(GL_PERIOD) = DATE '2026-10-01' FROM contract_view)

-- Money sum, cast first -- committed 2026-09-24: 22454928166.83. See checks/gl-facts.sql
-- AC9 for the no-floating-point-tail comparison against the same sum taken without
-- all_varchar; that comparison is not asserted here because it needs a second read path
-- (`bare`) this file deliberately does not define.
-- @assert jobcosts_sum: (SELECT sum(JOB_COSTS) FROM contract_view) = 22454928166.83
