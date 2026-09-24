# REVIEW — TASK.md item 2b round-2 corrections, and the PLAN-3 to PLAN-4 delta

Reviewer: `task-reviewer`. Verdict **NOT READY**, nine blocking issues, all applied. Seven were
replacement wording; two were ordering and labelling. Nothing suggested the plan was wrong — a
correctly-aimed round whose new checks were not yet decisive.

## Blocking (all fixed)

| # | Issue | Fix applied |
|---|---|---|
| B1 | **AC18 compared `f(x)` against `f(x)`.** The extract query applies `CONVERT_TIMEZONE('UTC', col)::TIMESTAMP_NTZ` and the reference applied the *identical* expression — so a wrong form (e.g. the three-argument `CONVERT_TIMEZONE` which double-shifts an LTZ input) shifts both sides equally and the check passes on a value six hours out. Also no join key, and **nothing asserted all 113 columns survived** — a projection emitting 111 passes every other check, since row counts still agree three ways. | Reference changed to `DATE_PART(EPOCH_SECOND, …)` versus DuckDB `epoch()` on three named keys — an independent path. Reviewer verified a 6-hour shift shows as exactly `21600`. Added `ncols` versus the `INFORMATION_SCHEMA.COLUMNS` count. |
| B2 | **AC19's "byte-identical to the SQL that was executed" had no reference but the sidecar itself**, so it could not fail. Plus a CRLF hazard: a PowerShell-built query carries `\r\n`, the round-trip may not. | Compare against `QUERY_TEXT` from `QUERY_HISTORY_BY_SESSION` for the `QUERY_ID` AC14 already quotes, line endings normalised; generated SQL must use `\n`. |
| B3 | **AC20 already passed before round 2 began — the reviewer ran it.** The round-1 sidecar on disk satisfies the literal string check exactly (`matches expected exactly: True`, `contains CONVERT_TIMEZONE: False`), so as written it proves nothing about the new rule. | Tied to a fresh materialize: assert `materialized_at` is later than the pre-round value, and quote the `INFORMATION_SCHEMA.COLUMNS` evidence (0 TZ columns vs 2) so the rule is distinguishable from special-casing two table names. |
| B4 | **No identifier-quoting rule.** `COLUMN_NAME` comes back unquoted, so a bare projection breaks on any quoted identifier or reserved word — and **`START` is reserved in Snowflake**, on a table that already has `START_DATE`. The reviewer had no Snowflake tool and could not rule it out across 113 columns. | Every column name emitted double-quoted, in both the cast and the plain projections; embedded `"` doubled. AC19's asserted literal updated to match. |
| B5 | **Undefined whether refresh re-derives the projection or replays the stored one.** `SIDECAR.md:12` says `query` *is* the refresh input, so replaying a frozen column list would silently drop any column added upstream — including a new TZ column, defeating the fail-loud rule. | Re-derived on every materialize, stated explicitly, with the reason. |
| B6 | **AC15-R2 said "delete one" without saying which**, and deleting `dt_projects` — the natural reading — destroys the Parquet AC18 reads and the sidecar AC19 reads. The task breaking its own check. | Delete `parent_projects` specifically; `dt_projects` must survive the round intact and stay re-runnable. |
| B7 | **The frozen body still instructs the verifier to reach Snowflake, which is false**, and AC19/AC20 were labelled `[command]` while depending on a materialize — so they would come back NOT RUN for exactly the reason round 1 already paid for. Also: **no `VERIFY-1.md` existed for round 1.** | Verifier scope restated and superseded, with the main tree's extract root named for the read-only halves; AC19/AC20 relabelled `[skill]`; `VERIFY-1.md` written. |
| B8 | **The projection rule was undefined for anything but a single-object `SELECT *`** — but `source_objects` is an array and the plan's point is named extracts over arbitrary queries. | Scope stated: whole-object single-source queries only; for hand-written or multi-object queries the author owns the projection, with the same fail-loud rule. |
| B9 | **Nothing verified the round's only deliverable — the `SKILL.md` text.** All three new checks observe one execution by an implementer who already knows the rule. The failure mode is a passing round whose prose the next session cannot follow. | `RESULT-2.md` must quote the new section verbatim, show the diff touched nothing else, and the text must state the rule **by column type, not by table name** — naming no special cases. |

## Non-blocking applied

`INFORMATION_SCHEMA` must be database-qualified (bare fails `invalid identifier` on this connection — the
same trap the body already documents for `QUERY_HISTORY_BY_SESSION`); `ORDINAL_POSITION` rationale stated
so it is not "improved" away; the `42,162` snapshot refreshed to `42,167`; the volatile "7 files" pin
relaxed to "more than one" (8, then 6, then 7 observed); round 1's three accepted deviations made contract
so they are not re-adjudicated; the `RESULT-1.md` transcription that abbreviated the qualified table name
flagged; re-run reporting detail specified; the LTZ-versus-TZ evidence limit and the
nanosecond-to-microsecond truncation stated; nested TZ types acknowledged as undetectable but covered by
the fail-loud rule; and the **multi-object gap recorded rather than silently assumed** — every
`extract-decide.ps1` fixture is single-object, so the multi-object stage-1/stage-2 rule and round 1's
`ConvertFrom-Json` nesting fix have no passing evidence.

## Drift from the plan

**Omission: none.** Every PLAN-4 delta instruction has a corresponding spec instruction.

**One contradiction with unchanged PLAN-3 text**, and it is the source of B5: item 2's untouched bullet
calls `query` *"provenance"* while `SIDECAR.md:12` calls it *"the input 2b re-executes on refresh"*. Not
wrong, but silent where the projection rule makes the difference observable. Settled in the spec.

**Verified safe:** the new `INFORMATION_SCHEMA.COLUMNS` query needs a warehouse, but it sits in the
materialize flow which already starts one for `COPY INTO` — so **AC10's zero-warehouse-cost proof for the
freshness check is unaffected**. Easy to have got wrong; now stated explicitly.

**Record integrity confirmed:** `PLAN-3.md` was superseded, not edited. Moving the spec's `Plan:` header
to `PLAN-4.md` while leaving the frozen body untouched, with the reason in a banner, is the correct
handling.

## What the reviewer said to keep

C1's workaround measured end to end with the error text verbatim and the blast radius counted rather than
asserted. **C2's fail-loud rule** — *"if `COPY INTO` still fails after projection, stop and report the
column and its type; do not widen the cast"* — called the best thing in the correction set, because it
converts the nested-type case the detection misses from a silent-wrong into a loud-stop. Keeping `SELECT *`
for the 98%. The naive-`TIMESTAMP`-holds-UTC statement tying the new column type to the discipline
`SIDECAR.md` already established. **C3's approval-recording rule** — the distinction between a recorded
approval and an unfalsifiable one. And the explicit negative scope naming the five round-1 scripts that
must not change, which is what keeps this round small.

## Scope

One round is right. The real work is a paragraph in `SKILL.md`, one generated query, two materializes and
three checks. B9 and the multi-object note add *reporting* requirements, not work — deliberately. If the
round runs long, the AC1–AC5 re-run is the safe trim, since a prose edit cannot reach
`publish-extract.ps1` or `extract-decide.ps1`.
