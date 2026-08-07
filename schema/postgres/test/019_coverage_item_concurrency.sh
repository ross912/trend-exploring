#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${M1_DATABASE_URL:-}" ]]; then
  echo "ERROR: set M1_DATABASE_URL to a disposable PostgreSQL database." >&2
  exit 1
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed." >&2
  exit 1
fi

psql_cmd() {
  psql -X "${M1_DATABASE_URL}" -v ON_ERROR_STOP=1 "$@"
}

scope_id="aaaaaaaa-0000-4000-8000-000000000010"
policy_version="coverage-policy-concurrency"
semantics_version="projection-semantics-v1"
detector_key="eeeeeeee-0000-4000-8000-000000000010"
projection_key="${scope_id}|${policy_version}|${semantics_version}|event_cluster|{\"typedInputKey\": \"event-cluster-concurrency\", \"typedInputKind\": \"event_cluster\"}|bbbbbbbb-0000-4000-8000-000000000010|primary"
item_id="$(psql_cmd -At -c "SELECT m1_uuid5('0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', '${projection_key}');")"

temp_dir="$(mktemp -d)"
cleanup() { rm -rf "${temp_dir}"; }
trap cleanup EXIT

insert_sql="
  BEGIN;
  INSERT INTO coverage_item (
    coverage_item_id, scope_snapshot_id, coverage_policy_version,
    projection_semantics_version, item_kind, typed_input_refs,
    primary_stratum_version_ids, projection_role, recorded_at,
    system_available_at, as_of, run_mode, input_record_ids
  ) VALUES (
    '${item_id}', '${scope_id}', '${policy_version}', '${semantics_version}', 'event_cluster',
    '{\"typedInputKind\":\"event_cluster\",\"typedInputKey\":\"event-cluster-concurrency\"}',
    ARRAY['bbbbbbbb-0000-4000-8000-000000000010']::uuid[], 'primary',
    '2026-08-07 04:10+00', '2026-08-07 04:10+00', '2026-08-07 04:10+00',
    'prospective', ARRAY['cccccccc-0000-4000-8000-000000000010']::uuid[]
  );
  SELECT pg_sleep(1);
  COMMIT;
"

set +e
psql_cmd -c "${insert_sql}" >"${temp_dir}/worker-a.log" 2>&1 &
worker_a=$!
psql_cmd -c "${insert_sql}" >"${temp_dir}/worker-b.log" 2>&1 &
worker_b=$!
wait "${worker_a}"; status_a=$?
wait "${worker_b}"; status_b=$?
set -e

if [[ "${status_a}" -eq 0 && "${status_b}" -eq 0 ]] || [[ "${status_a}" -ne 0 && "${status_b}" -ne 0 ]]; then
  echo "ERROR: concurrent CoverageItem writes did not produce exactly one winner" >&2
  cat "${temp_dir}/worker-a.log" "${temp_dir}/worker-b.log" >&2
  exit 1
fi

accepted_count="$(psql_cmd -At -c "SELECT count(*) FROM coverage_item WHERE coverage_item_id = '${item_id}';")"
if [[ "${accepted_count}" != "1" ]]; then
  echo "ERROR: expected one canonical CoverageItem, found ${accepted_count}" >&2
  exit 1
fi

echo "COVERAGE ITEM CONCURRENCY PASSED"
