#!/usr/bin/env bash
# Explicit, non-destructive restore hook. By default this only verifies a
# backup. With --confirm it creates two new disposable databases and restores
# both dumps; it refuses to drop or overwrite an existing database.
set -Eeuo pipefail

cloud_env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if [[ -r "${cloud_env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_env_file}"
fi
export PGHOST="${PGHOST:-${LOCAL_PGSOCKET:-}}"
export PGPORT="${PGPORT:-${LOCAL_PGPORT:-}}"
export PGUSER="${PGUSER:-${LOCAL_PGUSER:-}}"

backup_dir="${1:-}"
confirm=0
dry_run=0
global_db="${CLOUD_RESTORE_GLOBAL_DATABASE:-trend_exploring_restore_$(date -u +%Y%m%d%H%M%S)}"
personal_db="${CLOUD_RESTORE_PERSONAL_DATABASE:-trend_exploring_personal_restore_$(date -u +%Y%m%d%H%M%S)}"
if [[ "${backup_dir}" != --* && -n "${backup_dir}" ]]; then shift; fi
while (($#)); do
  case "$1" in
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --global-database) global_db="${2:?--global-database needs a name}"; shift 2 ;;
    --personal-database) personal_db="${2:?--personal-database needs a name}"; shift 2 ;;
    --help|-h) echo "Usage: restore_backup.sh BACKUP_DIR [--dry-run] [--confirm] [--global-database NAME] [--personal-database NAME]"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n "${backup_dir}" && -d "${backup_dir}" ]] || { echo "ERROR: backup directory is required" >&2; exit 2; }
[[ "${global_db}" != "${personal_db}" ]] || { echo "ERROR: restore database names must differ" >&2; exit 2; }
[[ "${global_db}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${personal_db}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: unsafe restore database name" >&2; exit 2; }
bash "$(dirname -- "${BASH_SOURCE[0]}")/verify_backup.sh" "${backup_dir}"
if ((dry_run || !confirm)); then
  echo "restore plan only: create new databases ${global_db} and ${personal_db}; no drop/overwrite"
  echo "Pass --confirm after selecting disposable names and a maintenance window."
  exit 0
fi
[[ "${EUID}" == 0 || -n "${PGHOST:-}" ]] || { echo "ERROR: restore requires a controlled DB identity" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "ERROR: gpg is missing" >&2; exit 78; }
command -v createdb >/dev/null 2>&1 || { echo "ERROR: createdb is missing" >&2; exit 78; }
command -v psql >/dev/null 2>&1 || { echo "ERROR: psql is missing" >&2; exit 78; }
command -v pg_restore >/dev/null 2>&1 || { echo "ERROR: pg_restore is missing" >&2; exit 78; }
for database_name in "${global_db}" "${personal_db}"; do
  if psql -XAt -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${database_name}'" | grep -q '^1$'; then
    echo "ERROR: refusing restore into existing database ${database_name}" >&2
    exit 78
  fi
done
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf -- "${tmp_dir}"; }
trap cleanup EXIT
gpg --batch --decrypt --output "${tmp_dir}/global.dump" "${backup_dir}/global.dump.gpg"
gpg --batch --decrypt --output "${tmp_dir}/personal.dump" "${backup_dir}/personal.dump.gpg"
createdb "${global_db}"
createdb "${personal_db}"
pg_restore --exit-on-error --no-owner --dbname="${global_db}" "${tmp_dir}/global.dump"
pg_restore --exit-on-error --no-owner --dbname="${personal_db}" "${tmp_dir}/personal.dump"
echo "restored into new disposable databases ${global_db} and ${personal_db}; no existing database was changed"
