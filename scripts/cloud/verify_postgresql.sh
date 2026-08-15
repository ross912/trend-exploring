#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
migration_path="${project_root}/schema/postgres/001_m1_core.sql"
smoke_path="${project_root}/schema/postgres/test/001_catalog_smoke.sql"

database_url="${M1_DATABASE_URL:-${CLOUD_DATABASE_URL:-}}"
if [[ -z "${database_url}" ]]; then
  echo "ERROR: set M1_DATABASE_URL (or CLOUD_DATABASE_URL) to a disposable, empty PostgreSQL database." >&2
  exit 1
fi

if [[ "${M1_CONFIRM_DISPOSABLE_DATABASE:-${CLOUD_CONFIRM_DISPOSABLE_DATABASE:-}}" != "YES" ]]; then
  echo "ERROR: set M1_CONFIRM_DISPOSABLE_DATABASE=YES after verifying the target is disposable." >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed." >&2
  exit 1
fi

server_version="$(psql -XAt "${database_url}" -v ON_ERROR_STOP=1 -c "SHOW server_version_num")"
server_major="$((server_version / 10000))"
if (( server_major < 15 )); then
  echo "ERROR: PostgreSQL 15+ is required; server reports ${server_version}." >&2
  exit 1
fi

listen_addresses="$(psql -XAt "${database_url}" -v ON_ERROR_STOP=1 -c "SHOW listen_addresses")"
if [[ "${listen_addresses}" != "localhost" && "${listen_addresses}" != "127.0.0.1" && "${listen_addresses}" != "" ]]; then
  echo "ERROR: PostgreSQL listen_addresses is not loopback-only (${listen_addresses}); refusing validation." >&2
  exit 1
fi

existing_relations="$(psql -XAt "${database_url}" -v ON_ERROR_STOP=1 -c "
  SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND n.nspname !~ '^pg_toast'
     AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f');
")"

if [[ "${existing_relations}" != "0" ]]; then
  echo "ERROR: target database is not empty (${existing_relations} user relations); refusing migration." >&2
  exit 1
fi

psql -X "${database_url}" -v ON_ERROR_STOP=1 -f "${migration_path}"
psql -X "${database_url}" -v ON_ERROR_STOP=1 -f "${smoke_path}"

echo "POSTGRESQL MIGRATION VALIDATION PASSED"
