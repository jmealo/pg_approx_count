#!/usr/bin/env bash
# Integration test for native index support.
#
# approx_count() on a partial (conditional) index returns the index's reltuples,
# which is an approximate count of the rows matching its predicate. Freshness and
# the ANALYZE refresh route through the underlying table. This test asserts the
# approximate filtered counts land within tolerance of the exact counts, that a
# call on a never-analyzed table's index refreshes via that table, and that a
# partitioned index is rejected.
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
    echo "psql is required but was not found in PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

psql_base() {
    if [[ -n "${DATABASE_URL:-}" ]]; then
        psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X "$@"
    else
        psql -v ON_ERROR_STOP=1 -X "$@"
    fi
}

scalar() {
    local out
    out="$(psql_base -tAc "$1")"
    echo "${out//[[:space:]]/}"
}

cleanup() {
    psql_base -q -c "DROP TABLE IF EXISTS public.idx_test, public.idx_fresh, public.idx_part CASCADE;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Installing approx_count from ${SCRIPT_DIR}/install.sql"
psql_base -q -f "${SCRIPT_DIR}/install.sql"

echo "Building fixtures (table + partial indexes, an unanalyzed table, a partitioned index)"
psql_base -q <<'SQL'
DROP TABLE IF EXISTS public.idx_test, public.idx_fresh, public.idx_part CASCADE;

CREATE TABLE public.idx_test (id bigint, country text, amount numeric);
ALTER TABLE public.idx_test SET (autovacuum_enabled = false);
INSERT INTO public.idx_test
SELECT g, (ARRAY['US','CA','US','GB'])[1 + (g % 4)], (g % 1000)
  FROM generate_series(1, 300000) AS g;
CREATE INDEX idx_test_us  ON public.idx_test (id) WHERE country = 'US';        -- literal predicate
CREATE INDEX idx_test_lus ON public.idx_test (id) WHERE lower(country) = 'us'; -- expression predicate
CREATE INDEX idx_test_big ON public.idx_test (id) WHERE amount > 900;          -- expression predicate
ANALYZE public.idx_test;

-- never analyzed: a call on its index must drive an ANALYZE of this table
CREATE TABLE public.idx_fresh (id int, k text);
ALTER TABLE public.idx_fresh SET (autovacuum_enabled = false);
INSERT INTO public.idx_fresh
SELECT g, CASE WHEN g % 5 = 0 THEN 'y' ELSE 'n' END FROM generate_series(1, 50000) AS g;
CREATE INDEX idx_fresh_y ON public.idx_fresh (id) WHERE k = 'y';

-- partitioned index (relkind I) must be rejected
CREATE TABLE public.idx_part (id int, k text) PARTITION BY RANGE (id);
CREATE TABLE public.idx_part1 PARTITION OF public.idx_part FOR VALUES FROM (0) TO (1000000);
ALTER TABLE public.idx_part1 SET (autovacuum_enabled = false);
CREATE INDEX idx_part_y ON public.idx_part (id) WHERE k = 'y';

DELETE FROM approx_count.metrics WHERE schemaname = 'public';
SQL

assert_within() {
    local idx="$1" exact="$2" approx lo hi
    approx="$(scalar "SELECT approx_count.approx_count('public.${idx}'::regclass);")"
    lo=$(( exact * 90 / 100 ))
    hi=$(( exact * 110 / 100 ))
    if (( approx < lo || approx > hi )); then
        echo "FAIL: ${idx} approx=${approx} not within 10% of exact=${exact}" >&2
        exit 1
    fi
    echo "OK: ${idx} approx=${approx} ~ exact=${exact}"
}

us_exact="$(scalar "SELECT count(*) FROM public.idx_test WHERE country = 'US';")"
lus_exact="$(scalar "SELECT count(*) FROM public.idx_test WHERE lower(country) = 'us';")"
big_exact="$(scalar "SELECT count(*) FROM public.idx_test WHERE amount > 900;")"

assert_within idx_test_us  "${us_exact}"
assert_within idx_test_lus "${lus_exact}"
assert_within idx_test_big "${big_exact}"

# A call on a never-analyzed table's index must refresh by analyzing that table.
# approx_count_info.refreshed is set true in the same transaction that runs the
# ANALYZE, so it is the deterministic signal that the underlying table was
# analyzed -- unlike pg_stat_all_tables.last_analyze, which on PG14 is published
# asynchronously by the legacy stats collector and reads NULL right after ANALYZE.
refreshed="$(scalar "SELECT refreshed FROM approx_count.approx_count_info('public.idx_fresh_y'::regclass, interval '0 seconds', false);")"
if [[ "${refreshed}" != "t" ]]; then
    echo "FAIL: index call on a never-analyzed table did not analyze the underlying table (refreshed='${refreshed}')." >&2
    exit 1
fi
echo "OK: index call on a never-analyzed table refreshed via the underlying table"

# The refresh must not only have happened, it must have produced a correct count:
# the now-analyzed partial index estimate must land within tolerance of its exact
# filtered count (50000 rows, every 5th has k = 'y', so ~10000).
fresh_exact="$(scalar "SELECT count(*) FROM public.idx_fresh WHERE k = 'y';")"
assert_within idx_fresh_y "${fresh_exact}"

# mods_since_analyze is the drift / margin-of-error signal: inserts/updates/deletes
# since the stats were taken, a conservative ceiling on the count's error readable
# without a COUNT(*). idx_fresh was just analyzed above (by the refresh on its index),
# so insert rows WITHOUT analyzing and confirm the drift shows up. n_mod_since_analyze
# is published synchronously only on PG15+ (shared-memory cumulative stats); on PG14
# the legacy collector publishes it asynchronously -- the same lag that makes
# last_analyze unreliable right after ANALYZE -- so the live-drift check is gated to
# PG15+ (made deterministic with pg_stat_force_next_flush). The reset-on-refresh check
# below is deterministic and runs on every version.
pgver="$(scalar "SELECT current_setting('server_version_num')::int;")"
if (( pgver >= 150000 )); then
    # Flush the writer's pending stats in the same session so the read is deterministic.
    psql_base -q -c "INSERT INTO public.idx_fresh SELECT g, 'n' FROM generate_series(100001, 105000) AS g; SELECT pg_stat_force_next_flush();"
    mods=0
    for _attempt in $(seq 1 10); do
        mods="$(scalar "SELECT mods_since_analyze FROM approx_count.approx_count_info('public.idx_fresh'::regclass, interval '1 hour');")"
        if [[ "${mods}" =~ ^[0-9]+$ ]] && (( mods > 0 )); then
            break
        fi
        sleep 0.5
    done
    if [[ ! "${mods}" =~ ^[0-9]+$ ]] || (( mods <= 0 )); then
        echo "FAIL: mods_since_analyze did not reflect un-analyzed inserts (got '${mods}')." >&2
        exit 1
    fi
    echo "OK: mods_since_analyze reflects drift since the last analyze (${mods} mods)"
else
    psql_base -q -c "INSERT INTO public.idx_fresh SELECT g, 'n' FROM generate_series(100001, 105000) AS g;"
    echo "SKIP: live-drift check on PG14 (n_mod_since_analyze is published asynchronously by the legacy stats collector)"
fi

# A forced refresh resets the drift signal to 0; it is set in the same transaction as
# the ANALYZE, so it is deterministic and not subject to stats-propagation lag.
mods_after="$(scalar "SELECT mods_since_analyze FROM approx_count.approx_count_info('public.idx_fresh'::regclass, interval '0 seconds');")"
if [[ "${mods_after}" != "0" ]]; then
    echo "FAIL: mods_since_analyze should reset to 0 after a forced refresh (got '${mods_after}')." >&2
    exit 1
fi
echo "OK: mods_since_analyze resets to 0 after a forced refresh"

# A partitioned index (relkind I) must be rejected.
if psql_base -tAc "SELECT approx_count.approx_count('public.idx_part_y'::regclass);" >/dev/null 2>&1; then
    echo "FAIL: a partitioned index was accepted; it should be rejected." >&2
    exit 1
fi
echo "OK: partitioned index rejected"

echo
echo "index support verified: partial indexes (literal and expression predicates) return approximate filtered counts within tolerance, the refresh routes through the underlying table, and partitioned indexes are rejected."
