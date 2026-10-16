# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(xlsx_meta
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
)

# Any extra extensions that should be built
# excel provides read_xlsx, so the tests can read a table end to end through read_xlsx_table.
# Pinned to the commit DuckDB v1.5.5 itself ships (duckdb/.github/config/extensions/excel.cmake).
duckdb_extension_load(excel
    GIT_URL https://github.com/duckdb/duckdb-excel
    GIT_TAG f4c72b5ef04a03b3a78a95b5a2ee94ba93e3178d
    INCLUDE_DIR src/excel/include
)