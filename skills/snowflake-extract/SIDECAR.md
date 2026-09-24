# The extract sidecar — `<extract dir>\_extract.json`

Frozen by item 2a and built on by item 2b, item 6, and item 8. UTF-8, no BOM. All fields are
required unless marked optional. This file is the schema contract: `registry.sql` reads exactly
these fields with exactly these pinned types, and AC12 in `../../TASK.md` asserts the two never
drift apart.

| field | type | notes |
|---|---|---|
| `sidecar_version` | integer | value **`1`**. Without it a later schema change is undetectable and old sidecars are indistinguishable from new ones. |
| `name` | string | the identity, and **must equal the containing directory's name** — a mismatch is a malformed sidecar. Not the query text: whitespace or a changed `LIMIT` makes an identical result set look like a different query. |
| `query` | string | verbatim SQL. **Not the identity key** — that is `name`. But it **is** the input 2b re-executes on refresh, so it must round-trip byte-exact; do not normalise whitespace. |
| `source_objects` | array of string | fully-qualified |
| `materialized_at` | string | UTC, ISO 8601 with `Z`. **The extract's version token** — item 6's manifest records it beside the contract hash, closing the named risk that a lakehouse table has no tie to which extract version it used. |
| `window_minutes` | integer | writer's window, **provenance only** |
| `expires_at` | string | UTC, **provenance only** |
| `row_count` | integer | rows in the extract |
| `output_bytes` | integer | from `COPY INTO`'s result — the extract's own size |
| `connection`, `role`, `database`, `warehouse` | string | the same query under a different role returns different rows |
| `source_rows` | array of integer, **elements nullable** | `SHOW TABLES` rows per source object at materialize time — 2b's stage-1 baseline. A `null` element means no metadata row count was available (e.g. the object is a view); stage 1 cannot decide for it and 2b falls through to stage 2. **`null` is never `0`** — `0` reads as "the table emptied". A null element does not violate the parallel-array rule; a *missing* element does. |
| `source_bytes` | array of integer | **provenance only, never compared** — bytes move on refresh with unchanged content |
| `source_last_altered` | array of string | UTC ISO 8601 per source object — 2b's stage-2 baseline, compared against the *current* `LAST_ALTERED` and **never against `materialized_at`**, which on a dynamic table would make "unchanged" unreachable |
| `runtime_seconds` | number, **optional** | omitted rather than wrong. A negative value means `EXECUTION_STATUS = 'SUCCESS'` was not filtered and an in-flight query's elapsed time was recorded. |

The three `source_*` arrays are **parallel to `source_objects`**; a length mismatch is malformed.

## The pinned type and the age formula are a matched pair

For one sidecar stamped 90 minutes ago:

| `columns = {...}` pin | age expression | result |
|---|---|---|
| `materialized_at: 'TIMESTAMP'` | `date_diff('minute', materialized_at, timezone('UTC', now()))` | **90** correct |
| `materialized_at: 'TIMESTAMPTZ'` | *same expression* | **390** wrong |
| `materialized_at: 'VARCHAR'` | `date_diff('minute', materialized_at::TIMESTAMPTZ, now())` | **90** correct |
| `materialized_at: 'TIMESTAMP'` | `date_diff('minute', materialized_at::TIMESTAMP, now()::TIMESTAMP)` | **-297** wrong |

**`read_json` infers a naive `TIMESTAMP` and discards the `Z`.** Pin `materialized_at: 'TIMESTAMP'`
and use `timezone('UTC', now())`. Do not mix the pairs — see `registry.sql` for the exact
`columns = {...}` map this schema requires.

## The freshness rule

```
age_minutes   = date_diff('minute', materialized_at, timezone('UTC', now()))   -- materialized_at pinned TIMESTAMP
stale         = coalesce(age_minutes > effective_window, true)                  -- window from the READER
past_ceiling  = coalesce(age_minutes > DSK_MAX_AGE_MINUTES, true)
```

- **`window_minutes` and `expires_at` are provenance and never inputs to a decision.** The reader's
  window governs.
- **No sidecar, malformed sidecar, or NULL age = `UNKNOWN`, never `FRESH`.**
- **A negative age means clock skew** — report `UNKNOWN (clock skew)`, never `FRESH`.
- **Age is never mtime.** Every `GET` rewrites the Parquet, so mtime always advances and would
  report fresh for exactly the data most likely to be stale. File timestamps are read for **size
  only**.

## Malformed-sidecar reasons

A per-extract read that raises a non-zero exit (invalid JSON, or `materialized_at` unparseable
against a pinned `TIMESTAMP`) is reported `UNKNOWN (unreadable sidecar)`. A directory with no
`_extract.json` is `UNKNOWN (no sidecar)`. A `name` that does not match its directory is
`UNKNOWN (name mismatch)`. A `source_rows`/`source_bytes`/`source_last_altered` array shorter than
`source_objects` is `UNKNOWN (parallel array mismatch)`.
