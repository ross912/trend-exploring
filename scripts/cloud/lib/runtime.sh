#!/usr/bin/env bash
# Shared runtime guard for the systemd cloud workers.
#
# This file deliberately does not use `exec` for the worker command.  An EXIT
# trap is the last line of defence for a lock and an `exec` would replace the
# shell before that trap can run.  The child is therefore started, drained on
# SIGTERM, and waited for explicitly.
set -Eeuo pipefail

cloud_runtime_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if [[ -r "${cloud_runtime_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_runtime_file}"
fi

# Auth agent contract. This explicit marker prevents a local-development env
# from being mounted into a public deployment by accident.
if [[ "${CLOUD_PUBLIC_DEPLOYMENT:-0}" != "1" ]]; then
  echo "cloud runtime refused: CLOUD_PUBLIC_DEPLOYMENT=1 is required" >&2
  exit 78
fi

# Authentication is fail-closed.  The former anonymous-public mode is not a
# supported cloud setting: a stale env file containing `=1` must stop startup.
if [[ "${PUBLIC_UNAUTHENTICATED_MODE:-0}" != "0" ]]; then
  echo "cloud runtime refused: PUBLIC_UNAUTHENTICATED_MODE must be 0" >&2
  exit 78
fi
if [[ "${AUTH_REQUIRED_FOR_APP:-0}" != "1" ]]; then
  echo "cloud runtime refused: AUTH_REQUIRED_FOR_APP=1 is required" >&2
  exit 78
fi
if [[ "${AUTH_MODE:-required}" != "required" ]]; then
  echo "cloud runtime refused: AUTH_MODE=required is required" >&2
  exit 78
fi
if [[ -z "${CLOUD_IDENTITY_PEPPER:-}" || -z "${CLOUD_SESSION_PEPPER:-}" ]]; then
  echo "cloud runtime refused: auth peppers must be provisioned outside the repository" >&2
  exit 78
fi
if [[ "${BIND_ADDRESS:-127.0.0.1}" != "127.0.0.1" && "${BIND_ADDRESS:-127.0.0.1}" != "::1" ]]; then
  echo "cloud runtime refused: BIND_ADDRESS must be loopback" >&2
  exit 78
fi
trusted_proxy_cidrs="${TRUSTED_PROXY_CIDRS:-}"
if [[ -z "${trusted_proxy_cidrs}" ]]; then
  echo "cloud runtime refused: TRUSTED_PROXY_CIDRS must contain loopback proxy CIDRs" >&2
  exit 78
fi
IFS=',' read -r -a trusted_proxy_values <<< "${trusted_proxy_cidrs}"
for trusted_proxy in "${trusted_proxy_values[@]}"; do
  case "${trusted_proxy}" in
    127.0.0.1/32|::1/128) ;;
    *) echo "cloud runtime refused: TRUSTED_PROXY_CIDRS must be loopback-only" >&2; exit 78 ;;
  esac
done
if [[ "${PUBLISH_API_ENABLED:-1}" != "0" ]]; then
  echo "cloud runtime refused: PUBLISH_API_ENABLED must be 0" >&2
  exit 78
fi

cloud_release_root="${CLOUD_RELEASE_ROOT:-/opt/trend-exploring/current}"
cloud_state_dir="${CLOUD_STATE_DIR:-/var/lib/trend-exploring}"
cloud_lock_root="${CLOUD_LOCK_ROOT:-${cloud_state_dir}/locks}"
cloud_service_name=""
cloud_service_lock=""
cloud_global_lock="${cloud_lock_root}/global-batch.lock"
cloud_global_lock_fd=""
cloud_global_dir_lock=""
cloud_child_pid=""
cloud_stop_requested=0
cloud_lock_owned=0

cloud_log() {
  printf 'trend-exploring[%s]: %s\n' "${cloud_service_name:-runtime}" "$*" >&2
}

cloud_cleanup() {
  local status=$?
  # Do not print env values or command strings here: those may contain a
  # database URL or another operator secret.
  if [[ -n "${cloud_child_pid}" ]] && kill -0 "${cloud_child_pid}" 2>/dev/null; then
    kill -TERM "${cloud_child_pid}" 2>/dev/null || true
    wait "${cloud_child_pid}" 2>/dev/null || true
  fi
  if [[ "${cloud_lock_owned}" == "1" && -n "${cloud_service_lock}" ]]; then
    rm -rf -- "${cloud_service_lock}"
  fi
  if [[ -n "${cloud_global_lock_fd}" ]]; then
    flock -u "${cloud_global_lock_fd}" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  fi
  if [[ -n "${cloud_global_dir_lock}" ]]; then
    rm -rf -- "${cloud_global_dir_lock}"
  fi
  trap - EXIT
  exit "${status}"
}

cloud_request_stop() {
  cloud_stop_requested=1
  if [[ -n "${cloud_child_pid}" ]] && kill -0 "${cloud_child_pid}" 2>/dev/null; then
    cloud_log "SIGTERM received; draining child ${cloud_child_pid}"
    kill -TERM "${cloud_child_pid}" 2>/dev/null || true
  fi
}

cloud_recover_stale_lock() {
  local pid_file="$1"
  local stale_pid=""
  [[ -f "${pid_file}" ]] && read -r stale_pid < "${pid_file}" || true
  if [[ -n "${stale_pid}" && "${stale_pid}" =~ ^[0-9]+$ ]] && kill -0 "${stale_pid}" 2>/dev/null; then
    return 1
  fi
  return 0
}

cloud_acquire_lock() {
  local service="$1"
  cloud_service_name="${service}"
  mkdir -p -- "${cloud_lock_root}"
  cloud_service_lock="${cloud_lock_root}/${service}.lock"
  if ! mkdir -- "${cloud_service_lock}" 2>/dev/null; then
    if cloud_recover_stale_lock "${cloud_service_lock}/pid"; then
      rm -rf -- "${cloud_service_lock}"
      mkdir -- "${cloud_service_lock}" 2>/dev/null || {
        cloud_log "active ${service} lock; refusing overlap"
        return 75
      }
      cloud_log "recovered stale ${service} lock"
    else
      cloud_log "active ${service} lock; refusing overlap"
      return 75
    fi
  fi
  printf '%s\n' "$$" > "${cloud_service_lock}/pid"
  cloud_lock_owned=1
  trap cloud_cleanup EXIT
  trap cloud_request_stop INT TERM
}

cloud_acquire_global_batch_lock() {
  # flock locks the descriptor, not the path.  A killed process cannot leave a
  # stale global lock behind, while the per-service directory remains useful
  # for operator diagnostics and stale-pid recovery.
  mkdir -p -- "${cloud_lock_root}"
  if command -v flock >/dev/null 2>&1; then
    # Bash 3 (still present on macOS test hosts) has no dynamic fd syntax.
    cloud_global_lock_fd=9
    exec 9>"${cloud_global_lock}"
    if ! flock -n 9; then
      cloud_log "another batch operation owns the global lock"
      return 75
    fi
  else
    # Development fallback; Ubuntu installs util-linux/flock and always uses
    # the descriptor path above. mkdir still prevents overlap in local tests.
    cloud_global_dir_lock="${cloud_global_lock}.d"
    if ! mkdir -- "${cloud_global_dir_lock}" 2>/dev/null; then
      cloud_log "another batch operation owns the global lock"
      return 75
    fi
  fi
}

cloud_run_recovery_hook() {
  local hook="${CLOUD_STALE_RECOVERY_COMMAND:-}"
  [[ -n "${hook}" ]] || return 0
  cloud_log "running configured stale-lease recovery hook"
  # The hook is operator supplied and executes with the same locked service
  # identity.  It must not receive credentials as command-line arguments.
  bash -c "${hook}" >/dev/null 2>&1
}

cloud_run_child() {
  local command_text="$1"
  if [[ "${CLOUD_DRY_RUN:-0}" == "1" ]]; then
    cloud_log "dry-run: worker command suppressed"
    return 0
  fi
  bash -c "${command_text}" &
  cloud_child_pid=$!
  local child_status=0
  # `wait` is intentionally in an if statement so set -e does not skip the
  # cleanup trap when a worker exits with a normal non-zero status.
  if wait "${cloud_child_pid}"; then
    child_status=0
  else
    child_status=$?
  fi
  cloud_child_pid=""
  if [[ "${cloud_stop_requested}" == "1" ]]; then
    cloud_run_recovery_hook || cloud_log "stale-lease recovery hook failed after drain"
    return 143
  fi
  return "${child_status}"
}

cloud_prepare_release() {
  [[ -d "${cloud_release_root}" ]] || {
    cloud_log "release root is missing: ${cloud_release_root}"
    return 78
  }
  cd -- "${cloud_release_root}"
}
