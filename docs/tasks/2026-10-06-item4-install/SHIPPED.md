# SHIPPED — item 4 of PLAN-5: installed in Claude Code (repo side)

**What shipped:**
- **The README** now describes a Claude-Code-first fork. Install, update and local development
  point at `woodsonpatclayco/duckdb-skills` and the `woodsonp-duckdb-skills` marketplace, with
  both `/plugin` and `claude plugin …` CLI forms.
- **The Skills list** gains `lakehouse` and `snowflake-extract`.
- **The marketplace file** has a description, so `claude plugin validate --strict` passes.

## Before and after you can observe

- **The install instructions, before:** the README told you to install
  `duckdb-skills@duckdb-skills` from `duckdb/duckdb-skills`. That is upstream's plugin, without
  the lakehouse, the extracts or any of PLAN-5's work. The note said the fork was for Cortex
  Code.
- **The install instructions, after:** the README installs `duckdb-skills@woodsonp-duckdb-skills`
  from the fork, and says an installed copy only updates when `version` is bumped.
- **The validator:**
  - **Before:** `claude.exe plugin validate --strict .` exits 1.
  - **After:** `✔ Validation passed`.

## Deliberately did not change

- **`version` stays `0.2.4`** until PLAN-5 archives, after Phil's install proof.
- **Issues:** the fork has GitHub Issues disabled. The README sends upstream bugs to
  upstream's tracker rather than linking a dead page.
- **Upstream text left as is:**
  - Platform support (upstream's "Windows not fully supported");
  - the line 3 intro;
  - Session state.
- **README entries for `convert-file`, `s3-explore` and `spatial`** stay missing, as in
  upstream.
- **`.cortex-plugin\`** is untouched and unused by Claude Code.
- **The install itself** was not run by any agent. Phil runs it.
