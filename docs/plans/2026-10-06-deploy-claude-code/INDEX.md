# Deploy duckdb-skills to Claude Code — plan archive

Archived 2026-10-06, after the last task (item 4) shipped and Phil's install proof passed.

**The plan:**
- **One version:** `PLAN-5.md`, reviewed in `REVIEW-plan-5.md` (the first review plus a delta
  review). It was edited in place before its first task spawned.
- **Numbering:** it is numbered on from the local-SQL plan at Phil's request, but it is a new
  plan, not a fifth version of that one.

**Serves:** Phil can use the lakehouse, Snowflake-extract and query skills from any Claude Code
session in any project, not only from inside this repo. Development of the plugin moves from
Cortex Code to Claude Code, and the fork becomes Claude-Code-first (Phil, 2026-10-06).

## Tasks this plan produced

Each folder holds its spec, review, result, verdict and `SHIPPED.md`.

| item | what it delivered | folder (`docs\tasks\`) | rounds |
|---|---|---|---|
| 1 | One project, chosen deliberately: git root or refuse; read-only tools never create folders | `2026-10-06-item1-project-resolution` | 1 |
| 2 | Skills find scripts via `${CLAUDE_PLUGIN_ROOT}`; one quoted compat `.read` line; `.duckdb-skills/` gitignored | `2026-10-06-item2-plugin-root` | 1 |
| 3a | Cortex Code adaptations undone: Snowflake macros and polyglot gone (`xl_date()` kept), upstream `read-memories` restored with Windows fixes | `2026-10-06-item3a-undo-cortex` | 1 |
| 3b | `tools\sf.py`: Snowflake through the Python connector, `COPY INTO`/`GET` in one session | `2026-10-06-item3b-python-connector` | 1 |
| 4 | README and marketplace for the fork; Phil installed `duckdb-skills@woodsonp-duckdb-skills` | `2026-10-06-item4-install` | 1 |

## Fixes made directly, outside the task loop

Phil asked for each of these to be done without a spec. Each is a single commit on `main`.

- **`25f42ad`:** `run-assertions` reads its truncation probe as text. It had failed on GL cell
  I3, `City of DeKalb`.
- **`8a2f3d9`:** made in Phil's forked analysis session, not this one. It replaced two calendar-
  or mix-dependent contract checks with business rules, and re-pinned the snapshots.
- **`c2703b7`:** a "not inside a git repository" refusal is now final.
  - **What happened:** in Phil's post-install test from a non-repo folder, the session found
    this repo's lake and read it with `-LakeRoot`.
  - **The fix:** the skill text and the refusal message now tell the model to stop and ask.
  - **Evidence:** a headless re-run stopped and asked.

## Proof that it shipped

Phil ran this on 2026-10-06, and the session logs confirm it.
- **The install:** `claude plugin marketplace add woodsonpatclayco/duckdb-skills`, then
  `plugin install duckdb-skills@woodsonp-duckdb-skills`.
- **In this repo:** a fresh session ran
  `C:/Users/woodsonp/.claude/plugins/cache/woodsonp-duckdb-skills/duckdb-skills/0.2.4/tools/lake-status.ps1`.
  It named the project and listed both contracts.
- **In a non-repo folder:** the tool refused.

## Known and left alone

- **`checks\gl-facts.sql`** fails on today's workbook. It is old dev scaffolding with a
  deliberately type-inferred oracle read.
- **`publish-extract.ps1`** does not check the element types inside sidecar arrays.
- **The Cortex Code install** at `~\.snowflake\cortex\plugins\duckdb-skills` is still upstream's
  2026-09-21 clone. It is not a target of this fork.
- **The stray `_verify-2a`/`-2b`/`-2b-r2` folders** under `~\.duckdb-skills\` predate item 1.
