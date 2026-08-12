#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
eval "$(bash "${project_root}/scripts/local/start_postgres.sh" --env)"
ruby "${project_root}/scripts/local/bootstrap_radar.rb"
ruby "${project_root}/scripts/local/bootstrap_personal_memory.rb"
if [[ "${LOCAL_INGEST_LIVE:-1}" == "1" ]]; then
  ruby "${project_root}/scripts/local/ingest_sources.rb"
fi
exec ruby "${project_root}/scripts/local/start_radar.rb"
