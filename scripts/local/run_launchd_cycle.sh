#!/usr/bin/env bash
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
eval "$(bash "${project_root}/scripts/local/start_postgres.sh" --env)"
ruby "${project_root}/scripts/local/bootstrap_radar.rb" >/dev/null
ruby "${project_root}/scripts/local/bootstrap_personal_memory.rb" >/dev/null
exec ruby "${project_root}/scripts/local/run_scheduled_cycle.rb"
