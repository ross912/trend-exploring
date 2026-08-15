#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/runtime.sh"

cloud_acquire_lock collect
cloud_acquire_global_batch_lock
cloud_prepare_release
cloud_run_recovery_hook

# Collection owns ingestion.  Translation and the scheduled cycle are separate
# jobs, so a Persistent timer catch-up cannot ingest the same batch twice.
command_text="${CLOUD_COLLECT_COMMAND:-ruby scripts/local/ingest_sources.rb}"
cloud_run_child "${command_text}"
