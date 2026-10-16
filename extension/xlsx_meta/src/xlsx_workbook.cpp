#include "xlsx_workbook.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/function/scalar/string_common.hpp"
#include "miniz.hpp"
#include "pugixml.hpp"

#include <algorithm>
#include <functional>

namespace duckdb {

namespace {

const char *const REL_TABLE_SUFFIX = "/table";

//===--------------------------------------------------------------------===//
// Zip access through DuckDB's FileSystem
//===--------------------------------------------------------------------===//
class ZipReader {
public:
	ZipReader(FileSystem &fs, const string &path) : path(path) {
		handle = fs.OpenFile(path, FileFlags::FILE_FLAGS_READ);
		memset(&zip, 0, sizeof(zip));
		zip.m_pRead = ReadCallback;
		zip.m_pIO_opaque = this;
		if (!duckdb_miniz::mz_zip_reader_init(&zip, handle->GetFileSize(), 0)) {
			throw InvalidInputException("xlsx_meta: not an .xlsx/.xlsm zip (an .xls or .xlsb?): %s", path);
		}
		open = true;
	}
	~ZipReader() {
		if (open) {
			duckdb_miniz::mz_zip_reader_end(&zip);
		}
	}

	bool Has(const string &name) {
		return Locate(name) >= 0;
	}

	string Read(const string &name) {
		auto index = Locate(name);
		if (index < 0) {
			throw InvalidInputException("xlsx_meta: no %s in %s", name, path);
		}
		size_t size = 0;
		auto data = duckdb_miniz::mz_zip_reader_extract_to_heap(&zip, UnsafeNumericCast<duckdb_miniz::mz_uint>(index),
		                                                        &size, 0);
		if (!data) {
			throw IOException("xlsx_meta: cannot decompress %s in %s: %s", name, path,
			                  duckdb_miniz::mz_zip_get_error_string(duckdb_miniz::mz_zip_get_last_error(&zip)));
		}
		string result(static_cast<const char *>(data), size);
		duckdb_miniz::mz_free(data);
		return result;
	}

private:
	int Locate(const string &name) {
		// Exact, case-sensitive part names, as the Python reference's z.namelist() checks.
		return duckdb_miniz::mz_zip_reader_locate_file(&zip, name.c_str(), nullptr,
		                                               duckdb_miniz::MZ_ZIP_FLAG_CASE_SENSITIVE);
	}

	static size_t ReadCallback(void *opaque, duckdb_miniz::mz_uint64 offset, void *buffer, size_t n) {
		auto &self = *static_cast<ZipReader *>(opaque);
		try {
			self.handle->Read(buffer, n, offset);
			return n;
		} catch (...) {
			return 0;
		}
	}

	string path;
	unique_ptr<FileHandle> handle;
	duckdb_miniz::mz_zip_archive zip;
	bool open = false;
};

//===--------------------------------------------------------------------===//
// XML helpers: match on local names, so prefixed documents (<x:table>) read the same
//===--------------------------------------------------------------------===//
const char *LocalName(const char *qualified) {
	auto colon = strrchr(qualified, ':');
	return colon ? colon + 1 : qualified;
}

bool IsElement(const pugi::xml_node &node, const char *local) {
	return node.type() == pugi::node_element && strcmp(LocalName(node.name()), local) == 0;
}

//! Attribute by local name, ignoring any namespace prefix (r:id etc.)
const char *LocalAttr(const pugi::xml_node &node, const char *local) {
	for (auto attr = node.first_attribute(); attr; attr = attr.next_attribute()) {
		if (strcmp(LocalName(attr.name()), local) == 0) {
			return attr.value();
		}
	}
	return nullptr;
}

pugi::xml_document ParseXml(const string &text, const string &part, const string &path) {
	pugi::xml_document doc;
	auto result = doc.load_buffer(text.data(), text.size());
	if (!result) {
		throw InvalidInputException("xlsx_meta: cannot parse %s in %s: %s", part, path, result.description());
	}
	return doc;
}

pugi::xml_node RootElement(const pugi::xml_document &doc) {
	for (auto node = doc.first_child(); node; node = node.next_sibling()) {
		if (node.type() == pugi::node_element) {
			return node;
		}
	}
	return pugi::xml_node();
}

void ForEachElement(const pugi::xml_node &node, const std::function<void(const pugi::xml_node &)> &fn) {
	for (auto child = node.first_child(); child; child = child.next_sibling()) {
		if (child.type() == pugi::node_element) {
			fn(child);
			ForEachElement(child, fn);
		}
	}
}

//===--------------------------------------------------------------------===//
// Part paths and relationships
//===--------------------------------------------------------------------===//
string PosixDirname(const string &part) {
	auto slash = part.rfind('/');
	return slash == string::npos ? string() : part.substr(0, slash);
}

string NormalizePart(const string &joined) {
	vector<string> out;
	for (auto &piece : StringUtil::Split(joined, '/')) {
		if (piece.empty() || piece == ".") {
			continue;
		}
		if (piece == "..") {
			if (!out.empty()) {
				out.pop_back();
			}
			continue;
		}
		out.push_back(piece);
	}
	return StringUtil::Join(out, "/");
}

string ResolveTarget(const string &base_dir, const string &target) {
	if (StringUtil::StartsWith(target, "/")) {
		auto first = target.find_first_not_of('/');
		return first == string::npos ? string() : target.substr(first);
	}
	return NormalizePart(base_dir.empty() ? target : base_dir + "/" + target);
}

struct Relationship {
	string id;
	string type;
	string target;
};

vector<Relationship> ReadRels(ZipReader &zip, const string &part, const string &path) {
	auto dir = PosixDirname(part);
	auto file = dir.empty() ? part : part.substr(dir.size() + 1);
	auto rels_part = (dir.empty() ? string() : dir + "/") + "_rels/" + file + ".rels";
	vector<Relationship> rels;
	if (!zip.Has(rels_part)) {
		return rels;
	}
	auto doc = ParseXml(zip.Read(rels_part), rels_part, path);
	for (auto rel = RootElement(doc).first_child(); rel; rel = rel.next_sibling()) {
		if (rel.type() != pugi::node_element) {
			continue;
		}
		if (string(rel.attribute("TargetMode").value()) == "External") {
			continue;
		}
		rels.push_back({rel.attribute("Id").value(), rel.attribute("Type").value(),
		                ResolveTarget(dir, rel.attribute("Target").value())});
	}
	return rels;
}

//===--------------------------------------------------------------------===//
// Cell areas
//===--------------------------------------------------------------------===//
struct Area {
	int64_t c1, r1, c2, r2;
};

//! 'B3' or '$B$3' -> (col, row); false if not a plain cell reference
bool ParseCell(const string &text, int64_t &col, int64_t &row) {
	idx_t i = 0;
	if (i < text.size() && text[i] == '$') {
		i++;
	}
	idx_t letters = 0;
	col = 0;
	while (i < text.size() && text[i] >= 'A' && text[i] <= 'Z') {
		col = col * 26 + (text[i] - 'A' + 1);
		i++;
		letters++;
	}
	if (letters < 1 || letters > 3) {
		return false;
	}
	if (i < text.size() && text[i] == '$') {
		i++;
	}
	idx_t digits = 0;
	row = 0;
	while (i < text.size() && text[i] >= '0' && text[i] <= '9') {
		if (row > 10000000) {
			return false;
		}
		row = row * 10 + (text[i] - '0');
		i++;
		digits++;
	}
	return digits > 0 && i == text.size();
}

//! 'A2:AO124' or 'B3' -> Area; false if not a plain rectangle
bool ParseArea(const string &ref, Area &area) {
	auto parts = StringUtil::Split(ref, ':');
	if (parts.empty() || parts.size() > 2 || (ref.find(':') != string::npos && parts.size() != 2)) {
		return false;
	}
	int64_t c1, r1, c2, r2;
	if (!ParseCell(parts.front(), c1, r1) || !ParseCell(parts.back(), c2, r2)) {
		return false;
	}
	area = {MinValue(c1, c2), MinValue(r1, r2), MaxValue(c1, c2), MaxValue(r1, r2)};
	return true;
}

string ColumnLetters(int64_t n) {
	string s;
	while (n > 0) {
		auto r = (n - 1) % 26;
		s.insert(s.begin(), char('A' + r));
		n = (n - 1) / 26;
	}
	return s;
}

string AreaText(int64_t c1, int64_t r1, int64_t c2, int64_t r2) {
	auto a = ColumnLetters(c1) + std::to_string(r1);
	auto b = ColumnLetters(c2) + std::to_string(r2);
	return a == b ? a : a + ":" + b;
}

//===--------------------------------------------------------------------===//
// Defined names
//===--------------------------------------------------------------------===//
//! 1-3 letters then digits, e.g. AB12: a sheet named like that must be quoted
bool LooksLikeCell(const string &text) {
	idx_t i = 0;
	while (i < text.size() && StringUtil::CharacterIsAlpha(text[i])) {
		i++;
	}
	if (i < 1 || i > 3 || i == text.size()) {
		return false;
	}
	for (; i < text.size(); i++) {
		if (!StringUtil::CharacterIsDigit(text[i])) {
			return false;
		}
	}
	return true;
}

//! Excel's way of writing a sheet name in front of '!'
string QuoteSheet(const string &sheet) {
	bool plain = !sheet.empty() && (StringUtil::CharacterIsAlpha(sheet[0]) || sheet[0] == '_');
	for (idx_t i = 1; plain && i < sheet.size(); i++) {
		auto c = sheet[i];
		plain = StringUtil::CharacterIsAlpha(c) || StringUtil::CharacterIsDigit(c) || c == '_' || c == '.';
	}
	if (plain && !LooksLikeCell(sheet)) {
		return sheet;
	}
	return "'" + StringUtil::Replace(sheet, "'", "''") + "'";
}

//! Sets status (and sheet/range/rows when ok) from a definedName's text. Only Sheet!rectangle
//! (sheet quoted or not, $ allowed) on an existing sheet is ok; #REF! anywhere is broken;
//! everything else -- OFFSET(...), whole columns, constants, missing sheets -- is formula.
void ClassifyDefinition(const string &text, const vector<XlsxSheet> &sheets, XlsxDefinedName &def) {
	if (StringUtil::Upper(text).find("#REF!") != string::npos) {
		def.status = "broken";
		return;
	}
	def.status = "formula";
	string sheet;
	idx_t i = 0;
	if (!text.empty() && text[0] == '\'') {
		bool closed = false;
		for (i = 1; i < text.size();) {
			if (text[i] == '\'') {
				if (i + 1 < text.size() && text[i + 1] == '\'') {
					sheet += '\'';
					i += 2;
					continue;
				}
				closed = true;
				i++;
				break;
			}
			sheet += text[i++];
		}
		if (!closed || sheet.empty()) {
			return;
		}
	} else {
		auto bang = text.find('!');
		if (bang == string::npos || bang == 0) {
			return;
		}
		sheet = text.substr(0, bang);
		if (sheet.find_first_of("'[]") != string::npos) {
			return;
		}
		i = bang;
	}
	if (i >= text.size() || text[i] != '!') {
		return;
	}
	auto cells = text.substr(i + 1);
	if (cells.empty() || cells.find_first_not_of("$ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:") != string::npos) {
		return;
	}
	Area area;
	if (!ParseArea(StringUtil::Replace(cells, "$", ""), area)) {
		return;
	}
	bool sheet_exists = false;
	for (auto &candidate : sheets) {
		sheet_exists = sheet_exists || candidate.name == sheet;
	}
	if (!sheet_exists) {
		return;
	}
	def.status = "ok";
	def.sheet = sheet;
	def.range = AreaText(area.c1, area.r1, area.c2, area.r2);
	def.rows = area.r2 - area.r1 + 1;
}

//! An element's text with surrounding whitespace removed
string TrimmedText(const pugi::xml_node &el) {
	string text = el.child_value();
	StringUtil::Trim(text);
	return text;
}

struct RawDefinedName {
	string name;
	//! -1 when the name has workbook scope
	int64_t local_sheet_id;
	string text;
};

vector<XlsxDefinedName> BuildNames(const vector<RawDefinedName> &raw, const vector<XlsxSheet> &sheets) {
	vector<XlsxDefinedName> names;
	for (auto &entry : raw) {
		if (StringUtil::StartsWith(entry.name, "_xlnm.")) {
			continue;
		}
		XlsxDefinedName def;
		def.name = entry.name;
		def.detail = entry.text;
		if (entry.local_sheet_id >= 0 && entry.local_sheet_id < NumericCast<int64_t>(sheets.size())) {
			def.scope_sheet = sheets[NumericCast<idx_t>(entry.local_sheet_id)].name;
		}
		def.scope = def.scope_sheet.empty() ? "workbook" : "sheet";
		def.address = def.scope_sheet.empty() ? def.name : QuoteSheet(def.scope_sheet) + "!" + def.name;
		ClassifyDefinition(entry.text, sheets, def);
		names.push_back(std::move(def));
	}

	// Group by lower-cased name, in order of first appearance
	vector<string> order;
	unordered_map<string, vector<idx_t>> by_name;
	for (idx_t i = 0; i < names.size(); i++) {
		auto key = XlsxLower(names[i].name);
		if (by_name.find(key) == by_name.end()) {
			order.push_back(key);
		}
		by_name[key].push_back(i);
	}

	for (auto &def : names) {
		auto bare = XlsxLower(def.name);
		if (def.scope_sheet.empty()) {
			def.keys.push_back(bare);
			continue;
		}
		// Excel's spelling, plus the sheet unquoted and always-quoted ('Rates'!Name is valid Excel)
		for (auto &spelling : {def.address, def.scope_sheet + "!" + def.name,
		                       "'" + StringUtil::Replace(def.scope_sheet, "'", "''") + "'!" + def.name}) {
			auto key = XlsxLower(spelling);
			if (std::find(def.keys.begin(), def.keys.end(), key) == def.keys.end()) {
				def.keys.push_back(key);
			}
		}
		// A sheet-scoped name that is the only definition of its name also answers to its bare name
		if (by_name[bare].size() == 1) {
			def.keys.push_back(bare);
		}
	}

	// A bare name defined on several sheets is ambiguous -- unless one definition is workbook-scoped:
	// then the bare name means that one (as in Excel), and the sheet-scoped ones are Sheet!Name.
	for (auto &key : order) {
		auto &defs = by_name[key];
		bool has_workbook_scope = false;
		for (auto index : defs) {
			has_workbook_scope = has_workbook_scope || names[index].scope_sheet.empty();
		}
		if (defs.size() < 2 || has_workbook_scope) {
			continue;
		}
		vector<string> where;
		for (auto index : defs) {
			where.push_back(names[index].address);
		}
		XlsxDefinedName ambiguous;
		ambiguous.name = names[defs[0]].name;
		ambiguous.address = ambiguous.name;
		ambiguous.scope = "-";
		ambiguous.status = "ambiguous";
		ambiguous.detail = "defined " + std::to_string(defs.size()) + " times: " + StringUtil::Join(where, ", ");
		ambiguous.keys.push_back(key);
		names.push_back(std::move(ambiguous));
	}
	return names;
}

int64_t ParseCount(const char *value, int64_t fallback, const string &what, const string &part, const string &path) {
	if (!value) {
		return fallback;
	}
	try {
		return std::stoll(value);
	} catch (...) {
		throw InvalidInputException("xlsx_meta: %s=\"%s\" is not a number in %s of %s", what, value, part, path);
	}
}

XlsxTable ReadTable(ZipReader &zip, const string &sheet, const string &part, const string &path) {
	auto doc = ParseXml(zip.Read(part), part, path);
	// <table> is the root element; only ITS attributes are used -- its <autoFilter> child has a
	// different ref (it excludes the totals row).
	auto root = RootElement(doc);
	XlsxTable table;
	table.sheet = sheet;
	table.part = part;
	string display_name = root.attribute("displayName").value();
	table.name = display_name.empty() ? root.attribute("name").value() : display_name;
	table.ref = root.attribute("ref").value();
	table.header_rows = ParseCount(root.attribute("headerRowCount").as_string(nullptr), 1, "headerRowCount", part, path);
	table.totals_rows = ParseCount(root.attribute("totalsRowCount").as_string(nullptr), 0, "totalsRowCount", part, path);

	bool have_count = false;
	for (auto child = root.first_child(); child; child = child.next_sibling()) {
		if (!IsElement(child, "tableColumns")) {
			continue;
		}
		for (auto col = child.first_child(); col; col = col.next_sibling()) {
			if (IsElement(col, "tableColumn")) {
				table.column_names.push_back(col.attribute("name").value());
			}
		}
		auto count = child.attribute("count").as_string(nullptr);
		table.column_count = (count && *count) ? ParseCount(count, 0, "count", part, path)
		                                       : NumericCast<int64_t>(table.column_names.size());
		have_count = true;
		break;
	}

	Area area;
	if (!ParseArea(table.ref, area)) {
		throw InvalidInputException("xlsx_meta: table %s on sheet %s has ref \"%s\", not a plain cell range (%s in %s)",
		                            table.name, sheet, table.ref, part, path);
	}
	auto data_first = area.r1 + table.header_rows;
	auto data_last = area.r2 - table.totals_rows;
	table.read_range = AreaText(area.c1, area.r1, area.c2, data_last);
	table.data_range = AreaText(area.c1, data_first, area.c2, data_last);
	table.data_rows = data_last - data_first + 1;
	if (!have_count) {
		table.column_count = area.c2 - area.c1 + 1;
	}
	return table;
}

} // namespace

string XlsxLower(const string &input) {
	auto length = LowerLength(input.c_str(), input.size());
	string result(length, '\0');
	LowerCase(input.c_str(), input.size(), &result[0]);
	return result;
}

XlsxWorkbook XlsxWorkbook::Load(FileSystem &fs, const string &path) {
	ZipReader zip(fs, path);
	XlsxWorkbook wb;
	wb.path = path;
	if (!zip.Has("xl/workbook.xml")) {
		throw InvalidInputException("xlsx_meta: no xl/workbook.xml in %s", path);
	}

	unordered_map<string, string> rid_target;
	for (auto &rel : ReadRels(zip, "xl/workbook.xml", path)) {
		rid_target[rel.id] = rel.target;
	}
	auto doc = ParseXml(zip.Read("xl/workbook.xml"), "xl/workbook.xml", path);
	vector<RawDefinedName> defined;
	ForEachElement(doc, [&](const pugi::xml_node &el) {
		if (IsElement(el, "definedName")) {
			auto lsid = el.attribute("localSheetId").as_string(nullptr);
			defined.push_back({el.attribute("name").value(),
			                   lsid ? ParseCount(lsid, -1, "localSheetId", "xl/workbook.xml", path) : -1,
			                   TrimmedText(el)});
			return;
		}
		if (!IsElement(el, "sheet")) {
			return;
		}
		XlsxSheet sheet;
		sheet.name = el.attribute("name").value();
		string state = el.attribute("state").value();
		sheet.state = state.empty() ? "visible" : state;
		auto rid = LocalAttr(el, "id");
		if (rid) {
			auto entry = rid_target.find(rid);
			if (entry != rid_target.end()) {
				sheet.part = entry->second;
			}
		}
		wb.sheets.push_back(std::move(sheet));
	});

	for (auto &sheet : wb.sheets) {
		if (sheet.part.empty()) {
			continue;
		}
		for (auto &rel : ReadRels(zip, sheet.part, path)) {
			if (!StringUtil::EndsWith(rel.type, REL_TABLE_SUFFIX) || !zip.Has(rel.target)) {
				continue;
			}
			wb.tables.push_back(ReadTable(zip, sheet.name, rel.target, path));
		}
	}
	wb.names = BuildNames(defined, wb.sheets);
	return wb;
}

const XlsxTable *XlsxWorkbook::FindTable(const string &table_name) const {
	auto wanted = XlsxLower(table_name);
	for (auto &table : tables) {
		if (XlsxLower(table.name) == wanted) {
			return &table;
		}
	}
	return nullptr;
}

const XlsxDefinedName *XlsxWorkbook::FindName(const string &name) const {
	auto wanted = XlsxLower(name);
	for (auto &def : names) {
		for (auto &key : def.keys) {
			if (key == wanted) {
				return &def;
			}
		}
	}
	return nullptr;
}

} // namespace duckdb
