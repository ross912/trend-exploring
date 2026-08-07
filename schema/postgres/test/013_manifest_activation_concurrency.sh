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

series_id="bf000000-0000-4000-8000-000000000001"
decision_initial="bf100000-0000-4000-8000-000000000000"
decision_a="bf100000-0000-4000-8000-000000000001"
decision_b="bf100000-0000-4000-8000-000000000002"
manifest_initial="bf200000-0000-4000-8000-000000000000"
manifest_a="bf200000-0000-4000-8000-000000000001"
manifest_b="bf200000-0000-4000-8000-000000000002"

psql_cmd -c "
  INSERT INTO manifest_series VALUES
    ('${series_id}', 'concurrency-fixture', 'scope-${series_id}',
     '2026-08-07 05:00+00', '2026-08-07 05:00+00');
  INSERT INTO manifest_activation_decision VALUES
    ('${decision_initial}', '${series_id}', 'concurrency-fixture',
     '${manifest_initial}', 'authoritative', '2026-08-07 05:00+00', NULL, 1,
     NULL, NULL, '2026-08-07 05:00+00', '2026-08-07 05:00+00');
"

temp_dir="$(mktemp -d)"
cleanup() { rm -rf "${temp_dir}"; }
trap cleanup EXIT

set +e
psql_cmd -c "
  BEGIN;
  INSERT INTO manifest_activation_decision VALUES
    ('${decision_a}', '${series_id}', 'concurrency-fixture',
     '${manifest_a}', 'shadow', '2026-08-07 05:00+00', NULL, 2,
     '${decision_initial}', 1, '2026-08-07 05:01+00', '2026-08-07 05:01+00');
  SELECT pg_sleep(1);
  COMMIT;
" >"${temp_dir}/worker-a.log" 2>&1 &
worker_a=$!
psql_cmd -c "
  BEGIN;
  INSERT INTO manifest_activation_decision VALUES
    ('${decision_b}', '${series_id}', 'concurrency-fixture',
     '${manifest_b}', 'shadow', '2026-08-07 05:00+00', NULL, 2,
     '${decision_initial}', 1, '2026-08-07 05:01+00', '2026-08-07 05:01+00');
  COMMIT;
" >"${temp_dir}/worker-b.log" 2>&1 &
worker_b=$!
wait "${worker_a}"; status_a=$?
wait "${worker_b}"; status_b=$?
set -e

if [[ "${status_a}" -eq 0 && "${status_b}" -eq 0 ]] || [[ "${status_a}" -ne 0 && "${status_b}" -ne 0 ]]; then
  echo "ERROR: concurrent manifest activation did not produce exactly one winner" >&2
  cat "${temp_dir}/worker-a.log" "${temp_dir}/worker-b.log" >&2
  exit 1
fi

accepted_count="$(psql_cmd -At -c "
  SELECT count(*)
    FROM manifest_activation_decision
   WHERE manifest_series_id = '${series_id}';
")"
if [[ "${accepted_count}" != "2" ]]; then
  echo "ERROR: expected initial decision plus one concurrent winner, found ${accepted_count}" >&2
  exit 1
fi

echo "MANIFEST ACTIVATION CONCURRENCY PASSED"
