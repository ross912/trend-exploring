\set ON_ERROR_STOP on

INSERT INTO service_principal VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'manifest-import-principal',
   '2026-08-07 01:00+00', '2026-08-07 01:00+00')
ON CONFLICT (service_principal_id) DO NOTHING;
INSERT INTO service_principal VALUES
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'fixture-test-governance',
   '2026-08-07 01:00+00', '2026-08-07 01:00+00')
ON CONFLICT (service_principal_id) DO NOTHING;

INSERT INTO test_governance_policy VALUES
  ('96000000-0000-4000-8000-000000000001', 9001,
   'm1.test-governance.v1', repeat('b', 64), 'signed-policy-fixture',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   ARRAY['96000000-0000-4000-8000-000000000010']::uuid[],
   '2026-08-07 01:00+00', '2026-08-07 01:00+00')
ON CONFLICT (test_governance_policy_version) DO NOTHING;

BEGIN;
SELECT import_event_registry_manifest(
  jsonb_build_object(
    'schemaVersion', 'm1.event-registry.fixture.v1',
    'schemaHash', repeat('a', 64),
    'signatureStatus', 'signed',
    'manifestSignature', 'signed-event-registry-fixture',
    'eventTypes', jsonb_build_array(
      jsonb_build_object(
        'eventType', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'SERVICE_PRINCIPAL_CREDENTIAL_LIFECYCLE',
        'aggregateKind', 'record',
        'aggregateConcreteType', 'ServicePrincipalCredentialVersion',
        'payloadSchemaHash', repeat('c', 64),
        'states', jsonb_build_array(jsonb_build_object('stateKey', 'active')),
        'transitions', jsonb_build_array(jsonb_build_object('fromState', 'active', 'toState', 'active'))
      ),
      jsonb_build_object(
        'eventType', 'CANDIDATE_TRIGGER',
        'stateSemantics', 'append_observation',
        'stateMachineFamily', NULL,
        'aggregateKind', 'object',
        'aggregateConcreteType', 'SignalCandidate',
        'payloadSchemaHash', repeat('d', 64)
      )
    )
  ),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '2026-08-07 01:00+00', '2026-08-07 01:00+00', true
);

SELECT import_test_catalog_manifest(
  jsonb_build_object(
    'schemaVersion', 'm1.test-catalog.v1',
    'schemaHash', repeat('e', 64),
    'catalogManifestId', '97000000-0000-4000-8000-000000000001',
    'targetPhase', 'M1',
    'targetGate', 'phase-exit',
    'testGovernancePolicyVersion', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'signatureStatus', 'signed',
    'manifestSignature', 'signed-test-catalog-fixture',
    'definitionsUniverseHash', encode(digest(
      '20000000-0000-4000-8000-000000000001|applicable
20000000-0000-4000-8000-000000000002|applicable
97000000-0000-4000-8000-000000000002|applicable', 'sha256'), 'hex'),
    'definitions', jsonb_build_array(jsonb_build_object(
      'testCode', 'IMP-001',
      'testId', '97000000-0000-4000-8000-000000000003',
      'testDefinitionVersionId', '97000000-0000-4000-8000-000000000002',
      'definitionRevision', 1,
      'introducedPhase', 'M1',
      'runOnOrAfter', 'M1',
      'applicabilityPredicate', 'always',
      'waiverAllowed', false,
      'severity', 'P0',
      'blocking', 'phase-exit',
      'fixtureContract', 'signed import fixture',
      'configContract', 'fixture-config-v1',
      'oracleSpec', 'import row exists and closes',
      'definitionHash', repeat('f', 64)
    )),
    'members', jsonb_build_array(
      jsonb_build_object(
        'testDefinitionVersionId', '20000000-0000-4000-8000-000000000001',
        'membership', 'applicable', 'exclusionReason', NULL,
        'applicabilityEvidence', 'inherited M0 P0 fixture'),
      jsonb_build_object(
        'testDefinitionVersionId', '20000000-0000-4000-8000-000000000002',
        'membership', 'applicable', 'exclusionReason', NULL,
        'applicabilityEvidence', 'inherited M1 fixture'),
      jsonb_build_object(
        'testDefinitionVersionId', '97000000-0000-4000-8000-000000000002',
        'membership', 'applicable', 'exclusionReason', NULL,
        'applicabilityEvidence', 'fixture predicate is always applicable')
    )
  ),
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '2026-08-07 01:00+00', '2026-08-07 01:00+00',
  ARRAY['96000000-0000-4000-8000-000000000011']::uuid[], true
);
COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    PERFORM import_event_registry_manifest(
      jsonb_build_object(
        'schemaVersion', 'm1.event-registry.unsigned',
        'schemaHash', repeat('1', 64),
        'signatureStatus', 'unsigned',
        'manifestSignature', NULL,
        'eventTypes', jsonb_build_array()
      ),
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      '2026-08-07 01:01+00', '2026-08-07 01:01+00', false
    );
    RAISE EXCEPTION 'unsigned event registry was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'event registry signature is not verified' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    PERFORM import_test_catalog_manifest(
      jsonb_build_object(
        'schemaVersion', 'm1.test-catalog.unsigned',
        'schemaHash', repeat('2', 64),
        'targetPhase', 'M1', 'targetGate', 'phase-exit',
        'signatureStatus', 'unsigned', 'manifestSignature', NULL,
        'definitionsUniverseHash', repeat('3', 64),
        'definitions', jsonb_build_array(), 'members', jsonb_build_array()
      ),
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      '2026-08-07 01:01+00', '2026-08-07 01:01+00',
      ARRAY[]::uuid[], false
    );
    RAISE EXCEPTION 'unsigned test catalog was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test catalog signature is not verified' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    PERFORM import_event_registry_manifest(
      jsonb_build_object(
        'schemaVersion', 'm1.event-registry.fixture.v1',
        'schemaHash', repeat('a', 64), 'signatureStatus', 'signed',
        'manifestSignature', 'signed-event-registry-fixture',
        'eventTypes', jsonb_build_array()
      ),
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      '2026-08-07 01:02+00', '2026-08-07 01:02+00', true
    );
    RAISE EXCEPTION 'duplicate event registry was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'event registry version is already imported' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'MANIFEST IMPORT FIXTURES PASSED' AS result;
