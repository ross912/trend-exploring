#!/usr/bin/env bash
set -euo pipefail
# Secrets live under state_dir/secrets and are intentionally never copied by
# this database-only backup workflow.

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
eval "$(bash "${project_root}/scripts/local/start_postgres.sh" --env)"
backup_dir="${1:-${LOCAL_BACKUP_DIR}/backup-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${backup_dir}"
ruby "${project_root}/scripts/local/verify_backup.rb" --write-stats "${backup_dir}/pre-stats.json" --psql "${LOCAL_PSQL}" --global-database "${LOCAL_PGDATABASE}" --personal-database "${PERSONAL_PGDATABASE}" --host "${LOCAL_PGHOST}" --port "${LOCAL_PGPORT}" --user "${LOCAL_PGUSER}" >&2
"${PG_BIN}/pg_dump" -Fc -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d "${LOCAL_PGDATABASE}" -f "${backup_dir}/global.dump"
"${PG_BIN}/pg_dump" -Fc -h "${LOCAL_PGHOST}" -p "${LOCAL_PGPORT}" -U "${LOCAL_PGUSER}" -d "${PERSONAL_PGDATABASE}" -f "${backup_dir}/personal.dump"
"${PG_BIN}/pg_restore" --list "${backup_dir}/global.dump" >/dev/null
"${PG_BIN}/pg_restore" --list "${backup_dir}/personal.dump" >/dev/null
ruby "${project_root}/scripts/local/verify_backup.rb" --write-manifest "${backup_dir}/manifest.json" --expected-stats "${backup_dir}/pre-stats.json" --dump-dir "${backup_dir}" --psql "${LOCAL_PSQL}" --global-database "${LOCAL_PGDATABASE}" --personal-database "${PERSONAL_PGDATABASE}" --host "${LOCAL_PGHOST}" --port "${LOCAL_PGPORT}" --user "${LOCAL_PGUSER}" >&2
rm -f "${backup_dir}/pre-stats.json"
printf '%s\n' "${backup_dir}"
