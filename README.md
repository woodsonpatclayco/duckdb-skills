# duckdb-skills

A [Claude Code](https://claude.ai/code) plugin that adds DuckDB-powered skills for data exploration and session memory.

> **This is a fork adapted for [Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code).**
> Upstream is [duckdb/duckdb-skills](https://github.com/duckdb/duckdb-skills). Only `read-memories`
> differs: it searches Cortex Code session logs instead of Claude Code ones, and is written for
> Windows / PowerShell. The other eight skills are unmodified from upstream and the sections below
> describe them as upstream does — including the Claude Code install and local-development steps,
> which do not apply to a Cortex Code install (plugins live in `~/.snowflake/cortex/plugins/`).

## Installation

### From the Discover tab (coming soon)

We are working on submitting this plugin to the official Anthropic marketplace. Once listed, it will appear in the **Discover** tab when you run `/plugin` inside Claude Code.

### From GitHub (available now)

Add the repository as a plugin source and install:

```
/plugin marketplace add duckdb/duckdb-skills
```
```
/plugin install duckdb-skills@duckdb-skills
```

This registers the GitHub repo as a marketplace and installs the plugin. Skills will be available as `/duckdb-skills:<skill-name>` in all future sessions.

### Updating

To pull the latest version, update the marketplace first and then the plugin:

```
/plugin marketplace update duckdb-skills
/plugin update duckdb-skills@duckdb-skills
```

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
Search past **Cortex Code** session logs (`~/.snowflake/cortex/conversations/`) to recover context from previous conversations — decisions made, patterns established, open TODOs. Skips injected `<system-reminder>` context and internal `thinking` blocks so hits are real conversation. A separate mode recovers the result sets of SQL queries run in past sessions.

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

## Local development

To test skills locally from a clone of this repo:

```bash
# 1. Clone the repo
git clone https://github.com/duckdb/duckdb-skills.git
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

In this fork, `read-memories` **is** written for and verified on **Windows / PowerShell 5.1**: its SQL ships in a `.sql` file invoked with `duckdb -f` (PowerShell expands `$` inside double-quoted `-c` strings, silently breaking inline JSON paths), and its path handling accepts both `/` and `\` separators.

## Reporting issues & suggestions

Found a bug or have an idea for improvement? Open an issue at:

**https://github.com/duckdb/duckdb-skills/issues**

For DuckDB-specific bugs (extension loading, SQL errors), please include the DuckDB version (`duckdb --version`) and the full error message.
