# REVIEW ? TASK.md item 2, and the PLAN-2 to PLAN-3 delta

Two review passes happened for item 2, both before any implementation.

## Pass 1 ? the combined item-2 spec (superseded)

Verdict **NOT READY**, nine blocking issues. Three mattered beyond wording:

| # | Issue |
|---|---|
| A1 | **`Move-Item` onto an existing directory does not fail \u2014 it nests the source inside it.** Reviewer reproduced: the stale Parquet stays put and the fresh Parquet lands one level down, so `<dir>\*.parquet` reads the OLD data, exit 0, silently. `[IO.Directory]::Move` fails outright instead. Every refresh check in the draft asserted reported text only, so this would have passed the whole acceptance list while serving stale data \u2014 item 1's failure class in a new costume. |
| A2 | Stage 2 had no stored `last_altered` baseline, making AC7 and AC10 demand different output for the same state. |
| A3 | **No check anywhere exercised \"source changed \u2192 refresh\"**, so an invalidation engine hardcoded to SKIP would have passed. |

Plus: `read_json` over an empty glob exits 1; script interfaces undefined; `expires_at` vs reader
window indistinguishable; pinned row counts are live dynamic-table state; `BYTES` stability never
measured; the ambiguous-SKIP failure mode unbounded.

**It also set me two measurements, and both changed the plan.** `BYTES` is **not** stable
(`DT_PROJECTS` held 42,161 rows while bytes moved 7,463,424 \u2192 7,430,144), and
`DYNAMIC_TABLE_REFRESH_HISTORY` is **not authorized** for this role \u2014 so the cheaper signal that
would have removed the ambiguity does not exist. Both are in the PLAN-3 delta.

**Response: took the reviewer's scope split.** Item 2 became two specs, plan count seven \u2192 eight. The
write-half findings (A1, A2, A3, the age ceiling) move to 2b; this spec's job became handing 2b the
schema to get them right.

## Pass 2 ? the 2a spec (current)

Verdict **NOT READY**, ten blocking issues. All applied. The reviewer confirmed the split genuinely
removed the Snowflake dependency rather than relocating it \u2014 it ran the DuckDB substrate of nine of
twelve checks with no credentials.

| # | Issue | Fix applied |
|---|---|---|
| A1 | **Fixtures were gitignored, partly uncommittable, and time-decaying.** `.duckdb-skills/` is in `.gitignore`, git cannot commit an empty directory, and a 90-minute fixture measured **93** minutes later in the same session \u2014 outside the stated band. Implementer and verifier would grade different artifacts. | `tools\make-extract-fixtures.ps1` added as a committed deliverable; every check now regenerates first. |
| A2 | AC3's band too narrow, **and a local-stamped fixture would let the broken naive-local implementation pass**. | Stamps from `[DateTime]::UtcNow` mandated; bands widened to 0\u20132 / 89\u201393 / 1499\u20131503; literal `materialized_at` printed beside local time. |
| A3 | **One malformed sidecar exits 1 for the whole query, and `ignore_errors=true` is refused** for non-newline-delimited JSON. `glob('*')` also returns 0 \u2014 it matches files, not directories \u2014 so a sidecar-less extract dir is invisible. The natural glob-based registry cannot meet the spec. | Architectural: enumerate with `Get-ChildItem -Directory`, read each sidecar in a **separate `duckdb -f`**. Fifth and sixth damaged cases added. |
| A4 | AC3 never passed `-Name`, so \"first output line\" had no subject. | Three invocations with `-Name`; first-line rule scoped to single-extract mode. |
| A5 | **The mandated age formula is correct for only one pinned column type.** `TIMESTAMPTZ` + the spec's formula returns **390** for a 90-minute extract. | Pinned type and formula stated as a matched pair, with the wrong-value table. |
| A6 | Verdict vocabulary and exit codes unpinned while four checks asserted on them. | `FRESH` / `EXPIRED` / `UNKNOWN (<reason>)` / `PAST-CEILING` pinned; exit 0 for any report, 2 for usage error. |
| A7 | **Three schema defects.** `query` labelled \"provenance only\" \u2014 but 2b re-executes it on refresh, so it had no defined input. `source_rows` needed nullable elements (`SHOW TABLES` gives no count for a view, and the rows-only delta removed the fallback). `path` left to the implementer although item 8 consumes it. | All three fixed; `sidecar_version` added so a later schema change is detectable. |
| A8 | AC9 named no script and its `output_bytes` assertion could not fail. | Assigned to `list-extracts.ps1`; one fixture engineered to AGREE, one to DISAGREE. |
| A9 | AC12 was \"assert\", not a command. | Symmetric difference of `SIDECAR.md` field names against `DESCRIBE` output, expected empty. |
| A10 | AC2's absent-root case self-invalidated once the tool created the root. | An explicitly passed `-ExtractRoot` is never created; the generator deletes the absent path. |

Non-blocking applied: state-file decision moved from `SIDECAR.md` to `README.md`'s Session state
section; NULL-age `coalesce` guard specified (`NULL > 60` is NULL, not true \u2014 a naive filter reports
a damaged sidecar as not-stale); clock-skew case added; `-ExtractRoot` resolved to absolute;
`name`-vs-directory mismatch added as a damaged case; AC11's unfalsifiable read-back half dropped with
the reason (a BOM'd sidecar reads fine).

## PLAN-3 delta

Three changed instructions, all measurement-forced: stage 1 compares **rows only**; refresh history is
unauthorized so the ambiguous-SKIP trade-off is forced and bounded by `DSK_MAX_AGE_MINUTES`; item 2
ships as two specs. Plus `output_bytes` added, which PLAN-2 asked for as a fallback without naming a
field to hold it.

The reviewer found **one contradiction with unchanged PLAN-2 text** that a delta review is exactly
prone to missing: line 481 still read \"compares `SHOW TABLES` rows/bytes through a no-warehouse
connection\". Corrected in place \u2014 the instruction had already changed elsewhere in the same file, so
this alters nothing. Two stale PLAN-2-era framings of 2a/2b as halves of one spec were also corrected,
and the item-2 acceptance paragraph now says which spec owns which check.

## What both passes said to keep

The 2a/2b labelling was verified accurate in pass 1 \u2014 no mislabelled check. **AC6 is the strongest
check in the spec**: two fixtures, both aged 90, catch three wrong implementations (comparing against
`expires_at`, using the sidecar's own window, or ignoring the reader's). AC1's handling of the
`<project-id>` trap \u2014 gating on properties, quoting the literal as a snapshot, and saying outright
that asserting a recomputation of the tool against the tool proves nothing. AC8's delete-and-re-run as
proof the registry is derived not stored. The measured-facts sections, four of five claims re-run and
held exactly.
