\set ON_ERROR_STOP on

BEGIN;

INSERT INTO service_principal VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'event-fixture-principal',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00')
ON CONFLICT (service_principal_id) DO NOTHING;

INSERT INTO event_type_registry_manifest VALUES
  ('event-registry-fixture-v1', 'event-registry-1', repeat('a', 64),
   'fixture-registry-signature', '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
INSERT INTO event_type_definition VALUES
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE',
   'exclusive_transition', 'SERVICE_PRINCIPAL_CREDENTIAL_LIFECYCLE',
   'record', 'ServicePrincipalCredentialVersion', repeat('b', 64)),
  ('event-registry-fixture-v1', 'CANDIDATE_TRIGGER',
   'append_only', NULL, 'object', 'SignalCandidate', repeat('c', 64));
INSERT INTO event_state_definition VALUES
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'active', true),
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'revoked', false),
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'compromised', false);
INSERT INTO event_state_transition_definition VALUES
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'active', 'revoked', false, true),
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'active', 'compromised', false, true);
INSERT INTO event_api_alias VALUES
  ('event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', 'canonical', 'service_principal_credential_state', true),
  ('event-registry-fixture-v1', 'CANDIDATE_TRIGGER', 'canonical', 'candidate_trigger', true);

INSERT INTO global_identity_registry VALUES
  ('90000000-0000-4000-8000-000000000001', 'event', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', '2026-08-07 00:01+00', '2026-08-07 00:01+00'),
  ('90000000-0000-4000-8000-000000000002', 'event', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE', '2026-08-07 00:02+00', '2026-08-07 00:02+00'),
  ('90000000-0000-4000-8000-000000000003', 'event', 'CANDIDATE_TRIGGER', '2026-08-07 00:03+00', '2026-08-07 00:03+00'),
  ('90000000-0000-4000-8000-000000000004', 'event', 'CANDIDATE_TRIGGER', '2026-08-07 00:01+00', '2026-08-07 00:01+00'),
  ('91000000-0000-4000-8000-000000000001', 'record', 'ServicePrincipalCredentialVersion', '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('92000000-0000-4000-8000-000000000001', 'record', 'RuleRecord', '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('93000000-0000-4000-8000-000000000001', 'object', 'SignalCandidate', '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('93000000-0000-4000-8000-000000000002', 'object', 'SignalCandidate', '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal', '2026-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO event_base VALUES
  ('90000000-0000-4000-8000-000000000001', 'event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE',
   '91000000-0000-4000-8000-000000000001', 'record', 'ServicePrincipalCredentialVersion',
   '2026-08-07 00:01+00', '2026-08-07 00:01+00', 'known',
   'a1000000-0000-4000-8000-000000000001', 1,
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal',
   '92000000-0000-4000-8000-000000000001', 'record', 'RuleRecord',
   'credential activated', 'credential-fixture', 'credential-rev-1',
   'SERVICE_PRINCIPAL_CREDENTIAL_LIFECYCLE', 1, NULL),
  ('90000000-0000-4000-8000-000000000002', 'event-registry-fixture-v1', 'SERVICE_PRINCIPAL_CREDENTIAL_STATE',
   '91000000-0000-4000-8000-000000000001', 'record', 'ServicePrincipalCredentialVersion',
   '2026-08-07 00:01+00', '2026-08-07 00:01+00', 'known',
   'a1000000-0000-4000-8000-000000000001', 2,
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal',
   '92000000-0000-4000-8000-000000000001', 'record', 'RuleRecord',
   'credential revoked', 'credential-fixture', 'credential-rev-2',
   'SERVICE_PRINCIPAL_CREDENTIAL_LIFECYCLE', 2,
   '90000000-0000-4000-8000-000000000001'),
  ('90000000-0000-4000-8000-000000000003', 'event-registry-fixture-v1', 'CANDIDATE_TRIGGER',
   '93000000-0000-4000-8000-000000000001', 'object', 'SignalCandidate',
   '2026-08-07 00:03+00', NULL, 'not_applicable',
   'a1000000-0000-4000-8000-000000000001', 3,
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal',
   NULL, NULL, NULL,
   'candidate detector emission', 'candidate-fixture', 'candidate-1', NULL, NULL, NULL),
  ('90000000-0000-4000-8000-000000000004', 'event-registry-fixture-v1', 'CANDIDATE_TRIGGER',
   '93000000-0000-4000-8000-000000000002', 'object', 'SignalCandidate',
   '2026-08-07 00:01+00', NULL, 'not_applicable',
   'a2000000-0000-4000-8000-000000000001', 1,
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal',
   NULL, NULL, NULL,
   'candidate detector emission', 'candidate-fixture', 'candidate-2', NULL, NULL, NULL);

INSERT INTO event_causal_parent VALUES
  ('90000000-0000-4000-8000-000000000002', '90000000-0000-4000-8000-000000000001',
   '2026-08-07 00:02+00', NULL),
  ('90000000-0000-4000-8000-000000000004', '90000000-0000-4000-8000-000000000001',
   '2026-08-07 00:02+00', '94000000-0000-4000-8000-000000000001');
COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO event_base VALUES
      ('90000000-0000-4000-8000-000000000005', 'event-registry-fixture-v1', 'UNKNOWN_EVENT',
       '93000000-0000-4000-8000-000000000001', 'object', 'SignalCandidate',
       '2026-08-07 00:04+00', NULL, 'not_applicable',
       'a1000000-0000-4000-8000-000000000001', 4,
       'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'object', 'ServicePrincipal',
       NULL, NULL, NULL, 'unknown type', 'negative', 'unknown-type', NULL, NULL, NULL);
    RAISE EXCEPTION 'unknown event type was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'event type is not present in the signed registry' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO event_causal_parent VALUES
      ('90000000-0000-4000-8000-000000000001', '90000000-0000-4000-8000-000000000004',
       '2026-08-07 00:03+00', '94000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'causal cycle was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'event causal parent graph must remain acyclic' THEN RAISE; END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO event_causal_parent VALUES
      ('90000000-0000-4000-8000-000000000001', '90000000-0000-4000-8000-000000000002',
       '2026-08-07 00:04+00', NULL);
    RAISE EXCEPTION 'same-domain reverse causal edge was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'same-domain causal parent must have a lower ingest sequence' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'EVENT BASE FIXTURES PASSED' AS result;
