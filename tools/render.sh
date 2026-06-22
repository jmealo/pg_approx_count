#!/usr/bin/env bash
# Generate the schema-specific build artifacts from the canonical sources:
#   - approx_count.control  (from approx_count.control.in; pins the extension schema)
#   - install.sql            (from sql/approx_count--1.0.sql; the plain-SQL package)
# Default schema: approx_count. Override with: SCHEMA=myschema ./tools/render.sh
set -euo pipefail

SCHEMA="${SCHEMA:-approx_count}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

case "${SCHEMA}" in
    pg_*|information_schema)
        echo "Refusing to render: '${SCHEMA}' is a reserved schema name." >&2
        exit 1 ;;
esac
if [[ ! "${SCHEMA}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "Refusing to render: SCHEMA '${SCHEMA}' is not a plain unquoted identifier." >&2
    exit 1
fi

# 1. Extension control file (pins the install schema).
sed "s/@PGFC_SCHEMA@/${SCHEMA}/g" "${ROOT}/approx_count.control.in" > "${ROOT}/approx_count.control"

# 2. Plain-SQL installer (no build tools required).
{
    echo "-- GENERATED FROM sql/approx_count--1.0.sql by tools/render.sh. DO NOT EDIT."
    echo "--"
    echo "-- Plain-SQL install of approx_count into schema \"${SCHEMA}\" (no build tools):"
    echo "--   psql \"\$DATABASE_URL\" -v ON_ERROR_STOP=1 -f install.sql"
    echo "--"
    echo "-- Or install it as an extension: make install && CREATE EXTENSION approx_count;"
    echo "-- Retarget the schema for both artifacts with: SCHEMA=<schema> ./tools/render.sh"
    echo ""
    echo "BEGIN;"
    echo ""
    echo "CREATE SCHEMA IF NOT EXISTS ${SCHEMA};"
    echo ""
    sed "s/@extschema@/${SCHEMA}/g" "${ROOT}/sql/approx_count--1.0.sql"
    echo ""
    echo "COMMIT;"
} > "${ROOT}/install.sql"

echo "Rendered approx_count.control and install.sql (schema=${SCHEMA})"
