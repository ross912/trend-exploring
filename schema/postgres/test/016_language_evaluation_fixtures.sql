\set ON_ERROR_STOP on

DO $$
DECLARE
  language_count integer;
  sample_size integer;
  section_key text;
  document_hash text;
  entity_required boolean;
  quotation_required boolean;
  message_text text;
BEGIN
  SELECT cardinality(language_keys), minimum_sample_size, contract_document_section,
         contract_document_hash, entity_attribution_required, quotation_attribution_required
    INTO language_count, sample_size, section_key, document_hash, entity_required, quotation_required
    FROM language_evaluation_manifest
   WHERE language_evaluation_manifest_id = 'bd000000-0000-4000-8000-000000000001';
  IF language_count <> 10 OR sample_size <> 500 OR section_key <> '15.1'
     OR document_hash <> '92eb37d5a26fd08dd3362028ca0d8d2ab7b1feef5881219cd9d96a4062b2a8c2'
     OR NOT entity_required OR NOT quotation_required THEN
    RAISE EXCEPTION 'language evaluation manifest is not closed over the current contract';
  END IF;

  BEGIN
    INSERT INTO language_evaluation_manifest (
      language_evaluation_manifest_id, contract_document_path, contract_document_version,
      contract_document_hash, contract_document_section, language_keys, minimum_sample_size,
      severe_semantic_reversal_threshold, double_review_required, entity_attribution_required,
      quotation_attribution_required, manifest_signature, effective_from, system_available_at
    ) VALUES (
      'bd000000-0000-4000-8000-000000000002',
      'docs/01-global-information-coverage-matrix.md', 'v0.1-m0-baseline',
      '92eb37d5a26fd08dd3362028ca0d8d2ab7b1feef5881219cd9d96a4062b2a8c2', '15.1',
      ARRAY['zh-CN', 'en', 'es', 'ar', 'fr', 'ru', 'pt', 'hi', 'ja'], 500, 0.01, true, true, true,
      'language-eval-signature', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
    RAISE EXCEPTION 'language set omission was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO language_evaluation_manifest (
      language_evaluation_manifest_id, contract_document_path, contract_document_version,
      contract_document_hash, contract_document_section, language_keys, minimum_sample_size,
      severe_semantic_reversal_threshold, double_review_required, entity_attribution_required,
      quotation_attribution_required, manifest_signature, effective_from, system_available_at
    ) VALUES (
      'bd000000-0000-4000-8000-000000000003',
      'docs/01-global-information-coverage-matrix.md', 'v0.1-m0-baseline',
      '92eb37d5a26fd08dd3362028ca0d8d2ab7b1feef5881219cd9d96a4062b2a8c2', '15.1',
      ARRAY['zh-CN', 'en', 'es', 'ar', 'fr', 'ru', 'pt', 'hi', 'ja', 'ko'], 499, 0.01, true, true, true,
      'language-eval-signature', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
    RAISE EXCEPTION 'undersized language evaluation set was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE language_evaluation_manifest
       SET contract_document_version = 'tampered'
     WHERE language_evaluation_manifest_id = 'bd000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'language evaluation manifest mutation was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'language_evaluation_manifest is append-only' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'LANGUAGE EVALUATION FIXTURES PASSED' AS result;
