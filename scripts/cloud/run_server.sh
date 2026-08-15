#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/runtime.sh"

cloud_acquire_lock server
cloud_prepare_release

command_text="${CLOUD_SERVER_COMMAND:-ruby scripts/local/start_radar.rb}"
cloud_run_child "${command_text}"
