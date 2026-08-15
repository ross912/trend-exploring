#!/usr/bin/env bash
# Apply global and personal PostgreSQL migrations under per-database advisory
# locks. A failed migration never moves the current application symlink.
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cloud_env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if [[ -r "${cloud_env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_env_file}"
fi

if [[ "${CLOUD_PUBLIC_DEPLOYMENT:-0}" != "1" || "${PUBLIC_UNAUTHENTICATED_MODE:-0}" != "0" || "${AUTH_REQUIRED_FOR_APP:-0}" != "1" || "${AUTH_MODE:-required}" != "required" || "${PUBLISH_API_ENABLED:-1}" != "0" ]]; then
  echo "migration refused: cloud authentication/publish guard is not fail-closed" >&2
  exit 78
fi
[[ "${TRUSTED_PROXY_CIDRS:-}" == "127.0.0.1/32,::1/128" ]] || { echo "migration refused: TRUSTED_PROXY_CIDRS must be loopback-only" >&2; exit 78; }

global_database_url="${DATABASE_URL:-${CLOUD_DATABASE_URL:-${M1_DATABASE_URL:-}}}"
personal_database_url="${PERSONAL_DATABASE_URL:-}"
[[ -n "${global_database_url}" ]] || { echo "migration refused: DATABASE_URL is not configured" >&2; exit 78; }
if [[ -z "${personal_database_url}" && "${CLOUD_DRY_RUN:-0}" != 1 ]]; then
  echo "migration refused: PERSONAL_DATABASE_URL is not configured" >&2
  exit 78
fi
psql_bin="${PSQL_BIN:-psql}"

migrations_dir="${CLOUD_MIGRATIONS_DIR:-${project_root}/schema/postgres}"
[[ -d "${migrations_dir}" ]] || { echo "migration refused: migration directory is missing" >&2; exit 78; }

# Runtime deliberately starts at 011. The 001-010 M1 files are disposable
# contract/verification schemas and are not part of the production chain.
global_migration_names=(
  011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql
  014_local_report_summary.sql 015_local_weak_signal.sql
  016_local_fulltext_translation.sql 017_raw_archive_immutability.sql
  018_multilingual_concepts.sql 019_world_change_candidates.sql
  020_signal_lifecycle.sql 021_report_claim_gate.sql
  022_report_summary_repair.sql 023_summary_run_leases.sql
  024_metadata_translation_leases.sql
)
personal_migration_names=(001_personal_memory.sql 002_conversation_ledger.sql 003_single_owner_auth.sql)

is_named_migration() {
  local candidate="$1"
  shift
  local expected
  for expected in "$@"; do [[ "${candidate}" == "${expected}" ]] && return 0; done
  return 1
}

global_migrations=()
for migration_name in "${global_migration_names[@]}"; do
  migration_path="${migrations_dir}/${migration_name}"
  [[ -f "${migration_path}" ]] || { echo "migration refused: required runtime migration is missing (${migration_name})" >&2; exit 78; }
  global_migrations+=("${migration_path}")
done
shopt -s nullglob
for migration_path in "${migrations_dir}"/[0-9][0-9][0-9]_*.sql; do
  migration_name="${migration_path##*/}"
  if ! is_named_migration "${migration_name}" "${global_migration_names[@]}"; then
    echo "migration refused: unexpected global migration ${migration_name}; M1 001-010 are disposable verification schemas only" >&2
    exit 78
  fi
done
shopt -u nullglob

personal_dir="${migrations_dir}/personal"
if [[ ! -d "${personal_dir}" ]]; then
  echo "migration refused: personal migration directory is missing" >&2
  exit 78
fi
personal_migrations=()
for migration_name in "${personal_migration_names[@]}"; do
  migration_path="${personal_dir}/${migration_name}"
  if [[ ! -f "${migration_path}" ]]; then
    echo "migration refused: required personal migration is missing (${migration_name})" >&2
    exit 78
  fi
  personal_migrations+=("${migration_path}")
done
if [[ -d "${personal_dir}" ]]; then
  shopt -s nullglob
  for migration_path in "${personal_dir}"/[0-9][0-9][0-9]_*.sql; do
    migration_name="${migration_path##*/}"
    if ! is_named_migration "${migration_name}" "${personal_migration_names[@]}"; then
      echo "migration refused: unexpected personal migration ${migration_name}" >&2
      exit 78
    fi
  done
  shopt -u nullglob
fi

if [[ "${CLOUD_DRY_RUN:-0}" == "1" ]]; then
  printf 'dry-run global migrations (%s):\n' "${migrations_dir}"
  printf '%s\n' "${global_migrations[@]}"
  printf 'dry-run personal migrations (%s):\n' "${migrations_dir}/personal"
  printf '%s\n' "${personal_migrations[@]}"
  exit 0
fi

command -v "${psql_bin}" >/dev/null 2>&1 || { echo "migration refused: psql is missing" >&2; exit 78; }

global_lock_key="${CLOUD_MIGRATION_ADVISORY_LOCK_KEY:-trend-exploring:migrations:v1}:global"
personal_lock_key="${CLOUD_MIGRATION_ADVISORY_LOCK_KEY:-trend-exploring:migrations:v1}:personal"
[[ "${global_lock_key}" =~ ^[A-Za-z0-9_.:-]+$ && "${personal_lock_key}" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
  echo "migration refused: advisory lock key contains unsafe characters" >&2; exit 78;
}
global_locked=0
personal_locked=0
unlock_migrations() {
  if ((global_locked)); then "${psql_bin}" -XAt "${global_database_url}" -c "SELECT pg_advisory_unlock(hashtext('${global_lock_key}'));" >/dev/null 2>&1 || true; fi
  if ((personal_locked)); then "${psql_bin}" -XAt "${personal_database_url}" -c "SELECT pg_advisory_unlock(hashtext('${personal_lock_key}'));" >/dev/null 2>&1 || true; fi
}
trap unlock_migrations EXIT

"${psql_bin}" -XAt "${global_database_url}" -v ON_ERROR_STOP=1 -c "SELECT pg_advisory_lock(hashtext('${global_lock_key}'));" >/dev/null
global_locked=1
while IFS= read -r migration; do
  echo "applying global migration ${migration##*/}"
  "${psql_bin}" -X "${global_database_url}" -v ON_ERROR_STOP=1 -f "${migration}"
done < <(printf '%s\n' "${global_migrations[@]}")

"${psql_bin}" -XAt "${personal_database_url}" -v ON_ERROR_STOP=1 -c "SELECT pg_advisory_lock(hashtext('${personal_lock_key}'));" >/dev/null
personal_locked=1
while IFS= read -r migration; do
  echo "applying personal migration ${migration##*/}"
  "${psql_bin}" -X "${personal_database_url}" -v ON_ERROR_STOP=1 -f "${migration}"
done < <(printf '%s\n' "${personal_migrations[@]}")

echo "GLOBAL+PERSONAL MIGRATIONS COMPLETE"
