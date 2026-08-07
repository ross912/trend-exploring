\set ON_ERROR_STOP on

BEGIN;

INSERT INTO service_principal VALUES
  ('a7000000-0000-4000-8000-000000000023', 'ctr013-family-fixture',
   '2026-08-07 07:00+00', '2026-08-07 07:00+00');

SELECT import_event_registry_manifest(
  jsonb_build_object(
    'schemaVersion', 'm1.event-registry.ctr013.v1',
    'schemaHash', repeat('a', 64),
    'signatureStatus', 'signed',
    'manifestSignature', 'ctr013-family-signature',
    'eventTypes', jsonb_build_array(
      jsonb_build_object(
        'eventType', 'RADAR_PUBLICATION',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'RADAR_PUBLICATION_LIFECYCLE',
        'aggregateKind', 'record',
        'aggregateConcreteType', 'RadarSurface',
        'payloadSchemaHash', repeat('b', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'active', 'isInitialState', true),
          jsonb_build_object('stateKey', 'superseded', 'isInitialState', false)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'active', 'toState', 'superseded',
                             'isInitialTransition', false, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(
          jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'radar_publication',
                             'typedApiAliasSharesEventId', true))),
      jsonb_build_object(
        'eventType', 'REVOCATION_EPOCH',
        'stateSemantics', 'exclusive_transition',
        'stateMachineFamily', 'REVOCATION_EPOCH_LIFECYCLE',
        'aggregateKind', 'record',
        'aggregateConcreteType', 'RevocationDomain',
        'payloadSchemaHash', repeat('c', 64),
        'states', jsonb_build_array(
          jsonb_build_object('stateKey', 'current', 'isInitialState', true)),
        'transitions', jsonb_build_array(
          jsonb_build_object('fromState', 'current', 'toState', 'current',
                             'isInitialTransition', true, 'typedGuardRequired', true)),
        'apiAliases', jsonb_build_array(
          jsonb_build_object('aliasKey', 'canonical', 'aliasPath', 'revocation_epoch',
                             'typedApiAliasSharesEventId', true)))
    )
  ),
  'a7000000-0000-4000-8000-000000000023',
  '2026-08-07 07:00+00', '2026-08-07 07:00+00', true
);

INSERT INTO global_identity_registry VALUES
  ('92000000-0000-4000-8000-000000000023', 'record', 'RadarSurface',
   '2026-08-07 07:00+00', '2026-08-07 07:00+00'),
  ('92000000-0000-4000-8000-000000000024', 'record', 'RevocationDomain',
   '2026-08-07 07:00+00', '2026-08-07 07:00+00'),
  ('a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
   '2026-08-07 07:00+00', '2026-08-07 07:00+00'),
  ('91000000-0000-4000-8000-000000000023', 'event', 'RADAR_PUBLICATION',
   '2026-08-07 07:01+00', '2026-08-07 07:01+00'),
  ('91000000-0000-4000-8000-000000000024', 'event', 'RADAR_PUBLICATION',
   '2026-08-07 07:02+00', '2026-08-07 07:02+00'),
  ('91000000-0000-4000-8000-000000000025', 'event', 'REVOCATION_EPOCH',
   '2026-08-07 07:03+00', '2026-08-07 07:03+00'),
  ('91000000-0000-4000-8000-000000000026', 'event', 'RADAR_PUBLICATION',
   '2026-08-07 07:04+00', '2026-08-07 07:04+00');

INSERT INTO event_base VALUES
  ('91000000-0000-4000-8000-000000000023', 'm1.event-registry.ctr013.v1', 'RADAR_PUBLICATION',
   '92000000-0000-4000-8000-000000000023', 'record', 'RadarSurface',
   '2026-08-07 07:01+00', NULL, 'not_applicable',
   'a8000000-0000-4000-8000-000000000023', 1,
   'a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
   NULL, NULL, NULL, 'radar initial', 'ctr013', 'radar-1',
   'RADAR_PUBLICATION_LIFECYCLE', 1, NULL),
  ('91000000-0000-4000-8000-000000000024', 'm1.event-registry.ctr013.v1', 'RADAR_PUBLICATION',
   '92000000-0000-4000-8000-000000000023', 'record', 'RadarSurface',
   '2026-08-07 07:02+00', NULL, 'not_applicable',
   'a8000000-0000-4000-8000-000000000023', 2,
   'a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
   NULL, NULL, NULL, 'radar supersede', 'ctr013', 'radar-2',
   'RADAR_PUBLICATION_LIFECYCLE', 2, '91000000-0000-4000-8000-000000000023'),
  ('91000000-0000-4000-8000-000000000025', 'm1.event-registry.ctr013.v1', 'REVOCATION_EPOCH',
   '92000000-0000-4000-8000-000000000024', 'record', 'RevocationDomain',
   '2026-08-07 07:03+00', NULL, 'not_applicable',
   'a8000000-0000-4000-8000-000000000023', 3,
   'a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
   NULL, NULL, NULL, 'revocation epoch', 'ctr013', 'revocation-1',
   'REVOCATION_EPOCH_LIFECYCLE', 1, NULL);

COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO event_base VALUES
      ('91000000-0000-4000-8000-000000000026', 'm1.event-registry.ctr013.v1', 'RADAR_PUBLICATION',
       '92000000-0000-4000-8000-000000000023', 'record', 'RadarSurface',
       '2026-08-07 07:04+00', NULL, 'not_applicable',
       'a8000000-0000-4000-8000-000000000023', 4,
       'a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
       NULL, NULL, NULL, 'wrong predecessor', 'ctr013', 'radar-3',
       'RADAR_PUBLICATION_LIFECYCLE', 3, '91000000-0000-4000-8000-000000000023');
    RAISE EXCEPTION 'wrong expected head predecessor was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'exclusive event predecessor is not revision - 1 on the same aggregate' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO event_base VALUES
      ('91000000-0000-4000-8000-000000000026', 'm1.event-registry.ctr013.v1', 'RADAR_PUBLICATION',
       '92000000-0000-4000-8000-000000000023', 'record', 'RadarSurface',
       '2026-08-07 07:04+00', NULL, 'not_applicable',
       'a8000000-0000-4000-8000-000000000023', 4,
       'a7000000-0000-4000-8000-000000000023', 'object', 'ServicePrincipal',
       NULL, NULL, NULL, 'duplicate revision', 'ctr013', 'radar-duplicate',
       'RADAR_PUBLICATION_LIFECYCLE', 2, '91000000-0000-4000-8000-000000000023');
    RAISE EXCEPTION 'duplicate expected-head revision was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'exclusive event revision must extend the current expected head' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'EVENT FAMILY EXPECTED HEAD FIXTURES PASSED' AS result;
