#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/runtime.sh"

cloud_acquire_lock migration
cloud_acquire_global_batch_lock
cloud_prepare_release
cloud_run_recovery_hook

command_text="${CLOUD_MIGRATION_COMMAND:-bash scripts/cloud/migrate.sh}"
cloud_run_child "${command_text}"
