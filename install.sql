-- GENERATED FROM sql/approx_count--1.0.sql by tools/render.sh. DO NOT EDIT.
--
-- Plain-SQL install of approx_count into schema "approx_count" (no build tools):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f install.sql
--
-- Or install it as an extension: make install && CREATE EXTENSION approx_count;
-- Retarget the schema for both artifacts with: SCHEMA=<schema> ./tools/render.sh

BEGIN;

CREATE SCHEMA IF NOT EXISTS approx_count;

-- approx_count 1.0
--
-- Canonical object definitions and the single source of truth. The schema
-- placeholder below is substituted with the extension's install schema by the
-- CREATE EXTENSION machinery; the control file pins that schema (default
-- approx_count), so a bare CREATE EXTENSION never lands in public. The plain-SQL
-- installer (install.sql) and the control file are GENERATED from this source by
-- tools/render.sh, which substitutes the placeholder with a concrete schema.
--
-- This file intentionally contains NO BEGIN/COMMIT, NO CREATE SCHEMA, NO
-- CREATE EXTENSION, and NO psql backslash commands.

CREATE TABLE IF NOT EXISTS approx_count.metrics (
    relid oid PRIMARY KEY,
    schemaname text NOT NULL,
    tablename text NOT NULL,
    total_calls_served bigint NOT NULL DEFAULT 0 CHECK (total_calls_served >= 0),
    total_analyzes_executed bigint NOT NULL DEFAULT 0 CHECK (total_analyzes_executed >= 0),
    avg_full_count_duration interval NOT NULL DEFAULT interval '15 seconds',
    total_time_saved interval NOT NULL DEFAULT interval '0 seconds',
    total_analyze_duration interval NOT NULL DEFAULT interval '0 seconds',
    last_analyze_duration interval,
    max_analyze_duration interval,
    optimal_stale_interval interval NOT NULL DEFAULT interval '10 minutes'
);

-- approx_count_info: the full implementation. Returns the estimate together with
-- enough context to judge it: the statistics timestamp it is based on (stats_at),
-- whether this call refreshed them (refreshed), and how far the table has drifted
-- since (mods_since_analyze). The scalar approx_count() below is a thin wrapper
-- that returns just estimated_rows.
--
-- The estimate is pg_class.reltuples: a float4 PLANNER statistic, not an exact
-- counter. ANALYZE sets it by reading a random sample of about
-- 300 * default_statistics_target rows (about 30,000 at the default target of 100)
-- from an equal-sized sample of pages and extrapolating reltuples from the sampled
-- tuple density times relpages, so the value is approximate even when fresh, and
-- reading it is free because the planner already maintains it for query costing. A
-- value of -1 means the relation has never been analyzed.
--
-- An index target is supported too: the estimate is the index's own reltuples,
-- which for a partial (conditional) index is an approximate count of the rows
-- matching its predicate. An index has no statistics of its own, so freshness and
-- the ANALYZE refresh route through the underlying table (pg_index.indrelid);
-- ANALYZE on the table updates every index's reltuples.
--
-- mods_since_analyze is the margin-of-error signal: inserts + updates + deletes
-- since the stats were taken (pg_stat_all_tables.n_mod_since_analyze, summed over
-- the same relations freshness is judged from). It is a conservative ceiling on how
-- far the count could have drifted, readable without a COUNT(*). stats_at bounds the
-- estimate's staleness in time; mods_since_analyze bounds it in observed churn.
CREATE OR REPLACE FUNCTION approx_count.approx_count_info(
    target_table regclass,
    max_stale interval DEFAULT NULL,
    debug_mode boolean DEFAULT false,
    OUT estimated_rows bigint,
    OUT stats_at timestamp with time zone,
    OUT refreshed boolean,
    OUT mods_since_analyze bigint
)
RETURNS record
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    _relid oid := target_table::oid;
    _schemaname text;
    _tablename text;
    _relkind "char";
    _ledger_stale_interval interval;
    _effective_max_stale interval;
    _oldest_stats_at timestamp with time zone;
    _has_missing_stats boolean;
    _is_stale boolean;
    _analyze_executed boolean := false;
    _analyze_started_at timestamp with time zone;
    _analyze_duration interval;
    _estimated_count bigint;
    _stats_reference_at timestamp with time zone := statement_timestamp();
    _session_label text;
    _read_only boolean;
    _sample_raw text;
    _sample_rate numeric;
    _judged_count bigint;
    _mods bigint;
    _refresh_wait text;
    _is_index boolean := false;
    _refresh_relid oid;
    _refresh_schema text;
    _refresh_table text;
BEGIN
    SELECT n.nspname, c.relname, c.relkind
      INTO _schemaname, _tablename, _relkind
      FROM pg_class AS c
      JOIN pg_namespace AS n
        ON n.oid = c.relnamespace
     WHERE c.oid = _relid;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'relation with OID % does not exist', _relid
            USING ERRCODE = 'undefined_table';
    END IF;

    IF _relkind = 'I' THEN
        RAISE EXCEPTION 'approx_count.approx_count does not support partitioned indexes (%.% has relkind I); target a leaf partition''s index instead',
            _schemaname, _tablename
            USING ERRCODE = 'wrong_object_type';
    END IF;

    IF _relkind NOT IN ('r', 'p', 'm', 'f', 'i') THEN
        RAISE EXCEPTION 'approx_count.approx_count only supports tables, partitioned tables, materialized views, foreign tables, and indexes; %.% has relkind %',
            _schemaname, _tablename, _relkind
            USING ERRCODE = 'wrong_object_type';
    END IF;

    -- For an index target the estimate is the index's own reltuples (for a partial
    -- index, an approximate count of the rows matching its predicate). Freshness and
    -- the refresh route through the underlying table: the index has no statistics of
    -- its own, and ANALYZE on the table updates every index's reltuples. For every
    -- other relkind the refresh target is the relation itself.
    IF _relkind = 'i' THEN
        _is_index := true;
        SELECT i.indrelid, tn.nspname, tc.relname
          INTO _refresh_relid, _refresh_schema, _refresh_table
          FROM pg_index AS i
          JOIN pg_class AS tc ON tc.oid = i.indrelid
          JOIN pg_namespace AS tn ON tn.oid = tc.relnamespace
         WHERE i.indexrelid = _relid;
    ELSE
        _refresh_relid := _relid;
        _refresh_schema := _schemaname;
        _refresh_table := _tablename;
    END IF;

    -- transaction_read_only is on both inside an explicit read-only transaction and
    -- on a physical standby, so this single check covers both. The distinction that
    -- matters: ANALYZE is allowed in a read-only transaction (it is maintenance, not
    -- a data write) but is impossible during recovery on a standby, and the ledger
    -- INSERT is impossible in either. So in both cases we skip the refresh and the
    -- write and return a best-effort estimate from whatever statistics already exist.
    _read_only := pg_is_in_recovery() OR current_setting('transaction_read_only')::boolean;

    SELECT m.optimal_stale_interval
      INTO _ledger_stale_interval
      FROM approx_count.metrics AS m
     WHERE m.relid = _relid;

    -- Ignore a manually corrupted (negative) ledger interval rather than letting
    -- it brick every NULL-max_stale call; an explicit negative max_stale still errors.
    IF _ledger_stale_interval < interval '0 seconds' THEN
        _ledger_stale_interval := NULL;
    END IF;

    _effective_max_stale := COALESCE(max_stale, _ledger_stale_interval, interval '10 minutes');

    IF _effective_max_stale < interval '0 seconds' THEN
        RAISE EXCEPTION 'max_stale must resolve to a non-negative interval';
    END IF;

    _session_label := current_setting('application_name', true);
    IF _session_label IS NULL OR btrim(_session_label) = '' THEN
        _session_label := 'Session ' || pg_backend_pid()::text;
    END IF;

    PERFORM pg_stat_clear_snapshot();

    -- Freshness is judged from the relations that actually hold rows and that
    -- autovacuum maintains: regular tables, matviews, foreign tables, and the
    -- leaf partitions of a partitioned table. The partitioned parent (relkind
    -- 'p') is excluded because autovacuum never autoanalyzes it, so including it
    -- would make every partitioned table look perpetually stale. For an index the
    -- tree is rooted at the underlying table, so it judges that table's stats.
    WITH RECURSIVE relation_tree AS (
        SELECT c.oid, c.relkind
          FROM pg_class AS c
         WHERE c.oid = _refresh_relid
        UNION ALL
        SELECT child.oid, child.relkind
          FROM relation_tree AS parent
          JOIN pg_inherits AS i
            ON i.inhparent = parent.oid
          JOIN pg_class AS child
            ON child.oid = i.inhrelid
    ),
    relation_stats AS (
        SELECT GREATEST(s.last_analyze, s.last_autoanalyze) AS analyzed_at,
               s.n_mod_since_analyze AS mods
          FROM relation_tree AS r
          LEFT JOIN pg_stat_all_tables AS s
            ON s.relid = r.oid
         WHERE r.relkind IN ('r', 'm', 'f')
    )
    SELECT MIN(analyzed_at), BOOL_OR(analyzed_at IS NULL), COUNT(*), COALESCE(SUM(mods), 0)
      INTO _oldest_stats_at, _has_missing_stats, _judged_count, _mods
      FROM relation_stats;

    -- With no row-holding relations to judge (e.g. a partitioned table with no
    -- leaf partitions) there is nothing to refresh, so treat it as fresh.
    _is_stale := _judged_count > 0
        AND (COALESCE(_has_missing_stats, true)
             OR _oldest_stats_at IS NULL
             OR _oldest_stats_at < (_stats_reference_at - _effective_max_stale));

    IF _is_stale AND _read_only THEN
        IF debug_mode THEN
            RAISE NOTICE '[%] READ-ONLY: statistics look stale but this is a read-only transaction or standby; returning a best-effort estimate without ANALYZE or metrics.',
                _session_label;
        END IF;
    ELSIF _is_stale THEN
        IF debug_mode THEN
            RAISE NOTICE '[%] STALE STATS: waiting for transaction-level advisory lock on %.% with threshold %.',
                _session_label, _refresh_schema, _refresh_table, _effective_max_stale;
        END IF;

        -- Serialize refreshers with a TRANSACTION-scoped advisory lock, never a
        -- session-scoped one. A session-level advisory lock outlives the logical
        -- request under a transaction pooler like PgBouncer: the physical backend is
        -- handed to the next client still holding the lock, so it leaks and can block
        -- unrelated work. pg_advisory_xact_lock releases automatically at commit or
        -- rollback, so its lifetime matches this call. Keyed on the refresh target so
        -- sibling indexes of one table serialize on its single ANALYZE.
        PERFORM pg_advisory_xact_lock(_refresh_relid::bigint);
        PERFORM pg_stat_clear_snapshot();

        WITH RECURSIVE relation_tree AS (
            SELECT c.oid, c.relkind
              FROM pg_class AS c
             WHERE c.oid = _refresh_relid
            UNION ALL
            SELECT child.oid, child.relkind
              FROM relation_tree AS parent
              JOIN pg_inherits AS i
                ON i.inhparent = parent.oid
              JOIN pg_class AS child
                ON child.oid = i.inhrelid
        ),
        relation_stats AS (
            SELECT GREATEST(s.last_analyze, s.last_autoanalyze) AS analyzed_at,
                   s.n_mod_since_analyze AS mods
              FROM relation_tree AS r
              LEFT JOIN pg_stat_all_tables AS s
                ON s.relid = r.oid
             WHERE r.relkind IN ('r', 'm', 'f')
        )
        SELECT MIN(analyzed_at), BOOL_OR(analyzed_at IS NULL), COUNT(*), COALESCE(SUM(mods), 0)
          INTO _oldest_stats_at, _has_missing_stats, _judged_count, _mods
          FROM relation_stats;

        _is_stale := _judged_count > 0
            AND (COALESCE(_has_missing_stats, true)
                 OR _oldest_stats_at IS NULL
                 OR _oldest_stats_at < (_stats_reference_at - _effective_max_stale));

        IF _is_stale THEN
            -- Bound only the ANALYZE's table-lock acquisition. If the relation is
            -- busy with a large operation that holds ShareUpdateExclusiveLock
            -- (CREATE INDEX CONCURRENTLY, VACUUM, some ALTER TABLE), give up within
            -- approx_count.max_refresh_wait and serve the current estimate instead
            -- of queuing behind it. Default '0' = no timeout = wait (1.0 behavior).
            _refresh_wait := COALESCE(NULLIF(btrim(current_setting('approx_count.max_refresh_wait', true)), ''), '0');
            -- lock_timeout granularity is milliseconds; 'us' would silently round
            -- sub-millisecond values to 0 = no timeout, the opposite of the intent.
            IF _refresh_wait !~ '^[0-9]+\s*(ms|s|min|h|d)?$' THEN
                _refresh_wait := '0';
            END IF;

            -- Apply the timeout in its own block: a value that passes the regex but
            -- overflows lock_timeout (an absurd magnitude) must never crash the
            -- count -- fall back to no timeout (block) rather than aborting.
            BEGIN
                PERFORM set_config('lock_timeout', _refresh_wait, true);
            EXCEPTION
                WHEN invalid_parameter_value THEN
                    PERFORM set_config('lock_timeout', '0', true);
            END;

            BEGIN
                -- Throttle this foreground ANALYZE with transaction-local vacuum
                -- cost settings so a refresh on the user path does not starve the
                -- storage system. Being transaction-local (the third set_config arg),
                -- they never leak into pooled sessions the way a plain SET would.
                PERFORM set_config('vacuum_cost_delay', '10', true);
                PERFORM set_config('vacuum_cost_limit', '200', true);

                IF debug_mode THEN
                    RAISE NOTICE '[%] ANALYZE EXECUTING: physical catalog refresh for %.% with transaction-local vacuum_cost_delay=10 and vacuum_cost_limit=200.',
                        _session_label, _refresh_schema, _refresh_table;
                END IF;

                _analyze_started_at := clock_timestamp();
                EXECUTE format('ANALYZE %I.%I', _refresh_schema, _refresh_table);
                _analyze_duration := clock_timestamp() - _analyze_started_at;
                _analyze_executed := true;

                IF debug_mode THEN
                    RAISE NOTICE '[%] ANALYZE EXECUTED: Physical ANALYZE completed in %.',
                        _session_label, _analyze_duration;
                END IF;
            EXCEPTION
                WHEN lock_not_available THEN
                    -- the relation is lock-busy; serve the stale estimate
                    IF debug_mode THEN
                        RAISE NOTICE '[%] REFRESH SKIPPED: %.% is lock-busy (could not acquire within approx_count.max_refresh_wait=%); serving stale estimate.',
                            _session_label, _refresh_schema, _refresh_table, _refresh_wait;
                    END IF;
            END;

            PERFORM set_config('lock_timeout', '0', true);
        ELSE
            IF debug_mode THEN
                RAISE NOTICE '[%] ANALYZE SKIPPED: Concurrency guard caught it.',
                    _session_label;
            END IF;
        END IF;
    ELSE
        IF debug_mode THEN
            RAISE NOTICE '[%] FAST PATH: catalog statistics are fresh for %.% with threshold %.',
                _session_label, _refresh_schema, _refresh_table, _effective_max_stale;
        END IF;
    END IF;

    IF _is_index THEN
        -- The estimate is the index's own reltuples (entries in the index). For a
        -- partial index that is an approximate count of the rows matching its
        -- predicate. Coerce the un-analyzed -1 sentinel to 0.
        SELECT CASE WHEN c.reltuples < 0 THEN 0::bigint
                    ELSE ROUND(c.reltuples)::bigint END
          INTO _estimated_count
          FROM pg_class AS c
         WHERE c.oid = _relid;
    ELSE
        WITH RECURSIVE relation_tree AS (
            SELECT c.oid, c.relkind
              FROM pg_class AS c
             WHERE c.oid = _relid
            UNION ALL
            SELECT child.oid, child.relkind
              FROM relation_tree AS parent
              JOIN pg_inherits AS i
                ON i.inhparent = parent.oid
              JOIN pg_class AS child
                ON child.oid = i.inhrelid
        )
        SELECT COALESCE(
                   ROUND(
                       SUM(
                           CASE
                               WHEN c.relkind = 'p' OR c.reltuples < 0 THEN 0::numeric
                               ELSE c.reltuples::numeric
                           END
                       )
                   )::bigint,
                   0::bigint
               )
          INTO _estimated_count
          FROM relation_tree AS r
          JOIN pg_class AS c
            ON c.oid = r.oid
         WHERE c.relkind IN ('r', 'p', 'm', 'f');
    END IF;

    IF _read_only THEN
        estimated_rows := _estimated_count;
        stats_at := _oldest_stats_at;
        refreshed := false;
        mods_since_analyze := _mods;
        RETURN;
    END IF;

    -- Metrics recording is sampleable so the per-call ledger write does not have
    -- to be a hot, serialized row on high-QPS single-table workloads. The
    -- approx_count.sample_rate GUC (default 1.0) controls the fraction of
    -- calls that update the ledger. The value is parsed defensively: anything
    -- that is not a plain decimal in [0,1] falls back to 1.0 (record every call)
    -- rather than erroring the query or silently inverting on NaN.
    _sample_raw := btrim(COALESCE(current_setting('approx_count.sample_rate', true), ''));
    IF _sample_raw ~ '^[0-9]+(\.[0-9]+)?$' THEN
        _sample_rate := LEAST(GREATEST(_sample_raw::numeric, 0::numeric), 1::numeric);
    ELSE
        _sample_rate := 1::numeric;
    END IF;

    IF _sample_rate >= 1
        OR (_sample_rate > 0 AND random() < _sample_rate)
    THEN
        INSERT INTO approx_count.metrics AS m (
            relid,
            schemaname,
            tablename,
            total_calls_served,
            total_analyzes_executed,
            total_time_saved,
            total_analyze_duration,
            last_analyze_duration,
            max_analyze_duration
        )
        VALUES (
            _relid,
            _schemaname,
            _tablename,
            1,
            CASE WHEN _analyze_executed THEN 1 ELSE 0 END,
            -- Only credit avoided count work when this call did NOT run ANALYZE.
            CASE WHEN _analyze_executed THEN interval '0 seconds' ELSE interval '15 seconds' END,
            COALESCE(_analyze_duration, interval '0 seconds'),
            _analyze_duration,
            _analyze_duration
        )
        ON CONFLICT (relid) DO UPDATE
            SET schemaname = EXCLUDED.schemaname,
                tablename = EXCLUDED.tablename,
                total_calls_served = m.total_calls_served + 1,
                total_analyzes_executed = m.total_analyzes_executed + EXCLUDED.total_analyzes_executed,
                total_time_saved = m.total_time_saved
                    + CASE
                          WHEN EXCLUDED.total_analyzes_executed > 0 THEN interval '0 seconds'
                          ELSE m.avg_full_count_duration
                      END,
                total_analyze_duration = m.total_analyze_duration + COALESCE(_analyze_duration, interval '0 seconds'),
                last_analyze_duration = COALESCE(_analyze_duration, m.last_analyze_duration),
                max_analyze_duration = GREATEST(m.max_analyze_duration, _analyze_duration);
    END IF;

    estimated_rows := _estimated_count;
    stats_at := CASE WHEN _analyze_executed THEN _analyze_started_at ELSE _oldest_stats_at END;
    refreshed := _analyze_executed;
    -- After our own ANALYZE, n_mod_since_analyze resets to ~0; _mods was captured
    -- before it ran, so report 0 to reflect the just-refreshed state. Otherwise
    -- report the observed drift, the count's conservative error ceiling.
    mods_since_analyze := CASE WHEN _analyze_executed THEN 0 ELSE _mods END;
    RETURN;
END;
$$;

-- Scalar convenience wrapper: returns just the estimate. plpgsql (not sql) so the
-- planner never inlines it and the refresh/ledger side effects run exactly once.
CREATE OR REPLACE FUNCTION approx_count.approx_count(
    target_table regclass,
    max_stale interval DEFAULT NULL,
    debug_mode boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    _rows bigint;
BEGIN
    SELECT estimated_rows
      INTO _rows
      FROM approx_count.approx_count_info(target_table, max_stale, debug_mode);
    RETURN _rows;
END;
$$;

CREATE OR REPLACE FUNCTION approx_count.tune_thresholds()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    _metric record;
    _read_write_ratio numeric;
    _candidate_seconds numeric;
    _bounded_seconds integer;
BEGIN
    -- Garbage-collect ledger rows whose relation has been dropped (OID gone), so
    -- orphans from drop/recreate do not accumulate forever.
    DELETE FROM approx_count.metrics AS m
     WHERE NOT EXISTS (SELECT 1 FROM pg_class AS c WHERE c.oid = m.relid);

    FOR _metric IN
        SELECT m.relid,
               GREATEST(m.total_calls_served, 1)::numeric AS total_calls_served,
               agg.write_activity
          FROM approx_count.metrics AS m
          JOIN pg_class AS c
            ON c.oid = m.relid
          CROSS JOIN LATERAL (
              -- Aggregate write activity across the whole inheritance tree so a
              -- partitioned parent (whose own counters are always zero) reflects
              -- the writes landing on its leaf partitions.
              WITH RECURSIVE tree AS (
                  SELECT m.relid AS oid
                  UNION ALL
                  SELECT i.inhrelid
                    FROM tree AS t
                    JOIN pg_inherits AS i
                      ON i.inhparent = t.oid
              )
              SELECT GREATEST(
                         COALESCE(SUM(s.n_mod_since_analyze), 0),
                         COALESCE(SUM(s.n_tup_ins + s.n_tup_upd + s.n_tup_del), 0),
                         1
                     )::numeric AS write_activity
                FROM tree AS t
                LEFT JOIN pg_stat_all_tables AS s
                  ON s.relid = t.oid
          ) AS agg
         WHERE c.relkind IN ('r', 'p', 'm', 'f')
    LOOP
        _read_write_ratio := _metric.total_calls_served / _metric.write_activity;

        _candidate_seconds := 300::numeric * sqrt(_read_write_ratio);
        _bounded_seconds := ROUND(
            LEAST(
                43200::numeric,
                GREATEST(300::numeric, _candidate_seconds)
            )
        )::integer;

        UPDATE approx_count.metrics AS m
           SET optimal_stale_interval = make_interval(secs => _bounded_seconds)
         WHERE m.relid = _metric.relid;
    END LOOP;
END;
$$;

CREATE OR REPLACE VIEW approx_count.dashboard AS
WITH metric_seconds AS (
    SELECT m.relid,
           m.schemaname,
           m.tablename,
           m.total_calls_served,
           m.total_analyzes_executed,
           m.avg_full_count_duration,
           m.total_time_saved,
           m.total_analyze_duration,
           m.last_analyze_duration,
           m.max_analyze_duration,
           m.optimal_stale_interval,
           GREATEST(0, FLOOR(EXTRACT(EPOCH FROM m.total_time_saved))::bigint) AS saved_seconds
      FROM approx_count.metrics AS m
),
formatted AS (
    SELECT metric_seconds.relid,
           metric_seconds.schemaname,
           metric_seconds.tablename,
           metric_seconds.total_calls_served,
           metric_seconds.total_analyzes_executed,
           metric_seconds.avg_full_count_duration,
           metric_seconds.total_time_saved,
           metric_seconds.total_analyze_duration,
           metric_seconds.last_analyze_duration,
           metric_seconds.max_analyze_duration,
           metric_seconds.optimal_stale_interval,
           metric_seconds.saved_seconds,
           metric_seconds.saved_seconds / 86400 AS saved_days,
           (metric_seconds.saved_seconds % 86400) / 3600 AS saved_hours,
           (metric_seconds.saved_seconds % 3600) / 60 AS saved_minutes,
           metric_seconds.saved_seconds % 60 AS saved_remaining_seconds
      FROM metric_seconds
)
SELECT formatted.relid,
       formatted.schemaname,
       formatted.tablename,
       formatted.total_calls_served,
       formatted.total_analyzes_executed,
       GREATEST(formatted.total_calls_served - formatted.total_analyzes_executed, 0) AS count_scans_prevented,
       formatted.avg_full_count_duration,
       formatted.total_time_saved,
       formatted.total_analyze_duration,
       formatted.last_analyze_duration,
       formatted.max_analyze_duration,
       formatted.optimal_stale_interval,
       CONCAT_WS(
           ' ',
           CASE WHEN formatted.saved_days > 0 THEN formatted.saved_days::text || 'd' END,
           CASE WHEN formatted.saved_hours > 0 THEN formatted.saved_hours::text || 'h' END,
           CASE WHEN formatted.saved_minutes > 0 THEN formatted.saved_minutes::text || 'm' END,
           CASE
               WHEN formatted.saved_seconds = 0 THEN '0s'
               ELSE formatted.saved_remaining_seconds::text || 's'
           END
       ) AS total_time_saved_pretty,
       CASE
           WHEN formatted.total_calls_served = 0 THEN '100.0000%'
           ELSE TO_CHAR(
               (
                   GREATEST(
                       formatted.total_calls_served - formatted.total_analyzes_executed,
                       0
                   )::numeric * 100
               ) / formatted.total_calls_served::numeric,
               'FM999999990.0000'
           ) || '%'
       END AS analyze_avoidance_ratio
  FROM formatted;

-- Privilege model: these functions write the ledger and (on the stale path) run
-- ANALYZE as the caller, so they are not world-executable by default. Operators
-- grant them explicitly to the roles that need them (see README / setup_role.sql).
REVOKE EXECUTE ON FUNCTION approx_count.approx_count_info(regclass, interval, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION approx_count.approx_count(regclass, interval, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION approx_count.tune_thresholds() FROM PUBLIC;

-- Catalog documentation: surface the contract and caveats in \dn+, \d+, \df+.
COMMENT ON SCHEMA approx_count IS
    'approx_count: fast row-count estimates from pg_class.reltuples with a governed, advisory-lock-serialized ANALYZE refresh.';

COMMENT ON TABLE approx_count.metrics IS
    'Per-relation ledger of approx_count activity, keyed by relation OID (with denormalized schema/name for display). OID keying survives a rename; a dropped relation leaves an orphan row until tune_thresholds() garbage-collects it, and a recreated table starts a fresh row.';
COMMENT ON COLUMN approx_count.metrics.relid IS 'OID of the relation this ledger row describes (primary key).';
COMMENT ON COLUMN approx_count.metrics.schemaname IS 'Schema of the relation as of the most recent call (denormalized for display).';
COMMENT ON COLUMN approx_count.metrics.tablename IS 'Name of the relation as of the most recent call (denormalized for display).';
COMMENT ON COLUMN approx_count.metrics.total_calls_served IS 'Count of approx_count() calls recorded for this relation (subject to approx_count.sample_rate; not recorded in read-only/standby contexts).';
COMMENT ON COLUMN approx_count.metrics.total_analyzes_executed IS 'Count of recorded calls that ran a foreground ANALYZE.';
COMMENT ON COLUMN approx_count.metrics.avg_full_count_duration IS 'Operator-supplied estimate of an exact COUNT(*) duration for this relation; used only to derive total_time_saved. Defaults to 15 seconds.';
COMMENT ON COLUMN approx_count.metrics.total_time_saved IS 'Estimated cumulative time avoided, accrued only on calls that did not run ANALYZE. An estimate, not a measurement.';
COMMENT ON COLUMN approx_count.metrics.total_analyze_duration IS 'Measured cumulative wall-clock time spent in foreground ANALYZE for this relation.';
COMMENT ON COLUMN approx_count.metrics.last_analyze_duration IS 'Measured duration of the most recent foreground ANALYZE for this relation.';
COMMENT ON COLUMN approx_count.metrics.max_analyze_duration IS 'Measured longest foreground ANALYZE observed for this relation.';
COMMENT ON COLUMN approx_count.metrics.optimal_stale_interval IS 'Fallback stale threshold used when approx_count() is called with NULL max_stale; maintained by tune_thresholds().';

COMMENT ON FUNCTION approx_count.approx_count_info(regclass, interval, boolean) IS
    'Like approx_count(), but returns (estimated_rows, stats_at, refreshed, mods_since_analyze): the estimate, the statistics timestamp it is based on, whether this call ran a foreground ANALYZE, and the inserts/updates/deletes since that analyze (n_mod_since_analyze, a churn-based ceiling on the count''s error readable without a COUNT(*)). Lets a caller see how old the number is and how far it could have drifted. Honors approx_count.max_refresh_wait.';

COMMENT ON FUNCTION approx_count.approx_count(regclass, interval, boolean) IS
    'Estimated row count from pg_class.reltuples for a table, partitioned table, materialized view, foreign table, or index, refreshing stale statistics with a governed, advisory-lock-serialized ANALYZE. For an index the estimate is its own reltuples (for a partial index, an approximate count of rows matching its predicate), and the refresh routes through the underlying table. With approx_count.max_refresh_wait set, serves the current estimate instead of waiting when the relation is lock-busy. Returns a best-effort estimate without refresh or metrics in read-only transactions and on standbys. A planner estimate, not a snapshot-exact count; use COUNT(*) when MVCC-exact correctness is required.';

COMMENT ON FUNCTION approx_count.tune_thresholds() IS
    'Optional fallback tuner: recomputes metrics.optimal_stale_interval per relation from observed read pressure vs. tree-aggregated write volatility. Prefer per-table autovacuum_analyze_scale_factor where autovacuum can keep stats fresh; reserve this for partition parents and autovacuum-disabled tables.';

COMMENT ON VIEW approx_count.dashboard IS
    'Human-readable view over metrics: calls served, analyzes executed, scans avoided, estimated time saved, measured ANALYZE durations, and analyze-avoidance ratio. Figures derived from avg_full_count_duration are estimates.';

COMMIT;
