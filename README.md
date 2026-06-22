# approx_count

Fast approximate row counts for tables and indexes in PostgreSQL 14+, read from `pg_class.reltuples` instead of disk-heavy exact `COUNT(*)` scans, with a governed `ANALYZE` refresh when the statistics go stale.

![approx_count demo](demo.gif)

- **Sub-millisecond estimates** instead of a `COUNT(*)` scan of the whole table.
- **Approximate filtered counts** straight from a partial or expression index, with no `COUNT(*) WHERE ...` scan.
- **Governed, serialized refresh** (no `ANALYZE` stampede) that serves the current estimate instead of blocking under load.

**Jump to:**

- [Install](#installation)
- [Gotchas](#operational-caveats)
- [When will I get stale data?](#when-will-i-get-stale-data)
- [Performance & accuracy](#accuracy-model)

## Quick start

```sql
-- On a ~300M-row table an exact count scans for minutes:
SELECT count(*) FROM events;     -- minutes, heavy I/O
-- approx_count reads the planner's cached estimate:
SELECT approx_count.approx_count('events');   -- ~0.2 ms
```

Pick one of three ways to install. The bare string literal `'events'` coerces to `regclass`
automatically, exactly like `pg_relation_size('events')`, so no `::regclass` cast is needed.

**a. One-line install, straight from GitHub** (no clone, no build tools):

```bash
curl -fsSL https://raw.githubusercontent.com/jmealo/pg_approx_count/v1.0.0/install.sql | psql "$DATABASE_URL"
```

**b. Clone, then run the script:**

```bash
git clone https://github.com/jmealo/pg_approx_count.git
psql "$DATABASE_URL" -f pg_approx_count/install.sql
```

**c. Managed PGXS extension** (so `ALTER EXTENSION ... UPDATE`, `\dx`, and `DROP EXTENSION` work):

```bash
make install && psql "$DATABASE_URL" -c 'CREATE EXTENSION approx_count;'
```

All three create the same objects in the `approx_count` schema. Then:

```sql
SELECT approx_count.approx_count('events');             -- fast estimated row count
--  approx_count
-- --------------
--     312000000

SELECT * FROM approx_count.approx_count_info('events'); -- estimate + how old it is + how far it drifted
--  estimated_rows |        stats_at        | refreshed | mods_since_analyze
-- ----------------+------------------------+-----------+--------------------
--       312000000 | 2026-06-22 14:03:11+00 | f         |             184000
```

Want bare `approx_count(...)` calls? Add the schema to your `search_path`; see [Prefer unqualified calls?](#prefer-unqualified-calls). Before you rely on the number, read [When Will I Get Stale Data?](#when-will-i-get-stale-data).

## When to use this (and when not to)

Autovacuum already bounds `reltuples` staleness by **churn**: it re-analyzes a table once `n_mod_since_analyze > autovacuum_analyze_threshold + autovacuum_analyze_scale_factor * reltuples` (by default, after roughly 10% of the rows change). approx_count bounds staleness by **time** instead: at most one refresh per `max_stale` window, regardless of write rate. That distinction is the whole decision.

**Just read `reltuples` (no extension) when:**

- The table is healthy and a churn-based bound (~10%, tunable per table with `autovacuum_analyze_scale_factor`) is good enough.
- You occasionally want an approximate count of a regular table. `SELECT reltuples FROM pg_class WHERE oid = 'events'::regclass` is the whole thing.

**Use approx_count when:**

- You need a **time** bound on freshness ("no older than N minutes regardless of write rate"), for example scraping a count into Prometheus at a fixed interval.
- The table churns too fast for autoanalyze to keep `reltuples` fresh without analyzing so often it becomes its own tax (a hot upsert table), and you would rather drive a serialized, bounded refresh from the read side.
- You want what plain `reltuples` gets wrong or cannot do: summing a **partitioned** table from its leaves (a parent's own `reltuples` is 0), approximate **filtered counts** from a partial or expression index, or never letting a burst of callers stampede into concurrent `ANALYZE`.

**Do not reach for it** to paper over a permanent core table with vacuum problems you should actually fix (partition it, tune autovacuum, rethink the write pattern). It earns its place when fixing the underlying table genuinely is not worth it: an ephemeral, high-churn table in a disposable state database, where a read-side, time-bounded estimate is the proportionate amount of effort.

## Features

- **Fast estimated row counts.** Reads the planner's estimate from `pg_class.reltuples`, returning in sub-milliseconds where an exact `COUNT(*)` scans the whole table.
- **Governed, serialized refresh.** When statistics are stale it runs an `ANALYZE`, serialized behind a per-relation transaction-scoped advisory lock so concurrent callers never stampede into a refresh storm.
- **Tells you how old the number is, and how far it drifted.** `approx_count_info()` returns the estimate plus the statistics timestamp it is based on (`stats_at`), whether this call refreshed, and `mods_since_analyze`: the rows changed since the stats were taken, a churn-based ceiling on the count's error you can read without a `COUNT(*)`.
- **Serves the current estimate instead of blocking.** With `max_refresh_wait` set, a refresh that cannot get its table lock behind `CREATE INDEX CONCURRENTLY` / `VACUUM` / DDL gives up and serves the existing estimate rather than queuing.
- **Read-only and standby aware.** Auto-detects a read-only transaction or a physical standby and returns a best-effort estimate without attempting `ANALYZE` or writing the ledger.
- **Metrics built in.** An OID-keyed metrics ledger and a `dashboard` view expose calls served, scans avoided, measured `ANALYZE` durations, and estimated time saved.
- **Optional closed-loop tuner.** `tune_thresholds()` derives a per-relation stale interval from observed read pressure versus write volatility (off by default; schedule it yourself).
- **Broad relation support.** Works with tables, partitioned tables (judged from leaf partitions), materialized views, and foreign tables (best-effort).
- **Approximate filtered counts from indexes.** Point it at a **partial (conditional) index** and it returns an approximate count of the rows matching the index's predicate (any expression), maintained by the same autovacuum: a filtered count without a `COUNT(*) WHERE ...` scan. See [Approximate Filtered Counts](#approximate-filtered-counts-partial-indexes).
- **PostgreSQL 14 to 18**, plus 19 beta in CI; installs as a PGXS extension or a single self-contained SQL file.
- **Triple-licensed** under the PostgreSQL License, MIT, or Apache-2.0.

`approx_count` is distributed both as a packaged PostgreSQL extension and as a plain SQL install script; both paths create the same objects in a dedicated schema (default `approx_count`), and the examples below assume that default. It installs:

- `<schema>.metrics`: a per-relation metrics ledger keyed by relation OID.
- `<schema>.approx_count(regclass, interval, boolean)`: the count-estimate function.
- `<schema>.tune_thresholds()`: an optional, manually-scheduled feedback function.
- `<schema>.dashboard`: a dashboard view for scans avoided, refresh activity, measured ANALYZE timing, time saved, and analyze-avoidance ratio.

`approx_count` is triple-licensed under the PostgreSQL License, MIT, or Apache-2.0 (see `LICENSE`).

## Lock Lifecycle

`approx_count` avoids caller-controlled search paths by resolving the input `regclass` to its OID and reading the system catalogs. The relation OID becomes both the identity of the target table and the key for the concurrency lock.

The execution path is:

1. Resolve schema, relation name, and relation kind from system catalogs.
2. If the call is in a read-only transaction or on a standby, return a best-effort estimate immediately (no refresh, no metrics write; see [Read-only transactions and replicas](#read-only-transactions-and-replicas)).
3. Load the effective stale threshold. If `max_stale` is `NULL`, the function uses `metrics.optimal_stale_interval`; if the ledger row does not exist yet, it uses `10 minutes`.
4. Read `last_analyze` and `last_autoanalyze` from [`pg_stat_all_tables`](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ALL-TABLES-VIEW) for the relations that hold rows: regular tables, materialized views, foreign tables, and the **leaf partitions** of a partitioned table. The partitioned parent is excluded, because autovacuum never autoanalyzes it.
5. If the stats are fresh, return the rounded `reltuples` estimate.
6. If the stats are stale, acquire [`pg_advisory_xact_lock(target_table::oid::bigint)`](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS).
7. Clear the backend statistics snapshot with `pg_stat_clear_snapshot()`, re-read the analyze timestamps, and skip physical work if another session already refreshed the table.
8. If still stale, set transaction-local cost limits and execute `ANALYZE` for the target relation (which recurses into partitions), recording the measured duration.
9. Sum relation estimates, coercing PostgreSQL's un-analyzed `-1` state to `0`.
10. Atomically upsert the metrics row (subject to `approx_count.sample_rate`) and return the estimate.

For an **index target**, the returned estimate is the index's own `reltuples`, but everything that drives the refresh routes through the **underlying table** (`pg_index.indrelid`): the freshness tree (which leaf partitions / relations are checked for stale stats), the relation the `ANALYZE` refresh targets, and the advisory-lock key are all the underlying table, not the index. The index supplies only the number to return; the table supplies the freshness and the serialization.

Transaction-level advisory locks are intentional. Session-level advisory locks can leak through PgBouncer transaction pooling because the physical backend session outlives the logical request. `pg_advisory_xact_lock` is released automatically at commit or rollback, so the lock lifetime matches the function call.

## Installation

`approx_count` installs into a dedicated schema, `approx_count` by default. The schema is chosen at **build time** for both install paths; to use a different one, regenerate the artifacts first:

```bash
make render SCHEMA=myschema         # retargets approx_count.control + install.sql
```

### As a plain SQL script (quickest: no build tools, no PGXN)

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f install.sql
```

`install.sql` is a single self-contained file, generated from the canonical SQL with the schema baked in (default `approx_count`); it creates the schema and all objects in one transaction. Clone or download the one file and run it. This is the fastest way to adopt `approx_count`.

### As a managed PostgreSQL extension

For `\dx` visibility, in-place upgrades (`ALTER EXTENSION approx_count UPDATE`), and a one-line `DROP EXTENSION`, install it with PGXS instead:

```bash
make install                        # uses the pg_config on PATH; override with PG_CONFIG=/path/to/pg_config
```

```sql
CREATE EXTENSION approx_count;     -- installs into the pinned schema, created automatically
```

The control file pins the schema, so a bare `CREATE EXTENSION approx_count` always lands in `approx_count` (created for you) and **never** silently in `public`. The extension is not relocatable afterward; to move it, `make render SCHEMA=...`, `make install`, then recreate.

### Uninstall

```sql
DROP EXTENSION approx_count;       -- extension install (drops the schema too if empty)
```

The script-install path has no extension to drop; remove it with `DROP SCHEMA approx_count CASCADE;`.

### Prefer unqualified calls?

Objects live in a dedicated schema rather than `public`, so calls are schema-qualified by default. If you would rather write a bare `approx_count(...)`, add the schema to the relevant `search_path` instead of moving the objects into `public`:

```sql
ALTER ROLE app_reader SET search_path = "$user", public, approx_count;
-- or database-wide:
ALTER DATABASE mydb   SET search_path = "$user", public, approx_count;
```

This gives the ergonomics of unqualified names without the object-collision and dump/restore hazards of installing a general-purpose tool into `public`.

## Privileges

`approx_count` writes the metrics ledger and, on the stale path, runs `ANALYZE` as the caller (both functions are `SECURITY INVOKER`). For that reason **both** functions have `EXECUTE` revoked from `PUBLIC` at install time. Grant access explicitly to the roles that need it:

```sql
GRANT USAGE ON SCHEMA approx_count TO app_reader;
GRANT EXECUTE ON FUNCTION approx_count.approx_count(regclass, interval, boolean) TO app_reader;
GRANT SELECT, INSERT, UPDATE ON approx_count.metrics TO app_reader;
GRANT SELECT ON approx_count.dashboard TO app_reader;
```

The ledger `INSERT, UPDATE` is **not** optional on a writable primary: by default every call records metrics, so a role lacking it gets a `permission denied` error, not a silent skip. If you do not want application roles writing the ledger (or contending on its single hot row per table), set `approx_count.sample_rate = 0` for them (the write is then skipped and the grant is unnecessary), or route `approx_count` through a dedicated maintainer role.

The grant block above is the plain `SECURITY INVOKER` setup, where the calling role does the ledger write itself. Under **Model A** of `setup_role.sql` (`SECURITY DEFINER`, below) this is superseded: the ledger write runs as the **owner** role, so the owner (not the app role) holds the `metrics` `INSERT, UPDATE`, and the app role needs only `EXECUTE`. Under Model A do **not** also grant the app role metrics writes.

### The ANALYZE-rights question (and why it works best on 17+)

The stale (`ANALYZE`) path needs the executing role to be able to `ANALYZE` the target relation, and **PostgreSQL 17 is the dividing line**. 17+ added the [`MAINTAIN`](https://www.postgresql.org/docs/current/ddl-priv.html) privilege and the [`pg_maintain`](https://www.postgresql.org/docs/current/predefined-roles.html) predefined role, which let a **non-superuser** `ANALYZE` relations it does not own. Before 17 there is no such grant: `ANALYZE` requires table ownership or superuser. `setup_role.sql` configures the least-privilege option for your version, in one of two models:

- **Owner-definer (works on 14+, the default).** The role that already owns your tables owns the `approx_count` functions, which then run `SECURITY DEFINER`; callers need only `EXECUTE`. Escalation is bounded to "trigger an `ANALYZE` the owner could already run" and leaks no data (`reltuples` is already world-readable, and `pg_stats` hides results from anyone who cannot read the table). Never own these functions with a **superuser**.
- **Least-privilege runner (17+).** A dedicated role holds `pg_maintain` (or per-table `MAINTAIN`) and runs the functions as itself, `SECURITY INVOKER`: no definer, fully audited, tightest with per-table `MAINTAIN`.

### What you still get when the refresh cannot run

You do not always need the refresh. **Autovacuum keeps `reltuples` fresh on every version** (it runs autoanalyze), so with healthy autovacuum `approx_count` stays on its catalog-read fast path and never refreshes synchronously; the foreground `ANALYZE` is only a fallback for the gaps autovacuum leaves.

To be honest about the worst case: on **PostgreSQL 16 and earlier**, for a role that does **not** own the tables and whose autovacuum is behind, `approx_count` cannot refresh and is essentially a smarter `reltuples` reader. Even then it beats reading `pg_class` by hand: it **sums leaf partitions** (a partitioned parent's own `reltuples` is `0`), coerces the un-analyzed `-1` sentinel, does **partial- and expression-index filtered counts**, reports **how stale** the number is via `approx_count_info`, and exposes the metrics dashboard. The governed self-refresh is the part that needs the rights above, so on those versions either own the tables (owner-definer) or lean on autovacuum.

`approx_count` does **not** create roles itself (roles are cluster-global and are not dropped by `DROP EXTENSION`); copy and run `setup_role.sql`.

## CI, Docker, and Coverage

The repository includes a Docker-based matrix runner covering PostgreSQL 14 through 18, plus 19 (beta) as a non-blocking entry:

```bash
./ci/run_postgres_matrix.sh        # 14-18
./ci/run_postgres_matrix.sh 17     # one version while iterating
./ci/run_postgres_matrix.sh 19     # PostgreSQL 19 beta (uses the postgres:19beta1 image)
```

The Docker image installs `pgtap` for behavioral unit tests and `plpgsql_check` for PL/pgSQL statement coverage. Coverage is measured for `approx_count.approx_count(regclass, interval, boolean)` and `approx_count.tune_thresholds()` by `ci/plpgsql_coverage.sql`, which exercises the fast, stale, read-only, sampling, and error branches. The runner parses pgTAP output so `not ok` assertions fail the job, even though `psql` exits successfully after a TAP failure.

GitHub Actions uses `.github/workflows/ci.yml`; GitLab CI uses `.gitlab-ci.yml`. Both call the same local matrix runner. CI exercises **both** install paths: the script path (`install.sql`) and the packaged extension path (`make install` + `CREATE EXTENSION`, with a `DROP EXTENSION` clean-uninstall assertion).

## Operational Caveats

`approx_count` is an estimate path with an optional synchronous statistics refresh. That makes it useful, but it is not operationally free.

### Foreground `ANALYZE`

The fast path is a catalog read. The slow path is `ANALYZE`. When statistics are stale, the caller can block behind `pg_advisory_xact_lock` and the winning session can run a physical statistics refresh in the caller's transaction. The function measures each foreground `ANALYZE` and records `total/last/max_analyze_duration` in the ledger so you can see the real latency it injects. The transaction-local cost settings reduce I/O pressure, but they do not make foreground maintenance free.

For high-QPS application paths, prefer a relaxed stale interval and, above all, a well-tuned autovacuum (see [Tuning](#tuning)) so the refresh happens in the background. Avoid `max_stale => interval '0 seconds'` outside deterministic tests.

### Bounding refresh latency (`max_refresh_wait`)

By default the stale path waits for whatever it needs. If the relation is busy with a large operation that holds `ShareUpdateExclusiveLock` ([`CREATE INDEX CONCURRENTLY`](https://www.postgresql.org/docs/current/sql-createindex.html#SQL-CREATEINDEX-CONCURRENTLY), `VACUUM`, some `ALTER TABLE`), the foreground `ANALYZE` blocks behind it, and because the caller holds the per-relation advisory lock while it waits, other callers queue too.

Set `approx_count.max_refresh_wait` to bound how long the `ANALYZE` will wait for its table lock before giving up and **serving the current estimate** instead:

```sql
SET approx_count.max_refresh_wait = '200ms';   -- or '2s', '1min'; '0' (default) = wait, as in 1.0
```

It is implemented with [`lock_timeout`](https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-LOCK-TIMEOUT) scoped to the `ANALYZE`, so it bounds only the *table-lock acquisition*. It intentionally does **not** bound the per-relation advisory coordination lock (that wait is brief, and a transaction-scoped advisory lock cannot leak), nor the `ANALYZE`'s own runtime once it holds the lock. For a slow `ANALYZE` on a large table, widen `max_stale` (or rely on autovacuum) instead. Like `sample_rate`, it is a session-settable placeholder parameter (`SET`, or `ALTER DATABASE/ROLE ... SET`); an invalid value falls back to `'0'`.

### Plan Cache Invalidation

`ANALYZE` updates planner statistics, and PostgreSQL forces prepared statements through re-analysis and re-planning when statistics for referenced objects change: <https://www.postgresql.org/docs/current/sql-prepare.html>. PL/pgSQL static SQL is prepared through SPI and can cache plans per session: <https://www.postgresql.org/docs/current/plpgsql-implementation.html>.

An aggressive freshness policy can therefore create a plan-cache tax:

- Server-side prepared statements can lose the CPU benefit of stable generic plans; the next `EXECUTE` may pay re-analysis and re-planning.
- PL/pgSQL functions with static SQL against the table can have cached plans invalidated and rebuilt.
- Driver auto-prepare features experience the same effect once a statement is promoted server-side.
- Bare simple-protocol queries keep no reusable server-side plan, so the impact is plan-choice churn and foreground `ANALYZE` overhead, not loss of a persistent plan.

If your application relies on server-side prepared statements, PL/pgSQL cached plans, or driver statement caches, keep foreground analyzes rare. Monitor plan churn with `pg_stat_statements.track_planning` before enabling strict stale intervals broadly: <https://www.postgresql.org/docs/current/pgstatstatements.html>.

### Metrics Are Estimates

`total_time_saved` is derived from a configured `avg_full_count_duration`, not an automatically measured exact-count benchmark; it accrues only on calls that did **not** run `ANALYZE`, and `count_scans_prevented` excludes analyze calls. Set `avg_full_count_duration` from real measurements for important relations, and treat `analyze_avoidance_ratio` as the fraction of calls that avoided a physical analyze. The `*_analyze_duration` columns, by contrast, are **measured**; they reflect the real cost of the foreground refresh.

### Ledger Is Keyed by OID

`metrics` is keyed by relation OID, with `schemaname`/`tablename` carried as denormalized, refreshed-each-call display columns. This means a table's history **survives a rename** (and `ALTER ... SET SCHEMA`). The trade-offs: dropping a relation leaves an orphan row (the OID is gone), though `tune_thresholds()` garbage-collects orphans on each run, and a recreated table simply starts a fresh row. The ledger also does **not** carry across `pg_dump`/restore or `pg_upgrade`, where OIDs change. Treat ledger data as advisory and rebuildable.

### Foreign Tables Are Best-Effort

`relkind 'f'` is accepted, but the stale path runs `ANALYZE`, which depends on the FDW implementing analyze and on `reltuples` being meaningful for that wrapper. Many wrappers implement neither and the stale path will error. Use a generous `max_stale` for foreign tables, and validate per wrapper before relying on the estimate. The same caution applies to TimescaleDB compressed chunks.

### Read-only Transactions and Replicas

`approx_count` detects read-only context automatically: when [`pg_is_in_recovery()`](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-RECOVERY-INFO) is true (a physical standby) or `transaction_read_only` is on (a read-only transaction), it returns a best-effort estimate from current statistics **without** attempting `ANALYZE` or writing the ledger. No configuration is required on a replica or in a read-only transaction; the estimate reflects the statistics the primary's autovacuum has produced and replicated to the standby.

(Strictly, `ANALYZE` is blocked only in recovery; in a read-only *transaction* it would actually be permitted, but it is skipped anyway, because the metrics `INSERT` it pairs with is not, and a read-only transaction signals "change nothing.")

### Metric Writes on High-QPS Single Tables

On a writable primary, every recorded call updates one ledger row per table, so a single hot table funnels concurrent calls through that row. **On high-QPS hot tables, lower the sampling** so the ledger write is not on the critical path of every call. `approx_count.sample_rate` (default `1.0`) controls the fraction of calls that write the ledger:

```sql
SET approx_count.sample_rate = 0.01;   -- record ~1% of calls on a hot table
SET approx_count.sample_rate = 0;       -- record none
```

Set it per session, or durably with `ALTER DATABASE/ROLE ... SET`. It is a custom (class-qualified) placeholder parameter, **not** a registered GUC: it does not appear in `pg_settings`, and `SHOW approx_count.sample_rate` errors until something sets it in the session. Sampling makes the ledger counters a sample, not a full count. Any value that is not a plain decimal in `[0,1]` falls back to `1.0` (record every call) rather than erroring the query.

## Tuning

### Autovacuum is the primary refresh mechanism

The cheapest way to keep `approx_count` on its fast path is to let [autovacuum](https://www.postgresql.org/docs/current/routine-vacuuming.html#AUTOVACUUM) keep `reltuples` fresh in the background, because autovacuum runs `ANALYZE` (autoanalyze) too. Autoanalyze is write-volume driven, firing per table when:

```text
n_mod_since_analyze > autovacuum_analyze_threshold
                    + autovacuum_analyze_scale_factor * reltuples
```

`approx_count` consumes `last_autoanalyze` as a freshness signal, so a well-tuned autovacuum means it rarely (ideally never) runs a foreground `ANALYZE`. Tune it **per table** instead of reaching for a scheduler on the read path:

```sql
ALTER TABLE analytics.fact_events
  SET (autovacuum_analyze_scale_factor = 0.02,   -- refresh at ~2% churn, not the 10% default
       autovacuum_analyze_threshold   = 1000);
```

### Where the foreground refresh and tuner still help

Autovacuum does not cover every case. Keep `max_stale` and the closed-loop tuner as a fallback for:

- **Very large tables**, where 10% drift before autoanalyze is millions of rows.
- **Partitioned tables.** Freshness is judged from the leaf partitions (which autovacuum maintains), so a partitioned table whose leaves are fresh stays on the fast path. When a refresh *is* needed, `ANALYZE` on the parent recurses into the partitions. The tuner aggregates write activity across the whole partition tree, since the parent's own counters are always zero.
- **Tables with autovacuum disabled** or a daemon that is throttled or behind.

### `max_stale`

Pass `NULL` to let the metrics ledger decide the stale threshold. Use an explicit interval when a caller has a known freshness requirement:

| Workload | Suggested threshold | Rationale |
| --- | --- | --- |
| User-facing activity dashboard | `1 minute` to `5 minutes` | Keeps estimates recent without analyzing on every request |
| Batch-loaded reporting table | `30 minutes` to `2 hours` | Lets load bursts settle before refreshing stats |
| Slowly changing reference table | `6 hours` to `12 hours` | Avoids needless analyze churn |
| Regression testing | `0 seconds` | Forces the lock path for deterministic concurrency tests |

### `optimal_stale_interval` and the closed-loop tuner

This column is a **fallback** for the cases above, not the primary tuning path. When callers pass `NULL` for `max_stale`, the function uses it, and `tune_thresholds()` sets it from observed read pressure versus tree-aggregated write volatility:

```text
candidate_seconds = 300 * sqrt(reads / max(writes, 1))
optimal_stale_interval = clamp(candidate_seconds, 300, 43200)
```

The tuner is installed with the extension but is never run automatically; it also garbage-collects ledger rows for dropped relations. It re-reads cumulative statistics once per ledger row, so its cost scales with the number of tracked relations. Schedule it off-peak with pg_cron, not on the read path:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('0 3 * * *', $$SELECT approx_count.tune_thresholds()$$);
```

### `avg_full_count_duration`

The dashboard uses this value to estimate cumulative time saved. Set it to a measured exact-count duration for high-value tables:

```sql
UPDATE approx_count.metrics
   SET avg_full_count_duration = interval '2 minutes 30 seconds'
 WHERE tablename = 'fact_events';
```

### `debug_mode`

Set this to `true` in tests or incident diagnosis. The function logs whether a session used the fast path, executed `ANALYZE` (and how long it took), skipped work because another session refreshed the table first, or returned a read-only best-effort estimate.

**The diagnostic `NOTICE`s are off by default.** The `STALE STATS`, `ANALYZE EXECUTING`, `REFRESH SKIPPED`, concurrency-guard, and fast-path notices only emit when the third argument, `debug_mode`, is `true`. With `debug_mode` at its default of `false`, both `approx_count` and `approx_count_info` are silent.

## Usage

```sql
-- estimate using the table's ledger-driven stale threshold
SELECT approx_count.approx_count('analytics.fact_events') AS estimated_rows;

-- force a one-minute freshness window
SELECT approx_count.approx_count('analytics.fact_events', interval '1 minute', false);

-- get the estimate plus how old it is, whether this call refreshed, and how far it drifted
SELECT * FROM approx_count.approx_count_info('analytics.fact_events');
--  estimated_rows | stats_at            | refreshed | mods_since_analyze

-- never block more than 200ms refreshing; serve the current estimate if the table is lock-busy
SET approx_count.max_refresh_wait = '200ms';
SELECT approx_count.approx_count('analytics.fact_events');

-- inspect the dashboard
SELECT schemaname,
       tablename,
       total_calls_served,
       count_scans_prevented,
       total_time_saved_pretty,
       last_analyze_duration,
       optimal_stale_interval,
       analyze_avoidance_ratio
  FROM approx_count.dashboard
 ORDER BY total_calls_served DESC;
```

## Prometheus

Use `metrics_export.yaml` as a `postgres_exporter` custom query file (it assumes the default `approx_count` schema; adjust the query if you installed elsewhere). The exporter emits metric names of the form `<query-key>_<column>`, so the query block named `approx_count_efficiency` exposes:

- `approx_count_efficiency_total_calls_served`
- `approx_count_efficiency_total_analyzes_executed`
- `approx_count_efficiency_total_time_saved_seconds`

each labeled with `schemaname` and `tablename`.

## Accuracy Model

`approx_count` returns a planner estimate, not a snapshot-exact count. It is appropriate for dashboards, pagination summaries, capacity indicators, and operational context. Use exact `COUNT(*)` when correctness depends on the caller's MVCC snapshot, and avoid it for billing, quota enforcement, reconciliation, or compliance reporting.

**What `reltuples` actually is.** It is a single `float4` column in [`pg_class`](https://www.postgresql.org/docs/current/catalog-pg-class.html), the planner's estimate of live rows in a table (or entries in an index). [`ANALYZE`](https://www.postgresql.org/docs/current/sql-analyze.html) sets it by sampling pages (roughly `300 * default_statistics_target` of them) and extrapolating; `VACUUM` updates it from the heap pages it scans (skipping all-visible pages via the visibility map) and, only when it actually scans the index, from that scan, which would yield an exact entry count. In practice `VACUUM` frequently skips index cleanup (and page-skips the heap), so an index's `reltuples` is usually the `ANALYZE`-sampled estimate rather than an exact count. The `-1` sentinel (PostgreSQL 14+) means "never analyzed." It is the very number the planner costs every query plan with, which is why reading it is effectively free, and also why it is an estimate rather than a transactional or snapshot-exact counter.

The estimate is best read as *"approximately the committed row count as of the last statistics refresh,"* not *"the rows my transaction can see right now."* Specifically:

- **No snapshot semantics.** `reltuples` is a database-wide statistic, identical for every transaction regardless of its MVCC snapshot. It cannot reflect your own *uncommitted* `INSERT`/`DELETE` (an exact `COUNT(*)` in the same transaction would), and it will not match a concurrent transaction's exact count.
- **Even "fresh" is sampled.** `ANALYZE` estimates live tuples from a page sample, so the value is approximate (typically within ~1-2%) even at `max_stale => 0`. `approx_count` never returns an exact count.
- **Churn drives drift between refreshes.** The error grows with the *net* row change since the last refresh. **Pure `UPDATE`s don't drift** (the row count is stable, and the churn makes autovacuum refresh more often); **insert- or delete-heavy** tables drift faster, so tighten `max_stale` or lower the per-table `autovacuum_analyze_scale_factor` if you need a closer number.
- **Partitioned tables mix freshness.** The result sums each leaf partition's `reltuples` *as of that leaf's own last analyze*, so one churny, recently-unanalyzed partition can skew the whole total even when the others are fresh.
- **Heavy bloat can degrade it.** With many dead tuples and lagging vacuum, the live-tuple estimate is less reliable; healthy autovacuum keeps it honest.

## When Will I Get Stale Data?

`approx_count` deliberately trades exactness for speed. Every case where the number is older than "right now":

- **Within the freshness window.** If the statistics are newer than `max_stale` (or the ledger's `optimal_stale_interval` when `max_stale` is `NULL`), it returns the existing `reltuples` without refreshing: the normal fast path. The default window is 10 minutes.
- **Read-only transaction or standby.** It never refreshes or writes; you get whatever the primary's autovacuum has produced and replicated. See [Read-only Transactions and Replicas](#read-only-transactions-and-replicas).
- **`max_refresh_wait` and a lock-busy table.** With `max_refresh_wait` set, if the `ANALYZE` cannot acquire its table lock in time (behind `CREATE INDEX CONCURRENTLY`/`VACUUM`/DDL), it serves the current estimate instead of waiting.
- **Always, to ~1-2%.** Even at `max_stale => 0` the refresh is a *sampled* `ANALYZE`, not an exact count.
- **Between refreshes, proportional to churn.** Net inserts/deletes since the last analyze are invisible until the next one.

To see exactly how old a given answer is, use `approx_count_info()`: `stats_at` is the statistics timestamp the estimate is based on, `refreshed` says whether that call ran an `ANALYZE`, and `mods_since_analyze` is the drift since:

```sql
SELECT estimated_rows, stats_at, now() - stats_at AS age, refreshed, mods_since_analyze
  FROM approx_count.approx_count_info('analytics.fact_events');
```

If you care about the **margin of error** rather than the clock (you cannot measure the true error without a `COUNT(*)`, but you can bound it), `mods_since_analyze` is the signal: the inserts, updates, and deletes since `stats_at` (`pg_stat_all_tables.n_mod_since_analyze`), a conservative ceiling on how far the count could have drifted. `stats_at` bounds staleness in time; `mods_since_analyze` bounds it in churn. On an append-only table with healthy autovacuum the drift term is small and the residual error is just the analyze sampling floor (~1-2%); a bloated, vacuum-starved table degrades both.

## Approximate Filtered Counts (Partial Indexes)

`reltuples` exists for indexes too, and an index's `reltuples` estimates the number of entries it holds. For a **partial (conditional) index** that is the number of rows matching its predicate, so `approx_count` accepts an index directly and returns a near-free approximate count of a *subset*, without a filtered `COUNT(*)`:

```sql
-- a partial index over the rows you want to count
CREATE INDEX events_errors ON events (id) WHERE status = 'error';
ANALYZE events;   -- maintains the index's reltuples (autovacuum does this for you)

-- approximate count of the error rows:
SELECT approx_count.approx_count('events_errors');
```

The predicate can be any expression, so the filter is whatever you can index:

```sql
CREATE INDEX orders_us  ON orders (id) WHERE lower(country) = 'us';
CREATE INDEX orders_big ON orders (id) WHERE amount > 1000;
SELECT approx_count.approx_count('orders_us');   -- approx count of US orders
SELECT approx_count.approx_count('orders_big');  -- approx count of orders over 1000
```

An index has no statistics of its own, so freshness and the `ANALYZE` refresh route through the **underlying table**, the same governed, serialized refresh a table target gets. The estimate is the index's own `reltuples`, so a *non-partial* index just returns approximately the table's total row count: the filtering power comes from the `WHERE` predicate. Partitioned indexes (relkind `I`) are rejected; target a leaf partition's index instead. If you already keep partial indexes for query performance, you are also maintaining free approximate counters for the slices they cover.

The ledger is keyed on the index's OID for an index target, so the dashboard and metrics row's `tablename` shows the **index** name (not the underlying table's). Index-keyed rows are also not auto-tuned by `tune_thresholds()`, which only tunes tables, partitioned tables, matviews, and foreign tables; freshness and refresh still work for an index target, driven by its underlying table.
