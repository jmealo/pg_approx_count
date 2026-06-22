\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS plpgsql_check;

SET plpgsql_check.profiler = on;

DROP TABLE IF EXISTS public.coverage_approx_count_empty;
DROP TABLE IF EXISTS public.coverage_approx_count_partitioned CASCADE;
DROP SEQUENCE IF EXISTS public.coverage_approx_count_sequence;

CREATE TABLE public.coverage_approx_count_empty (
    id bigint NOT NULL,
    payload text NOT NULL
);

CREATE TABLE public.coverage_approx_count_partitioned (
    id integer NOT NULL,
    payload text NOT NULL
) PARTITION BY RANGE (id);

CREATE TABLE public.coverage_approx_count_partitioned_1
    PARTITION OF public.coverage_approx_count_partitioned
    FOR VALUES FROM (1) TO (100000);

INSERT INTO public.coverage_approx_count_partitioned (id, payload)
SELECT g, md5(g::text || ':' || random()::text)
  FROM generate_series(1, 2500) AS g;

CREATE SEQUENCE public.coverage_approx_count_sequence;

DELETE FROM approx_count.metrics
 WHERE schemaname = 'public'
   AND tablename IN (
       'coverage_approx_count_empty',
       'coverage_approx_count_partitioned',
       'coverage_approx_count_sequence'
   );

SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '1 day', true);
SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '1 day', true);

UPDATE approx_count.metrics
   SET optimal_stale_interval = interval '0 seconds'
 WHERE schemaname = 'public'
   AND tablename = 'coverage_approx_count_empty';

SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, NULL, true);
SELECT approx_count.approx_count('public.coverage_approx_count_partitioned'::regclass, interval '0 seconds', true);

DO $$
BEGIN
    PERFORM approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '-1 second', false);
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
$$;

DO $$
BEGIN
    PERFORM approx_count.approx_count('public.coverage_approx_count_sequence'::regclass, NULL, false);
EXCEPTION
    WHEN wrong_object_type THEN
        NULL;
END;
$$;

-- Exercise the read-only / standby branch: a best-effort estimate with no
-- ANALYZE and no ledger write, plus the early read-only RETURN.
SET default_transaction_read_only = on;
SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '0 seconds', true);
SET default_transaction_read_only = off;

-- Exercise the defensive sample_rate parse: a non-numeric value must
-- fall back to 1.0 rather than erroring the query.
SET approx_count.sample_rate = 'not-a-number';
SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '1 day', false);
RESET approx_count.sample_rate;

-- Exercise the sampling-off branch (no ledger write).
SET approx_count.sample_rate = '0';
SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '1 day', false);
RESET approx_count.sample_rate;

-- Exercise the max_refresh_wait parse + lock_timeout set_config branch (the
-- table is not contended here, so the refresh still runs; the parse path is hit).
SET approx_count.max_refresh_wait = '100ms';
SELECT approx_count.approx_count('public.coverage_approx_count_empty'::regclass, interval '0 seconds', false);
RESET approx_count.max_refresh_wait;

-- Exercise approx_count_info's record-return path directly.
SELECT estimated_rows, stats_at, refreshed
  FROM approx_count.approx_count_info('public.coverage_approx_count_empty'::regclass, interval '1 day', false);

SELECT approx_count.tune_thresholds();

CREATE TEMP TABLE approx_count_plpgsql_coverage AS
SELECT 'approx_count.approx_count_info(regclass,interval,boolean)'::text AS function_signature,
       p.*
  FROM plpgsql_profiler_function_tb('approx_count.approx_count_info(regclass,interval,boolean)'::regprocedure) AS p
UNION ALL
SELECT 'approx_count.tune_thresholds()'::text AS function_signature,
       p.*
  FROM plpgsql_profiler_function_tb('approx_count.tune_thresholds()'::regprocedure) AS p;

\echo 'PL/pgSQL statement coverage report'

WITH coverage AS (
    SELECT function_signature,
           count(*) FILTER (WHERE cmds_on_row > 0) AS executable_statement_rows,
           count(*) FILTER (
               WHERE cmds_on_row > 0
                 AND COALESCE(
                     (
                         SELECT bool_or(statement_exec_count > 0)
                           FROM unnest(exec_stmts) AS statement_exec_count
                     ),
                     false
                 )
           ) AS covered_statement_rows
      FROM approx_count_plpgsql_coverage
     GROUP BY function_signature
),
scored AS (
    SELECT function_signature,
           executable_statement_rows,
           covered_statement_rows,
           ROUND((covered_statement_rows::numeric * 100) / NULLIF(executable_statement_rows, 0), 2) AS coverage_percent
      FROM coverage
)
SELECT function_signature,
       executable_statement_rows,
       covered_statement_rows,
       coverage_percent
  FROM scored
 ORDER BY function_signature;

DO $$
DECLARE
    _minimum_coverage numeric := 55.00;
    _failing_functions text;
BEGIN
    WITH coverage AS (
        SELECT function_signature,
               count(*) FILTER (WHERE cmds_on_row > 0) AS executable_statement_rows,
               count(*) FILTER (
                   WHERE cmds_on_row > 0
                     AND COALESCE(
                         (
                             SELECT bool_or(statement_exec_count > 0)
                               FROM unnest(exec_stmts) AS statement_exec_count
                         ),
                         false
                     )
               ) AS covered_statement_rows
          FROM approx_count_plpgsql_coverage
         GROUP BY function_signature
    ),
    scored AS (
        SELECT function_signature,
               ROUND((covered_statement_rows::numeric * 100) / NULLIF(executable_statement_rows, 0), 2) AS coverage_percent
          FROM coverage
    )
    SELECT string_agg(function_signature || ' = ' || coverage_percent::text || '%', ', ' ORDER BY function_signature)
      INTO _failing_functions
      FROM scored
     WHERE coverage_percent < _minimum_coverage;

    IF _failing_functions IS NOT NULL THEN
        RAISE EXCEPTION 'PL/pgSQL statement coverage below %: %', _minimum_coverage, _failing_functions;
    END IF;
END;
$$;
