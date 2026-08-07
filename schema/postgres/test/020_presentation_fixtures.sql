\set ON_ERROR_STOP on

WITH source AS (
  SELECT
    'aaaaaaaa-0000-4000-8000-000000000020'::uuid AS presentation_event_id,
    'bbbbbbbb-0000-4000-8000-000000000020'::uuid AS claim_slot_manifest_id,
    'cccccccc-0000-4000-8000-000000000020'::uuid AS container_identity_id,
    'web'::text AS channel,
    'zh-CN'::text AS locale,
    1::integer AS ordinal,
    2::integer AS maximum_ordinal,
    repeat('a', 64)::text AS manifest_hash
), keyed AS (
  SELECT source.*,
         m1_claim_generation_key(presentation_event_id, claim_slot_manifest_id,
           container_identity_id, channel, locale, ordinal, manifest_hash) AS generation_key
    FROM source
)
INSERT INTO claim_generation_unit (
  claim_generation_unit_id, presentation_event_id, claim_slot_manifest_id,
  container_identity_id, channel, locale, ordinal, minimum_required,
  maximum_ordinal, claim_slot_manifest_hash, recorded_at, system_available_at,
  as_of, run_mode, input_record_ids
)
SELECT m1_uuid5('f2a83d84-3b92-5d5f-9c37-9d8a5f4e2b10', generation_key),
       presentation_event_id, claim_slot_manifest_id, container_identity_id,
       channel, locale, ordinal, true, maximum_ordinal, manifest_hash,
       '2026-08-07 05:00+00', '2026-08-07 05:00+00', '2026-08-07 05:00+00',
       'prospective', ARRAY['dddddddd-0000-4000-8000-000000000020']::uuid[]
  FROM keyed;

INSERT INTO claim_generation_decision VALUES
  ('eeeeeeee-0000-4000-8000-000000000020',
   (SELECT claim_generation_unit_id FROM claim_generation_unit LIMIT 1),
   'claim', 'required minimum claim slot generated',
   '2026-08-07 05:01+00', '2026-08-07 05:01+00', '2026-08-07 05:01+00',
   'prospective', ARRAY['dddddddd-0000-4000-8000-000000000021']::uuid[]);

DO $$
DECLARE
  unit_id uuid;
  plan_id uuid;
  content_id uuid;
  message_text text;
BEGIN
  SELECT claim_generation_unit_id INTO unit_id FROM claim_generation_unit LIMIT 1;
  BEGIN
    INSERT INTO claim_generation_unit (
      claim_generation_unit_id, presentation_event_id, claim_slot_manifest_id,
      container_identity_id, channel, locale, ordinal, minimum_required,
      maximum_ordinal, claim_slot_manifest_hash, recorded_at, system_available_at,
      as_of, run_mode, input_record_ids
    )
    SELECT 'ffffffff-0000-4000-8000-000000000020', presentation_event_id,
           claim_slot_manifest_id, container_identity_id, channel, locale,
           ordinal, minimum_required, maximum_ordinal, claim_slot_manifest_hash,
           recorded_at, system_available_at, as_of, run_mode, input_record_ids
      FROM claim_generation_unit existing WHERE existing.claim_generation_unit_id = unit_id;
    RAISE EXCEPTION 'random claim generation unit id was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'claim generation unit id does not match canonical slot key' THEN RAISE; END IF;
  END;

  INSERT INTO presentation_render_plan VALUES
    ('11111111-0000-4000-8000-000000000020',
     'aaaaaaaa-0000-4000-8000-000000000020', 'web', 'zh-CN', repeat('b', 64),
     '2026-08-07 05:02+00', '2026-08-07 05:02+00', '2026-08-07 05:02+00',
     'prospective', ARRAY['dddddddd-0000-4000-8000-000000000022']::uuid[])
  RETURNING presentation_render_plan_id INTO plan_id;

  BEGIN
    INSERT INTO presentation_render_plan VALUES
      ('11111111-0000-4000-8000-000000000021',
       'aaaaaaaa-0000-4000-8000-000000000020', 'web', 'zh-CN', repeat('c', 64),
       '2026-08-07 05:03+00', '2026-08-07 05:03+00', '2026-08-07 05:03+00',
       'prospective', ARRAY['dddddddd-0000-4000-8000-000000000023']::uuid[]);
    RAISE EXCEPTION 'second plan for one presentation event was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  INSERT INTO presentation_content_unit VALUES
    ('22222222-0000-4000-8000-000000000020', plan_id,
     'cccccccc-0000-4000-8000-000000000020', 'web', 'zh-CN', 1, 'title',
     '2026-08-07 05:04+00', '2026-08-07 05:04+00', '2026-08-07 05:04+00',
     'prospective', ARRAY['dddddddd-0000-4000-8000-000000000024']::uuid[])
  RETURNING presentation_content_unit_id INTO content_id;
  INSERT INTO presentation_title_content VALUES (content_id, 'A typed title');

  BEGIN
    INSERT INTO presentation_body_content VALUES (content_id, 'wrong child kind');
    RAISE EXCEPTION 'kind-incompatible presentation child was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'presentation content child kind does not match content unit' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO presentation_content_unit VALUES
      ('22222222-0000-4000-8000-000000000021', plan_id,
       'cccccccc-0000-4000-8000-000000000020', 'web', 'zh-CN', 1, 'body',
       '2026-08-07 05:05+00', '2026-08-07 05:05+00', '2026-08-07 05:05+00',
       'prospective', ARRAY['dddddddd-0000-4000-8000-000000000025']::uuid[]);
    RAISE EXCEPTION 'duplicate presentation order was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  INSERT INTO source_text_ref VALUES
    ('33333333-0000-4000-8000-000000000020', plan_id, content_id, 'web', 'zh-CN',
     '44444444-0000-4000-8000-000000000020', NULL,
     '2026-08-07 05:06+00', '2026-08-07 05:06+00');

  BEGIN
    INSERT INTO source_text_ref VALUES
      ('33333333-0000-4000-8000-000000000021', plan_id, content_id, 'web', 'zh-CN',
       NULL, NULL, '2026-08-07 05:07+00', '2026-08-07 05:07+00');
    RAISE EXCEPTION 'source ref without exactly one typed source was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO source_text_ref VALUES
      ('33333333-0000-4000-8000-000000000022', plan_id, content_id, 'web', 'zh-CN',
       '44444444-0000-4000-8000-000000000021',
       '55555555-0000-4000-8000-000000000021',
       '2026-08-07 05:08+00', '2026-08-07 05:08+00');
    RAISE EXCEPTION 'source ref with two typed sources was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO presentation_content_unit VALUES
      ('22222222-0000-4000-8000-000000000022', plan_id,
       'cccccccc-0000-4000-8000-000000000021', 'web', 'zh-CN', 2, 'body',
       '2026-08-07 05:09+00', '2026-08-07 05:09+00', '2026-08-07 05:09+00',
       'prospective', ARRAY['dddddddd-0000-4000-8000-000000000026']::uuid[]);
    SET CONSTRAINTS presentation_content_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'presentation unit without kind-specific child was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'presentation content unit must have exactly one kind-specific child' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'PRESENTATION FIXTURES PASSED' AS result;
