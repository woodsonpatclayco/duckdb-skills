-- Snowflake dialect compatibility shim for DuckDB.
-- 17 macros. Value-correct where DuckDB has no equivalent syntax; does not
-- reach syntax (TOP n, MINUS, NUMBER(38,2), LISTAGG ... WITHIN GROUP) —
-- use polyglot_query for those. See skills/query/duckdb-compat.md.
--
-- DATEADD is deliberately absent: the natural macro body returns TIMESTAMP
-- where Snowflake returns DATE, a silent type drift. It stays out until
-- fixed and type-asserted (skills/query/duckdb-compat.md).
--
-- Round 2 (measured on CLAYCO-DATAHUB, see TASK.md C1/C6): TO_NUMBER and
-- TRY_TO_NUMBER default to scale 0, not 6 -- Snowflake rounds fractional
-- digits away. REGEXP_SUBSTR returns NULL, not '', on no match. UUID_STRING
-- returns VARCHAR, not UUID. DIV0/DIV0NULL are value-correct at scale 6; the
-- precision digit varies with input and is not reproducible (deviation, not
-- a fixed drift). TRY_TO_DATE is NOT fixed for all-digit strings -- Snowflake
-- reads them as an epoch offset (TRY_TO_DATE('46204') = 1970-01-01); use
-- xl_date() for Excel serials instead.
CREATE OR REPLACE MACRO IFF(c, t, f) AS CASE WHEN c THEN t ELSE f END;
CREATE OR REPLACE MACRO NVL(a, b) AS coalesce(a, b);
CREATE OR REPLACE MACRO NVL2(a, b, c) AS CASE WHEN a IS NOT NULL THEN b ELSE c END;
CREATE OR REPLACE MACRO ZEROIFNULL(a) AS coalesce(a, 0);
CREATE OR REPLACE MACRO NULLIFZERO(a) AS nullif(a, 0);
CREATE OR REPLACE MACRO DIV0(a, b) AS CAST(CASE WHEN b = 0 THEN 0 ELSE a / b END AS DECIMAL(38, 6));
CREATE OR REPLACE MACRO DIV0NULL(a, b) AS CAST(CASE WHEN b = 0 OR b IS NULL THEN 0 ELSE a / b END AS DECIMAL(38, 6));
CREATE OR REPLACE MACRO TO_VARCHAR(a) AS CAST(a AS VARCHAR);
CREATE OR REPLACE MACRO TO_NUMBER(a) AS CAST(a AS DECIMAL(38, 0));
CREATE OR REPLACE MACRO TRY_TO_NUMBER(a) AS TRY_CAST(a AS DECIMAL(38, 0));
CREATE OR REPLACE MACRO TRY_TO_DATE(a) AS TRY_CAST(a AS DATE);
CREATE OR REPLACE MACRO EQUAL_NULL(a, b) AS a IS NOT DISTINCT FROM b;
CREATE OR REPLACE MACRO REGEXP_SUBSTR(s, p) AS
  CASE WHEN regexp_matches(s, p) THEN regexp_extract(s, p) END;
CREATE OR REPLACE MACRO CHARINDEX(a, b) AS strpos(b, a);
CREATE OR REPLACE MACRO LEN(a) AS length(a);
CREATE OR REPLACE MACRO UUID_STRING() AS CAST(uuid() AS VARCHAR);

-- Excel serial -> DATE. Named once here instead of retyped per column.
-- The trailing ::DATE cast is load-bearing: without it, "+ to_days(...)"
-- yields TIMESTAMP, not DATE. Verified: xl_date(46204) = 2026-07-01, DATE.
CREATE OR REPLACE MACRO xl_date(serial) AS (DATE '1899-12-30' + to_days(serial::BIGINT))::DATE;
