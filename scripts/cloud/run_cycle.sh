#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/runtime.sh"

cloud_acquire_lock cycle
cloud_acquire_global_batch_lock
cloud_prepare_release
cloud_run_recovery_hook

# The cycle consumes the latest immutable collection.  Ingestion is explicitly
# skipped; this avoids duplicate writes when systemd replays a Persistent
# timer.  An operator may provide a freshness-aware command if desired.
if [[ -n "${CLOUD_CYCLE_COMMAND:-}" ]]; then
  command_text="${CLOUD_CYCLE_COMMAND}"
else
  command_text="ruby scripts/local/run_scheduled_cycle.rb --skip-ingest"
fi
cloud_run_child "${command_text}"
