-- tests/contracts/SDI_Combined_Formulas.sql
--
-- PLAN-6 item 4 proof contract: formula checks on the SDI Calculator's Combined_SDI_Data table.
-- It lives in tests\contracts\, NOT contracts\, because it reads a STAGED COPY of the SDI
-- Calculator (a live working file) -- the runners' default glob never picks it up. Run it with
--     tools\run-assertions.ps1 -Contract tests\contracts\SDI_Combined_Formulas.sql
-- after tests\prove-formula-checks.ps1 has staged the copy (that script also plants one defect
-- at a time in throwaway copies and shows which check catches it).
--
-- The "SDI Basis" column (Combined!A10:A90) holds one logical formula on every row, stored with
-- different A1 text per row -- INDEX(_xlfn.ANCHORARRAY(AI$10),$AG10) on row 10, ...$AG11) on row
-- 11 -- so these checks compare R1C1 forms, not A1 text. Counts measured on the staged copy of
-- 2026-10-08: 81 rows, one formula, no typed values, no blanks, no errors; 748 error cells in the
-- whole workbook (642 #N/A, 65 #REF!, 41 #VALUE!).
--
-- @table: Combined_SDI_Data
-- @fingerprint: SDI Basis|Status|% Comp|Cost Manager|Project Accountant|Project Number|Project Name|Risk Reserve Basis|SDI Rate|SDI Budget|Total Project Cost Included in SDI Calc To Date|Project Cost Included in SDI Calc This Month|Previous SDI Cost To Date|Recalc SDI To Date|SDI Variance To Date (Project)|SDI Phase Check|SDI Variance (This will post to project cost)|SDI On This Month's Costs|SDI Adjustments To Previous Months|Validation Check|Prebid Exclusion|Manual Exclusion|Exclude from Analysis|Forcast Basis Amount EAC|Excluded Amount EAC|SDI Projected EAC|Recalc SDI Projected EAC|SDI Premiums + Tax EAC|SDI Variance EAC|Enterprise Earnings from SDI|Vendors With 3rd Party Bonds
--
-- Every data row of SDI Basis holds a formula, and it is the same formula on every row:
-- @formula_consistent sdi_basis_consistent: Combined_SDI_Data[SDI Basis]
-- ...and it is still the formula committed here (row 10 in A1: =INDEX(_xlfn.ANCHORARRAY(AI$10),$AG10)):
-- @formula_fingerprint sdi_basis_formula: Combined_SDI_Data[SDI Basis] == INDEX(_xlfn.ANCHORARRAY(R10C[34]),RC33)
-- The column never shows an error:
-- @formula_errors_max sdi_basis_errors: Combined_SDI_Data[SDI Basis] <= 0
-- And the workbook as a whole has not grown errors since this was committed:
-- @formula_errors_max workbook_errors: * <= 748

CREATE OR REPLACE VIEW contract_view AS
SELECT *
FROM read_xlsx_table(
    'C:/Users/woodsonp/Claude/Dev/duckdb-skills/.duckdb-skills/formula-proof/SDI.xlsx',
    'Combined_SDI_Data'
);
