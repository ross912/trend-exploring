#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
migration_path="${project_root}/schema/postgres/001_m1_core.sql"
smoke_path="${project_root}/schema/postgres/test/001_catalog_smoke.sql"

if [[ -z "${M1_DATABASE_URL:-}" ]]; then
  echo "ERROR: set M1_DATABASE_URL to a disposable, empty PostgreSQL database." >&2
  exit 1
fi

if [[ "${M1_CONFIRM_DISPOSABLE_DATABASE:-}" != "YES" ]]; then
  echo "ERROR: set M1_CONFIRM_DISPOSABLE_DATABASE=YES after verifying the target is disposable." >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed." >&2
  exit 1
fi

psql_cmd() {
  psql -X "${M1_DATABASE_URL}" -v ON_ERROR_STOP=1 "$@"
}

server_version="$(psql_cmd -At -c 'SHOW server_version_num')"
server_major="$((server_version / 10000))"
if (( server_major < 15 )); then
  echo "ERROR: PostgreSQL 15+ is required; server reports ${server_version}." >&2
  exit 1
fi

existing_relations="$(psql_cmd -At -c "
  SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND n.nspname !~ '^pg_toast'
     AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f');
")"
if [[ "${existing_relations}" != "0" ]]; then
  echo "ERROR: target database is not empty (${existing_relations} user relations); refusing fixtures." >&2
  exit 1
fi

psql_cmd -f "${migration_path}"
psql_cmd -f "${smoke_path}"

psql_cmd <<'SQL'
BEGIN;
INSERT INTO service_principal VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'fixture-main',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO model_invocation VALUES
  ('00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000011',
   '00000000-0000-4000-8000-000000000012',
   '00000000-0000-4000-8000-000000000013',
   '00000000-0000-4000-8000-000000000014', NULL,
   '00000000-0000-4000-8000-000000000015', repeat('1', 64),
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');
INSERT INTO provider_response_set_profile VALUES
  ('00000000-0000-4000-8000-000000000002', 'paged', 'member', 2, 2, true,
   'm1-fixture', 'schema-hash', 'fixture-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000016']::uuid[],
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');
INSERT INTO provider_response_set VALUES
  ('00000000-0000-4000-8000-000000000003',
   '00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000002', 2,
   encode(digest(
     '11111111-1111-4111-8111-111111111111|41|1|706167652d61|73686172642d61|0
22222222-2222-4222-8222-222222222222|42|2|706167652d62|73686172642d62|1',
     'sha256'), 'hex'),
   '2026-08-07 00:00+00', '2026-08-07 00:00+00', '2026-08-07 00:00+00');
INSERT INTO provider_response_member_unit VALUES
  ('11111111-1111-4111-8111-111111111111',
   '00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000002',
   '00000000-0000-4000-8000-000000000003', 'A', 1,
   'page-a', 'shard-a', false,
   '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000017']::uuid[]);
INSERT INTO provider_response_member_unit VALUES
  ('22222222-2222-4222-8222-222222222222',
   '00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000002',
   '00000000-0000-4000-8000-000000000003', 'B', 2,
   'page-b', 'shard-b', true,
   '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000018']::uuid[]);
INSERT INTO provider_response_member_decision VALUES
  ('00000000-0000-4000-8000-000000000021',
   '11111111-1111-4111-8111-111111111111',
   '00000000-0000-4000-8000-000000000001', 'failed', 'provider_error', true,
   '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000019']::uuid[]);
INSERT INTO provider_response_member_decision VALUES
  ('00000000-0000-4000-8000-000000000022',
   '22222222-2222-4222-8222-222222222222',
   '00000000-0000-4000-8000-000000000001', 'success', NULL, true,
   '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000020']::uuid[]);
INSERT INTO provider_response_receipt VALUES
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000022',
   '00000000-0000-4000-8000-000000000001', 'success', 'poll',
   'exchange-b', 'peer-fixture', 'job-b', repeat('2', 64),
   '2026-08-07 00:00+00', '2026-08-07 00:00+00', '2026-08-07 00:00+00');
INSERT INTO model_output_artifact VALUES
  ('00000000-0000-4000-8000-000000000041',
   '00000000-0000-4000-8000-000000000022',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001', repeat('3', 64),
   'fixture://output-b', '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000042']::uuid[]);
INSERT INTO provider_response_set_closure VALUES
  ('00000000-0000-4000-8000-000000000003',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');
COMMIT;

DO $$
BEGIN
  IF (SELECT count(*) FROM provider_response_set_closure) <> 1
     OR (SELECT count(*) FROM model_output_artifact) <> 1 THEN
    RAISE EXCEPTION 'ADV-013 valid closure did not persist';
  END IF;
END;
$$;
SQL
echo 'ADV-013 valid full closure: PASSED'

if psql_cmd <<'SQL'
BEGIN;
INSERT INTO model_invocation VALUES
  ('00000000-0000-4000-8000-000000000101',
   '00000000-0000-4000-8000-000000000111',
   '00000000-0000-4000-8000-000000000112',
   '00000000-0000-4000-8000-000000000113',
   '00000000-0000-4000-8000-000000000114', NULL,
   '00000000-0000-4000-8000-000000000115', repeat('4', 64),
   '2026-08-07 00:01+00', '2026-08-07 00:01+00');
INSERT INTO provider_response_set_profile VALUES
  ('00000000-0000-4000-8000-000000000102', 'paged', 'member', 2, 2, true,
   'm1-fixture', 'schema-hash', 'fixture-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000116']::uuid[],
   '2026-08-07 00:01+00', '2026-08-07 00:01+00');
INSERT INTO provider_response_set VALUES
  ('00000000-0000-4000-8000-000000000103',
   '00000000-0000-4000-8000-000000000101',
   '00000000-0000-4000-8000-000000000102', 2,
   encode(digest(
     '33333333-3333-4333-8333-333333333333|41|1|706167652d61|73686172642d61|0
44444444-4444-4444-8444-444444444444|42|2|706167652d62|73686172642d62|1',
     'sha256'), 'hex'),
   '2026-08-07 00:01+00', '2026-08-07 00:01+00', '2026-08-07 00:01+00');
INSERT INTO provider_response_member_unit VALUES
  ('44444444-4444-4444-8444-444444444444',
   '00000000-0000-4000-8000-000000000101',
   '00000000-0000-4000-8000-000000000102',
   '00000000-0000-4000-8000-000000000103', 'B', 2,
   'page-b', 'shard-b', true,
   '2026-08-07 00:01+00', '2026-08-07 00:01+00',
   '2026-08-07 00:01+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000118']::uuid[]);
INSERT INTO provider_response_member_decision VALUES
  ('00000000-0000-4000-8000-000000000122',
   '44444444-4444-4444-8444-444444444444',
   '00000000-0000-4000-8000-000000000101', 'success', NULL, true,
   '2026-08-07 00:01+00', '2026-08-07 00:01+00',
   '2026-08-07 00:01+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000120']::uuid[]);
INSERT INTO provider_response_receipt VALUES
  ('00000000-0000-4000-8000-000000000131',
   '00000000-0000-4000-8000-000000000122',
   '00000000-0000-4000-8000-000000000101', 'success', 'poll',
   'exchange-omitted', 'peer-fixture', 'job-omitted', repeat('5', 64),
   '2026-08-07 00:01+00', '2026-08-07 00:01+00', '2026-08-07 00:01+00');
INSERT INTO model_output_artifact VALUES
  ('00000000-0000-4000-8000-000000000141',
   '00000000-0000-4000-8000-000000000122',
   '00000000-0000-4000-8000-000000000131',
   '00000000-0000-4000-8000-000000000101', repeat('6', 64),
   'fixture://output-omitted', '2026-08-07 00:01+00', '2026-08-07 00:01+00',
   '2026-08-07 00:01+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000142']::uuid[]);
INSERT INTO provider_response_set_closure VALUES
  ('00000000-0000-4000-8000-000000000103',
   '2026-08-07 00:01+00', '2026-08-07 00:01+00');
COMMIT;
SQL
then
  echo 'ERROR: ADV-013 omitted member was accepted' >&2
  exit 1
fi
echo 'ADV-013 omitted member: BLOCKED as expected'

if psql_cmd <<'SQL'
BEGIN;
INSERT INTO model_invocation VALUES
  ('00000000-0000-4000-8000-000000000201',
   '00000000-0000-4000-8000-000000000211',
   '00000000-0000-4000-8000-000000000212',
   '00000000-0000-4000-8000-000000000213',
   '00000000-0000-4000-8000-000000000214', NULL,
   '00000000-0000-4000-8000-000000000215', repeat('7', 64),
   '2026-08-07 00:02+00', '2026-08-07 00:02+00');
INSERT INTO provider_response_set_profile VALUES
  ('00000000-0000-4000-8000-000000000202', 'paged', 'member', 2, 2, true,
   'm1-fixture', 'schema-hash', 'fixture-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000216']::uuid[],
   '2026-08-07 00:02+00', '2026-08-07 00:02+00');
INSERT INTO provider_response_set VALUES
  ('00000000-0000-4000-8000-000000000203',
   '00000000-0000-4000-8000-000000000201',
   '00000000-0000-4000-8000-000000000202', 2,
   encode(digest(
     '55555555-5555-4555-8555-555555555555|41|1|706167652d61|73686172642d61|0
66666666-6666-4666-8666-666666666666|42|2|706167652d62|73686172642d62|1',
     'sha256'), 'hex'),
   '2026-08-07 00:02+00', '2026-08-07 00:02+00', '2026-08-07 00:02+00');
INSERT INTO provider_response_member_unit VALUES
  ('55555555-5555-4555-8555-555555555555',
   '00000000-0000-4000-8000-000000000201',
   '00000000-0000-4000-8000-000000000202',
   '00000000-0000-4000-8000-000000000203', 'A', 1,
   'page-a', 'shard-a', false,
   '2026-08-07 00:02+00', '2026-08-07 00:02+00',
   '2026-08-07 00:02+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000217']::uuid[]);
INSERT INTO provider_response_member_unit VALUES
  ('66666666-6666-4666-8666-666666666666',
   '00000000-0000-4000-8000-000000000201',
   '00000000-0000-4000-8000-000000000202',
   '00000000-0000-4000-8000-000000000203', 'B', 2,
   'page-b', 'shard-b', true,
   '2026-08-07 00:02+00', '2026-08-07 00:02+00',
   '2026-08-07 00:02+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000218']::uuid[]);
INSERT INTO provider_response_member_decision VALUES
  ('00000000-0000-4000-8000-000000000221',
   '55555555-5555-4555-8555-555555555555',
   '00000000-0000-4000-8000-000000000201', 'failed', 'provider_error', true,
   '2026-08-07 00:02+00', '2026-08-07 00:02+00',
   '2026-08-07 00:02+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000219']::uuid[]);
INSERT INTO provider_response_member_decision VALUES
  ('00000000-0000-4000-8000-000000000222',
   '66666666-6666-4666-8666-666666666666',
   '00000000-0000-4000-8000-000000000201', 'success', NULL, false,
   '2026-08-07 00:02+00', '2026-08-07 00:02+00',
   '2026-08-07 00:02+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000220']::uuid[]);
INSERT INTO provider_response_receipt VALUES
  ('00000000-0000-4000-8000-000000000231',
   '00000000-0000-4000-8000-000000000222',
   '00000000-0000-4000-8000-000000000201', 'success', 'poll',
   'exchange-open', 'peer-fixture', 'job-open', repeat('8', 64),
   '2026-08-07 00:02+00', '2026-08-07 00:02+00', '2026-08-07 00:02+00');
INSERT INTO model_output_artifact VALUES
  ('00000000-0000-4000-8000-000000000241',
   '00000000-0000-4000-8000-000000000222',
   '00000000-0000-4000-8000-000000000231',
   '00000000-0000-4000-8000-000000000201', repeat('9', 64),
   'fixture://output-open', '2026-08-07 00:02+00', '2026-08-07 00:02+00',
   '2026-08-07 00:02+00', 'prospective',
   ARRAY['00000000-0000-4000-8000-000000000242']::uuid[]);
INSERT INTO provider_response_set_closure VALUES
  ('00000000-0000-4000-8000-000000000203',
   '2026-08-07 00:02+00', '2026-08-07 00:02+00');
COMMIT;
SQL
then
  echo 'ERROR: ADV-013 open continuation was accepted' >&2
  exit 1
fi
echo 'ADV-013 open continuation: BLOCKED as expected'

psql_cmd <<'SQL'
BEGIN;
INSERT INTO token_use_policy_manifest VALUES
  ('00000000-0000-4000-8000-000000000301', 'export', 'download', 'single_use', 1, false,
   'm1-fixture', 'policy-hash', 'policy-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000302']::uuid[],
   '2026-08-07 00:03+00', '2026-08-07 00:03+00');
INSERT INTO token_use_ledger_checkpoint VALUES
  ('00000000-0000-4000-8000-000000000303', 0, repeat('0', 64), 0,
   NULL, NULL, '2026-08-07 00:03+00', '2026-08-07 00:03+00',
   '2026-08-07 00:03+00', ARRAY['00000000-0000-4000-8000-000000000304']::uuid[]);
INSERT INTO presentation_capability_token (
  presentation_capability_token_id, token_use_policy_manifest_id, token_type, action,
  jti, subject_id, head_id, query_shape_hash, issued_at, expires_at,
  token_use_epoch, recorded_at, system_available_at
)
VALUES
  ('00000000-0000-4000-8000-000000000305',
   '00000000-0000-4000-8000-000000000301', 'export', 'download',
   'jti-fixture-rollback', '00000000-0000-4000-8000-000000000306',
   '00000000-0000-4000-8000-000000000307', 'query-fixture',
   '2026-08-07 00:03+00', '2026-08-07 01:03+00', 0,
   '2026-08-07 00:03+00', '2026-08-07 00:03+00');
COMMIT;

BEGIN;
INSERT INTO token_use_unit
SELECT '00000000-0000-4000-8000-000000000308', presentation_capability_token_id,
       scope_binding_hash, 'rollback-nonce', NULL,
       '2026-08-07 00:03+00', '2026-08-07 00:03+00'
  FROM presentation_capability_token
 WHERE presentation_capability_token_id = '00000000-0000-4000-8000-000000000305';
INSERT INTO token_use_decision VALUES
  ('00000000-0000-4000-8000-000000000309',
   '00000000-0000-4000-8000-000000000308', 'accepted', NULL,
   '2026-08-07 00:04+00', '2026-08-07 00:04+00', '2026-08-07 00:04+00');
SET CONSTRAINTS token_use_guard IMMEDIATE;
ROLLBACK;

BEGIN;
INSERT INTO token_use_unit
SELECT '00000000-0000-4000-8000-00000000030a', presentation_capability_token_id,
       scope_binding_hash, 'delivery-nonce', NULL,
       '2026-08-07 00:03+00', '2026-08-07 00:03+00'
  FROM presentation_capability_token
 WHERE presentation_capability_token_id = '00000000-0000-4000-8000-000000000305';
INSERT INTO token_use_decision VALUES
  ('00000000-0000-4000-8000-00000000030b',
   '00000000-0000-4000-8000-00000000030a', 'accepted', NULL,
   '2026-08-07 00:05+00', '2026-08-07 00:05+00', '2026-08-07 00:05+00');
COMMIT;

INSERT INTO token_use_ledger_checkpoint VALUES
  ('00000000-0000-4000-8000-00000000030c', 1, repeat('1', 64), 1,
   '00000000-0000-4000-8000-000000000303', 0,
   '2026-08-07 00:06+00', '2026-08-07 00:06+00',
   '2026-08-07 00:06+00', ARRAY['00000000-0000-4000-8000-00000000030d']::uuid[]);

INSERT INTO presentation_capability_token (
  presentation_capability_token_id, token_use_policy_manifest_id, token_type, action,
  jti, subject_id, head_id, query_shape_hash, issued_at, expires_at,
  token_use_epoch, recorded_at, system_available_at
)
VALUES
  ('00000000-0000-4000-8000-00000000030e',
   '00000000-0000-4000-8000-000000000301', 'export', 'download',
   'jti-fixture-concurrent', '00000000-0000-4000-8000-00000000030f',
   '00000000-0000-4000-8000-000000000310', 'query-fixture',
   '2026-08-07 00:06+00', '2026-08-07 01:06+00', 1,
   '2026-08-07 00:06+00', '2026-08-07 00:06+00');

DO $$
BEGIN
  IF (SELECT count(*) FROM token_use_decision WHERE outcome = 'accepted') <> 1 THEN
    RAISE EXCEPTION 'PRI-012 rollback was counted as an accepted use';
  END IF;
END;
$$;
SQL
echo 'PRI-012 transaction rollback and checkpoint setup: PASSED'

if psql_cmd <<'SQL'
BEGIN;
INSERT INTO token_use_unit
SELECT '00000000-0000-4000-8000-000000000311', presentation_capability_token_id,
       scope_binding_hash, 'stale-replay-nonce', NULL,
       '2026-08-07 00:06+00', '2026-08-07 00:06+00'
  FROM presentation_capability_token
 WHERE presentation_capability_token_id = '00000000-0000-4000-8000-000000000305';
INSERT INTO token_use_decision VALUES
  ('00000000-0000-4000-8000-000000000312',
   '00000000-0000-4000-8000-000000000311', 'accepted', NULL,
   '2026-08-07 00:07+00', '2026-08-07 00:07+00', '2026-08-07 00:07+00');
COMMIT;
SQL
then
  echo 'ERROR: PRI-012 stale token replay was accepted' >&2
  exit 1
fi
echo 'PRI-012 stale epoch replay: BLOCKED as expected'

fixture_tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-fixtures.XXXXXX")"
trap 'rm -rf "${fixture_tmp}"' EXIT

(
  psql_cmd <<'SQL'
BEGIN;
INSERT INTO token_use_unit
SELECT '00000000-0000-4000-8000-000000000313', presentation_capability_token_id,
       scope_binding_hash, 'concurrent-a', NULL,
       '2026-08-07 00:06+00', '2026-08-07 00:06+00'
  FROM presentation_capability_token
 WHERE presentation_capability_token_id = '00000000-0000-4000-8000-00000000030e';
INSERT INTO token_use_decision VALUES
  ('00000000-0000-4000-8000-000000000314',
   '00000000-0000-4000-8000-000000000313', 'accepted', NULL,
   '2026-08-07 00:08+00', '2026-08-07 00:08+00', '2026-08-07 00:08+00');
SET CONSTRAINTS token_use_guard IMMEDIATE;
SELECT pg_sleep(1);
COMMIT;
SQL
) >"${fixture_tmp}/token-a.log" 2>&1 &
token_a_pid=$!
sleep 0.4
if psql_cmd >"${fixture_tmp}/token-b.log" 2>&1 <<'SQL'
BEGIN;
INSERT INTO token_use_unit
SELECT '00000000-0000-4000-8000-000000000315', presentation_capability_token_id,
       scope_binding_hash, 'concurrent-b', NULL,
       '2026-08-07 00:06+00', '2026-08-07 00:06+00'
  FROM presentation_capability_token
 WHERE presentation_capability_token_id = '00000000-0000-4000-8000-00000000030e';
INSERT INTO token_use_decision VALUES
  ('00000000-0000-4000-8000-000000000316',
   '00000000-0000-4000-8000-000000000315', 'accepted', NULL,
   '2026-08-07 00:08+00', '2026-08-07 00:08+00', '2026-08-07 00:08+00');
SET CONSTRAINTS token_use_guard IMMEDIATE;
COMMIT;
SQL
then
  echo 'ERROR: PRI-012 concurrent second use was accepted' >&2
  exit 1
fi
wait "${token_a_pid}"
echo 'PRI-012 concurrent single-use CAS: BLOCKED second use as expected'

psql_cmd <<'SQL'
BEGIN;
INSERT INTO service_principal VALUES
  ('00000000-0000-4000-8000-000000000401', 'fixture-private-gateway',
   '2026-08-07 00:09+00', '2026-08-07 00:09+00');
INSERT INTO service_principal_credential_version VALUES
  ('00000000-0000-4000-8000-000000000402',
   '00000000-0000-4000-8000-000000000401', 'C1', 'internal-rpc',
   ARRAY['read', 'export'], '2026-08-07 00:09+00', '2027-08-07 00:09+00',
   '2026-08-07 00:09+00', '2026-08-07 00:09+00');
INSERT INTO service_principal_credential_state_event VALUES
  ('00000000-0000-4000-8000-000000000403',
   '00000000-0000-4000-8000-000000000402', 1, NULL, NULL,
   'active', 'active', '00000000-0000-4000-8000-000000000404', 0,
   'initial', '2026-08-07 00:09+00',
   '00000000-0000-4000-8000-000000000405', 1,
   '2026-08-07 00:09+00');
INSERT INTO service_principal_credential_version VALUES
  ('00000000-0000-4000-8000-000000000406',
   '00000000-0000-4000-8000-000000000401', 'C2', 'internal-rpc',
   ARRAY['read', 'export'], '2026-08-07 00:09+00', '2027-08-07 00:09+00',
   '2026-08-07 00:09+00', '2026-08-07 00:09+00');
INSERT INTO service_principal_credential_state_event VALUES
  ('00000000-0000-4000-8000-000000000407',
   '00000000-0000-4000-8000-000000000406', 1, NULL, NULL,
   'active', 'active', '00000000-0000-4000-8000-000000000408', 0,
   'initial', '2026-08-07 00:09+00',
   '00000000-0000-4000-8000-000000000409', 2,
   '2026-08-07 00:09+00');
COMMIT;

SELECT assert_service_principal_credential_usable(
  '00000000-0000-4000-8000-000000000402', 'internal-rpc', 'export',
  '2026-08-07 00:10+00');

INSERT INTO service_principal_credential_state_event VALUES
  ('00000000-0000-4000-8000-00000000040a',
   '00000000-0000-4000-8000-000000000402', 2,
   '00000000-0000-4000-8000-000000000403', 1,
   'active', 'compromised', '00000000-0000-4000-8000-000000000404', 1,
   'leaked-c1', '2026-08-07 00:11+00',
   '00000000-0000-4000-8000-000000000405', 3,
   '2026-08-07 00:11+00');

DO $$
BEGIN
  IF (SELECT current_state FROM current_service_principal_credential_state
      WHERE service_principal_credential_version_id = '00000000-0000-4000-8000-000000000402') <> 'compromised'
     OR (SELECT current_state FROM current_service_principal_credential_state
      WHERE service_principal_credential_version_id = '00000000-0000-4000-8000-000000000406') <> 'active' THEN
    RAISE EXCEPTION 'PRI-013 C1/C2 current state projection is wrong';
  END IF;
END;
$$;
SQL
echo 'PRI-013 C1 revoke/C2 active projection: PASSED'

if psql_cmd <<'SQL'
SELECT assert_service_principal_credential_usable(
  '00000000-0000-4000-8000-000000000402', 'internal-rpc', 'export',
  '2026-08-07 00:12+00');
SQL
then
  echo 'ERROR: PRI-013 compromised C1 remained usable' >&2
  exit 1
fi
echo 'PRI-013 compromised C1 gate: BLOCKED as expected'

psql_cmd <<'SQL'
BEGIN;
INSERT INTO service_principal_credential_version VALUES
  ('00000000-0000-4000-8000-00000000040b',
   '00000000-0000-4000-8000-000000000401', 'C3', 'internal-rpc',
   ARRAY['read', 'export'], '2026-08-07 00:13+00', '2027-08-07 00:13+00',
   '2026-08-07 00:13+00', '2026-08-07 00:13+00');
INSERT INTO service_principal_credential_state_event VALUES
  ('00000000-0000-4000-8000-00000000040c',
   '00000000-0000-4000-8000-00000000040b', 1, NULL, NULL,
   'active', 'active', '00000000-0000-4000-8000-00000000040d', 0,
   'initial', '2026-08-07 00:13+00',
   '00000000-0000-4000-8000-00000000040e', 4,
   '2026-08-07 00:13+00');
COMMIT;
SQL

(
  psql_cmd <<'SQL'
BEGIN;
INSERT INTO service_principal_credential_state_event VALUES
  ('00000000-0000-4000-8000-00000000040f',
   '00000000-0000-4000-8000-00000000040b', 2,
   '00000000-0000-4000-8000-00000000040c', 1,
   'active', 'revoked', '00000000-0000-4000-8000-00000000040d', 1,
   'rotation-c3', '2026-08-07 00:14+00',
   '00000000-0000-4000-8000-00000000040e', 5,
   '2026-08-07 00:14+00');
SELECT pg_sleep(1);
COMMIT;
SQL
) >"${fixture_tmp}/credential-revoke.log" 2>&1 &
credential_pid=$!
sleep 0.4
if psql_cmd >"${fixture_tmp}/credential-use.log" 2>&1 <<'SQL'
SELECT assert_service_principal_credential_usable(
  '00000000-0000-4000-8000-00000000040b', 'internal-rpc', 'export',
  '2026-08-07 00:15+00');
SQL
then
  echo 'ERROR: PRI-013 concurrent use passed after committed revoke' >&2
  exit 1
fi
wait "${credential_pid}"
echo 'PRI-013 concurrent revoke/use serialization: BLOCKED old credential as expected'

psql_cmd <<'SQL'
BEGIN;
INSERT INTO evaluation_arm_manifest VALUES
  ('00000000-0000-4000-8000-000000000501', 'system',
   '00000000-0000-4000-8000-000000000502',
   '00000000-0000-4000-8000-000000000503',
   '2026-08-07 00:16+00', 10, 'm1-fixture', 'arm-hash', 'arm-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000504']::uuid[],
   '2026-08-07 00:16+00', '2026-08-07 00:16+00');

INSERT INTO evaluation_arm_generation_unit
SELECT md5('eva-pos-unit-' || i)::uuid,
       '00000000-0000-4000-8000-000000000501', i,
       md5('eva-pos-candidate-' || i)::uuid,
       '2026-08-07 00:16+00', '2026-08-07 00:16+00',
       '2026-08-07 00:16+00', 'prospective',
       ARRAY[md5('eva-pos-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;

INSERT INTO evaluation_arm_generation_decision
SELECT md5('eva-pos-decision-' || i)::uuid,
       md5('eva-pos-unit-' || i)::uuid,
       '00000000-0000-4000-8000-000000000501', 'selected', NULL,
       '2026-08-07 00:16+00', '2026-08-07 00:16+00',
       '2026-08-07 00:16+00', 'prospective',
       ARRAY[md5('eva-pos-decision-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;

INSERT INTO evaluation_obligation
SELECT md5('eva-pos-obligation-' || i)::uuid,
       '00000000-0000-4000-8000-000000000501',
       md5('eva-pos-unit-' || i)::uuid,
       md5('eva-pos-candidate-' || i)::uuid,
       '2026-08-07 00:16+00', '2026-08-07 00:16+00',
       '2026-08-07 00:16+00', 'prospective',
       ARRAY[md5('eva-pos-obligation-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;

INSERT INTO evaluation_snapshot_decision
SELECT md5('eva-pos-snapshot-' || i)::uuid,
       md5('eva-pos-obligation-' || i)::uuid, 'captured',
       '2026-08-07 00:16+00', '2026-08-07 00:16+00',
       '2026-08-07 00:16+00', 'prospective',
       ARRAY[md5('eva-pos-snapshot-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;

INSERT INTO evaluation_result
SELECT md5('eva-pos-result-' || i)::uuid,
       md5('eva-pos-obligation-' || i)::uuid, 'observed',
       '2026-08-07 00:16+00', '2026-08-07 00:16+00',
       '2026-08-07 00:16+00', 'prospective',
       ARRAY[md5('eva-pos-result-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;

INSERT INTO evaluation_arm_output_snapshot VALUES
  ('00000000-0000-4000-8000-000000000505',
   '00000000-0000-4000-8000-000000000501',
   ARRAY(SELECT md5('eva-pos-candidate-' || i)::uuid
           FROM generate_series(1, 10) AS i),
   repeat('0', 64), '2026-08-07 00:16+00', '2026-08-07 00:16+00',
   '2026-08-07 00:16+00',
   ARRAY['00000000-0000-4000-8000-000000000506']::uuid[]);
COMMIT;

DO $$
BEGIN
  IF (SELECT count(*) FROM evaluation_obligation
      WHERE evaluation_arm_manifest_id = '00000000-0000-4000-8000-000000000501') <> 10
     OR (SELECT count(*) FROM evaluation_result r JOIN evaluation_obligation o
         ON o.evaluation_obligation_id = r.evaluation_obligation_id
         WHERE o.evaluation_arm_manifest_id = '00000000-0000-4000-8000-000000000501') <> 10 THEN
    RAISE EXCEPTION 'EVA-025 full arm closure did not persist';
  END IF;
END;
$$;
SQL
echo 'EVA-025 K=10 full output/obligation/snapshot/result closure: PASSED'

if psql_cmd <<'SQL'
BEGIN;
INSERT INTO evaluation_arm_manifest VALUES
  ('00000000-0000-4000-8000-000000000601', 'editor',
   '00000000-0000-4000-8000-000000000602',
   '00000000-0000-4000-8000-000000000603',
   '2026-08-07 00:17+00', 10, 'm1-fixture', 'arm-hash', 'arm-signature',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['00000000-0000-4000-8000-000000000604']::uuid[],
   '2026-08-07 00:17+00', '2026-08-07 00:17+00');
INSERT INTO evaluation_arm_generation_unit
SELECT md5('eva-neg-unit-' || i)::uuid,
       '00000000-0000-4000-8000-000000000601', i,
       md5('eva-neg-candidate-' || i)::uuid,
       '2026-08-07 00:17+00', '2026-08-07 00:17+00',
       '2026-08-07 00:17+00', 'prospective',
       ARRAY[md5('eva-neg-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;
INSERT INTO evaluation_arm_generation_decision
SELECT md5('eva-neg-decision-' || i)::uuid,
       md5('eva-neg-unit-' || i)::uuid,
       '00000000-0000-4000-8000-000000000601', 'selected', NULL,
       '2026-08-07 00:17+00', '2026-08-07 00:17+00',
       '2026-08-07 00:17+00', 'prospective',
       ARRAY[md5('eva-neg-decision-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 10) AS i;
INSERT INTO evaluation_obligation
SELECT md5('eva-neg-obligation-' || i)::uuid,
       '00000000-0000-4000-8000-000000000601',
       md5('eva-neg-unit-' || i)::uuid,
       md5('eva-neg-candidate-' || i)::uuid,
       '2026-08-07 00:17+00', '2026-08-07 00:17+00',
       '2026-08-07 00:17+00', 'prospective',
       ARRAY[md5('eva-neg-obligation-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 3) AS i;
INSERT INTO evaluation_snapshot_decision
SELECT md5('eva-neg-snapshot-' || i)::uuid,
       md5('eva-neg-obligation-' || i)::uuid, 'captured',
       '2026-08-07 00:17+00', '2026-08-07 00:17+00',
       '2026-08-07 00:17+00', 'prospective',
       ARRAY[md5('eva-neg-snapshot-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 3) AS i;
INSERT INTO evaluation_result
SELECT md5('eva-neg-result-' || i)::uuid,
       md5('eva-neg-obligation-' || i)::uuid, 'observed',
       '2026-08-07 00:17+00', '2026-08-07 00:17+00',
       '2026-08-07 00:17+00', 'prospective',
       ARRAY[md5('eva-neg-result-input-' || i)::uuid]::uuid[]
  FROM generate_series(1, 3) AS i;
INSERT INTO evaluation_arm_output_snapshot VALUES
  ('00000000-0000-4000-8000-000000000605',
   '00000000-0000-4000-8000-000000000601',
   ARRAY(SELECT md5('eva-neg-candidate-' || i)::uuid
           FROM generate_series(1, 3) AS i),
   repeat('0', 64), '2026-08-07 00:17+00', '2026-08-07 00:17+00',
   '2026-08-07 00:17+00',
   ARRAY['00000000-0000-4000-8000-000000000606']::uuid[]);
COMMIT;
SQL
then
  echo 'ERROR: EVA-025 partial editor arm was accepted' >&2
  exit 1
fi
echo 'EVA-025 partial editor arm: BLOCKED as expected'

echo 'M1 TRANSACTION FIXTURES PASSED'
