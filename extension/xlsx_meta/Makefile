PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=xlsx_meta
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# extension_config.cmake builds the excel extension for the tests, and it needs vcpkg packages
# (expat, zlib, minizip-ng). Merge every extension's vcpkg.json instead of copying excel's here.
# Locally also set VCPKG_TOOLCHAIN_PATH (see README).
USE_MERGED_VCPKG_MANIFEST ?= 1

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile