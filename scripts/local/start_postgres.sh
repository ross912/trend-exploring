#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${PG_BIN:-}" ]]; then
  pg_bin="${PG_BIN}"
else
  pg_bin="$(bash "${project_root}/scripts/local/install_postgres_runtime.sh" --print-bin)"
fi
if [[ ! -x "${pg_bin}/pg_ctl" || ! -x "${pg_bin}/initdb" || ! -x "${pg_bin}/psql" ]]; then
  pg_bin="$(bash "${project_root}/scripts/local/install_postgres_runtime.sh")"
fi

state_dir="${LOCAL_STATE_DIR:-}"
if [[ -z "${state_dir}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    state_dir="${HOME:-/tmp}/Library/Application Support/TrendExploring"
  else
    state_dir="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/trend-exploring"
  fi
fi
pgdata="${LOCAL_PGDATA:-${state_dir}/postgres}"
socket_dir="${LOCAL_PGSOCKET:-${state_dir}/socket}"
port="${LOCAL_PGPORT:-55433}"
user_name="${LOCAL_PGUSER:-${USER:-postgres}}"

mkdir -p "${socket_dir}"
chmod 700 "${socket_dir}"
if [[ ! -f "${pgdata}/PG_VERSION" ]]; then
  mkdir -p "${pgdata}"
  "${pg_bin}/initdb" -D "${pgdata}" -U "${user_name}" --auth-local=trust --auth-host=reject >/dev/null
fi

# Keep the local instance on its private Unix socket.  The auto-conf file is
# product-owned and overrides an older `listen_addresses='*'` setting.  A
# running server is restarted only when its effective value is not empty.
socket_config="${socket_dir//\'/\'\'}"
cat > "${pgdata}/postgresql.auto.conf" <<EOF
listen_addresses = ''
unix_socket_permissions = 0700
unix_socket_directories = '${socket_config}'
port = ${port}
EOF
chmod 600 "${pgdata}/postgresql.auto.conf"

start_options="-c listen_addresses=''"

if ! "${pg_bin}/pg_ctl" -D "${pgdata}" status >/dev/null 2>&1; then
  "${pg_bin}/pg_ctl" -D "${pgdata}" -l "${pgdata}/server.log" -o "${start_options}" start >/dev/null
else
  effective_listen="$(${pg_bin}/psql -XAt -h "${socket_dir}" -p "${port}" -U "${user_name}" -d postgres -c "SHOW listen_addresses" 2>/dev/null || true)"
  if [[ -n "${effective_listen}" ]]; then
    "${pg_bin}/pg_ctl" -D "${pgdata}" -m fast -l "${pgdata}/server.log" -o "${start_options}" restart >/dev/null
  else
    "${pg_bin}/pg_ctl" -D "${pgdata}" reload >/dev/null 2>&1 || true
  fi
fi

if [[ "${1:-}" == "--env" ]]; then
  printf 'export LOCAL_STATE_DIR=%q\n' "${state_dir}"
  printf 'export LOCAL_PGDATA=%q\n' "${pgdata}"
  printf 'export LOCAL_PGSOCKET=%q\n' "${socket_dir}"
  printf 'export LOCAL_BACKUP_DIR=%q\n' "${state_dir}/backups"
  printf 'export PG_BIN=%q\n' "${pg_bin}"
  printf 'export LOCAL_PSQL=%q\n' "${pg_bin}/psql"
  printf 'export LOCAL_CREATEDB=%q\n' "${pg_bin}/createdb"
  printf 'export LOCAL_PGHOST=%q\n' "${socket_dir}"
  printf 'export LOCAL_PGPORT=%q\n' "${port}"
  printf 'export LOCAL_PGUSER=%q\n' "${user_name}"
  printf 'export LOCAL_PGDATABASE=%q\n' "${LOCAL_PGDATABASE:-trend_exploring_local}"
  printf 'export PERSONAL_PGDATABASE=%q\n' "${PERSONAL_PGDATABASE:-trend_exploring_personal}"
else
  echo "Local PostgreSQL 15 staging is running on ${socket_dir}:${port}"
fi
