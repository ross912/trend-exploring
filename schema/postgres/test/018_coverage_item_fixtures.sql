\set ON_ERROR_STOP on

BEGIN;

INSERT INTO coverage_policy_registry (
  coverage_policy_version, policy_hash, effective_from, system_available_at
) VALUES
  ('coverage-policy-v1', repeat('1', 64), '2026-08-07 04:00+00', '2026-08-07 04:00+00'),
  ('coverage-policy-v2', repeat('2', 64), '2026-08-07 04:02+00', '2026-08-07 04:02+00');
INSERT INTO coverage_projection_role_registry (
  projection_role, role_kind, effective_from, system_available_at
) VALUES
  ('primary', 'coverage-primary', '2026-08-07 04:00+00', '2026-08-07 04:00+00');
INSERT INTO coverage_stratum_version_registry (
  stratum_version_id, stratum_key, stratum_hash, effective_from, system_available_at
) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'stratum-a', repeat('a', 64), '2026-08-07 04:00+00', '2026-08-07 04:00+00'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'stratum-b', repeat('b', 64), '2026-08-07 04:00+00', '2026-08-07 04:00+00');
INSERT INTO coverage_detector_version_registry (
  detector_version_id, detector_key, detector_hash, effective_from, system_available_at
) VALUES
  ('eeeeeeee-0000-4000-8000-000000000001', 'detector-v1', repeat('c', 64), '2026-08-07 04:00+00', '2026-08-07 04:00+00');

WITH source AS (
  SELECT
    'aaaaaaaa-0000-4000-8000-000000000001'::uuid AS scope_snapshot_id,
    'coverage-policy-v1'::text AS coverage_policy_version,
    'projection-semantics-v1'::text AS projection_semantics_version,
    'event_cluster'::coverage_item_kind AS item_kind,
    '{"typedInputKind":"event_cluster","typedInputKey":"event-cluster-v1"}'::jsonb AS typed_input_refs,
    ARRAY['bbbbbbbb-0000-4000-8000-000000000001'::uuid,
          'bbbbbbbb-0000-4000-8000-000000000002'::uuid] AS primary_strata,
    'primary'::text AS projection_role
), keyed AS (
  SELECT source.*,
         m1_coverage_projection_key(scope_snapshot_id, coverage_policy_version,
           projection_semantics_version, item_kind, typed_input_refs,
           primary_strata, projection_role) AS projection_key
    FROM source
)
INSERT INTO coverage_item (
  coverage_item_id, scope_snapshot_id, coverage_policy_version,
  projection_semantics_version, item_kind, typed_input_refs,
  primary_stratum_version_ids, projection_role, recorded_at,
  system_available_at, as_of, run_mode, input_record_ids
)
SELECT m1_uuid5('0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', projection_key),
       scope_snapshot_id, coverage_policy_version, projection_semantics_version,
       item_kind, typed_input_refs, primary_strata, projection_role,
       '2026-08-07 04:00+00', '2026-08-07 04:00+00', '2026-08-07 04:00+00',
       'prospective', ARRAY['cccccccc-0000-4000-8000-000000000001']::uuid[]
  FROM keyed;

DO $$
DECLARE
  selected_item_id uuid;
  generation_id uuid;
  message_text text;
BEGIN
  SELECT coverage_item_id INTO selected_item_id FROM coverage_item LIMIT 1;
  IF selected_item_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM coverage_item
        WHERE coverage_item_id = selected_item_id
          AND coverage_item_id = m1_uuid5(
            '0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', coverage_projection_key)
     ) THEN
    RAISE EXCEPTION 'coverage item canonical identity was not persisted';
  END IF;

  BEGIN
    INSERT INTO coverage_item (
      coverage_item_id, scope_snapshot_id, coverage_policy_version,
      projection_semantics_version, item_kind, typed_input_refs,
      primary_stratum_version_ids, projection_role, recorded_at,
      system_available_at, as_of, run_mode, input_record_ids
    )
    SELECT 'dddddddd-0000-4000-8000-000000000001', scope_snapshot_id,
           coverage_policy_version, projection_semantics_version, item_kind,
           typed_input_refs, primary_stratum_version_ids, projection_role,
           recorded_at, system_available_at, as_of, run_mode, input_record_ids
      FROM coverage_item existing WHERE existing.coverage_item_id = selected_item_id;
    RAISE EXCEPTION 'client supplied random CoverageItem ID was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'coverage item id does not match canonical projection key' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO coverage_item (
      coverage_item_id, scope_snapshot_id, coverage_policy_version,
      projection_semantics_version, item_kind, typed_input_refs,
      primary_stratum_version_ids, projection_role, recorded_at,
      system_available_at, as_of, run_mode, input_record_ids
    )
    SELECT coverage_item_id, scope_snapshot_id, coverage_policy_version,
           projection_semantics_version, item_kind, typed_input_refs,
           primary_stratum_version_ids, projection_role, recorded_at,
           system_available_at, as_of, run_mode, input_record_ids
      FROM coverage_item existing WHERE existing.coverage_item_id = selected_item_id;
    RAISE EXCEPTION 'duplicate canonical CoverageItem was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  WITH generation AS (
    SELECT selected_item_id AS coverage_item_id,
           'eeeeeeee-0000-4000-8000-000000000001'::uuid AS detector_version_id,
           'generation-semantics-v1'::text AS generation_semantics_version
  )
  INSERT INTO coverage_generation_unit (
    generation_unit_id, coverage_item_id, detector_version_id,
    generation_semantics_version, recorded_at, system_available_at,
    as_of, run_mode, input_record_ids
  )
  SELECT m1_uuid5('0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5',
                  m1_coverage_generation_key(coverage_item_id, detector_version_id, generation_semantics_version)),
         coverage_item_id, detector_version_id, generation_semantics_version,
         '2026-08-07 04:01+00', '2026-08-07 04:01+00', '2026-08-07 04:01+00',
         'prospective', ARRAY['cccccccc-0000-4000-8000-000000000002']::uuid[]
    FROM generation;

  SELECT generation_unit_id INTO generation_id FROM coverage_generation_unit LIMIT 1;
  IF generation_id IS NULL THEN RAISE EXCEPTION 'coverage generation unit was not created'; END IF;

  BEGIN
    UPDATE coverage_item SET projection_role = 'tampered' WHERE coverage_item_id = selected_item_id;
    RAISE EXCEPTION 'coverage item mutation was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'coverage_item is append-only' THEN RAISE; END IF;
  END;
END;
$$;

WITH source AS (
  SELECT
    'aaaaaaaa-0000-4000-8000-000000000001'::uuid AS scope_snapshot_id,
    'coverage-policy-v2'::text AS coverage_policy_version,
    'projection-semantics-v1'::text AS projection_semantics_version,
    'event_cluster'::coverage_item_kind AS item_kind,
    '{"typedInputKind":"event_cluster","typedInputKey":"event-cluster-v1"}'::jsonb AS typed_input_refs,
    ARRAY['bbbbbbbb-0000-4000-8000-000000000001'::uuid,
          'bbbbbbbb-0000-4000-8000-000000000002'::uuid] AS primary_strata,
    'primary'::text AS projection_role
), keyed AS (
  SELECT source.*,
         m1_coverage_projection_key(scope_snapshot_id, coverage_policy_version,
           projection_semantics_version, item_kind, typed_input_refs,
           primary_strata, projection_role) AS projection_key
    FROM source
)
INSERT INTO coverage_item (
  coverage_item_id, scope_snapshot_id, coverage_policy_version,
  projection_semantics_version, item_kind, typed_input_refs,
  primary_stratum_version_ids, projection_role, recorded_at,
  system_available_at, as_of, run_mode, input_record_ids
)
SELECT m1_uuid5('0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', projection_key),
       scope_snapshot_id, coverage_policy_version, projection_semantics_version,
       item_kind, typed_input_refs, primary_strata, projection_role,
       '2026-08-07 04:02+00', '2026-08-07 04:02+00', '2026-08-07 04:02+00',
       'prospective', ARRAY['cccccccc-0000-4000-8000-000000000003']::uuid[]
  FROM keyed;

INSERT INTO coverage_watermark_gap (
  coverage_watermark_gap_id, coverage_item_id, gap_state, reason_code,
  recorded_at, system_available_at
)
SELECT 'ffff0000-0000-4000-8000-000000000002', coverage_item_id, 'open',
       'generation_not_emitted', '2026-08-07 04:02+00', '2026-08-07 04:02+00'
  FROM coverage_item
 WHERE coverage_policy_version = 'coverage-policy-v2';

DO $$
BEGIN
  IF (SELECT count(*) FROM coverage_item) <> 2 THEN
    RAISE EXCEPTION 'real policy change did not create a distinct CoverageItem';
  END IF;
END;
$$;

SELECT 'COVERAGE ITEM FIXTURES PASSED' AS result;

COMMIT;
