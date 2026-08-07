\set ON_ERROR_STOP on

-- CTR-007: p_signature_verified=true represents a cryptographically valid
-- detached signature at ingress.  The database must still reject a key that
-- is unauthorized for the manifest kind, outside its validity window, or
-- revoked/compromised.

INSERT INTO service_principal VALUES
  ('a2400000-0000-4000-8000-000000000024', 'ctr007-signature-fixture',
   '2026-08-07 08:00+00', '2026-08-07 08:00+00');

INSERT INTO governance_signing_key_version (
  signing_key_version_id, service_principal_id, key_purpose,
  key_fingerprint, key_state, authorized_manifest_kinds,
  effective_from, expires_at, system_available_at
) VALUES
  ('86240000-0000-4000-8000-000000000001',
   'a2400000-0000-4000-8000-000000000024', 'test-governance',
   'ctr007-catalog-only-key', 'active', ARRAY['test-catalog']::text[],
   '2026-08-07 08:00+00', '2027-08-07 08:00+00', '2026-08-07 08:00+00'),
  ('86240000-0000-4000-8000-000000000002',
   'a2400000-0000-4000-8000-000000000024', 'test-governance',
   'ctr007-expired-key', 'active', ARRAY['event-registry']::text[],
   '2026-08-07 08:00+00', '2026-08-07 08:10+00', '2026-08-07 08:00+00'),
  ('86240000-0000-4000-8000-000000000003',
   'a2400000-0000-4000-8000-000000000024', 'test-governance',
   'ctr007-revoked-key', 'revoked', ARRAY['event-registry']::text[],
   '2026-08-07 08:00+00', '2027-08-07 08:00+00', '2026-08-07 08:00+00');

DO $$
DECLARE
  manifest jsonb := jsonb_build_object(
    'schemaVersion', 'm1.event-registry.ctr007.fixture.v1',
    'schemaHash', repeat('a', 64),
    'signatureStatus', 'signed',
    'manifestSignature', 'ctr007-cryptographically-valid-fixture',
    'eventTypes', jsonb_build_array(jsonb_build_object(
      'eventType', 'GOVERNANCE_SIGNATURE_FIXTURE',
      'stateSemantics', 'append_observation',
      'stateMachineFamily', NULL,
      'aggregateKind', 'object',
      'aggregateConcreteType', 'SignalCandidate',
      'payloadSchemaHash', repeat('b', 64),
      'apiAliases', jsonb_build_array(jsonb_build_object(
        'aliasKey', 'canonical',
        'aliasPath', 'governance_signature_fixture',
        'typedApiAliasSharesEventId', true))
    ))
  );
  message_text text;
BEGIN
  BEGIN
    PERFORM import_event_registry_manifest(
      manifest, 'a2400000-0000-4000-8000-000000000024',
      '2026-08-07 08:00+00', '2026-08-07 08:00+00', true,
      '86240000-0000-4000-8000-000000000001', '2026-08-07 08:00+00');
    RAISE EXCEPTION 'unauthorized manifest key was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'manifest signing key is not currently authorized' THEN RAISE; END IF;
  END;

  manifest := jsonb_set(
    manifest, '{schemaVersion}', to_jsonb('m1.event-registry.ctr007.expired.v1'::text));
  BEGIN
    PERFORM import_event_registry_manifest(
      manifest, 'a2400000-0000-4000-8000-000000000024',
      '2026-08-07 08:11+00', '2026-08-07 08:11+00', true,
      '86240000-0000-4000-8000-000000000002', '2026-08-07 08:11+00');
    RAISE EXCEPTION 'expired manifest key was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'manifest signing key is not currently authorized' THEN RAISE; END IF;
  END;

  manifest := jsonb_set(
    manifest, '{schemaVersion}', to_jsonb('m1.event-registry.ctr007.revoked.v1'::text));
  BEGIN
    PERFORM import_event_registry_manifest(
      manifest, 'a2400000-0000-4000-8000-000000000024',
      '2026-08-07 08:01+00', '2026-08-07 08:01+00', true,
      '86240000-0000-4000-8000-000000000003', '2026-08-07 08:01+00');
    RAISE EXCEPTION 'revoked manifest key was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'manifest signing key is not currently authorized' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'TEST GOVERNANCE SIGNATURE FIXTURES PASSED' AS result;
