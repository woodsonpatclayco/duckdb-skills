# duckdb-snowflake extension — findings

Investigated 2026-09-22 on Phil's machine while evaluating options for querying Snowflake from
DuckDB. Written to be usable two ways: as our own record of why we did not build on this
extension, and as the basis of an upstream issue, since the defect appears unreported.

## Environment

| Component | Version / value |
|---|---|
| OS | Windows, PowerShell 5.1 |
| DuckDB CLI | v1.5.5 (Variegata) `d8cdaa33fd` |
| `snowflake` extension | v0.5.2, installed via `INSTALL snowflake FROM community` |
| ADBC Snowflake driver | `go/v1.11.0` (also tested `go/v1.14.0`) |
| Driver location | `%USERPROFILE%\.duckdb\extensions\v1.5.5\windows_amd64\libadbc_driver_snowflake.so` |
| Snowflake account | `CLAYCO-DATAHUB` (Okta SSO) |
| Auth | `AUTH_TYPE 'ext_browser'` |
| Role / warehouse | `CLYCO_PWRUSR_COST_MGMT_GROUP` / `WH_POWER_USERS_XS` |

Install was done manually, then verified against
`scripts/install-adbc-driver.bat`: our steps match it exactly — same driver version, same
download URL, same extract, same `.dll` → `.so` rename, same target directory. No registry
manifest, no `snowflake.toml`, and no `SNOWFLAKE_ADBC_DRIVER_PATH` are required, and we have
none. **The installation is not misconfigured.**

## What works — verified, not assumed

All of the following returned correct results in this environment:

- **Snowflake dialect passthrough.** `snowflake_query()` executes real Snowflake SQL
  server-side. `IFF`, `NVL`, `DIV0`, `TO_VARCHAR` all evaluated correctly, returning
  `yes, fallback, 0.000000, 1234.50`.
- **One-statement materialize.**
  `COPY (SELECT * FROM snowflake_query(...)) TO 'x.parquet' (FORMAT PARQUET)` writes local
  Parquet with no stage, no `GET`, and no `REMOVE`.
- **Exact type fidelity.** A Parquet round-trip preserved `DECIMAL(5,0)`, `DECIMAL(12,2)`, and
  `VARCHAR` — `'01100'` kept its leading zero. This is the single strongest reason to want the
  extension: no CSV hop, so no decimal-to-float or cost-code-to-integer corruption.
- **Hybrid local/remote joins.** A `snowflake_query()` result joined to a local
  `read_parquet()` file in one statement returned `1, 1234.56, 01100`.
- **Auth persistence.** After one interactive Okta login, subsequent fresh `duckdb` processes
  connected with **no browser prompt**. Round trip ~1.07s.
- **Driver discovery.** stderr confirms resolution:
  `[Snowflake Ext INFO] Final adbc driver path: ...libadbc_driver_snowflake.so`

## The defect — process does not exit after connecting

**A `duckdb` process that has opened a Snowflake connection through this extension does not
reliably terminate.** The query itself succeeds; correct rows are produced. Only shutdown
fails.

### Isolation

Each case run as `duckdb -csv -f <file>`, launched detached, 20s cap:

| Case | Result |
|---|---|
| `SELECT 1` — no extension | exits cleanly, 0.13s |
| `LOAD snowflake;` then `SELECT 1` | exits cleanly, 0.15s |
| `LOAD snowflake;` + `CREATE SECRET`, **no connection** | exits cleanly, 0.15s |
| `LOAD polyglot;` (Rust extension, control) | exits cleanly, 0.20s |
| `LOAD snowflake;` + `CREATE SECRET` + `snowflake_query(...)` | **does not exit** |

So it is not DuckDB, not extension loading, not secret creation, and not extensions in general.
The trigger is specifically establishing the ADBC connection.

### Reproduction

```sql
LOAD snowflake;
CREATE OR REPLACE SECRET s (
    TYPE snowflake,
    ACCOUNT '<account>',
    USER '<user>',
    AUTH_TYPE 'ext_browser',
    WAREHOUSE '<wh>'
);
SELECT * FROM snowflake_query('SELECT current_role() AS r, 7 AS v', 's');
```

Run as `duckdb -csv -f repro.sql`. The rows are correct. The process does not return.

### Driver version is not the cause

The extension's installer pins driver `1.11.0`; releases `1.12.0`, `1.13.0`, and `1.14.0` exist.
Upgraded to `go/v1.14.0` and verified the swap by hash (61,232,532 bytes /
`5BC39854011C6F8F` → 55,990,019 bytes / `4CACE3E94C369D27`, matching the tarball and differing
from the v1.11.0 backup).

Result with v1.14.0: **0 clean exits out of 4; 4 hangs out of 4.** Reverted to v1.11.0.

### It is intermittent, which is the worst part

One run exited on its own in 1.07s. Three consecutive runs on v1.11.0, and four on v1.14.0, did
not. A defect that reproduces most of the time but not always will not reproduce when someone
goes looking for it.

### Results are not reliably retrievable

With redirected stdout, the buffer flushes on exit — so a process that never exits sometimes
never surfaces its output. Of the four v1.14.0 attempts, **two produced no rows at all within
30 seconds** despite the query having succeeded. Polling the output file works sometimes
(rows appeared at 1.07s in one run) and not others.

### It can leave an unkillable process

One hung process (pid 22216, ~17 min old, reported as *responding*) survived both
`Stop-Process -Force` and `taskkill /F /T`:

```
SUCCESS: The process with PID 18328 (child process of PID 22216) has been terminated.
ERROR: The process with PID 22216 (child process of PID 15768) could not be terminated.
```

It held a file lock on `libadbc_driver_snowflake.so`, which **blocked the driver upgrade** —
testing v1.14.0 required a reboot. After the reboot, all hung processes were killable, so the
unkillable state seems to need accumulated session state rather than being guaranteed. It
happened once and that is enough to matter.

### Likely cause

Consistent with Go `c-shared` behavior: once the Go runtime inside the `dlopen`'d driver starts
its network machinery, the host process cannot tear it down cleanly. Apache Arrow ADBC issue
[#3840](https://github.com/apache/arrow-adbc/issues/3840) — *"initializing the driver creates
some dangling resources which hangs application during shutdown"* — describes the same class of
bug, reported against the **Snowflake** driver, traced to the ADBC FFI init function. It was
closed in the "ADBC Libraries 22" milestone (2026-01-06), which predates driver v1.11.0
(2026-06-18), so whatever was fixed there does not cover this path. Related:
[#3491](https://github.com/apache/arrow-adbc/pull/3491), goroutine leak on connection close.

No matching issue found on `iqea-ai/duckdb-snowflake`; its tracker returns nothing for
hang/exit/shutdown. `adbc-drivers/snowflake` has zero issues filed at all.

## Hypotheses ruled out

Recording these because each was believed at some point during the investigation and each was
wrong:

- **"SSO prompts on every invocation."** False. Auth persists after one login; later processes
  connect with no browser. The evidence for this claim was an empty stdout from a run that never
  flushed.
- **"`ext_browser` is unusable; key-pair is required."** False, and it produced a wasted
  recommendation to raise an IT request for an RSA public key. Not needed.
- **"The ADBC install is misconfigured."** False. Verified identical to the official installer.
- **"Stale OCSP cache / the 13-month-old `ocsp_response_cache.json.lck`."** Not the cause; the
  hang reproduces regardless.
- **"Cortex Code's leaked shells."** A real and separate problem — 13 PowerShell processes, the
  oldest 22 hours — which *amplified* every hang into a session-wide stall. But the defect
  reproduces in a clean shell after a reboot.
- **"The harness pattern was the cause."** Partly: running `duckdb` with `-NoNewWindow` and
  redirected streams inside a piped wrapper turns the hang into an unrecoverable tool-level
  stall, because the pipeline cannot close while a non-exiting grandchild holds inherited
  handles. Launching detached (`-WindowStyle Hidden`) and reading the file separately avoids
  that. It does not fix the underlying non-exit.

## Conclusion

Do not build the default Snowflake path on this extension.

This is not a judgment on its capabilities, which are good and which nothing else matches —
real Snowflake dialect, one-statement typed Parquet, live hybrid joins. It is a judgment on one
defect: normal use can leave a stuck process behind, sometimes with results unreadable, once
unkillable and holding a file lock. Documenting a launch-and-kill wrapper in a `SKILL.md` is not
adequate protection, because the mitigation itself proved unreliable — `Kill()` returned without
error and the process survived.

Chosen instead, both safe by construction rather than by convention:

- **`polyglot`** for Snowflake dialect locally. Never opens a connection; exits in 0.2s.
  Measured 36/41 Snowflake constructs versus 28 for a hand-written macro shim and 17 for raw
  DuckDB.
- **The app's built-in connection** (`COPY INTO` stage as Parquet, then `GET`) for extracts.
  The Go driver is never loaded into a `duckdb` process, so this failure mode is impossible
  rather than avoided.

**ducksync** (`INSTALL ducksync FROM community`) is out for the same reason: it routes every
cache refresh through this extension's connection, so it would inherit an intermittent hang on
the exact operation it exists to perform — and it additionally requires PostgreSQL for its
DuckLake catalog. Its two-stage invalidation design is worth reimplementing directly, though:
compare `SHOW TABLES` rows/bytes through a no-warehouse connection first, and fall back to
`information_schema.tables.last_altered` only when those change. That avoids waking a warehouse
just to ask whether data moved, and needs no PostgreSQL, no DuckLake, and no third extension.

## Revisit if

- An upstream fix lands for connection-shutdown teardown in the Go driver or the extension.
- Key-pair auth becomes available **and** is shown to change shutdown behavior (no reason to
  think it would — the hang is in teardown, not auth).
- A newer extension version than v0.5.2 reports fixing process exit.

Worth filing upstream on `iqea-ai/duckdb-snowflake`: the reproduction above is small, the
isolation table shows it is the connection rather than the load, and it is driver-version
independent across v1.11.0 and v1.14.0.
