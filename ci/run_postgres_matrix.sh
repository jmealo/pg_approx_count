#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

if [[ "$#" -gt 0 ]]; then
    PG_VERSIONS=("$@")
else
    read -r -a PG_VERSIONS <<< "${PG_VERSIONS:-14 15 16 17 18}"
fi

cleanup_container() {
    local container_name="$1"
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

for pg_major in "${PG_VERSIONS[@]}"; do
    image_name="pg-approx-count-test:${pg_major}"
    container_name="pg-approx-count-pg${pg_major}-$$"
    database_url="postgresql://postgres:postgres@127.0.0.1:5432/postgres"

    case "${pg_major}" in
        19) pg_image_tag="19beta1" ;;  # 19 has no GA image yet; test the beta
        *)  pg_image_tag="${pg_major}" ;;
    esac

    echo "=== Building ${image_name} (postgres:${pg_image_tag}) ==="
    docker build \
        --build-arg "PG_MAJOR=${pg_major}" \
        --build-arg "PG_IMAGE_TAG=${pg_image_tag}" \
        --tag "${image_name}" \
        --file "${ROOT_DIR}/ci/Dockerfile.pgtest" \
        "${ROOT_DIR}"

    echo "=== Starting PostgreSQL ${pg_major} test container ==="
    cleanup_container "${container_name}"
    docker run \
        --detach \
        --name "${container_name}" \
        --env POSTGRES_PASSWORD=postgres \
        --volume "${ROOT_DIR}:/workspace:ro" \
        --workdir /workspace \
        "${image_name}" >/dev/null

    trap 'cleanup_container "${container_name}"' EXIT

    for _attempt in {1..120}; do
        if docker exec "${container_name}" psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
            sleep 1
            if docker exec "${container_name}" psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
                break
            fi
        fi
        sleep 1
    done

    if ! docker exec "${container_name}" psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
        echo "PostgreSQL ${pg_major} did not become ready." >&2
        docker logs "${container_name}" >&2 || true
        exit 1
    fi

    echo "=== Running approx_count tests on PostgreSQL ${pg_major} ==="
    if ! docker exec \
        --env "DATABASE_URL=${database_url}" \
        "${container_name}" \
        bash ./ci/run_tests_in_container.sh; then
        echo "Test failure on PostgreSQL ${pg_major}." >&2
        docker logs "${container_name}" >&2 || true
        exit 1
    fi

    cleanup_container "${container_name}"
    trap - EXIT
    echo "=== PostgreSQL ${pg_major} passed ==="
done
