#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:5432/postgres}"

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -c "SELECT version();"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -f install.sql

pgtap_output="$(mktemp)"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -f test_approx_count.sql | tee "${pgtap_output}"
if grep -Eq '^[[:space:]]*not ok|Looks like you failed' "${pgtap_output}"; then
    echo "pgTAP reported a failing assertion." >&2
    exit 1
fi

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -f ci/plpgsql_coverage.sql
DATABASE_URL="${DATABASE_URL}" bash ./concurrency_test.sh
DATABASE_URL="${DATABASE_URL}" bash ./refresh_guard_test.sh
DATABASE_URL="${DATABASE_URL}" bash ./index_support_test.sh

# Verify the packaged extension path (PGXS make install + CREATE EXTENSION) in a
# separate database so it does not collide with the script-path objects above,
# and assert DROP EXTENSION cleanly uninstalls everything. Build from a writable
# copy because the workspace is mounted read-only.
echo "=== verifying CREATE EXTENSION path ==="
build_dir="$(mktemp -d)"
cp Makefile approx_count.control "${build_dir}/"
mkdir -p "${build_dir}/sql"
cp sql/approx_count--*.sql "${build_dir}/sql/"
make -C "${build_dir}" install

psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -c "DROP DATABASE IF EXISTS approx_count_ext_check;"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -X -c "CREATE DATABASE approx_count_ext_check;"
ext_url="${DATABASE_URL%/*}/approx_count_ext_check"
psql "${ext_url}" -v ON_ERROR_STOP=1 -X <<'SQL'
-- The control pins schema=approx_count, so no SCHEMA clause is needed and the
-- schema is created automatically (a bare CREATE EXTENSION cannot land in public).
CREATE EXTENSION approx_count;
CREATE TABLE ext_probe AS SELECT g AS id FROM generate_series(1, 500) AS g;
SELECT approx_count.approx_count('ext_probe'::regclass, interval '0 seconds', false) AS ext_est;
DROP EXTENSION approx_count;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'approx_count'
    ) THEN
        RAISE EXCEPTION 'DROP EXTENSION left functions behind in schema approx_count';
    END IF;
END
$$;
SQL
echo "=== CREATE EXTENSION path verified (clean install + uninstall) ==="
