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
-- this session before this file runs -- tools/check-contract.ps1, tools/run-assertions.ps1
-- and checks/gl-facts.sql all do that themselves; this file does not load it, so it
-- stays exactly one view.
--
-- The read rule (item 5, deliverable 4): one blank row in a ListObject-backed sheet
-- makes read_xlsx's default stop_at_empty=true stop early, silently discarding every
-- row after it -- measured on a synthetic fixture as 3 of 5 real data rows lost, sum
-- wrong by 75%, exit 0. This sheet has never shown the hazard (raw stop_at_empty=false
-- count and the default count agree, 62,110 = 62,110 as measured 2026-09-24 -- see
-- TASK.md item 5's "Both real sheets are clean today" and AC7), but the correction is
-- applied here anyway as a standing guard, not a live-data fix. stop_at_empty = false
-- reads past any blank row; the WHERE clause below then drops only rows where every
-- one of the 13 raw columns is NULL, generated explicitly (NOT the "COLUMNS(*) IS
-- NULL" shorthand, which means "no column is null" and would silently drop any row
-- populated in only some columns -- see TASK.md item 5, measured 4 vs 5 on a fixture
-- built for exactly this trap).
--
-- item 5's four additive directives (below). These add to item 4's `-- @assert`
-- grammar; they do not alter it or its two guards, and tools/run-assertions.ps1 parses
-- them the same way (same comment form, same before-the-view timing, same
-- missing-or-duplicate-is-an-error rule as a malformed @assert).
-- @sheet: Clayco_Job_Costs_from_GL
-- @anchor: JOB_COSTS
-- @rows_floor: 50000
-- @fingerprint: PARENT_PROJECT_NUMBER|PROJECT_COMPANY|COST_TYPE_CODE|PHASE_DIVISION|PHASE|DIVISION|ACCRUAL_FLAG|VENDOR_NUMBER|VENDOR_NAME|GL_PERIOD|MONTH_OFFSET|MONTH_OFFSET_LABEL|JOB_COSTS

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
FROM (
    SELECT *
    FROM read_xlsx(
        'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
        sheet = 'Clayco_Job_Costs_from_GL',
        all_varchar = true,
        stop_at_empty = false
    )
    WHERE NOT (
        PARENT_PROJECT_NUMBER IS NULL AND PROJECT_COMPANY IS NULL AND COST_TYPE_CODE IS NULL
        AND PHASE_DIVISION IS NULL AND PHASE IS NULL AND DIVISION IS NULL AND ACCRUAL_FLAG IS NULL
        AND VENDOR_NUMBER IS NULL AND VENDOR_NAME IS NULL AND GL_PERIOD IS NULL
        AND MONTH_OFFSET IS NULL AND MONTH_OFFSET_LABEL IS NULL AND JOB_COSTS IS NULL
    )
) AS with_data;

-- Row count is no longer a hard @assert equality here (item 5 deliverable 4 -- the
-- prior `= 62110` broke on the sheet's first ordinary growth). It is now covered by
-- two drift-tolerant mechanisms the harness (tools/run-assertions.ps1) evaluates from
-- the @rows_floor and @sheet directives above: a floor (>= 50,000 -- the lowest ever
-- observed for this sheet is 57,801) and the internal-consistency equality (this
-- view's row count against an independent with-data count over every raw column the
-- sheet returns, in the same run). The absolute count is reported context, not a gate
-- -- see the @snapshot rows below.

-- Round 2, C1 -- every assertion below is reclassified into exactly one of three kinds
-- (TASK.md CORRECTIONS section). Round 1 left four hard-equality snapshot @assert
-- lines in place (jobcosts_nn, vendorname_nn, glperiod_nn, jobcosts_sum) because
-- deliverable 4 named only row_count; the workbook then refreshed again and all four
-- failed on live data for the same reason row_count once did. This round removes that
-- whole class rather than patching the instance:
--
--   INVARIANT (a relationship, never a literal -- refresh-proof):
--     - anchor completeness, count(JOB_COSTS) = count(*): this is what the
--       "@sheet"-family @anchor directive (JOB_COSTS, above) already computes and
--       reports as the ANCHOR,... line. It REPLACES jobcosts_nn outright; no new
--       assert line is needed, since the harness already runs this exact
--       relationship for every contract's declared anchor.
--     - glperiod_is_date (below, unchanged): GL_PERIOD decodes to a real DATE.
--     - the consistency equality (view rows = with-data rows over all sheet columns,
--       CONSISTENCY_VIEW_ROWS vs TRUNCATION_WITHDATA_ROWS): already computed by the
--       harness for every contract, unchanged by this round.
--     - jobcosts_sum_exact_decimal (below, new): the sum has no floating-point tail.
--       This is a property of the DECIMAL(18,2) cast on JOB_COSTS above and cannot
--       drift with the row count, unlike the sum's own value.
--
--   FLOOR (a measured ratio with justified headroom -- survives growth and ordinary
--   shrink; still gates the exit code, unlike a snapshot):
--     - vendorname_ratio_floor (below, new) replaces vendorname_nn: >= 0.80 -- observed
--       0.83607 (2026-09-24) and 0.83620 (2026-09-25), stable across a refresh that
--       moved every absolute count.
--     - glperiod_ratio_floor (below, new) replaces glperiod_nn: >= 0.25 -- observed
--       0.30211 and 0.30345 across the same refresh.
--     - the existing @rows_floor: 50000 directive above, unchanged.
--
--   SNAPSHOT (reported as a SNAPSHOT,<name>,<value> context line, never gating the
--   exit code -- exactly the category jobcosts_sum, jobcosts_nn, vendorname_nn and
--   glperiod_nn should have been in round 1): rows, jobcosts_nn, vendorname_nn,
--   glperiod_nn, and jobcosts_sum, all declared via @snapshot / @snapshot_committed
--   pairs below. Phil ties SUM(JOB_COSTS) to a report; its value must stay visible
--   even though the assertion protecting it is now about the cast, not the number.
--
-- One assertion is deleted outright rather than reclassified: glperiod_range (the
-- hard `min = 2026-07-01 AND max = 2026-10-01` equality). It adds nothing beyond what
-- two stronger, already-committed checks already prove: glperiod_is_date (below) that
-- the column decodes to a real DATE, and checks/gl-facts.sql's AC8 that xl_date's
-- decoding agrees with DuckDB's own independent decoder row-for-row (not just on
-- aggregates). A literal min/max window is exactly the kind of absolute figure this
-- round exists to stop gating on, and unlike the four counts above it has no ratio
-- form -- so it is dropped rather than turned into a floor that would have to be
-- re-guessed with no justification.
-- @assert jobcosts_sum_exact_decimal: (SELECT typeof(sum(JOB_COSTS)) FROM contract_view) LIKE 'DECIMAL%'
-- @assert vendorname_ratio_floor: (SELECT count(VENDOR_NAME)::DOUBLE / count(*) FROM contract_view) >= 0.80
-- @assert glperiod_ratio_floor: (SELECT count(GL_PERIOD)::DOUBLE / count(*) FROM contract_view) >= 0.25

-- GL_PERIOD type. any_value() is required: an un-aggregated typeof() would return one
-- row per record and trip the one-row assertion rule.
-- @assert glperiod_is_date: (SELECT any_value(typeof(GL_PERIOD)) FROM contract_view) = 'DATE'

-- Snapshots (round 2, C2): reported unconditionally, gate nothing. Committed values
-- below are this session's own baseline (2026-09-25, workbook hash
-- A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3) -- a mismatch on a
-- future run is drift to observe via SNAPSHOT_DRIFT, not a failure.
-- @snapshot rows: (SELECT count(*) FROM contract_view)
-- @snapshot_committed rows: 62230
-- @snapshot jobcosts_nn: (SELECT count(JOB_COSTS) FROM contract_view)
-- @snapshot_committed jobcosts_nn: 62230
-- @snapshot vendorname_nn: (SELECT count(VENDOR_NAME) FROM contract_view)
-- @snapshot_committed vendorname_nn: 52037
-- @snapshot glperiod_nn: (SELECT count(GL_PERIOD) FROM contract_view)
-- @snapshot_committed glperiod_nn: 18884
-- @snapshot jobcosts_sum: (SELECT sum(JOB_COSTS) FROM contract_view)
-- @snapshot_committed jobcosts_sum: 22478661033.93
