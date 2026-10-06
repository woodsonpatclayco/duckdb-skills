# SHIPPED — item 2 of PLAN-5: the plugin runs from wherever it is installed

**What shipped:**
- **Script paths:** the four skills that run scripts (`lakehouse`, `snowflake-extract`,
  `read-file`, `query`) now name them through `${CLAUDE_PLUGIN_ROOT}`, the plugin's install
  folder. They no longer use a path relative to this repo.
- **One stated form:** each skill now states one way to run a script.
- **`ensure-duckdb-compat`:** it now keeps exactly one quoted compat line in `state.sql` and
  gitignores `.duckdb-skills/` in the project.
- **Plugin files:** both now name the fork.

## Before and after you can observe

- **The compat line, before:** `ensure-duckdb-compat` wrote `.read C:/…/duckdb-compat.sql`
  unquoted, and only ever added lines. A plugin path with a space made DuckDB fail
  (`Usage: '.read FILE'`, exit 1). Every plugin update would also have left a dead line behind.
- **The compat line, after:** `state.sql` holds exactly one
  `.read '<plugin folder>/skills/query/duckdb-compat.sql'`, replaced on each run.
  `duckdb -init state.sql -c "SELECT xl_date(46204)"` returns `2026-07-01` from a spaced path.
- **Git, before:** a project using the skills got an untracked `.duckdb-skills\` folder in
  `git status`.
- **Git, after:** the first run adds `.duckdb-skills/` to that project's `.gitignore`, once.

## Deliberately did not change

- **`version` stays `0.2.4`.** It is bumped after PLAN-5 archives.
- **Marketplace name.** It is now `woodsonp-duckdb-skills`, so item 4 installs
  `duckdb-skills@woodsonp-duckdb-skills`. The plugin name is still `duckdb-skills`, so skill
  names are unchanged. Installing upstream's plugin as well would still collide on those
  names.
- **Out of scope, left for item 3a:**
  - `read-memories`;
  - the polyglot and Snowflake-macro text in `query`, apart from two path-only rewrites;
  - the README.
- **Out of scope, left for item 3b:** the `snowflake_sql_execute` steps and `allowed-tools`.
- **The `PROJECT_ROOT … || echo "$PWD"` state lookups** in `query` and `attach-db`.
- **No script under `tools\` changed** except `ensure-duckdb-compat.ps1`.
- **Real `${CLAUDE_PLUGIN_ROOT}` substitution is still unobserved.** It cannot be seen until
  item 4 installs the plugin. Item 4's proof must use the substituted command line as its
  evidence, because no tool prints its own folder.
