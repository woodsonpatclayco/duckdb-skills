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

-- Round 2, C1 -- every assertion below is reclassified into exactly one of three kinds
-- (TASK.md CORRECTIONS section), the same pass applied to the GL contract. This sheet
-- showed zero drift between the two measurement sessions, so nothing here failed in
-- round 1 -- but the six hard-equality counts below (jobnum_nn, matchproject_nn,
-- revtotal_nn, earntotal_nn, startdate_nn, enddate_nn), the two hard sums, the hard
-- date range, and the hard distinct-year count carry exactly the same latent defect
-- the GL contract's four broken asserts had: none of them can survive the sheet's own
-- ordinary movement (227 -> 226 -> 219 rows, and new sales years arriving on a
-- calendar this workbook has no control over).
--
--   INVARIANT (a relationship, never a literal -- refresh-proof):
--     - anchor completeness, count("Job #") = count(*): computed by the "@anchor"
--       directive above and reported as the ANCHOR,... line. REPLACES jobnum_nn.
--     - startdate_is_date (below, unchanged): "Start Date" decodes to a real DATE.
--     - the consistency equality (view rows = with-data rows over all sheet columns):
--       already computed by the harness for every contract, unchanged by this round.
--     - revtotal_sum_exact_decimal, earntotal_sum_exact_decimal, and
--       revtotal_maxcast_exact_decimal (below, new): each sum/max has no
--       floating-point tail, a property of the DECIMAL(18,2) casts above and not of
--       the row count.
--
--   FLOOR (a measured ratio with justified headroom -- gates the exit code):
--     - matchproject_ratio_floor (below, new) replaces matchproject_nn: >= 0.90 --
--       observed 0.9772 (214 of 219).
--     - revtotal_ratio_floor (below, new) replaces revtotal_nn: >= 0.85 -- observed
--       0.9178 (201 of 219).
--     - enddate_ratio_floor (below, new) replaces enddate_nn: >= 0.55 -- observed
--       0.6621 (145 of 219).
--     - the existing @rows_floor: 200 directive above, unchanged.
--
--   SNAPSHOT (reported, never gates the exit code): earntotal_nn and startdate_nn have
--   no measured floor headroom given for this round (the CORRECTIONS section's floor
--   table names only rows/Job #/Revenue Total/End Date/match project for this
--   contract), so both stay absolute counts -- reported, not asserted. Also
--   snapshotted: matchproject_nn, revtotal_nn, enddate_nn (the same counts the three
--   floors above are ratios of -- Phil sees both forms), both money sums, the cast
--   max, the "Start Date" min/max, and the distinct "Sales Year" count -- all of these
--   are absolute figures that can legitimately move (a new year arrives, more sales
--   close) and none of them has a defensible floor value handed down for this round.
-- @assert startdate_is_date: (SELECT any_value(typeof("Start Date")) FROM contract_view) = 'DATE'
-- @assert matchproject_ratio_floor: (SELECT count("match project")::DOUBLE / count(*) FROM contract_view) >= 0.90
-- @assert revtotal_ratio_floor: (SELECT count("Revenue Total")::DOUBLE / count(*) FROM contract_view) >= 0.85
-- @assert enddate_ratio_floor: (SELECT count("End Date")::DOUBLE / count(*) FROM contract_view) >= 0.55
-- @assert revtotal_sum_exact_decimal: (SELECT typeof(sum("Revenue Total")) FROM contract_view) LIKE 'DECIMAL%'
-- @assert earntotal_sum_exact_decimal: (SELECT typeof(sum("Earnings Total")) FROM contract_view) LIKE 'DECIMAL%'
-- @assert revtotal_maxcast_exact_decimal: (SELECT typeof(max("Revenue Total")) FROM contract_view) LIKE 'DECIMAL%'

-- Snapshots (round 2, C2): reported unconditionally, gate nothing. Committed values
-- below are this session's own baseline (2026-09-25) -- zero drift observed against
-- the 2026-09-24 figures this contract originally shipped with. A mismatch on a
-- future run is drift to observe via SNAPSHOT_DRIFT, not a failure.
-- @snapshot matchproject_nn: (SELECT count("match project") FROM contract_view)
-- @snapshot_committed matchproject_nn: 214
-- @snapshot revtotal_nn: (SELECT count("Revenue Total") FROM contract_view)
-- @snapshot_committed revtotal_nn: 201
-- @snapshot earntotal_nn: (SELECT count("Earnings Total") FROM contract_view)
-- @snapshot_committed earntotal_nn: 201
-- @snapshot startdate_nn: (SELECT count("Start Date") FROM contract_view)
-- @snapshot_committed startdate_nn: 150
-- @snapshot enddate_nn: (SELECT count("End Date") FROM contract_view)
-- @snapshot_committed enddate_nn: 145
-- @snapshot revtotal_sum: (SELECT sum("Revenue Total") FROM contract_view)
-- @snapshot_committed revtotal_sum: 36580445574.84
-- @snapshot earntotal_sum: (SELECT sum("Earnings Total") FROM contract_view)
-- @snapshot_committed earntotal_sum: 1439728975.91
-- @snapshot revtotal_max: (SELECT max("Revenue Total") FROM contract_view)
-- @snapshot_committed revtotal_max: 1682000000.00
-- @snapshot startdate_min: (SELECT min("Start Date") FROM contract_view)
-- @snapshot_committed startdate_min: 2023-07-15
-- @snapshot startdate_max: (SELECT max("Start Date") FROM contract_view)
-- @snapshot_committed startdate_max: 2027-03-15
-- @snapshot salesyear_distinct: (SELECT count(DISTINCT "Sales Year") FROM contract_view)
-- @snapshot_committed salesyear_distinct: 4
