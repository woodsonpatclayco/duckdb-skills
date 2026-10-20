-- contracts/SDI_Combined_SDI_Data.sql
--
-- The SDI Calculator's Combined_SDI_Data table (sheet Combined, A9:AE90): one row per project,
-- the table the month's SDI journal entry is built from. Read from the LIVE workbook. It is a
-- working file, so a run while someone has it open may fail with DuckDB's file-lock error
-- naming the holder; that is a refusal, never a silent wrong read.
--
-- Its formulas are the point of this contract. Measured on 2026-10-20 (workbook saved 2026-10-19):
--   - 81 rows, 81 distinct Project Numbers.
--   - All 29 formula columns hold ONE formula each (compared in R1C1), with nothing typed over
--     it. Project Number and Manual Exclusion are inputs and hold no formula.
--   - 5 error cells in the table, all #VALUE! on row 89 (1008945000 HHShea Exteriors, 0Precon),
--     in the EAC columns X, Y, AA, AC, AD.
--   - 722 error cells in the whole workbook (608 #N/A, 65 #REF!, 49 #VALUE!), 125 of them in
--     formulas.
--
-- Columns come back VARCHAR (read_xlsx_table reads all_varchar); cast in a query, not here.
--
-- @table: Combined_SDI_Data
-- @fingerprint: SDI Basis|Status|% Comp|Cost Manager|Project Accountant|Project Number|Project Name|Risk Reserve Basis|SDI Rate|SDI Budget|Total Project Cost Included in SDI Calc To Date|Project Cost Included in SDI Calc This Month|Previous SDI Cost To Date|Recalc SDI To Date|SDI Variance To Date (Project)|SDI Phase Check|SDI Variance (This will post to project cost)|SDI On This Month's Costs|SDI Adjustments To Previous Months|Validation Check|Prebid Exclusion|Manual Exclusion|Exclude from Analysis|Forcast Basis Amount EAC|Excluded Amount EAC|SDI Projected EAC|Recalc SDI Projected EAC|SDI Premiums + Tax EAC|SDI Variance EAC|Enterprise Earnings from SDI|Vendors With 3rd Party Bonds
--
-- The columns that feed the journal entry and the earnings figure: one formula, every row.
-- @formula_consistent sdi_basis_consistent: Combined_SDI_Data[SDI Basis]
-- @formula_consistent recalc_sdi_consistent: Combined_SDI_Data[Recalc SDI To Date]
-- @formula_consistent posting_consistent: Combined_SDI_Data[SDI Variance (This will post to project cost)]
-- @formula_consistent this_month_consistent: Combined_SDI_Data[SDI On This Month's Costs]
-- @formula_consistent prior_months_consistent: Combined_SDI_Data[SDI Adjustments To Previous Months]
-- @formula_consistent earnings_consistent: Combined_SDI_Data[Enterprise Earnings from SDI]
--
-- The posting column is still the committed formula. Row 10 in A1:
--   =SUM(FILTER(HSTACK(CHOOSECOLS('Journal Entry Helpers'!B$3#,3),IFERROR(-VALUE(CHOOSECOLS('Journal Entry Helpers'!B$3#,4)),0)),'Journal Entry Helpers'!N$3#=[@[Project Number]],0))
-- An edit copied down the whole column stays consistent; only this catches it.
-- @formula_fingerprint posting_formula: Combined_SDI_Data[SDI Variance (This will post to project cost)] == SUM(_xlfn._xlws.FILTER(_xlfn.HSTACK(_xlfn.CHOOSECOLS(_xlfn.ANCHORARRAY('Journal Entry Helpers'!R3C[-15]),3),IFERROR(-VALUE(_xlfn.CHOOSECOLS(_xlfn.ANCHORARRAY('Journal Entry Helpers'!R3C[-15]),4)),0)),_xlfn.ANCHORARRAY('Journal Entry Helpers'!R3C[-3])=Combined_SDI_Data[[#This Row],[Project Number]],0))
-- @formula_fingerprint sdi_basis_formula: Combined_SDI_Data[SDI Basis] == INDEX(_xlfn.ANCHORARRAY(R10C[34]),RC33)
--
-- Errors have not grown: the table's 5 (row 89), and the workbook's 722.
-- @formula_errors_max table_errors: Combined_SDI_Data <= 5
-- @formula_errors_max workbook_errors: * <= 722
--
-- NOT CHECKED YET, pending Phil's decision (2026-10-20): Insurance_Basis's "Project Cost of
-- Performance Bonds" column holds SUMIFS(Bonds[...]) on 192 of 229 rows; 3 rows are typed over
-- and 34 are blank. Once those are resolved, add a formula_consistent check (an at-sign line,
-- like the ones above -- written without it here so the runners don't pick it up) named
-- bonds_consistent on: Insurance_Basis[Project Cost of Performance Bonds (this amount will be subtracted from the Recalculated SDI total)]
-- Phase_Mapping_Override's Not_to_Exceed_SDI and Final_Pay_App_Adjs are hand-entered override
-- tables (a few cells start with "=" only to hold arithmetic), so they get no formula check.

CREATE OR REPLACE VIEW contract_view AS
SELECT *
FROM read_xlsx_table(
    'C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/SDI Calculator/SDI Calculator Data thru Current Month.xlsx',
    'Combined_SDI_Data'
);

-- One row per project.
-- @assert project_unique: (SELECT count(*) = count(DISTINCT "Project Number") AND count(*) = count("Project Number") FROM contract_view)
