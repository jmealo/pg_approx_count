#!/usr/bin/env bash
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
    echo "psql is required but was not found in PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="${TMPDIR:-/tmp}/approx_count_concurrency_$(date +%Y%m%d_%H%M%S)_$$"
READY_FILE="${LOG_DIR}/lock_holder.ready"
HOLDER_LOG="${LOG_DIR}/lock_holder.log"
LOCK_HOLDER_PID=""

mkdir -p "${LOG_DIR}"

cleanup() {
    if [[ -n "${LOCK_HOLDER_PID}" ]] && kill -0 "${LOCK_HOLDER_PID}" >/dev/null 2>&1; then
        wait "${LOCK_HOLDER_PID}" || true
    fi
}
trap cleanup EXIT

psql_base() {
    if [[ -n "${DATABASE_URL:-}" ]]; then
        psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X "$@"
    else
        psql -v ON_ERROR_STOP=1 -X "$@"
    fi
}

echo "Installing approx_count from ${SCRIPT_DIR}/install.sql"
psql_base -q -f "${SCRIPT_DIR}/install.sql"

echo "Creating public.concurrency_race_test with exactly 1,000,000 random rows"
psql_base -q <<'SQL'
DROP TABLE IF EXISTS public.concurrency_race_test;

CREATE UNLOGGED TABLE public.concurrency_race_test (
    id bigint NOT NULL,
    payload text NOT NULL,
    shard_key integer NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT clock_timestamp()
) WITH (autovacuum_enabled = false);

INSERT INTO public.concurrency_race_test (id, payload, shard_key)
SELECT g,
       md5(g::text || ':' || random()::text || ':' || clock_timestamp()::text),
       (random() * 1000000)::integer
  FROM generate_series(1, 1000000) AS g;

DO $$
DECLARE
    _rows_loaded bigint;
BEGIN
    SELECT count(*) INTO _rows_loaded
      FROM public.concurrency_race_test;

    IF _rows_loaded <> 1000000 THEN
        RAISE EXCEPTION 'expected 1,000,000 rows in public.concurrency_race_test, found %', _rows_loaded;
    END IF;
END;
$$;

DELETE FROM approx_count.metrics
 WHERE schemaname = 'public'
   AND tablename = 'concurrency_race_test';
SQL

echo "Holding the same transaction-level advisory lock so all workers queue together"
psql_base -q >"${HOLDER_LOG}" 2>&1 <<SQL &
BEGIN;
SELECT pg_advisory_xact_lock('public.concurrency_race_test'::regclass::oid::bigint);
\! touch "${READY_FILE}"
SELECT pg_sleep(6);
COMMIT;
SQL
LOCK_HOLDER_PID="$!"

for _attempt in {1..100}; do
    if [[ -f "${READY_FILE}" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -f "${READY_FILE}" ]]; then
    echo "The advisory lock holder did not become ready." >&2
    echo "Lock holder log:" >&2
    cat "${HOLDER_LOG}" >&2
    exit 1
fi

echo "Launching 5 parallel approx_count workers with max_stale = '0 seconds'"
worker_pids=()
for session_id in 1 2 3 4 5; do
    (
        psql_base -q -c "SET client_min_messages = notice; SET application_name = 'Session ${session_id}'; SELECT approx_count.approx_count('public.concurrency_race_test'::regclass, interval '0 seconds', true) AS estimated_count;"
    ) >"${LOG_DIR}/session_${session_id}.log" 2>&1 &
    worker_pids+=("$!")
done

worker_failures=0
for worker_pid in "${worker_pids[@]}"; do
    if ! wait "${worker_pid}"; then
        worker_failures=1
    fi
done

wait "${LOCK_HOLDER_PID}"
LOCK_HOLDER_PID=""

echo
echo "Collected worker logs from ${LOG_DIR}"
for session_log in "${LOG_DIR}"/session_*.log; do
    echo "===== ${session_log##*/} ====="
    cat "${session_log}"
done

if [[ "${worker_failures}" -ne 0 ]]; then
    echo "At least one worker session failed." >&2
    exit 1
fi

executed_count="$({ grep -h "ANALYZE EXECUTED: Physical ANALYZE completed." "${LOG_DIR}"/session_*.log || true; } | wc -l | tr -d ' ')"
skipped_count="$({ grep -h "ANALYZE SKIPPED: Concurrency guard caught it." "${LOG_DIR}"/session_*.log || true; } | wc -l | tr -d ' ')"

if [[ "${executed_count}" -ne 1 ]]; then
    echo "Expected exactly 1 physical ANALYZE execution, observed ${executed_count}." >&2
    exit 1
fi

if [[ "${skipped_count}" -ne 4 ]]; then
    echo "Expected exactly 4 concurrency-guard skips, observed ${skipped_count}." >&2
    exit 1
fi

echo
echo "Concurrency invariant verified: exactly one ANALYZE executed and four sessions skipped after the double-check."

psql_base -q <<'SQL'
DO $$
DECLARE
    _metric_rows integer;
    _calls bigint;
    _analyzes bigint;
BEGIN
    SELECT count(*),
           COALESCE(sum(total_calls_served), 0),
           COALESCE(sum(total_analyzes_executed), 0)
      INTO _metric_rows, _calls, _analyzes
      FROM approx_count.metrics
     WHERE schemaname = 'public'
       AND tablename = 'concurrency_race_test';

    IF _metric_rows <> 1 OR _calls <> 5 OR _analyzes <> 1 THEN
        RAISE EXCEPTION 'expected one metric row with 5 calls and 1 analyze, found rows=%, calls=%, analyzes=%',
            _metric_rows, _calls, _analyzes;
    END IF;
END;
$$;

\x on
SELECT schemaname,
       tablename,
       total_calls_served,
       total_analyzes_executed,
       count_scans_prevented,
       total_time_saved_pretty,
       analyze_avoidance_ratio
  FROM approx_count.dashboard
 WHERE schemaname = 'public'
   AND tablename = 'concurrency_race_test';
SQL
