\set ON_ERROR_STOP on

BEGIN;

INSERT INTO owner_group VALUES
  ('a0000000-0000-4000-8000-000000000001', 'group-a', '2026-08-07 02:00+00');
INSERT INTO publisher_account VALUES
  ('a1000000-0000-4000-8000-000000000001', 'brand-a',
   'a0000000-0000-4000-8000-000000000001', 'known', '2026-08-07 02:00+00'),
  ('a1000000-0000-4000-8000-000000000002', 'brand-b',
   'a0000000-0000-4000-8000-000000000001', 'known', '2026-08-07 02:00+00'),
  ('a1000000-0000-4000-8000-000000000003', 'unknown-owner-brand',
   NULL, 'unknown', '2026-08-07 02:00+00');

INSERT INTO collection_opportunity VALUES
  ('b0000000-0000-4000-8000-000000000001',
   'b1000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001',
   '2026-08-07 02:00+00', '2026-08-07 01:00+00', '2026-08-07 03:00+00',
   'hourly', 'O_acquire', '2026-08-07 02:00+00');
INSERT INTO collection_opportunity_state_event VALUES
  ('b2000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', 1, NULL, NULL,
   'scheduled', 'scheduled', 'opportunity scheduled',
   '2026-08-07 02:00+00', '2026-08-07 02:00+00'),
  ('b2000000-0000-4000-8000-000000000002',
   'b0000000-0000-4000-8000-000000000001', 2,
   'b2000000-0000-4000-8000-000000000001', 1,
   'scheduled', 'succeeded', 'capture completed',
   '2026-08-07 02:10+00', '2026-08-07 02:10+00');

INSERT INTO raw_item VALUES
  ('b3000000-0000-4000-8000-000000000001',
   'b1000000-0000-4000-8000-000000000001', 'item-1',
   '2026-08-07 02:10+00', '2026-08-07 02:10+00');
INSERT INTO raw_item_version VALUES
  ('b4000000-0000-4000-8000-000000000001',
   'b3000000-0000-4000-8000-000000000001', 1, NULL,
   'first title', repeat('1', 64), '2026-08-07 01:00+00',
   '2026-08-07 02:10+00', '2026-08-07 02:10+00',
   '2026-08-07 02:10+00', '2026-08-07 02:10+00'),
  ('b4000000-0000-4000-8000-000000000002',
   'b3000000-0000-4000-8000-000000000001', 2,
   'b4000000-0000-4000-8000-000000000001',
   'updated title', repeat('2', 64), '2026-08-07 01:00+00',
   '2026-08-07 02:20+00', '2026-08-07 02:20+00',
   '2026-08-07 02:10+00', '2026-08-07 02:20+00');
INSERT INTO capture VALUES
  ('b5000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', 'success',
   'b3000000-0000-4000-8000-000000000001',
   '2026-08-07 02:10+00', '2026-08-07 02:10+00');

INSERT INTO purpose_authorization VALUES
  ('b6000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'O_acquire', 'collector-main', 'allow',
   'grant-a', 'scope-metadata', NULL, NULL,
   '2026-08-07 02:00+00', '2026-08-08 02:00+00', 1, NULL, '2026-08-07 02:00+00'),
  ('b6000000-0000-4000-8000-000000000002',
   'b4000000-0000-4000-8000-000000000001', 'O_extract', 'extractor-local', 'allow',
   'grant-a', 'scope-full', 'identity', NULL,
   '2026-08-07 02:00+00', '2026-08-08 02:00+00', 1, NULL, '2026-08-07 02:00+00'),
  ('b6000000-0000-4000-8000-000000000003',
   'b4000000-0000-4000-8000-000000000001', 'O_display', 'renderer-public', 'allow',
   'grant-b', 'scope-quote', 'identity', 20,
   '2026-08-07 02:00+00', '2026-08-08 02:00+00', 1, NULL, '2026-08-07 02:00+00');
SELECT assert_purpose_authorized(
  'b4000000-0000-4000-8000-000000000001', 'O_display', 'renderer-public',
  '2026-08-07 03:00+00', 20, 'identity');

INSERT INTO preservation_manifest_version VALUES
  ('b7000000-0000-4000-8000-000000000001', 'preserve-v1', 'sha256',
   'm1-preservation-v1', repeat('3', 64), 'preservation-signature',
   '2026-08-07 02:00+00', '2026-08-07 02:00+00');
INSERT INTO storage_blob VALUES
  ('b8000000-0000-4000-8000-000000000001', repeat('1', 64), 120,
   'key-v1', '2026-08-07 02:00+00'),
  ('b8000000-0000-4000-8000-000000000002', repeat('4', 64), 80,
   'key-v1', '2026-08-07 02:00+00');
INSERT INTO artifact_blob_binding VALUES
  ('b9000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001',
   'b8000000-0000-4000-8000-000000000001', 1, 'active', 'legal-a',
   '2026-08-07 02:00+00'),
  ('b9000000-0000-4000-8000-000000000002',
   'ba000000-0000-4000-8000-000000000002',
   'b8000000-0000-4000-8000-000000000002', 1, 'active', 'legal-b',
   '2026-08-07 02:00+00');
INSERT INTO raw_artifact VALUES
  ('ba000000-0000-4000-8000-000000000001',
   'b4000000-0000-4000-8000-000000000001', 'full_bytes',
   'b8000000-0000-4000-8000-000000000001', repeat('1', 64), NULL, NULL, NULL,
   'b7000000-0000-4000-8000-000000000001', NULL, '2026-08-07 02:00+00'),
  ('ba000000-0000-4000-8000-000000000002',
   'b4000000-0000-4000-8000-000000000001', 'licensed_excerpt',
   'b8000000-0000-4000-8000-000000000002', repeat('4', 64), 'short quote', NULL, NULL,
   'b7000000-0000-4000-8000-000000000001', NULL, '2026-08-07 02:00+00'),
  ('ba000000-0000-4000-8000-000000000003',
   'b4000000-0000-4000-8000-000000000001', 'metadata_only',
   NULL, NULL, NULL, repeat('5', 64), NULL, NULL, NULL, '2026-08-07 02:00+00'),
  ('ba000000-0000-4000-8000-000000000004',
   'b4000000-0000-4000-8000-000000000001', 'external_pointer',
   NULL, NULL, NULL, NULL, 'https://example.invalid/item-1', NULL, NULL, '2026-08-07 02:00+00');
INSERT INTO restore_test_event VALUES
  ('bb000000-0000-4000-8000-000000000001',
   'b7000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001', repeat('1', 64),
   true, true, true, true, 60, 120,
   '2026-08-07 02:30+00', '2026-08-07 02:30+00');

INSERT INTO storage_blob VALUES
  ('b8000000-0000-4000-8000-000000000003', repeat('6', 64), 90,
   'key-v1', '2026-08-07 02:00+00');
INSERT INTO artifact_blob_binding VALUES
  ('b9000000-0000-4000-8000-000000000003',
   'ba000000-0000-4000-8000-000000000005',
   'b8000000-0000-4000-8000-000000000003', 1, 'active', 'legal-derived',
   '2026-08-07 02:00+00');
INSERT INTO raw_artifact VALUES
  ('ba000000-0000-4000-8000-000000000005',
   'b4000000-0000-4000-8000-000000000001', 'full_bytes',
   'b8000000-0000-4000-8000-000000000003', repeat('6', 64), NULL, NULL, NULL,
   'b7000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001', '2026-08-07 02:40+00');
INSERT INTO format_migration_event VALUES
  ('bc000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000005', repeat('1', 64),
   'fixture-parser-v1', '2026-08-07 02:40+00', '2026-08-07 02:40+00');

INSERT INTO language_evaluation_manifest (
  language_evaluation_manifest_id, contract_document_path, contract_document_version,
  contract_document_hash, contract_document_section, language_keys, minimum_sample_size,
  severe_semantic_reversal_threshold, double_review_required, entity_attribution_required,
  quotation_attribution_required, manifest_signature, effective_from, system_available_at
) VALUES
  ('bd000000-0000-4000-8000-000000000001',
   'docs/01-global-information-coverage-matrix.md', 'v0.1-m0-baseline',
   '92eb37d5a26fd08dd3362028ca0d8d2ab7b1feef5881219cd9d96a4062b2a8c2', '15.1',
   ARRAY['zh-CN', 'en', 'es', 'ar', 'fr', 'ru', 'pt', 'hi', 'ja', 'ko'], 500, 0.01, true, true, true,
   'language-eval-signature', '2026-08-07 02:00+00', '2026-08-07 02:00+00');

COMMIT;

DO $$
DECLARE
  message_text text;
  group_count integer;
  unknown_count integer;
BEGIN
  SELECT count(DISTINCT owner_group_id), count(*) FILTER (WHERE ownership_relation = 'unknown')
    INTO group_count, unknown_count
    FROM publisher_account;
  IF group_count <> 1 OR unknown_count <> 1 THEN
    RAISE EXCEPTION 'owner-group and dependency-unknown bounds are wrong';
  END IF;

  SELECT count(*) INTO group_count FROM collection_opportunity;
  IF group_count <> 1 THEN
    RAISE EXCEPTION 'unplanned hourly opportunity entered the acquisition denominator';
  END IF;

  BEGIN
    PERFORM assert_purpose_authorized(
      'b4000000-0000-4000-8000-000000000001', 'O_model:provider', 'provider-a',
      '2026-08-07 03:00+00', 0, 'identity');
    RAISE EXCEPTION 'external provider model was authorized without a grant';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'PURPOSE_MODEL_DENIED' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM assert_purpose_authorized(
      'b4000000-0000-4000-8000-000000000001', 'O_display', 'renderer-public',
      '2026-08-07 03:00+00', 21, 'identity');
    RAISE EXCEPTION 'display scope exceeded its maximum';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'PURPOSE_DISPLAY_DENIED' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM assert_purpose_authorized(
      'b4000000-0000-4000-8000-000000000001', 'O_train', 'model-a',
      '2026-08-07 03:00+00', 0, 'identity');
    RAISE EXCEPTION 'training was authorized without explicit training grant';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'PURPOSE_TRAIN_DENIED' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO raw_item_version VALUES
      ('b4000000-0000-4000-8000-000000000003',
       'b3000000-0000-4000-8000-000000000001', 4,
       'b4000000-0000-4000-8000-000000000002', 'invalid jump', repeat('8', 64), NULL,
       '2026-08-07 02:30+00', '2026-08-07 02:30+00', '2026-08-07 02:10+00',
       '2026-08-07 02:30+00');
    RAISE EXCEPTION 'raw item version jump was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'raw item version must extend the current ordinal head' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO raw_artifact VALUES
      ('ba000000-0000-4000-8000-000000000006',
       'b4000000-0000-4000-8000-000000000001', 'metadata_only',
       'b8000000-0000-4000-8000-000000000001', NULL, NULL, repeat('9', 64), NULL, NULL, NULL,
       '2026-08-07 02:50+00');
    SET CONSTRAINTS raw_artifact_mode_guard IMMEDIATE;
    RAISE EXCEPTION 'metadata-only artifact accepted content binding';
  EXCEPTION WHEN check_violation THEN
    NULL;
  WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'new row for relation "raw_artifact" violates check constraint "raw_artifact_check"' THEN
      IF message_text <> 'metadata-only or external-pointer artifact cannot have a content binding' THEN RAISE; END IF;
    END IF;
  END;

  BEGIN
    INSERT INTO restore_test_event VALUES
      ('bb000000-0000-4000-8000-000000000002',
       'b7000000-0000-4000-8000-000000000001',
       'ba000000-0000-4000-8000-000000000001', repeat('1', 64),
       true, false, true, true, 60, 120,
       '2026-08-07 02:50+00', '2026-08-07 02:50+00');
    RAISE EXCEPTION 'failed restore test was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

SELECT 'M1 SOURCE ARCHIVE FIXTURES PASSED' AS result;
