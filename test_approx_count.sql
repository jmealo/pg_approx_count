BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(7);

SELECT has_table(
    'approx_count',
    'metrics',
    'approx_count.metrics exists'
);

SELECT has_column(
    'approx_count',
    'metrics',
    'optimal_stale_interval',
    'approx_count.metrics tracks optimal_stale_interval'
);

SELECT has_pk(
    'approx_count',
    'metrics',
    'approx_count.metrics has a primary key'
);

SELECT is(
    (
        SELECT string_agg(a.attname, ',' ORDER BY key_columns.ordinality)
          FROM pg_index AS i
          JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS key_columns(attnum, ordinality)
            ON true
          JOIN pg_attribute AS a
            ON a.attrelid = i.indrelid
           AND a.attnum = key_columns.attnum
         WHERE i.indrelid = 'approx_count.metrics'::regclass
           AND i.indisprimary
    ),
    'relid',
    'approx_count.metrics primary key is exactly (relid)'
);

DROP TABLE IF EXISTS public.pgtap_approx_count_unanalyzed;

CREATE TABLE public.pgtap_approx_count_unanalyzed (
    id bigint NOT NULL,
    payload text NOT NULL
);

DELETE FROM approx_count.metrics
 WHERE schemaname = 'public'
   AND tablename = 'pgtap_approx_count_unanalyzed';

SELECT is(
    approx_count.approx_count('public.pgtap_approx_count_unanalyzed'::regclass, interval '1 day', false),
    0::bigint,
    'an un-analyzed freshly created table returns 0 instead of -1'
);

SELECT results_eq(
    $$
    SELECT total_calls_served, total_analyzes_executed, optimal_stale_interval
      FROM approx_count.metrics
     WHERE schemaname = 'public'
       AND tablename = 'pgtap_approx_count_unanalyzed'
    $$,
    $$
    VALUES (1::bigint, 1::bigint, interval '10 minutes')
    $$,
    'the first function call records metrics and the default optimal stale interval'
);

UPDATE approx_count.metrics
   SET optimal_stale_interval = interval '0 seconds'
 WHERE schemaname = 'public'
   AND tablename = 'pgtap_approx_count_unanalyzed';

SELECT approx_count.approx_count('public.pgtap_approx_count_unanalyzed'::regclass, NULL, false);

SELECT results_eq(
    $$
    SELECT m.total_calls_served, m.total_analyzes_executed
      FROM approx_count.metrics AS m
     WHERE m.schemaname = 'public'
       AND m.tablename = 'pgtap_approx_count_unanalyzed'
    $$,
    $$
    VALUES (2::bigint, 2::bigint)
    $$,
    'a NULL max_stale parameter falls back to the ledger optimal_stale_interval'
);

SELECT * FROM finish();

ROLLBACK;
