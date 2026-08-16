#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/lib/runtime.sh"

# The worker itself owns translation.lock so it can be safely launched from
# the browser, launchd, or this systemd wrapper. Keep a distinct outer lock
# for the cloud wrapper; reusing translation.lock makes the child fail with
# EEXIST before it can do any work.
cloud_acquire_lock translation-wrapper
cloud_acquire_global_batch_lock
cloud_prepare_release
cloud_run_recovery_hook

command_text="${CLOUD_TRANSLATION_COMMAND:-ruby scripts/local/translation_worker.rb}"
cloud_run_child "${command_text}"
