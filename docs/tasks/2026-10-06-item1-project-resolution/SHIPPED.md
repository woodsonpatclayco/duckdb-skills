# SHIPPED — item 1 of PLAN-5: one project, chosen deliberately

**What shipped:** every lake and extract tool now decides "which project" in one way: the git
root of the folder it runs from. Outside a git repo, a tool stops instead of guessing.

## Before and after you can observe

- **Before:** `tools\lake-status.ps1` run from a non-repo folder quietly created
  `~\.duckdb-skills\<that folder>\lake\` and answered `no lake`. That is how the three
  `_verify-*` folders appeared.
- **After:** the same command prints
  `ERROR: not inside a git repository: <folder>. Run from your project folder, or pass -LakeRoot.`
  It exits 2 and creates nothing.
- **Every tool now names its project on stderr:**
  `project: c-users-woodsonp-claude-dev-duckdb-skills (C:\Users\woodsonp\Claude\Dev\duckdb-skills)`.

## Also changed

- **Contracts:** they are read from `<project root>\contracts`, no longer from beside the
  scripts. That is what lets an installed plugin read your project's contracts (item 2).
- **Read-only tools never create folders,** including folders named with explicit
  `-LakeRoot` / `-ExtractRoot`. These tools are `lake-status`, `list-extracts`,
  `extract-status`, `extract-decide` and `cross-query`. Only `materialize` and
  `publish-extract` create folders.
- **`cross-query -Save` with no lake** now refuses, where before it created a lake.
- **`publish-extract -ExtractRoot <missing>`** now creates the folder, where before it failed.
- **`prove-no-snowflake.ps1`:** its materialize call tolerates the new stderr line.

## Deliberately did not change

- **No stdout line in any tool moved.** All project reporting is on stderr, which departs from
  PLAN-5's wording on purpose. AC5 shows stdout byte-identical to before.
- **The `query` and `attach-db` skills** still fall back to the current folder outside a git
  repo, so ad-hoc DuckDB use needs no repo.
- **The old `_verify-*` folders** under `~\.duckdb-skills\` are still there. Item 1 only stops
  new ones.
- **Skills still call scripts as `tools\…` relative to the repo.** That is item 2.
- **Development scaffolding** (`prove-*`, `make-*`, `run-compat-tests`) keeps its own path
  logic, apart from the one stderr tolerance fix.
- **Known leftovers, harmless and left alone:**
  - `cross-query.ps1:689` has a redundant resolver call.
  - `publish-extract` with a missing `-StagingDir` leaves an empty extract root.
