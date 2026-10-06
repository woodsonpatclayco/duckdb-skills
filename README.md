# duckdb-skills

A [Claude Code](https://claude.ai/code) plugin that adds DuckDB-powered skills for data exploration and session memory.

> **A Claude-Code-first fork of [duckdb/duckdb-skills](https://github.com/duckdb/duckdb-skills), used on Windows.**
> It adds the `lakehouse` skill (contracts materialized into DuckLake) and the `snowflake-extract`
> skill (Snowflake extracts through the Python connector, `tools\sf.py`). It also adapts
> `read-memories` for Windows, keeps only `xl_date()` in the compat file, and resolves the project
> by git root (tools refuse outside a git repo). Cortex Code is not a target of this fork.

## Installation

### From GitHub

Add the fork as a plugin source and install:

```
/plugin marketplace add woodsonpatclayco/duckdb-skills
/plugin install duckdb-skills@woodsonp-duckdb-skills
```

The same from a shell:

```
claude plugin marketplace add woodsonpatclayco/duckdb-skills
claude plugin install duckdb-skills@woodsonp-duckdb-skills
```

This registers the GitHub repo as a marketplace and installs the plugin. Skills will be available as `/duckdb-skills:<skill-name>` in all future sessions.

### Updating

To pull the latest version, update the marketplace first and then the plugin:

```
/plugin marketplace update woodsonp-duckdb-skills
/plugin update duckdb-skills@woodsonp-duckdb-skills
```

The same from a shell:

```
claude plugin marketplace update woodsonp-duckdb-skills
claude plugin update duckdb-skills@woodsonp-duckdb-skills
```

A change reaches an installed copy only when `version` in `.claude-plugin\plugin.json` and `marketplace.json` is bumped.

## Skills

### `attach-db`
Attach a DuckDB database file for interactive querying. Explores the schema (tables, columns, row counts) and writes a SQL state file so all other skills can restore the session automatically. You can choose to store state in the project directory (`.duckdb-skills/state.sql`) or in your home directory (`~/.duckdb-skills/<project>/state.sql`).

```
/duckdb-skills:attach-db my_analytics.duckdb
```

Supports multiple databases — running `attach-db` again can append to the existing state file.

### `query`
Run SQL queries against attached databases or ad-hoc against files. Accepts raw SQL or natural language questions. Uses DuckDB's Friendly SQL dialect. Automatically picks up session state from `attach-db`.

```
/duckdb-skills:query FROM sales LIMIT 10
/duckdb-skills:query "what are the top 5 customers by revenue?"
/duckdb-skills:query FROM 'exports.csv' WHERE amount > 100
```

### `read-file`
Read and explore any data file — CSV, JSON, Parquet, Avro, Excel, spatial, SQLite, Jupyter notebooks, and more — locally or from remote storage (S3, GCS, Azure, HTTPS). Auto-detects the format by file extension using a built-in `read_any` table macro. Suggests `query` for further exploration.

```
/duckdb-skills:read-file variants.parquet what columns does it have?
/duckdb-skills:read-file s3://my-bucket/data.parquet describe the schema
/duckdb-skills:read-file https://example.com/data.csv how many rows?
```

### `duckdb-docs`
Search DuckDB and DuckLake documentation and blog posts using full-text search against the hosted search indexes. No local setup required — queries run over HTTPS by default, with an option to cache the index locally for faster offline searches.

```
/duckdb-skills:duckdb-docs window functions
/duckdb-skills:duckdb-docs "how do I read a CSV with custom delimiters?"
```

### `read-memories`
Search the raw transcripts of past **Claude Code** sessions (`~/.claude/projects/`) to recover the exact wording of earlier conversations. For decisions and conventions, check shared memory first (the `memory_*` tools); use this skill for what shared memory does not hold. It cannot see Cortex Code sessions.

```
/duckdb-skills:read-memories <keyword> [--here]
/duckdb-skills:read-memories duckdb --here
```

`--here` scopes to sessions whose working directory matches the current one.

### `install-duckdb`
Install or update DuckDB extensions. Supports `name@repo` syntax for community extensions and a `--update` flag that also checks whether your DuckDB CLI is on the latest stable version.

```
/duckdb-skills:install-duckdb spatial httpfs
/duckdb-skills:install-duckdb gcs@community
/duckdb-skills:install-duckdb --update
```

### `lakehouse`
Materialize Excel contracts into a DuckLake lake, then check its status and check history. Freshness is reported per table; nothing is refreshed on your behalf.

```
/duckdb-skills:lakehouse what's the lake status?
```

### `snowflake-extract`
Pull a named Snowflake query to local Parquet through the Python connector. A freshness registry records baselines, so reads re-pull only when the source has changed.

```
/duckdb-skills:snowflake-extract is the dt_projects extract fresh?
```

## Session state

All skills except `read-memories` share a single `state.sql` file per project — a plain SQL file containing ATTACH/USE/LOAD statements, secrets, and macros. When state is first needed, you'll be asked where to store it:

1. **In the project directory** (`.duckdb-skills/state.sql`) — colocated with the project, optionally gitignored
2. **In your home directory** (`~/.duckdb-skills/<project>/state.sql`) — keeps the repo clean

The file is append-only and idempotent. Any skill restores the session via `duckdb -init state.sql`.

`read-memories` stays outside this convention deliberately: it reads a fixed absolute log path and needs no attached database, so it neither creates nor reads `state.sql`.

**Precedence when both exist:** the project-local file wins. If `.duckdb-skills/state.sql` is
present, it is used even when a home-side `~/.duckdb-skills/<project>/state.sql` also exists. This
was decided, not derived from existing code: the project-local file is more discoverable, and
`tools\ensure-duckdb-compat.ps1` already behaves this way. It deliberately **contradicts**
`skills/query/SKILL.md:22-25`, which prefers the home-side file first — that skill's resolution is
POSIX bash and does not run on Windows, so the contradiction is left standing rather than
"reconciled," to avoid silently changing where a Windows session's macros land. No resolution code
changes as a result of this note; it records the decision for whichever skill implements Windows
state-file lookup next.

## Joining a Snowflake extract to a workbook sheet

`tools\cross-query.ps1` answers one question across a Snowflake extract (`tools\snowflake-extract`)
and a workbook sheet materialized into the DuckLake lakehouse (`tools\materialize.ps1`) in a single
SQL statement, printing the age of every input beside the answer. Steps, from a clean shell in this
repo:

1. **`tools\materialize.ps1`** — bring the lake current. A stale lake table (its workbook has
   changed since the last materialize) is *reported*, never fixed automatically — this tool never
   refreshes anything on your behalf.
2. **`tools\list-extracts.ps1`** — see which Snowflake extracts exist and how old they are.
   Refreshing a stale extract is done through the `snowflake-extract` skill in an agent session, not
   by any script here — `cross-query.ps1` cannot call Snowflake itself.
3. **`tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql`** — read the `EXTRACT`,
   `LAKE` and `RESULT` lines it prints, in that order, before the answer's own CSV rows.
4. **`tools\cross-query.ps1 -Sql examples\job-costs-unmatched.sql`** — the same two inputs, but an
   anti-join: GL rows whose parent project is missing from the extract. This is the check a stale
   extract fails first — a project created in Snowflake after the extract was taken shows up here,
   even though the join in step 3 quietly drops it.
5. **`-Save <table>`** — save the joined result as a table in the lake
   (`tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql -Save gl_by_parent`), then
   re-query it with `cross-query.ps1 -Sql <a file selecting from lake.gl_by_parent>` so its `SAVED`
   provenance line prints instead of `LAKE`.

**The freshness rule.** Every input's age prints beside the answer, unconditionally. Nothing is ever
refused for being old — a stale extract or a lake table whose workbook has changed since it was
materialized is loud, recorded, and still answered. The reader's window (`DSK_WINDOW_MINUTES`,
60 minutes by default) decides whether an age counts as `stale`; it never decides whether the query
runs. A saved join keeps the data it was built from — it does not re-read either source — and every
time it is read back, it reports the age of its own **oldest** recorded input, not the age of the
save itself.

**The patterns.** A query given to `cross-query.ps1` may only read `extract_table('<name>')` for a
Snowflake extract (the name is resolved from the extract registry at run time — the query text never
contains a path) and `lake.<table>` for a workbook sheet materialized as a contract, or a previously
saved join. Nothing else is dateable, so nothing else is accepted: a raw `read_parquet`/`read_csv`/
`read_xlsx`/`read_json` call, a quoted file path, or any other table function is refused. A saved join
is stored as a real **table**, never a view — a view's `extract_table` macro does not survive into a
new process, so a saved join that referenced an extract would silently break the moment it was
re-queried.

## Local development

To test skills locally from a clone of this repo:

```bash
# 1. Clone the repo
git clone https://github.com/woodsonpatclayco/duckdb-skills.git
cd duckdb-skills

# 2. Launch Claude Code with the local plugin directory
claude --plugin-dir .
```

This loads the plugin from disk instead of the marketplace, so any edits to `skills/*/SKILL.md` take effect immediately — just start a new conversation (or re-run the slash command) to pick up changes.

You can test individual skills directly:

```
/duckdb-skills:read-file some_local_file.parquet
/duckdb-skills:duckdb-docs pivot unpivot
/duckdb-skills:query SELECT 42
```

**Prerequisites:** DuckDB CLI must be installed. If it isn't, the skills will offer to install it via `/duckdb-skills:install-duckdb`.

## How the skills work together

Skills reference each other where it makes sense:

- `read-file` suggests `query` for follow-up exploration and `attach-db` for persisting large files
- `query` and `read-file` use `duckdb-docs` to troubleshoot DuckDB errors automatically
- Those skills share the same `state.sql` — secrets and macros set up by `read-file` are reused by `query`, and databases attached by `attach-db` are available everywhere. `read-memories` is standalone and shares nothing.

## Platform support

These skills have been tested upstream on **macOS** and **Linux**. Windows is not fully supported by the upstream skills — some shell commands and path handling may not work as expected.

`read-memories` is adapted for Windows paths in this fork.

## Reporting issues & suggestions

The fork has GitHub Issues disabled. Report problems to the fork's owner; upstream DuckDB bugs go to https://github.com/duckdb/duckdb-skills/issues.

For DuckDB-specific bugs (extension loading, SQL errors), please include the DuckDB version (`duckdb --version`) and the full error message.
