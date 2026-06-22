# Changelog

All notable changes to `approx_count` are documented here. The PostgreSQL
extension `default_version` (`1.0`) maps to the PGXN/semver release (`1.0.0`).

## 1.0.0 (2026-06-22)

Initial release.

- `approx_count(regclass, interval, boolean)`: planner-estimate row counts from
  `pg_class.reltuples`, with a governed, advisory-lock-serialized `ANALYZE`
  refresh when statistics are stale.
- `approx_count_info(regclass, interval, boolean)`: returns
  `(estimated_rows, stats_at, refreshed, mods_since_analyze)`: the estimate, the
  statistics timestamp it is based on, whether this call refreshed, and the rows
  changed since the stats were taken (a churn-based ceiling on the count's error
  you can read without a `COUNT(*)`). The scalar `approx_count()` is a thin wrapper
  over it.
- Index support: `approx_count()` and `approx_count_info()` also accept an index.
  The estimate is the index's own `reltuples`, which for a **partial (conditional)
  index** is an approximate count of the rows matching its predicate, including
  predicates over expressions (e.g. `WHERE lower(country) = 'us'`), giving
  near-free approximate **filtered** counts maintained by the same autovacuum. An
  index has no statistics of its own, so freshness and the `ANALYZE` refresh route
  through the underlying table; partitioned indexes (relkind `I`) are rejected.
- `approx_count.max_refresh_wait`: when set (e.g. `'200ms'`), the stale-refresh
  path serves the current estimate instead of waiting if the relation's `ANALYZE`
  cannot acquire its table lock within that budget, so it does not get stuck
  behind `CREATE INDEX CONCURRENTLY`, `VACUUM`, or DDL holding
  `ShareUpdateExclusiveLock`. Default `'0'` keeps the blocking behavior. The
  per-relation advisory coordination lock is intentionally *not* bounded.
- Read-only transaction and standby auto-detection: returns a best-effort estimate
  without refreshing statistics or writing the ledger.
- OID-keyed metrics ledger (history survives a rename) with measured `ANALYZE`
  timing and the `dashboard` view.
- Optional `tune_thresholds()` closed-loop tuner, partition-tree aware.
- Sampleable metrics write via the `approx_count.sample_rate` GUC.
- Freshness gate judged from leaf partitions, so partitioned tables stay on the
  fast path when autovacuum keeps their leaves analyzed.
- Installs as a PGXS extension (`CREATE EXTENSION approx_count`; the schema is
  pinned in the control file) or via the generated `install.sql` script.
- `EXECUTE` revoked from `PUBLIC`; version-aware privilege recipe in
  `setup_role.sql`.
- Triple-licensed: PostgreSQL / MIT / Apache-2.0.
- Tested on PostgreSQL 14-18, with 19 (beta) covered non-blocking in CI.
