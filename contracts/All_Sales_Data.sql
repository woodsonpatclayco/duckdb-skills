-- contracts/All_Sales_Data.sql
--
-- One CREATE OR REPLACE VIEW over the All_Sales_Data sheet of the pinned workbook
-- (item 5, deliverable 3 -- the second contract, chosen because it stresses what the
-- GL sheet cannot: headers with spaces and punctuation). Same discipline as
-- contracts/Clayco_Job_Costs_from_GL.sql: read via read_xlsx with all_varchar = true,
-- cast every column explicitly, never ignore_errors, never normalize_names
-- (Decisions 1/2, inherited from items 3+4).
--
-- Why exact quoting reaches these headers (Decision 2): "Job #", "Start Date",
-- "Revenue Total", and "match project" (lowercase, spaced -- the most hostile of the
-- 16) all survive only because normalize_names is left false and every reference below
-- is double-quoted exactly as the workbook spells it. This is the first contract in the
-- repo to actually exercise that rule against a hostile header.
--
-- Safety condition for the casts that could otherwise throw (measured 2026-09-25,
-- non-null rows only, stop_at_empty = false, all_varchar = true):
--   "Start Date" is all-digits in 150 of 150 non-null values -> ::BIGINT cannot fail.
--   "End Date" is all-digits in 145 of 145 non-null values -> ::BIGINT cannot fail.
--   "Revenue Total" is castable to DECIMAL(18,2) in 201 of 201 non-null values.
--   "Earnings Total" is castable to DECIMAL(18,2) in 201 of 201 non-null values.
-- xl_date() is itself null-safe and accepts a VARCHAR serial directly, so the explicit
-- ::BIGINT casts below are belt-and-braces, not load-bearing.
--
-- Committed header fingerprint (order matters -- a workbook column reorder or rename
-- shows up here as drift, not a failure to silently absorb; annotations #14/#42 record
-- that this workbook's convention is to append new columns last):
--   Sales Year|Filename|Folder Path|Business Unit|Job #|Status|Status_Description|Market|Client|Start Date|End Date|State|Project Name|Revenue Total|Earnings Total|match project
--
-- xl_date() comes from skills/query/duckdb-compat.sql and must already be loaded in
-- this session before this file runs -- tools/check-contract.ps1 and
-- tools/run-assertions.ps1 both do that themselves; this file does not load it, so it
-- stays exactly one view.
--
-- The read rule (item 5, deliverable 3): stop_at_empty = false reads past any blank
-- row; the WHERE clause below then drops only rows where every one of the 16 raw
-- columns is NULL, generated explicitly over named columns (never the
-- "NOT (COLUMNS(*) IS NULL)" shorthand -- that means "no column is null" and would
-- silently drop any row populated in only some columns). Measured 2026-09-25: this
-- sheet shows no truncation today (default 219 = with-data 219), so the rule is a
-- standing guard here, not a live-data fix -- see TASK.md item 5 AC6.
--
-- item 5's four additive directives (below). These add to item 4's `-- @assert`
-- grammar; they do not alter it or its two guards, and tools/run-assertions.ps1 parses
-- them the same way (same comment form, same before-the-view timing, same
-- missing-or-duplicate-is-an-error rule as a malformed @assert). @anchor's value is
-- the bare column name, unquoted -- the harness double-quotes it itself when building
-- count(...) SQL, so a hostile name like "Job #" never has to be spelled with embedded
-- quotes inside the directive.
-- @sheet: All_Sales_Data
-- @anchor: Job #
-- @rows_floor: 200
-- @fingerprint: Sales Year|Filename|Folder Path|Business Unit|Job #|Status|Status_Description|Market|Client|Start Date|End Date|State|Project Name|Revenue Total|Earnings Total|match project

CREATE OR REPLACE VIEW contract_view AS
SELECT
    "Sales Year"::VARCHAR AS "Sales Year",
    "Filename"::VARCHAR AS "Filename",
    "Folder Path"::VARCHAR AS "Folder Path",
    "Business Unit"::VARCHAR AS "Business Unit",
    "Job #"::VARCHAR AS "Job #",
    "Status"::VARCHAR AS "Status",
    "Status_Description"::VARCHAR AS "Status_Description",
    "Market"::VARCHAR AS "Market",
    "Client"::VARCHAR AS "Client",
    xl_date("Start Date"::BIGINT) AS "Start Date",
    xl_date("End Date"::BIGINT) AS "End Date",
    "State"::VARCHAR AS "State",
    "Project Name"::VARCHAR AS "Project Name",
    "Revenue Total"::DECIMAL(18,2) AS "Revenue Total",
    "Earnings Total"::DECIMAL(18,2) AS "Earnings Total",
    "match project"::VARCHAR AS "match project"
FROM (
    SELECT *
    FROM read_xlsx(
        'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data Warehousing/Domo/Data Extracts.xlsm',
        sheet = 'All_Sales_Data',
        all_varchar = true,
        stop_at_empty = false
    )
    WHERE NOT (
        "Sales Year" IS NULL AND "Filename" IS NULL AND "Folder Path" IS NULL
        AND "Business Unit" IS NULL AND "Job #" IS NULL AND "Status" IS NULL
        AND "Status_Description" IS NULL AND "Market" IS NULL AND "Client" IS NULL
        AND "Start Date" IS NULL AND "End Date" IS NULL AND "State" IS NULL
        AND "Project Name" IS NULL AND "Revenue Total" IS NULL AND "Earnings Total" IS NULL
        AND "match project" IS NULL
    )
) AS with_data;

-- Row count is not a hard @assert equality -- see the GL contract's note on why. It is
-- covered by the harness's floor (>= 200 -- observed 227 -> 226 -> 219, never near 200)
-- and internal-consistency equality (this view's row count against an independent
-- with-data count over every raw column, in the same run), both driven by the
-- directives above.

-- Per-column non-null floors, measured individually -- never templated. Committed
-- 2026-09-25. "Job #" (the anchor) is 219 of 219; "End Date" is 145 of 219 -- nothing
-- alike, which is why a floor copied from one column to the other would be wrong.
-- @assert jobnum_nn: (SELECT count("Job #") FROM contract_view) = 219
-- @assert matchproject_nn: (SELECT count("match project") FROM contract_view) = 214
-- @assert revtotal_nn: (SELECT count("Revenue Total") FROM contract_view) = 201
-- @assert earntotal_nn: (SELECT count("Earnings Total") FROM contract_view) = 201
-- @assert startdate_nn: (SELECT count("Start Date") FROM contract_view) = 150
-- @assert enddate_nn: (SELECT count("End Date") FROM contract_view) = 145

-- Start Date type and range. any_value() is required for the same reason as the GL
-- contract's glperiod_is_date: an un-aggregated typeof() returns one row per record.
-- @assert startdate_is_date: (SELECT any_value(typeof("Start Date")) FROM contract_view) = 'DATE'
-- @assert startdate_range: (SELECT min("Start Date") = DATE '2023-07-15' AND max("Start Date") = DATE '2027-03-15' FROM contract_view)

-- Money sums, cast first -- committed 2026-09-25.
-- @assert revtotal_sum: (SELECT sum("Revenue Total") FROM contract_view) = 36580445574.84
-- @assert earntotal_sum: (SELECT sum("Earnings Total") FROM contract_view) = 1439728975.91

-- Distinct year count, committed 2026-09-25.
-- @assert salesyear_distinct: (SELECT count(DISTINCT "Sales Year") FROM contract_view) = 4

-- Cast-before-compare guard (PLAN-4 §5's "casts applied before any range comparison",
-- discharged here for the first time on this contract -- see TASK.md AC11). If
-- "Revenue Total" were left VARCHAR, max() would return the lexicographic maximum
-- '99266455' instead of the true 1,682,000,000.00 -- a 17x error. Because this
-- assertion evaluates against contract_view, where the cast is already applied, it
-- fails loudly (wrong value or a comparison type error) if that cast is ever removed.
-- @assert revtotal_maxcast: (SELECT max("Revenue Total") FROM contract_view) = 1682000000.00
