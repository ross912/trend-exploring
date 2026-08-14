#!/usr/bin/env bash
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_dir="${LOCAL_STATE_DIR:-}"
if [[ -z "${state_dir}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    state_dir="${HOME:-/tmp}/Library/Application Support/TrendExploring"
  else
    state_dir="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/trend-exploring"
  fi
fi
lock_root="${state_dir}/locks"
lock_dir="${lock_root}/cycle.lock"
mkdir -p "${lock_root}"
if [[ -e "${state_dir}/deploy.lock" ]]; then
  echo "cycle refused: deployment lock is active (${state_dir}/deploy.lock)" >&2
  exit 75
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "cycle refused: active cycle lock (${lock_dir})" >&2
  exit 75
fi
printf '%s\n' "$$" > "${lock_dir}/pid"
cleanup_lock() { rm -rf "${lock_dir}"; }
trap cleanup_lock EXIT INT TERM
eval "$(bash "${project_root}/scripts/local/start_postgres.sh" --env)"
ruby "${project_root}/scripts/local/bootstrap_radar.rb" >/dev/null
ruby "${project_root}/scripts/local/bootstrap_personal_memory.rb" >/dev/null
exec ruby "${project_root}/scripts/local/run_scheduled_cycle.rb"
