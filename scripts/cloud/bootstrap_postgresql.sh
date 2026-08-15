#!/usr/bin/env bash
# Idempotent PostgreSQL role/database bootstrap for the dedicated application
# account. It uses local peer authentication as the postgres OS account and
# never accepts or places a password in argv. No write occurs without
# --confirm; existing owners/superusers are never silently changed.
set -Eeuo pipefail

cloud_env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if [[ -r "${cloud_env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_env_file}"
fi

role_name="${CLOUD_PG_ROLE:-${LOCAL_PGUSER:-trendexploring}}"
global_db="${CLOUD_PG_GLOBAL_DATABASE:-${LOCAL_PGDATABASE:-trend_exploring}}"
personal_db="${CLOUD_PG_PERSONAL_DATABASE:-${PERSONAL_PGDATABASE:-trend_exploring_personal}}"
confirm=0
dry_run=0
while (($#)); do
  case "$1" in
    --role) role_name="${2:?--role needs a role name}"; shift 2 ;;
    --global-database) global_db="${2:?--global-database needs a database name}"; shift 2 ;;
    --personal-database) personal_db="${2:?--personal-database needs a database name}"; shift 2 ;;
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h)
      echo "Usage: bootstrap_postgresql.sh [--dry-run] [--confirm] [--role ROLE] [--global-database DB] [--personal-database DB]"
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

valid_identifier() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
valid_identifier "${role_name}" || { echo "ERROR: unsafe role name" >&2; exit 2; }
valid_identifier "${global_db}" || { echo "ERROR: unsafe global database name" >&2; exit 2; }
valid_identifier "${personal_db}" || { echo "ERROR: unsafe personal database name" >&2; exit 2; }
[[ "${global_db}" != "${personal_db}" ]] || { echo "ERROR: global and personal database names must differ" >&2; exit 2; }

if ((dry_run || !confirm)); then
  cat <<PLAN
PostgreSQL bootstrap plan (no changes made):
  role: ${role_name} (LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, peer/local only)
  databases: ${global_db}, ${personal_db} (owner=${role_name})
  grants: CONNECT,TEMP on both databases; USAGE,CREATE on public schema
Pass --confirm as root or the postgres OS account after reviewing pg_hba/listen_addresses.
PLAN
  exit 0
fi

if [[ "${EUID}" == 0 ]]; then
  id postgres >/dev/null 2>&1 || { echo "ERROR: postgres OS account is missing" >&2; exit 1; }
  command -v runuser >/dev/null 2>&1 || { echo "ERROR: runuser is required when invoked as root" >&2; exit 78; }
  run_as_postgres() { runuser -u postgres -- "$@"; }
elif [[ "$(id -un)" == postgres ]]; then
  run_as_postgres() { "$@"; }
else
  echo "ERROR: run as root or the postgres OS account" >&2
  exit 1
fi

psql_bin="${PSQL_BIN:-psql}"
createdb_bin="${CREATEDB_BIN:-createdb}"
command -v "${psql_bin}" >/dev/null 2>&1 || { echo "ERROR: psql is missing" >&2; exit 78; }
command -v "${createdb_bin}" >/dev/null 2>&1 || { echo "ERROR: createdb is missing" >&2; exit 78; }

role_row="$(run_as_postgres "${psql_bin}" -XAt -d postgres -c "SELECT rolcanlogin || E'\\t' || rolsuper || E'\\t' || rolcreatedb || E'\\t' || rolcreaterole || E'\\t' || rolreplication || E'\\t' || rolbypassrls FROM pg_roles WHERE rolname='${role_name}'")"
if [[ -z "${role_row}" ]]; then
  run_as_postgres "${psql_bin}" -XAt -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"${role_name}\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
else
  IFS=$'\t' read -r role_can_login role_super role_createdb role_createrole role_replication role_bypassrls <<< "${role_row}"
  [[ "${role_super}" == f ]] || { echo "ERROR: existing role is a superuser; refusing to alter it" >&2; exit 78; }
  run_as_postgres "${psql_bin}" -XAt -d postgres -v ON_ERROR_STOP=1 -c "ALTER ROLE \"${role_name}\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
fi

ensure_database() {
  local database_name="$1"
  local owner
  owner="$(run_as_postgres "${psql_bin}" -XAt -d postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='${database_name}'")"
  if [[ -z "${owner}" ]]; then
    run_as_postgres "${createdb_bin}" --owner "${role_name}" "${database_name}"
  elif [[ "${owner}" != "${role_name}" ]]; then
    echo "ERROR: ${database_name} is owned by ${owner}; refusing reassignment" >&2
    exit 78
  fi
  run_as_postgres "${psql_bin}" -XAt -d postgres -v ON_ERROR_STOP=1 -c "REVOKE ALL ON DATABASE \"${database_name}\" FROM PUBLIC; GRANT CONNECT, TEMP ON DATABASE \"${database_name}\" TO \"${role_name}\""
  run_as_postgres "${psql_bin}" -XAt -d "${database_name}" -v ON_ERROR_STOP=1 -c "GRANT USAGE, CREATE ON SCHEMA public TO \"${role_name}\""
}

ensure_database "${global_db}"
ensure_database "${personal_db}"
echo "PostgreSQL role/databases ready (role=${role_name}, global=${global_db}, personal=${personal_db})"
