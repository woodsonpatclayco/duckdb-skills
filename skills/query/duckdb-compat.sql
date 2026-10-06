-- Excel serial-date helper for DuckDB. The contracts call xl_date() to decode
-- Excel serial numbers into DATE. Load it with tools/ensure-duckdb-compat.ps1.
-- See skills/query/duckdb-compat.md.

-- Excel serial -> DATE. Named once here instead of retyped per column.
-- The trailing ::DATE cast is load-bearing: without it, "+ to_days(...)"
-- yields TIMESTAMP, not DATE. Verified: xl_date(46204) = 2026-07-01, DATE.
CREATE OR REPLACE MACRO xl_date(serial) AS (DATE '1899-12-30' + to_days(serial::BIGINT))::DATE;
