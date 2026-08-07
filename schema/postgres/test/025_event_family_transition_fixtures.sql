\set ON_ERROR_STOP on

-- CTR-013: exercise additional frozen exclusive families through the same
-- EventBase + EventTransitionState closure, rather than only RADAR/credential.

BEGIN;

INSERT INTO service_principal VALUES
  ('a9000000-0000-4000-8000-000000000025', 'ctr013-transition-fixture',
   '2026-08-07 09:00+00', '2026-08-07 09:00+00');
INSERT INTO governance_signing_key_version (
  signing_key_version_id, service_principal_id, key_purpose,
  key_fingerprint, key_state, authorized_manifest_kinds,
  effective_from, expires_at, system_available_at
) VALUES (
  '86250000-0000-4000-8000-000000000001',
  'a9000000-0000-4000-8000-000000000025', 'test-governance',
  'ctr013-extra-event-registry-key-v1', 'active', ARRAY['event-registry']::text[],
  '2026-08-07 09:00+00', '2027-08-07 09:00+00', '2026-08-07 09:00+00'
);

SELECT import_event_registry_manifest(
  jsonb_build_object(
    'schemaVersion', 'm1.event-registry.ctr013.extra.v1',
    'schemaHash', repeat('a', 64),
    'signatureStatus', 'signed',
    'manifestSignature', 'ctr013-extra-family-signature',
    'eventTypes', jsonb_build_array(
      jsonb_build_object(
        'eventType', 'WATERMARK_GAP_STATE',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'WATERMARK_GAP_LIFECYCLE',
        'aggregateKind', 'record', 'aggregateConcreteType', 'WatermarkGap',
        'payloadSchemaHash', repeat('b', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'open', 'isInitialState', true),
          jsonb_build_object('stateKey', 'closed', 'isInitialState', false),
          jsonb_build_object('stateKey', 'superseded', 'isInitialState', false)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'open', 'toState', 'closed', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'open', 'toState', 'superseded', 'isInitialTransition', false, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'watermark_gap_state', 'typedApiAliasSharesEventId', true))),
      jsonb_build_object(
        'eventType', 'SIGNING_KEY_STATE',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'SIGNING_KEY_LIFECYCLE',
        'aggregateKind', 'record', 'aggregateConcreteType', 'SigningKeyVersion',
        'payloadSchemaHash', repeat('c', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'active', 'isInitialState', true),
          jsonb_build_object('stateKey', 'revoked', 'isInitialState', false),
          jsonb_build_object('stateKey', 'compromised', 'isInitialState', false)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'active', 'toState', 'revoked', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'active', 'toState', 'compromised', 'isInitialTransition', false, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'signing_key_state', 'typedApiAliasSharesEventId', true))),
      jsonb_build_object(
        'eventType', 'MEMORY_CANDIDATE_DECISION',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'MEMORY_CANDIDATE_LIFECYCLE',
        'aggregateKind', 'object', 'aggregateConcreteType', 'MemoryCandidate',
        'payloadSchemaHash', repeat('d', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'pending', 'isInitialState', true),
          jsonb_build_object('stateKey', 'accepted', 'isInitialState', false),
          jsonb_build_object('stateKey', 'rejected', 'isInitialState', false),
          jsonb_build_object('stateKey', 'revoked', 'isInitialState', false)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'pending', 'toState', 'accepted', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'pending', 'toState', 'rejected', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'rejected', 'toState', 'accepted', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'accepted', 'toState', 'revoked', 'isInitialTransition', false, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'memory_candidate_decision', 'typedApiAliasSharesEventId', true))),
      jsonb_build_object(
        'eventType', 'CORRECTION_PROPOSAL_DECISION',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'CORRECTION_PROPOSAL_LIFECYCLE',
        'aggregateKind', 'record', 'aggregateConcreteType', 'CorrectionProposal',
        'payloadSchemaHash', repeat('e', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'pending', 'isInitialState', true),
          jsonb_build_object('stateKey', 'accepted', 'isInitialState', false),
          jsonb_build_object('stateKey', 'rejected', 'isInitialState', false),
          jsonb_build_object('stateKey', 'withdrawn', 'isInitialState', false)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'pending', 'toState', 'accepted', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'pending', 'toState', 'rejected', 'isInitialTransition', false, 'typedGuardRequired', true),
          jsonb_build_object('fromState', 'pending', 'toState', 'withdrawn', 'isInitialTransition', false, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'correction_proposal_decision', 'typedApiAliasSharesEventId', true)))
    )
  ),
  'a9000000-0000-4000-8000-000000000025',
  '2026-08-07 09:00+00', '2026-08-07 09:00+00', true,
  '86250000-0000-4000-8000-000000000001', '2026-08-07 09:00+00'
);

INSERT INTO global_identity_registry VALUES
  ('92000000-0000-4000-8000-000000000025', 'record', 'WatermarkGap', '2026-08-07 09:00+00', '2026-08-07 09:00+00'),
  ('92000000-0000-4000-8000-000000000026', 'record', 'SigningKeyVersion', '2026-08-07 09:00+00', '2026-08-07 09:00+00'),
  ('92000000-0000-4000-8000-000000000027', 'object', 'MemoryCandidate', '2026-08-07 09:00+00', '2026-08-07 09:00+00'),
  ('92000000-0000-4000-8000-000000000028', 'record', 'CorrectionProposal', '2026-08-07 09:00+00', '2026-08-07 09:00+00'),
  ('a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', '2026-08-07 09:00+00', '2026-08-07 09:00+00');

INSERT INTO global_identity_registry VALUES
  ('91500000-0000-4000-8000-000000000025', 'event', 'WATERMARK_GAP_STATE', '2026-08-07 09:01+00', '2026-08-07 09:01+00'),
  ('91500000-0000-4000-8000-000000000026', 'event', 'WATERMARK_GAP_STATE', '2026-08-07 09:02+00', '2026-08-07 09:02+00'),
  ('91500000-0000-4000-8000-000000000027', 'event', 'SIGNING_KEY_STATE', '2026-08-07 09:03+00', '2026-08-07 09:03+00'),
  ('91500000-0000-4000-8000-000000000028', 'event', 'SIGNING_KEY_STATE', '2026-08-07 09:04+00', '2026-08-07 09:04+00'),
  ('91500000-0000-4000-8000-000000000029', 'event', 'MEMORY_CANDIDATE_DECISION', '2026-08-07 09:05+00', '2026-08-07 09:05+00'),
  ('91500000-0000-4000-8000-000000000030', 'event', 'MEMORY_CANDIDATE_DECISION', '2026-08-07 09:06+00', '2026-08-07 09:06+00'),
  ('91500000-0000-4000-8000-000000000031', 'event', 'CORRECTION_PROPOSAL_DECISION', '2026-08-07 09:07+00', '2026-08-07 09:07+00'),
  ('91500000-0000-4000-8000-000000000032', 'event', 'CORRECTION_PROPOSAL_DECISION', '2026-08-07 09:08+00', '2026-08-07 09:08+00'),
  ('91500000-0000-4000-8000-000000000033', 'event', 'CORRECTION_PROPOSAL_DECISION', '2026-08-07 09:09+00', '2026-08-07 09:09+00');

INSERT INTO event_base VALUES
  ('91500000-0000-4000-8000-000000000025', 'm1.event-registry.ctr013.extra.v1', 'WATERMARK_GAP_STATE', '92000000-0000-4000-8000-000000000025', 'record', 'WatermarkGap', '2026-08-07 09:01+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 1, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'watermark gap opened', 'ctr013-extra', 'watermark-1', 'WATERMARK_GAP_LIFECYCLE', 1, NULL),
  ('91500000-0000-4000-8000-000000000026', 'm1.event-registry.ctr013.extra.v1', 'WATERMARK_GAP_STATE', '92000000-0000-4000-8000-000000000025', 'record', 'WatermarkGap', '2026-08-07 09:02+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 2, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'watermark gap closed', 'ctr013-extra', 'watermark-2', 'WATERMARK_GAP_LIFECYCLE', 2, '91500000-0000-4000-8000-000000000025'),
  ('91500000-0000-4000-8000-000000000027', 'm1.event-registry.ctr013.extra.v1', 'SIGNING_KEY_STATE', '92000000-0000-4000-8000-000000000026', 'record', 'SigningKeyVersion', '2026-08-07 09:03+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 3, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'signing key active', 'ctr013-extra', 'key-1', 'SIGNING_KEY_LIFECYCLE', 1, NULL),
  ('91500000-0000-4000-8000-000000000028', 'm1.event-registry.ctr013.extra.v1', 'SIGNING_KEY_STATE', '92000000-0000-4000-8000-000000000026', 'record', 'SigningKeyVersion', '2026-08-07 09:04+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 4, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'signing key revoked', 'ctr013-extra', 'key-2', 'SIGNING_KEY_LIFECYCLE', 2, '91500000-0000-4000-8000-000000000027'),
  ('91500000-0000-4000-8000-000000000029', 'm1.event-registry.ctr013.extra.v1', 'MEMORY_CANDIDATE_DECISION', '92000000-0000-4000-8000-000000000027', 'object', 'MemoryCandidate', '2026-08-07 09:05+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 5, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'memory pending', 'ctr013-extra', 'memory-1', 'MEMORY_CANDIDATE_LIFECYCLE', 1, NULL),
  ('91500000-0000-4000-8000-000000000030', 'm1.event-registry.ctr013.extra.v1', 'MEMORY_CANDIDATE_DECISION', '92000000-0000-4000-8000-000000000027', 'object', 'MemoryCandidate', '2026-08-07 09:06+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 6, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'memory accepted', 'ctr013-extra', 'memory-2', 'MEMORY_CANDIDATE_LIFECYCLE', 2, '91500000-0000-4000-8000-000000000029'),
  ('91500000-0000-4000-8000-000000000031', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', '92000000-0000-4000-8000-000000000028', 'record', 'CorrectionProposal', '2026-08-07 09:07+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 7, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'proposal pending', 'ctr013-extra', 'proposal-1', 'CORRECTION_PROPOSAL_LIFECYCLE', 1, NULL),
  ('91500000-0000-4000-8000-000000000032', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', '92000000-0000-4000-8000-000000000028', 'record', 'CorrectionProposal', '2026-08-07 09:08+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 8, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'proposal accepted', 'ctr013-extra', 'proposal-2', 'CORRECTION_PROPOSAL_LIFECYCLE', 2, '91500000-0000-4000-8000-000000000031');

INSERT INTO event_transition_state VALUES
  ('91500000-0000-4000-8000-000000000025', 'm1.event-registry.ctr013.extra.v1', 'WATERMARK_GAP_STATE', 'WATERMARK_GAP_LIFECYCLE', '92000000-0000-4000-8000-000000000025', 1, NULL, 'open'),
  ('91500000-0000-4000-8000-000000000026', 'm1.event-registry.ctr013.extra.v1', 'WATERMARK_GAP_STATE', 'WATERMARK_GAP_LIFECYCLE', '92000000-0000-4000-8000-000000000025', 2, 'open', 'closed'),
  ('91500000-0000-4000-8000-000000000027', 'm1.event-registry.ctr013.extra.v1', 'SIGNING_KEY_STATE', 'SIGNING_KEY_LIFECYCLE', '92000000-0000-4000-8000-000000000026', 1, NULL, 'active'),
  ('91500000-0000-4000-8000-000000000028', 'm1.event-registry.ctr013.extra.v1', 'SIGNING_KEY_STATE', 'SIGNING_KEY_LIFECYCLE', '92000000-0000-4000-8000-000000000026', 2, 'active', 'revoked'),
  ('91500000-0000-4000-8000-000000000029', 'm1.event-registry.ctr013.extra.v1', 'MEMORY_CANDIDATE_DECISION', 'MEMORY_CANDIDATE_LIFECYCLE', '92000000-0000-4000-8000-000000000027', 1, NULL, 'pending'),
  ('91500000-0000-4000-8000-000000000030', 'm1.event-registry.ctr013.extra.v1', 'MEMORY_CANDIDATE_DECISION', 'MEMORY_CANDIDATE_LIFECYCLE', '92000000-0000-4000-8000-000000000027', 2, 'pending', 'accepted'),
  ('91500000-0000-4000-8000-000000000031', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', 'CORRECTION_PROPOSAL_LIFECYCLE', '92000000-0000-4000-8000-000000000028', 1, NULL, 'pending'),
  ('91500000-0000-4000-8000-000000000032', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', 'CORRECTION_PROPOSAL_LIFECYCLE', '92000000-0000-4000-8000-000000000028', 2, 'pending', 'accepted');

COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO event_base VALUES
      ('91500000-0000-4000-8000-000000000033', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', '92000000-0000-4000-8000-000000000028', 'record', 'CorrectionProposal', '2026-08-07 09:09+00', NULL, 'not_applicable', 'a9100000-0000-4000-8000-000000000025', 9, 'a9000000-0000-4000-8000-000000000025', 'object', 'ServicePrincipal', NULL, NULL, NULL, 'invalid withdraw after accept', 'ctr013-extra', 'proposal-3', 'CORRECTION_PROPOSAL_LIFECYCLE', 3, '91500000-0000-4000-8000-000000000032');
    INSERT INTO event_transition_state VALUES
      ('91500000-0000-4000-8000-000000000033', 'm1.event-registry.ctr013.extra.v1', 'CORRECTION_PROPOSAL_DECISION', 'CORRECTION_PROPOSAL_LIFECYCLE', '92000000-0000-4000-8000-000000000028', 3, 'accepted', 'withdrawn');
    SET CONSTRAINTS event_transition_state_guard IMMEDIATE;
    RAISE EXCEPTION 'unregistered correction transition was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'event transition is not registered' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'EVENT FAMILY TRANSITION FIXTURES PASSED' AS result;
