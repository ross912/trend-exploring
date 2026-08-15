#!/usr/bin/env bash
# Root orchestration helper. It reads the protected cloud env as root, then
# runs the actual DB/app command as the dedicated trendexploring user with a
# non-root HOME. Secrets stay in the child environment and are never argv.
set -Eeuo pipefail

app_user="${CLOUD_APP_USER:-trendexploring}"
env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
[[ $# -gt 0 ]] || { echo "usage: run_as_app_user.sh [--dry-run] COMMAND [ARGS...]" >&2; exit 2; }

if ((dry_run)); then
  printf 'effective_user=%s home=/var/lib/trend-exploring command=' "${app_user}"
  printf ' %q' "$@"
  printf '\n'
  exit 0
fi

if [[ "${EUID}" == 0 ]]; then
  id "${app_user}" >/dev/null 2>&1 || { echo "ERROR: app user ${app_user} is missing" >&2; exit 78; }
  command -v runuser >/dev/null 2>&1 || { echo "ERROR: runuser is required for root orchestration" >&2; exit 78; }
  [[ -r "${env_file}" ]] || { echo "ERROR: protected cloud env is unreadable: ${env_file}" >&2; exit 78; }
  # Preserve caller overrides needed during a release transaction, while the
  # protected env supplies all other configuration and secrets.
  release_override="${CLOUD_RELEASE_ROOT:-}"
  state_override="${LOCAL_STATE_DIR:-}"
  lock_override="${CLOUD_LOCK_ROOT:-}"
  # shellcheck disable=SC1090
  set -a
  source "${env_file}"
  set +a
  [[ -z "${release_override}" ]] || CLOUD_RELEASE_ROOT="${release_override}"
  [[ -z "${state_override}" ]] || LOCAL_STATE_DIR="${state_override}"
  [[ -z "${lock_override}" ]] || CLOUD_LOCK_ROOT="${lock_override}"
  export HOME=/var/lib/trend-exploring
  export CLOUD_ENV_FILE="${env_file}"
  exec runuser --preserve-environment -u "${app_user}" -- env HOME=/var/lib/trend-exploring "$@"
fi

# A non-root caller is already expected to be the dedicated service identity;
# do not attempt a privilege transition or read a root-only env file.
exec env HOME="${HOME:-/var/lib/trend-exploring}" "$@"
