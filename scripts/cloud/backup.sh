#!/usr/bin/env bash
# Encrypted PostgreSQL backup with bounded local retention and optional
# off-host/verification hooks. The cloud product has two databases: global
# radar data and the personal/auth database. Both are required for a complete
# restore; this script never prints either connection URL.
set -Eeuo pipefail

cloud_env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if [[ -r "${cloud_env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_env_file}"
fi

backup_root="${CLOUD_BACKUP_ROOT:-/var/backups/trend-exploring}"
retention="${CLOUD_BACKUP_RETENTION:-10}"
global_database_url="${DATABASE_URL:-${CLOUD_DATABASE_URL:-${M1_DATABASE_URL:-}}}"
personal_database_url="${PERSONAL_DATABASE_URL:-}"
gpg_recipient="${CLOUD_BACKUP_GPG_RECIPIENT:-}"
verify_hook="${CLOUD_BACKUP_VERIFY_HOOK:-}"
offsite_hook="${CLOUD_BACKUP_OFFSITE_HOOK:-}"
dry_run="${CLOUD_DRY_RUN:-0}"

[[ "${retention}" =~ ^[0-9]+$ ]] && ((retention >= 7 && retention <= 14)) || {
  echo "backup refused: CLOUD_BACKUP_RETENTION must be between 7 and 14" >&2
  exit 78
}
[[ -n "${global_database_url}" ]] || { echo "backup refused: DATABASE_URL is not configured" >&2; exit 78; }
if [[ -z "${personal_database_url}" && "${dry_run}" != 1 ]]; then
  echo "backup refused: PERSONAL_DATABASE_URL is not configured; refusing a partial backup" >&2
  exit 78
fi
if [[ "${dry_run}" != 1 && -z "${gpg_recipient}" ]]; then
  echo "backup refused: encrypted backups require CLOUD_BACKUP_GPG_RECIPIENT" >&2
  exit 78
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target_dir="${backup_root}/${stamp}"
if [[ "${dry_run}" == 1 ]]; then
  printf 'backup dry-run: would dump global and personal databases into %s\n' "${target_dir}"
  [[ -n "${personal_database_url}" ]] || echo 'backup dry-run: PERSONAL_DATABASE_URL is missing (production run will fail-closed)'
  printf 'backup dry-run: would encrypt global.dump.gpg + personal.dump.gpg, retain newest %s snapshots, and invoke hooks\n' "${retention}"
  exit 0
fi

[[ "${EUID}" == 0 || -w "$(dirname -- "${backup_root}")" || -w "${backup_root}" ]] || {
  echo "backup refused: backup root is not writable" >&2; exit 1;
}
command -v pg_dump >/dev/null 2>&1 || { echo "backup refused: pg_dump is missing" >&2; exit 78; }
command -v gpg >/dev/null 2>&1 || { echo "backup refused: gpg is missing" >&2; exit 78; }
command -v sha256sum >/dev/null 2>&1 || { echo "backup refused: sha256sum is missing" >&2; exit 78; }
mkdir -p -- "${backup_root}"
chmod 700 "${backup_root}"
if [[ -e "${target_dir}" ]]; then
  echo "backup refused: target already exists" >&2
  exit 1
fi
mkdir -- "${target_dir}"
chmod 700 "${target_dir}"
tmp_dir="$(mktemp -d "${target_dir}/.work.XXXXXX")"
cleanup() { rm -rf -- "${tmp_dir}"; }
trap cleanup EXIT

pg_dump --format=custom --no-owner --file="${tmp_dir}/global.dump" "${global_database_url}"
pg_dump --format=custom --no-owner --file="${tmp_dir}/personal.dump" "${personal_database_url}"
gpg --batch --yes --trust-model always --recipient "${gpg_recipient}" --output "${target_dir}/global.dump.gpg" --encrypt "${tmp_dir}/global.dump"
gpg --batch --yes --trust-model always --recipient "${gpg_recipient}" --output "${target_dir}/personal.dump.gpg" --encrypt "${tmp_dir}/personal.dump"

global_sha="$(sha256sum "${target_dir}/global.dump.gpg" | awk '{ print $1 }')"
personal_sha="$(sha256sum "${target_dir}/personal.dump.gpg" | awk '{ print $1 }')"
cat > "${target_dir}/manifest.json" <<EOF
{"created_at":"${stamp}","format":"pg_dump-custom","encrypted":true,"databases":{"global":{"file":"global.dump.gpg","sha256":"${global_sha}"},"personal":{"file":"personal.dump.gpg","sha256":"${personal_sha}"}},"restore_hook_configured":$([[ -n "${CLOUD_BACKUP_RESTORE_HOOK:-}" ]] && echo true || echo false)}
EOF
chmod 600 "${target_dir}/manifest.json" "${target_dir}/global.dump.gpg" "${target_dir}/personal.dump.gpg"
rm -f -- "${tmp_dir}/global.dump" "${tmp_dir}/personal.dump"

if [[ -n "${verify_hook}" ]]; then
  # Hook output is suppressed so a verifier cannot accidentally leak metadata
  # or connection details into journald.
  bash -c "${verify_hook} \"${target_dir}\"" >/dev/null 2>&1
fi
if [[ -n "${offsite_hook}" ]]; then
  # The off-site hook receives only the already encrypted directory.
  bash -c "${offsite_hook} \"${target_dir}\"" >/dev/null 2>&1
fi

snapshots=()
while IFS= read -r snapshot; do snapshots+=("${snapshot}"); done < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -print | sort -r)
if ((${#snapshots[@]} > retention)); then
  for ((index=retention; index<${#snapshots[@]}; index++)); do rm -rf -- "${snapshots[index]}"; done
fi
printf 'encrypted global+personal backup created (%s); local retention=%s\n' "${stamp}" "${retention}"
