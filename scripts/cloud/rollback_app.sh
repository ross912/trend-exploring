#!/usr/bin/env bash
# Roll back only the application symlink. Database schema/data are never
# rolled back by this command.
set -Eeuo pipefail

target_root="${CLOUD_DEPLOY_ROOT:-/opt/trend-exploring}"
release_name=""
confirm=0
dry_run=0
no_restart=0
while (($#)); do
  case "$1" in
    --to) release_name="${2:?--to needs a release directory name}"; shift 2 ;;
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --no-restart) no_restart=1; shift ;;
    --help|-h)
      echo "Usage: rollback_app.sh --to RELEASE [--confirm] [--dry-run] [--no-restart]"
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -n "${release_name}" ]] || { echo "ERROR: --to is required; no implicit rollback" >&2; exit 2; }
[[ "${release_name}" != */* && "${release_name}" != .* ]] || { echo "ERROR: invalid release name" >&2; exit 2; }
release_path="${target_root}/releases/${release_name}"
[[ -d "${release_path}" ]] || { echo "ERROR: release does not exist" >&2; exit 1; }
if (( !dry_run && !confirm )); then
  echo "ERROR: app rollback changes the active service; pass --confirm" >&2
  exit 78
fi

if ((dry_run)); then
  printf 'rollback dry-run: would switch current -> %s (app only; no DB rollback)\n' "${release_path}"
  exit 0
fi
[[ "${EUID}" == 0 ]] || { echo "ERROR: rollback requires root" >&2; exit 1; }
exec 9>"${CLOUD_DEPLOY_LOCK:-/var/lock/trend-exploring-deploy.lock}"
flock -n 9 || { echo "ERROR: another deployment is active" >&2; exit 75; }
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
tmp_link="${target_root}/.current.rollback.${stamp}.$$"
ln -s -- "${release_path}" "${tmp_link}"
mv -T -- "${tmp_link}" "${target_root}/current"
if ((no_restart == 0)); then systemctl try-restart trend-exploring-server.service; fi
printf 'application rolled back to %s; database unchanged\n' "${release_name}"
