#!/usr/bin/env bash
# Integration test for approx_count.max_refresh_wait (the "serve stale instead of
# blocking behind a table operation" guard).
#
# One session holds SHARE UPDATE EXCLUSIVE on a table (the same lock class ANALYZE
# needs, as CREATE INDEX CONCURRENTLY / VACUUM would). A second session forces the
# stale path with max_refresh_wait set and must return the existing estimate
# promptly WITHOUT running ANALYZE, rather than queuing behind the lock holder.
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
    echo "psql is required but was not found in PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="${TMPDIR:-/tmp}/approx_count_refresh_guard_$(date +%Y%m%d_%H%M%S)_$$"
READY_FILE="${LOG_DIR}/holder.ready"
HOLDER_LOG="${LOG_DIR}/holder.log"
HOLDER_PID=""
LOCK_HOLD_SECONDS=8

mkdir -p "${LOG_DIR}"

psql_base() {
    if [[ -n "${DATABASE_URL:-}" ]]; then
        psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X "$@"
    else
        psql -v ON_ERROR_STOP=1 -X "$@"
    fi
}

cleanup() {
    if [[ -n "${HOLDER_PID}" ]] && kill -0 "${HOLDER_PID}" >/dev/null 2>&1; then
        wait "${HOLDER_PID}" || true
    fi
}
trap cleanup EXIT

echo "Installing approx_count from ${SCRIPT_DIR}/install.sql"
psql_base -q -f "${SCRIPT_DIR}/install.sql"

echo "Creating public.refresh_guard_test with a fresh ANALYZE baseline"
psql_base -q <<'SQL'
DROP TABLE IF EXISTS public.refresh_guard_test;
CREATE TABLE public.refresh_guard_test (id bigint NOT NULL, payload text NOT NULL);
INSERT INTO public.refresh_guard_test
SELECT g, md5(g::text) FROM generate_series(1, 50000) AS g;
ANALYZE public.refresh_guard_test;
DELETE FROM approx_count.metrics
 WHERE schemaname = 'public' AND tablename = 'refresh_guard_test';
SQL

echo "Holding SHARE UPDATE EXCLUSIVE on the table (conflicts with ANALYZE) for ${LOCK_HOLD_SECONDS}s"
psql_base -q >"${HOLDER_LOG}" 2>&1 <<SQL &
BEGIN;
LOCK TABLE public.refresh_guard_test IN SHARE UPDATE EXCLUSIVE MODE;
\! touch "${READY_FILE}"
SELECT pg_sleep(${LOCK_HOLD_SECONDS});
COMMIT;
SQL
HOLDER_PID="$!"

for _attempt in {1..100}; do
    [[ -f "${READY_FILE}" ]] && break
    sleep 0.1
done
if [[ ! -f "${READY_FILE}" ]]; then
    echo "The lock holder did not become ready." >&2
    cat "${HOLDER_LOG}" >&2
    exit 1
fi

echo "Calling approx_count with max_refresh_wait=200ms and max_stale=0 (forced stale)"
worker_log="${LOG_DIR}/worker.log"
start_ns="$(date +%s)"
psql_base -q -c "SET client_min_messages = notice;" \
              -c "SET approx_count.max_refresh_wait = '200ms';" \
              -c "SELECT approx_count.approx_count('public.refresh_guard_test'::regclass, interval '0 seconds', true) AS estimated_count;" \
              >"${worker_log}" 2>&1
end_ns="$(date +%s)"
elapsed=$(( end_ns - start_ns ))

echo "===== worker output ====="
cat "${worker_log}"
echo "========================="

# 1. It must have served stale (skipped the refresh because the table was lock-busy).
if ! grep -q "REFRESH SKIPPED" "${worker_log}"; then
    echo "FAIL: expected a REFRESH SKIPPED notice (the guard did not trigger)." >&2
    exit 1
fi

# 2. It must have returned the estimate, not errored.
if ! grep -Eq "^[[:space:]]*50000$" "${worker_log}"; then
    echo "FAIL: expected the estimate 50000 to be returned." >&2
    exit 1
fi

# 3. It must NOT have blocked for the full lock hold (it should bail at ~200ms).
if [[ "${elapsed}" -ge $(( LOCK_HOLD_SECONDS - 1 )) ]]; then
    echo "FAIL: the call took ${elapsed}s; it should have served stale in well under ${LOCK_HOLD_SECONDS}s." >&2
    exit 1
fi

# 4. No ANALYZE should have been recorded for the relation.
analyzes="$(psql_base -tAc "SELECT COALESCE(total_analyzes_executed, 0) FROM approx_count.metrics WHERE schemaname='public' AND tablename='refresh_guard_test';")"
analyzes="${analyzes//[[:space:]]/}"
if [[ "${analyzes}" != "0" ]]; then
    echo "FAIL: expected 0 recorded ANALYZE for the lock-busy relation, got '${analyzes}'." >&2
    exit 1
fi

wait "${HOLDER_PID}"
HOLDER_PID=""

# 5. An out-of-range max_refresh_wait must NOT crash the call. Such a value passes
#    the unit regex but overflows lock_timeout (SQLSTATE 22023); the guard catches
#    that and falls back to no timeout, so with the lock now released the forced
#    refresh completes normally and returns the estimate instead of erroring.
echo "Checking that an out-of-range max_refresh_wait cannot crash the call"
overflow_log="${LOG_DIR}/overflow.log"
psql_base -q -c "SET approx_count.max_refresh_wait = '9999999999d';" \
              -c "SELECT approx_count.approx_count('public.refresh_guard_test'::regclass, interval '0 seconds', false) AS estimated_count;" \
              >"${overflow_log}" 2>&1
if ! grep -Eq "^[[:space:]]*50000$" "${overflow_log}"; then
    echo "FAIL: an out-of-range max_refresh_wait should fall back to no timeout and still return 50000." >&2
    cat "${overflow_log}" >&2
    exit 1
fi

echo
echo "max_refresh_wait verified: served the stale estimate (50000) in ${elapsed}s without ANALYZE while the table held ShareUpdateExclusiveLock; an out-of-range value fell back to no timeout without error."
