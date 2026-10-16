#define DUCKDB_EXTENSION_MAIN

#include "xlsx_meta_extension.hpp"
#include "xlsx_workbook.hpp"

#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/function/table_function.hpp"

#include <algorithm>

namespace duckdb {

//===--------------------------------------------------------------------===//
// Scalars: xlsx_table_sheet / xlsx_table_range (path, table),
//          xlsx_name_sheet / xlsx_name_range / xlsx__name_header (path, name)
//
// Registered CONSISTENT (DuckDB's default, i.e. not volatile) on purpose: with constant
// arguments they fold at bind time, which is what lets a table macro hand their results to
// read_xlsx(sheet=, range=) through query(). A volatile registration would break that.
//
// Names and error messages are the ones tools/xlsx_meta.py's generated macros use, so the
// duckdb-skills read_xlsx_table / read_xlsx_name macros work on top of either unchanged.
//===--------------------------------------------------------------------===//
static const XlsxTable &RequireTable(const XlsxWorkbook &wb, const string &table_name) {
	auto table = wb.FindTable(table_name);
	if (!table) {
		throw InvalidInputException("no table '%s' in %s -- list them with FROM xlsx_tables('%s')", table_name,
		                            wb.path, wb.path);
	}
	return *table;
}

//! The definition if it resolves to a rectangle; otherwise the refusal it calls for
static const XlsxDefinedName &RequireName(const XlsxWorkbook &wb, const string &name) {
	auto def = wb.FindName(name);
	if (!def) {
		throw InvalidInputException("no defined name '%s' in %s -- list them with FROM xlsx_names('%s')", name,
		                            wb.path, wb.path);
	}
	if (def->status == "ambiguous") {
		throw InvalidInputException("read_xlsx_name: %s is ambiguous -- %s; address it as Sheet!Name", def->name,
		                            def->detail);
	}
	if (def->status == "broken") {
		throw InvalidInputException("read_xlsx_name: %s is broken: %s", def->address, def->detail);
	}
	if (def->status != "ok") {
		throw InvalidInputException(
		    "read_xlsx_name: %s is not a plain cell range (it is %s); formula-defined names are not resolved",
		    def->address, def->detail);
	}
	return *def;
}

template <class OP>
static void WorkbookLookup(DataChunk &args, ExpressionState &state, Vector &result) {
	auto &fs = FileSystem::GetFileSystem(state.GetContext());
	// One workbook load per distinct path in the chunk, not one per row.
	string cached_path;
	unique_ptr<XlsxWorkbook> cached;
	BinaryExecutor::Execute<string_t, string_t, typename OP::RESULT>(
	    args.data[0], args.data[1], result, args.size(), [&](string_t path, string_t key) {
		    auto path_str = path.GetString();
		    if (!cached || cached_path != path_str) {
			    cached = make_uniq<XlsxWorkbook>(XlsxWorkbook::Load(fs, path_str));
			    cached_path = path_str;
		    }
		    return OP::Get(*cached, key.GetString(), result);
	    });
}

struct TableSheetOp {
	using RESULT = string_t;
	static string_t Get(const XlsxWorkbook &wb, const string &key, Vector &result) {
		return StringVector::AddString(result, RequireTable(wb, key).sheet);
	}
};

struct TableRangeOp {
	using RESULT = string_t;
	static string_t Get(const XlsxWorkbook &wb, const string &key, Vector &result) {
		auto &table = RequireTable(wb, key);
		// Refuse rather than guess (PLAN-6)
		if (table.header_rows == 0) {
			throw InvalidInputException("read_xlsx_table: table %s on sheet %s has no header row (headerRowCount=0); "
			                            "refusing to guess column names",
			                            table.name, table.sheet);
		}
		if (table.data_rows < 1) {
			throw InvalidInputException("read_xlsx_table: table %s has no data rows (ref %s)", table.name, table.ref);
		}
		return StringVector::AddString(result, table.read_range);
	}
};

struct NameSheetOp {
	using RESULT = string_t;
	static string_t Get(const XlsxWorkbook &wb, const string &key, Vector &result) {
		return StringVector::AddString(result, RequireName(wb, key).sheet);
	}
};

struct NameRangeOp {
	using RESULT = string_t;
	static string_t Get(const XlsxWorkbook &wb, const string &key, Vector &result) {
		return StringVector::AddString(result, RequireName(wb, key).range);
	}
};

//! read_xlsx_name's header default: a one-row range has nothing below a header to read
struct NameHeaderOp {
	using RESULT = bool;
	static bool Get(const XlsxWorkbook &wb, const string &key, Vector &result) {
		return RequireName(wb, key).rows > 1;
	}
};

//===--------------------------------------------------------------------===//
// Table functions: xlsx_tables(path), xlsx_sheets(path)
//===--------------------------------------------------------------------===//
struct XlsxRowsBindData : public TableFunctionData {
	vector<vector<Value>> rows;
};

struct XlsxRowsState : public GlobalTableFunctionState {
	idx_t offset = 0;
};

static string ConstantPath(TableFunctionBindInput &input, const char *fn) {
	if (input.inputs.empty() || input.inputs[0].IsNull()) {
		throw BinderException("%s: path must not be NULL", fn);
	}
	return input.inputs[0].GetValue<string>();
}

static unique_ptr<FunctionData> XlsxTablesBind(ClientContext &context, TableFunctionBindInput &input,
                                               vector<LogicalType> &return_types, vector<string> &names) {
	auto path = ConstantPath(input, "xlsx_tables");
	auto wb = XlsxWorkbook::Load(FileSystem::GetFileSystem(context), path);

	names = {"table_name",  "sheet_name",  "ref",         "read_range",   "data_range",
	         "data_rows",   "header_rows", "totals_rows", "column_count", "column_names"};
	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	                LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::BIGINT,
	                LogicalType::BIGINT,  LogicalType::BIGINT,  LogicalType::BIGINT,
	                LogicalType::LIST(LogicalType::VARCHAR)};

	// Tab order of the sheet, then ref as text: the order tools/xlsx_meta.py tables prints.
	unordered_map<string, idx_t> sheet_index;
	for (idx_t i = 0; i < wb.sheets.size(); i++) {
		sheet_index.emplace(wb.sheets[i].name, i);
	}
	vector<const XlsxTable *> ordered;
	for (auto &table : wb.tables) {
		ordered.push_back(&table);
	}
	std::stable_sort(ordered.begin(), ordered.end(), [&](const XlsxTable *a, const XlsxTable *b) {
		auto ia = sheet_index[a->sheet], ib = sheet_index[b->sheet];
		return ia != ib ? ia < ib : a->ref < b->ref;
	});

	auto result = make_uniq<XlsxRowsBindData>();
	for (auto table : ordered) {
		vector<Value> column_names;
		for (auto &name : table->column_names) {
			column_names.emplace_back(name);
		}
		result->rows.push_back({Value(table->name), Value(table->sheet), Value(table->ref), Value(table->read_range),
		                        Value(table->data_range), Value::BIGINT(table->data_rows),
		                        Value::BIGINT(table->header_rows), Value::BIGINT(table->totals_rows),
		                        Value::BIGINT(table->column_count),
		                        Value::LIST(LogicalType::VARCHAR, std::move(column_names))});
	}
	return std::move(result);
}

static unique_ptr<FunctionData> XlsxSheetsBind(ClientContext &context, TableFunctionBindInput &input,
                                               vector<LogicalType> &return_types, vector<string> &names) {
	auto path = ConstantPath(input, "xlsx_sheets");
	auto wb = XlsxWorkbook::Load(FileSystem::GetFileSystem(context), path);

	names = {"sheet_index", "sheet_name", "state", "part", "table_count"};
	return_types = {LogicalType::BIGINT, LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	                LogicalType::BIGINT};

	auto result = make_uniq<XlsxRowsBindData>();
	for (idx_t i = 0; i < wb.sheets.size(); i++) {
		auto &sheet = wb.sheets[i];
		int64_t table_count = 0;
		for (auto &table : wb.tables) {
			table_count += table.sheet == sheet.name ? 1 : 0;
		}
		result->rows.push_back({Value::BIGINT(NumericCast<int64_t>(i + 1)), Value(sheet.name), Value(sheet.state),
		                        sheet.part.empty() ? Value(LogicalType::VARCHAR) : Value(sheet.part),
		                        Value::BIGINT(table_count)});
	}
	return std::move(result);
}

static Value OptionalText(const string &text) {
	return text.empty() ? Value(LogicalType::VARCHAR) : Value(text);
}

static unique_ptr<FunctionData> XlsxNamesBind(ClientContext &context, TableFunctionBindInput &input,
                                              vector<LogicalType> &return_types, vector<string> &names) {
	auto path = ConstantPath(input, "xlsx_names");
	auto wb = XlsxWorkbook::Load(FileSystem::GetFileSystem(context), path);

	names = {"defined_name", "address",    "scope",     "scope_sheet", "status",
	         "sheet_name",   "cell_range", "row_count", "detail"};
	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	                LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	                LogicalType::VARCHAR, LogicalType::BIGINT,  LogicalType::VARCHAR};

	// Same rows and order as tools/xlsx_meta.py names: definitions, then 'ambiguous' rows
	auto result = make_uniq<XlsxRowsBindData>();
	for (auto &def : wb.names) {
		auto ok = def.status == "ok";
		result->rows.push_back({Value(def.name), Value(def.address), Value(def.scope), OptionalText(def.scope_sheet),
		                        Value(def.status), OptionalText(def.sheet), OptionalText(def.range),
		                        ok ? Value::BIGINT(def.rows) : Value(LogicalType::BIGINT), Value(def.detail)});
	}
	return std::move(result);
}

static unique_ptr<GlobalTableFunctionState> XlsxRowsInit(ClientContext &context, TableFunctionInitInput &input) {
	return make_uniq<XlsxRowsState>();
}

static void XlsxRowsScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind_data = data.bind_data->Cast<XlsxRowsBindData>();
	auto &state = data.global_state->Cast<XlsxRowsState>();
	idx_t count = 0;
	while (state.offset < bind_data.rows.size() && count < STANDARD_VECTOR_SIZE) {
		auto &row = bind_data.rows[state.offset++];
		for (idx_t col = 0; col < row.size(); col++) {
			output.SetValue(col, count, row[col]);
		}
		count++;
	}
	output.SetCardinality(count);
}

static void LoadInternal(ExtensionLoader &loader) {
	auto lookup = [&](const char *name, const LogicalType &type, scalar_function_t fn) {
		loader.RegisterFunction(ScalarFunction(name, {LogicalType::VARCHAR, LogicalType::VARCHAR}, type, fn));
	};
	lookup("xlsx_table_sheet", LogicalType::VARCHAR, WorkbookLookup<TableSheetOp>);
	lookup("xlsx_table_range", LogicalType::VARCHAR, WorkbookLookup<TableRangeOp>);
	lookup("xlsx_name_sheet", LogicalType::VARCHAR, WorkbookLookup<NameSheetOp>);
	lookup("xlsx_name_range", LogicalType::VARCHAR, WorkbookLookup<NameRangeOp>);
	lookup("xlsx__name_header", LogicalType::BOOLEAN, WorkbookLookup<NameHeaderOp>);

	for (auto &entry : {std::make_pair("xlsx_tables", XlsxTablesBind), std::make_pair("xlsx_sheets", XlsxSheetsBind),
	                    std::make_pair("xlsx_names", XlsxNamesBind)}) {
		loader.RegisterFunction(
		    TableFunction(entry.first, {LogicalType::VARCHAR}, XlsxRowsScan, entry.second, XlsxRowsInit));
	}
}

void XlsxMetaExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}
std::string XlsxMetaExtension::Name() {
	return "xlsx_meta";
}

std::string XlsxMetaExtension::Version() const {
#ifdef EXT_VERSION_XLSX_META
	return EXT_VERSION_XLSX_META;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(xlsx_meta, loader) {
	duckdb::LoadInternal(loader);
}
}
