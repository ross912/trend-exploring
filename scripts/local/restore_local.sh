#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
backup_dir="${1:-}"
[[ -n "${backup_dir}" && -f "${backup_dir}/manifest.json" ]] || { echo "usage: restore_local.sh BACKUP_DIR" >&2; exit 2; }
cleanup_restore="${LOCAL_RESTORE_CLEANUP:-0}"
eval "$(bash "${project_root}/scripts/local/start_postgres.sh" --env)"
stamp="$(date -u +%Y%m%d%H%M%S)"
global_db="${LOCAL_RESTORE_GLOBAL_DATABASE:-trend_exploring_restore_${stamp}}"
personal_db="${LOCAL_RESTORE_PERSONAL_DATABASE:-trend_exploring_personal_restore_${stamp}}"
[[ "${global_db}" != "${LOCAL_PGDATABASE}" && "${personal_db}" != "${PERSONAL_PGDATABASE}" && "${global_db}" != "${personal_db}" ]] || { echo "restore databases must be disposable and distinct from running databases" >&2; exit 1; }
"${LOCAL_CREATEDB}" -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" "${global_db}"
"${LOCAL_CREATEDB}" -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" "${personal_db}"
"${PG_BIN}/pg_restore" --exit-on-error --no-owner -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d "${global_db}" "${backup_dir}/global.dump"
"${PG_BIN}/pg_restore" --exit-on-error --no-owner -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d "${personal_db}" "${backup_dir}/personal.dump"
ruby "${project_root}/scripts/local/verify_backup.rb" --verify-manifest "${backup_dir}/manifest.json" --dump-dir "${backup_dir}" --psql "${LOCAL_PSQL}" --global-database "${global_db}" --personal-database "${personal_db}" --host "${LOCAL_PGHOST}" --port "${LOCAL_PGPORT}" --user "${LOCAL_PGUSER}"
if [[ "${cleanup_restore}" == "1" ]]; then
  "${LOCAL_PSQL}" -XAt -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d postgres -c "DROP DATABASE \"${global_db//\"/\"\"}\"" >/dev/null
  "${LOCAL_PSQL}" -XAt -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d postgres -c "DROP DATABASE \"${personal_db//\"/\"\"}\"" >/dev/null
  printf 'verified and cleaned disposable restore databases\n'
  exit 0
fi
printf 'restored global=%s personal=%s (disposable databases retained for inspection)\n' "${global_db}" "${personal_db}"
