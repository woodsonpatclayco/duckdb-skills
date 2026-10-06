# duckdb-compat: Excel serial dates

`skills/query/duckdb-compat.sql` holds one macro, `xl_date(serial)`. It turns an Excel serial
number into a `DATE`: `(DATE '1899-12-30' + to_days(serial::BIGINT))::DATE`. The trailing
`::DATE` cast matters. Without it, adding `to_days()` yields a `TIMESTAMP`, not a `DATE`.
The contracts call `xl_date()` to decode Excel date columns.

## How it reaches a session

`tools\ensure-duckdb-compat.ps1` writes one quoted `.read '<forward-slash absolute path to
duckdb-compat.sql>'` line as the first line of `state.sql`, idempotently. Run it once per
project. It is not a second `-init`: `duckdb -init` takes one file, and `state.sql` already
uses that slot.

## Editing the file re-materializes every contract

The SHA-256 of `duckdb-compat.sql` is one of `materialize`'s four freshness keys (reason label
`compat_sha256`). Any edit to the file, even a comment, rebuilds every contract on the next
`materialize` run.

## History

The Snowflake macro layer (`IFF`, `NVL`, `DIV0`, and the other 15) was removed on 2026-10-06.
It lives in git history before that commit.
