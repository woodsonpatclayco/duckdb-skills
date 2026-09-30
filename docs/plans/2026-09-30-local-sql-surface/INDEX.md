# One local SQL surface over Snowflake extracts and Excel workbooks — plan archive

Archived 2026-09-30, when its last task (item 8) shipped. Four versions; each supersedes the one before
and is frozen. **`PLAN-4.md` is the one the final specs were written against.** Each later version opens
with its delta, so read the deltas rather than the whole of each file.

| version | why it was revised |
|---|---|
| `PLAN-1.md` | original |
| `PLAN-2.md` | `TRY_TO_NUMBER` table was wrong (Snowflake returns `NUMBER(38,0)`); a Windows `<project-id>` definition; expectations established against Snowflake, not DuckDB |
| `PLAN-3.md` | stage-1 invalidation compares row count only (bytes move on a dynamic-table refresh); refresh history not authorized; item 2 split into 2a/2b |
| `PLAN-4.md` | Parquet unload refuses `TIMESTAMP_TZ`/`LTZ`, so an extract query cannot be a blind `SELECT *` |

No `REVIEW-plan-*.md` exists for any version — none was committed at the time, so there is no plan-review
record to archive.

**Serves:** one SQL surface where a Snowflake extract and an Excel workbook sheet are both just tables, so
joining them is ordinary SQL — and the joined result is saved and re-queryable without re-reading either
source or re-running the query against Snowflake.

## Tasks this plan produced — each folder holds its spec, review, result, verdict and SHIPPED.md

| item | what it delivered | folder (`docs\tasks\`) | spec written against | rounds |
|---|---|---|---|---|
| 1 | Dialect layer: macro file, polyglot, routing rule, compat fixture | `2026-09-23-item1-dialect-layer` | PLAN-2 | 2 |
| 2a | Extract sidecar schema, registry, list/status tools | `2026-09-24-item2a-extract-registry` | PLAN-3 | 1 |
| 2b | `snowflake-extract` skill: materialize, refresh, two-stage invalidation | `2026-09-24-item2b-snowflake-extract` | PLAN-4 | 2 |
| 3 + 4 | Sheet discovery; first contract (`Clayco_Job_Costs_from_GL`) | `2026-09-24-items34-sheet-discovery-contract` | PLAN-4 | 1 |
| 5 | Assertion harness; invariant / floor / snapshot taxonomy | `2026-09-25-item5-assertion-harness` | PLAN-4 | 2 |
| 6 | Materialize into DuckLake with workbook freshness | `2026-09-25-item6-lakehouse-materialize` | PLAN-4 | 1 |
| 2c | Multi-object extract debt (reopened item 2) | `2026-09-29-item2c-multi-object-debt` | PLAN-4 | 1 |
| 5b | Quality definitions optional; unknown-directive guard | `2026-09-29-item5b-optional-quality` | PLAN-4 | 1 |
| 7 | Re-query without sources; `snowflake` extension never loads; `.xlsm` routing; missing-workbook fix | `2026-09-29-item7-workbook-proof` | PLAN-4 | 1 |
| 8 | The cross-source join, with every input's age beside the answer | `2026-09-30-item8-cross-source-join` | PLAN-4 | 1 |

Items 2c and 5b correspond to no step in the plan — both are corrections Phil asked for directly — but
both were written against PLAN-4 and belong to this body of work.

Not from this plan: the four `2026-09-22-*read-memories*` folders predate it.

## Facts in PLAN-4 that later measurement overturned

The plan is frozen and was not edited; these are recorded in the `SHIPPED.md` of the item that found them.

- **GL row count.** PLAN-4 pinned 61,741. The workbook moves with SharePoint syncs — 62,230 (item 6),
  62,377 then 62,603 (items 7–8). No check after item 7 pins a count.
- **`VENDOR_NAME` inference.** PLAN-4 measured it inferring DOUBLE and silently nulling to 0. By item 7 it
  inferred correctly; money still sums as DOUBLE. Inference depends on whatever rows sit at the top of the
  sheet (item 7).
- **"`duckdb_extensions()` shows no loaded `snowflake`"** proves nothing when run in a fresh process;
  item 7 replaced it with an in-process probe on every call.
- **"Item 6's manifest records the extract's `materialized_at`"** (PLAN-4:674-675) was never true; item 8
  records input versions in `lake.join_manifest` instead.
