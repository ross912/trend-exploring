#!/usr/bin/env bash
set -euo pipefail

pg_bin="${PG_BIN:-/private/tmp/pg15-build-20260808/install/bin}"
pgdata="${LOCAL_PGDATA:-/private/tmp/trend-exploring-pg15}"
socket_dir="${LOCAL_PGSOCKET:-/private/tmp/trend-exploring-pg-socket}"
port="${LOCAL_PGPORT:-55433}"
user_name="${LOCAL_PGUSER:-${USER:-postgres}}"

mkdir -p "${socket_dir}"
if [[ ! -f "${pgdata}/PG_VERSION" ]]; then
  mkdir -p "${pgdata}"
  "${pg_bin}/initdb" -D "${pgdata}" -U "${user_name}" --auth=trust >/dev/null
fi

if ! "${pg_bin}/pg_ctl" -D "${pgdata}" status >/dev/null 2>&1; then
  "${pg_bin}/pg_ctl" -D "${pgdata}" -l "${pgdata}/server.log" -o "-k ${socket_dir} -p ${port}" start >/dev/null
fi

if [[ "${1:-}" == "--env" ]]; then
  printf 'export LOCAL_PSQL=%q\n' "${pg_bin}/psql"
  printf 'export LOCAL_CREATEDB=%q\n' "${pg_bin}/createdb"
  printf 'export LOCAL_PGHOST=%q\n' "${socket_dir}"
  printf 'export LOCAL_PGPORT=%q\n' "${port}"
  printf 'export LOCAL_PGUSER=%q\n' "${user_name}"
  printf 'export LOCAL_PGDATABASE=%q\n' "trend_exploring_local"
else
  echo "Local PostgreSQL 15 staging is running on ${socket_dir}:${port}"
fi
