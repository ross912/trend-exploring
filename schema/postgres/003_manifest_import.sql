-- Signed TestCatalog/EventRegistry import boundary.
-- Callers must verify the detached signature outside PostgreSQL and pass
-- p_signature_verified = true.  Unsigned deterministic generator output is
-- deliberately rejected by these functions.

BEGIN;

CREATE OR REPLACE FUNCTION m1_md5_uuid(p_value text)
RETURNS uuid LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  hex text := md5(p_value);
BEGIN
  RETURN format('%s-%s-%s-%s-%s',
    substr(hex, 1, 8), substr(hex, 9, 4), substr(hex, 13, 4),
    substr(hex, 17, 4), substr(hex, 21, 12))::uuid;
END;
$$;

CREATE OR REPLACE FUNCTION import_event_registry_manifest(
  p_registry jsonb,
  p_owner_service_principal_id uuid,
  p_effective_from timestamptz,
  p_system_available_at timestamptz,
  p_signature_verified boolean DEFAULT false,
  p_signing_key_version_id uuid DEFAULT NULL,
  p_signed_at timestamptz DEFAULT NULL
)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  registry_version text;
  schema_hash text;
  manifest_signature text;
  definition jsonb;
  event_type text;
  semantics text;
  state_machine_family text;
  aggregate_kind text;
  aggregate_concrete_type text;
  payload_schema_hash text;
  state jsonb;
  transition jsonb;
  alias jsonb;
  from_state text;
  to_state text;
BEGIN
  IF jsonb_typeof(p_registry) <> 'object'
     OR p_registry->>'signatureStatus' <> 'signed'
     OR coalesce(p_registry->>'manifestSignature', '') = ''
     OR NOT p_signature_verified
     OR p_signing_key_version_id IS NULL
     OR p_signed_at IS NULL THEN
    RAISE EXCEPTION 'event registry signature is not verified';
  END IF;
  registry_version := p_registry->>'schemaVersion';
  schema_hash := p_registry->>'schemaHash';
  manifest_signature := p_registry->>'manifestSignature';
  PERFORM assert_manifest_signature_authorized(
    'event-registry', manifest_signature, p_owner_service_principal_id,
    p_signing_key_version_id, p_signed_at, p_effective_from,
    p_system_available_at, p_signature_verified
  );
  IF coalesce(registry_version, '') = '' THEN
    RAISE EXCEPTION 'event registry manifest is malformed';
  END IF;
  IF EXISTS (SELECT 1 FROM event_type_registry_manifest WHERE event_type_registry_version = registry_version) THEN
    RAISE EXCEPTION 'event registry version is already imported';
  END IF;
  IF coalesce(registry_version, '') = ''
     OR schema_hash !~ '^[a-f0-9]{64}$'
     OR jsonb_typeof(p_registry->'eventTypes') <> 'array'
     OR jsonb_array_length(p_registry->'eventTypes') = 0 THEN
    RAISE EXCEPTION 'event registry manifest is malformed';
  END IF;
  INSERT INTO event_type_registry_manifest VALUES (
    registry_version,
    registry_version,
    schema_hash,
    manifest_signature,
    p_effective_from,
    p_system_available_at,
    p_owner_service_principal_id
  );

  FOR definition IN SELECT value FROM jsonb_array_elements(p_registry->'eventTypes') LOOP
    event_type := definition->>'eventType';
    semantics := definition->>'stateSemantics';
    state_machine_family := NULLIF(definition->>'stateMachineFamily', '');
    aggregate_kind := definition->>'aggregateKind';
    aggregate_concrete_type := definition->>'aggregateConcreteType';
    payload_schema_hash := definition->>'payloadSchemaHash';
    IF coalesce(event_type, '') = ''
       OR semantics IS NULL
       OR aggregate_kind NOT IN ('object', 'record', 'event')
       OR coalesce(aggregate_concrete_type, '') = ''
       OR payload_schema_hash !~ '^[a-f0-9]{64}$' THEN
      RAISE EXCEPTION 'event registry definition is malformed: %', coalesce(event_type, '<unknown>');
    END IF;
    IF semantics = 'exclusive_transition'
       AND (jsonb_typeof(definition->'states') <> 'array'
         OR jsonb_typeof(definition->'transitions') <> 'array') THEN
      RAISE EXCEPTION 'exclusive event lacks state machine children: %', event_type;
    END IF;
    IF jsonb_typeof(definition->'apiAliases') <> 'array'
       OR jsonb_array_length(definition->'apiAliases') = 0 THEN
      RAISE EXCEPTION 'event type lacks a typed API alias: %', event_type;
    END IF;
    INSERT INTO event_type_definition VALUES (
      registry_version,
      event_type,
      semantics::event_state_semantics,
      state_machine_family,
      aggregate_kind::event_identity_kind,
      aggregate_concrete_type,
      payload_schema_hash
    );

    FOR state IN SELECT value FROM jsonb_array_elements(coalesce(definition->'states', '[]'::jsonb)) LOOP
      INSERT INTO event_state_definition VALUES (
        registry_version,
        event_type,
        state->>'stateKey',
        coalesce((state->>'isInitialState')::boolean, false)
      );
    END LOOP;
    FOR transition IN SELECT value FROM jsonb_array_elements(coalesce(definition->'transitions', '[]'::jsonb)) LOOP
      from_state := transition->>'fromState';
      to_state := transition->>'toState';
      INSERT INTO event_state_transition_definition VALUES (
        registry_version,
        event_type,
        from_state,
        to_state,
        coalesce((transition->>'isInitialTransition')::boolean, false),
        coalesce((transition->>'typedGuardRequired')::boolean, false)
      );
    END LOOP;
    FOR alias IN SELECT value FROM jsonb_array_elements(definition->'apiAliases') LOOP
      INSERT INTO event_api_alias VALUES (
        registry_version,
        event_type,
        alias->>'aliasKey',
        alias->>'aliasPath',
        coalesce((alias->>'typedApiAliasSharesEventId')::boolean, false)
      );
    END LOOP;
  END LOOP;
  RETURN registry_version;
END;
$$;

CREATE OR REPLACE FUNCTION import_test_catalog_manifest(
  p_catalog jsonb,
  p_owner_service_principal_id uuid,
  p_effective_from timestamptz,
  p_system_available_at timestamptz,
  p_input_record_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_signature_verified boolean DEFAULT false,
  p_signing_key_version_id uuid DEFAULT NULL,
  p_signed_at timestamptz DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  catalog_id uuid;
  policy_version uuid;
  schema_hash text;
  manifest_signature text;
  definition jsonb;
  member jsonb;
  v_test_id uuid;
  v_definition_version_id uuid;
  v_member_definition_id uuid;
  target_phase text;
  target_gate text;
  v_definition_revision bigint;
BEGIN
  IF jsonb_typeof(p_catalog) <> 'object'
     OR p_catalog->>'signatureStatus' <> 'signed'
     OR coalesce(p_catalog->>'manifestSignature', '') = ''
     OR NOT p_signature_verified
     OR p_signing_key_version_id IS NULL
     OR p_signed_at IS NULL THEN
    RAISE EXCEPTION 'test catalog signature is not verified';
  END IF;
  schema_hash := p_catalog->>'schemaHash';
  manifest_signature := p_catalog->>'manifestSignature';
  PERFORM assert_manifest_signature_authorized(
    'test-catalog', manifest_signature, p_owner_service_principal_id,
    p_signing_key_version_id, p_signed_at, p_effective_from,
    p_system_available_at, p_signature_verified
  );
  policy_version := NULLIF(p_catalog->>'testGovernancePolicyVersion', '')::uuid;
  target_phase := p_catalog->>'targetPhase';
  target_gate := p_catalog->>'targetGate';
  IF schema_hash !~ '^[a-f0-9]{64}$'
     OR policy_version IS NULL
     OR target_phase NOT IN ('M0', 'M1', 'M2', 'M3', 'M4', 'M5')
     OR target_gate NOT IN ('phase-exit', 'normal-edition', 'service-claim', 'release', 'capability-claim', 'version-promotion', 'none')
     OR p_catalog->>'definitionsUniverseHash' !~ '^[a-f0-9]{64}$'
     OR jsonb_typeof(p_catalog->'definitions') <> 'array'
     OR jsonb_typeof(p_catalog->'members') <> 'array'
     OR jsonb_array_length(p_catalog->'definitions') = 0 THEN
    RAISE EXCEPTION 'test catalog manifest is malformed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM test_governance_policy
     WHERE test_governance_policy_version = policy_version
  ) THEN
    RAISE EXCEPTION 'test catalog governance policy is not imported';
  END IF;

  catalog_id := coalesce(
    NULLIF(p_catalog->>'catalogManifestId', '')::uuid,
    m1_md5_uuid((p_catalog->>'schemaVersion') || '|' || target_phase || '|' || target_gate || '|' || (p_catalog->>'definitionsUniverseHash'))
  );
  IF EXISTS (SELECT 1 FROM test_catalog_manifest WHERE test_catalog_manifest_id = catalog_id) THEN
    RAISE EXCEPTION 'test catalog manifest is already imported';
  END IF;

  FOR definition IN SELECT value FROM jsonb_array_elements(p_catalog->'definitions') LOOP
    v_test_id := (definition->>'testId')::uuid;
    v_definition_version_id := (definition->>'testDefinitionVersionId')::uuid;
    v_definition_revision := (definition->>'definitionRevision')::bigint;
    IF v_definition_revision IS NULL OR v_definition_revision <> 1
       OR coalesce(definition->>'testCode', '') = ''
       OR definition->>'definitionHash' !~ '^[a-f0-9]{64}$' THEN
      RAISE EXCEPTION 'test catalog definition is malformed';
    END IF;
    INSERT INTO test_definition VALUES (
      v_test_id,
      definition->>'testCode',
      p_system_available_at,
      p_system_available_at
    ) ON CONFLICT (test_id) DO NOTHING;
    INSERT INTO test_definition_version VALUES (
      v_definition_version_id,
      v_test_id,
      policy_version,
      v_definition_revision,
      NULL,
      NULL,
      (definition->>'introducedPhase')::test_phase,
      (definition->>'runOnOrAfter')::test_phase,
      definition->>'applicabilityPredicate',
      (definition->>'waiverAllowed')::boolean,
      (definition->>'severity')::test_severity,
      (definition->>'blocking')::test_blocking_mode,
      definition->>'fixtureContract',
      definition->>'configContract',
      definition->>'oracleSpec',
      definition->>'definitionHash',
      manifest_signature,
      p_effective_from,
      p_effective_from,
      p_system_available_at,
      p_system_available_at,
      'prospective',
      p_input_record_ids
    );
  END LOOP;

  INSERT INTO test_catalog_manifest VALUES (
    catalog_id,
    target_phase::test_phase,
    target_gate::test_blocking_mode,
    policy_version,
    p_catalog->>'definitionsUniverseHash',
    p_catalog->>'schemaVersion',
    schema_hash,
    manifest_signature,
    p_owner_service_principal_id,
    p_input_record_ids,
    p_effective_from,
    p_system_available_at
  );

  FOR member IN SELECT value FROM jsonb_array_elements(p_catalog->'members') LOOP
    v_member_definition_id := (member->>'testDefinitionVersionId')::uuid;
    INSERT INTO test_catalog_definition_member VALUES (
      m1_md5_uuid(catalog_id::text || '|' || v_member_definition_id::text),
      catalog_id,
      v_member_definition_id,
      (member->>'membership')::test_catalog_membership,
      NULLIF(member->>'exclusionReason', ''),
      coalesce(NULLIF(member->>'applicabilityEvidence', ''), 'imported signed catalog predicate'),
      p_effective_from,
      p_system_available_at
    );
  END LOOP;
  RETURN catalog_id;
END;
$$;

COMMIT;
