#!/usr/bin/env bash
# Pre-builds the approx_count demo database so the recording never shows the slow
# table build. Run this once before `vhs demo.tape`. It creates a ~220M-row events
# table large enough that a single-threaded exact filtered count genuinely scans for
# over a minute (lower(country) ~ '^us$' over 220M rows takes ~1m26s, the table is
# ~11 GB so it does not fit in cache, and a throttled ANALYZE takes ~8s), adds a
# PARTIAL index on an EXPRESSION predicate (rows where lower(country) = 'us'),
# installs approx_count, and ANALYZEs so the estimate has fresh stats.
set -euo pipefail

DB=approx_count_demo
ROWS=${ROWS:-220000000}

dropdb --if-exists "$DB"
createdb "$DB"
psql -d "$DB" -v ON_ERROR_STOP=1 -f install.sql >/dev/null

psql -d "$DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
SET max_parallel_workers_per_gather=0;
SET maintenance_work_mem='512MB';
CREATE TABLE public.events AS
SELECT g AS id,
       (ARRAY['US','us','CA','GB','DE','FR','JP','IN'])[1 + (g % 8)] AS country,
       (random()*1000)::numeric(10,2) AS amount,
       (timestamp '2024-01-01' + (g % 86400) * interval '1 second') AS created_at
FROM generate_series(1, ${ROWS}) AS g;

-- The killer feature: a PARTIAL index whose predicate is an EXPRESSION.
-- approx_count('events_us_idx'::regclass) returns this index's reltuples, which
-- is an approximate count of just the rows matching lower(country) = 'us' --
-- without scanning the table.
CREATE INDEX events_us_idx ON public.events (id) WHERE lower(country) = 'us';

ANALYZE public.events;
SQL

# Warm up once so the recorded filtered count is a steady ~1m26s, not skewed by a
# one-off cold read. The filtered count stays minutes-long either way: at 220M rows
# it is bound by the per-row lower()+regexp work, not by I/O caching.
psql -d "$DB" -c "SET max_parallel_workers_per_gather=0;" -c "SELECT count(*) FROM public.events WHERE lower(country) ~ '^us\$';" >/dev/null

echo "demo db ready: $DB ($ROWS rows, partial expression index events_us_idx)"
