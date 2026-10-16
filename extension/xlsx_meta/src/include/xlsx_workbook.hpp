//===----------------------------------------------------------------------===//
// xlsx_workbook.hpp
//
// Reads Excel table (ListObject) locations out of an .xlsx/.xlsm zip.
// A C++ port of the table half of duckdb-skills tools/xlsx_meta.py (PLAN-6 item 1).
// Read-only: the workbook is opened through DuckDB's FileSystem and never written.
//===----------------------------------------------------------------------===//

#pragma once

#include "duckdb.hpp"

namespace duckdb {

struct XlsxSheet {
	string name;
	//! visible, hidden or veryHidden
	string state;
	//! Zip part, e.g. xl/worksheets/sheet1.xml; empty if the workbook rels don't resolve it
	string part;
};

struct XlsxTable {
	//! displayName, falling back to name (the name formulas and the Name Manager use)
	string name;
	string sheet;
	//! As stored: includes the header row and any totals row
	string ref;
	//! Header row through the last data row (totals trimmed): what read_xlsx(range=) needs
	string read_range;
	//! Data rows only
	string data_range;
	int64_t header_rows = 1;
	int64_t totals_rows = 0;
	int64_t data_rows = 0;
	int64_t column_count = 0;
	vector<string> column_names;
	string part;
};

//! One defined name (named range), or one 'ambiguous' row for a bare name defined on several
//! sheets and not at workbook scope. Hidden _xlnm.* built-ins are excluded.
struct XlsxDefinedName {
	string name;
	//! How Excel writes it: Name, or Sheet!Name / 'Bob''s Data'!Name for a sheet-scoped name
	string address;
	//! workbook, sheet, or - for an 'ambiguous' row
	string scope;
	//! Sheet a sheet-scoped name belongs to (from localSheetId); empty otherwise
	string scope_sheet;
	//! ok, ambiguous, broken (#REF!) or formula (anything that isn't Sheet!rectangle)
	string status;
	//! Where an ok name points; empty otherwise
	string sheet;
	string range;
	int64_t rows = 0;
	//! The definition text as stored, or for 'ambiguous' where it is defined
	string detail;
	//! Lower-cased spellings that address this entry, in lookup order
	vector<string> keys;
};

class XlsxWorkbook {
public:
	//! Throws IOException / InvalidInputException naming the path on any failure.
	static XlsxWorkbook Load(FileSystem &fs, const string &path);

	string path;
	//! Tab order; index == definedName localSheetId
	vector<XlsxSheet> sheets;
	//! Sheet order, then rels order within a sheet
	vector<XlsxTable> tables;
	//! Definitions in workbook order, then one 'ambiguous' row per bare name defined on several
	//! sheets with no workbook-scoped definition
	vector<XlsxDefinedName> names;

	//! Case-insensitive (Unicode lower-casing, as Excel compares names); nullptr if absent
	const XlsxTable *FindTable(const string &table_name) const;
	//! Name, Sheet!Name or 'Quoted Sheet'!Name, case-insensitive. The first entry whose keys
	//! match wins -- the same order as the CASE macros tools/xlsx_meta.py generates.
	const XlsxDefinedName *FindName(const string &name) const;
};

//! Unicode-aware lower-casing, used for every name comparison
string XlsxLower(const string &input);

} // namespace duckdb
