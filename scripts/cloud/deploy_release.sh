#!/usr/bin/env bash
# Build a release directory and switch /opt/trend-exploring/current atomically.
# Backup and migration happen before the switch; no force flag can bypass them.
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd -- "${script_dir}/../.." && pwd)"
target_root="${CLOUD_DEPLOY_ROOT:-/opt/trend-exploring}"
source_path="${source_root}"
dry_run=0
skip_backup=0
skip_migration=0
no_restart=0
while (($#)); do
  case "$1" in
    --source) source_path="${2:?--source needs a checkout path}"; shift 2 ;;
    --target-root) target_root="${2:?--target-root needs a path}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --skip-backup) skip_backup=1; shift ;;
    --skip-migration) skip_migration=1; shift ;;
    --no-restart) no_restart=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: deploy_release.sh [--source CHECKOUT] [--target-root PATH] [--dry-run]
                         [--no-restart]
Backup and migration are mandatory. --skip-* are rejected unless the
operator explicitly sets CLOUD_ALLOW_SKIP_BACKUP/MIGRATION=1.
USAGE
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if ((skip_backup)) && [[ "${CLOUD_ALLOW_SKIP_BACKUP:-0}" != 1 ]]; then
  echo "ERROR: refusing --skip-backup without CLOUD_ALLOW_SKIP_BACKUP=1" >&2
  exit 78
fi
if ((skip_migration)) && [[ "${CLOUD_ALLOW_SKIP_MIGRATION:-0}" != 1 ]]; then
  echo "ERROR: refusing --skip-migration without CLOUD_ALLOW_SKIP_MIGRATION=1" >&2
  exit 78
fi
[[ -d "${source_path}" ]] || { echo "ERROR: source checkout does not exist" >&2; exit 1; }

run() { if ((dry_run)); then printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
if ((dry_run)); then
  echo "release plan: source=${source_path} target=${target_root}"
fi
if (( !dry_run )); then
  [[ "${EUID}" == 0 ]] || { echo "ERROR: deploy requires root" >&2; exit 1; }
  install -d -o root -g root -m 0755 "${target_root}/releases"
  deploy_lock="${CLOUD_DEPLOY_LOCK:-/var/lock/trend-exploring-deploy.lock}"
  exec 9>"${deploy_lock}"
  flock -n 9 || { echo "ERROR: another release deployment is active" >&2; exit 75; }
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
revision="$(git -C "${source_path}" rev-parse --short=12 HEAD 2>/dev/null || echo no-git)"
release_dir="${target_root}/releases/${stamp}-${revision}"
current_link="${target_root}/current"

if ((dry_run)); then
  echo "would create ${release_dir} and atomically switch ${current_link}"
else
  [[ ! -e "${release_dir}" ]] || { echo "ERROR: release target already exists" >&2; exit 1; }
  install -d -o root -g trendexploring -m 0750 "${release_dir}"
  # tar/cp copy is bounded to the requested checkout; no broad cleanup occurs.
  tar -C "${source_path}" --exclude='./.git' --exclude='./.DS_Store' -cf - . | tar -C "${release_dir}" -xf -
  chown -R root:trendexploring "${release_dir}"
  find "${release_dir}" -type d -exec chmod 0750 {} +
  find "${release_dir}" -type f -exec chmod u=rwX,g=rX,o= {} +
fi

preflight="${CLOUD_PREFLIGHT_BIN:-${script_dir}/preflight_ubuntu.sh}"
run_as_app="${CLOUD_RUN_AS_APP_BIN:-${script_dir}/run_as_app_user.sh}"
if ((dry_run)); then
  run "${preflight}" --release-root "${release_dir}" --strict
else
  "${preflight}" --release-root "${release_dir}" --strict
fi

if ((skip_backup == 0)); then
  backup_bin="${CLOUD_BACKUP_BIN:-${script_dir}/run_backup.sh}"
  if ((dry_run)); then "${run_as_app}" --dry-run "${backup_bin}"; else CLOUD_RELEASE_ROOT="${release_dir}" "${run_as_app}" "${backup_bin}"; fi
fi

if ((skip_migration == 0)); then
  migration_bin="${CLOUD_MIGRATION_BIN:-${script_dir}/run_migration.sh}"
  if ((dry_run)); then
    "${run_as_app}" --dry-run "${migration_bin}"
  else
    CLOUD_RELEASE_ROOT="${release_dir}" "${run_as_app}" "${migration_bin}"
  fi
fi

if ((dry_run)); then
  echo "dry-run complete: no release or symlink changed"
  exit 0
fi

tmp_link="${target_root}/.current.${stamp}.$$"
ln -s -- "${release_dir}" "${tmp_link}"
mv -T -- "${tmp_link}" "${current_link}"
if ((no_restart == 0)); then
  systemctl try-restart trend-exploring-server.service
fi
printf 'release active: %s\n' "${release_dir}"
