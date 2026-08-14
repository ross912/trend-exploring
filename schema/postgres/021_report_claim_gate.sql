-- Report-summary atomic claim/evidence gate and provider exchange receipts.
--
-- This migration is additive. Existing two-field summary artifacts are never
-- rewritten; read paths must expose them as legacy_unverified. New verified
-- artifacts require typed claims, locatable title/summary scopes, and a
-- provider_response_receipt belonging to the same summary run.
BEGIN;

ALTER TABLE local_report_summary_artifact
  ADD COLUMN IF NOT EXISTS claim_gate_status text,
  ADD COLUMN IF NOT EXISTS provider_receipt_id text;

CREATE TABLE IF NOT EXISTS provider_response_receipt (
  receipt_id text PRIMARY KEY,
  run_id text NOT NULL UNIQUE REFERENCES local_report_summary_run(run_id),
  provider text NOT NULL CHECK (btrim(provider) <> ''),
  model text NOT NULL CHECK (btrim(model) <> ''),
  prompt_version text NOT NULL CHECK (btrim(prompt_version) <> ''),
  exchange_id text NOT NULL CHECK (btrim(exchange_id) <> ''),
  canonical_request_hash text NOT NULL CHECK (canonical_request_hash ~ '^[a-f0-9]{64}$'),
  raw_response_hash text NOT NULL CHECK (raw_response_hash ~ '^[a-f0-9]{64}$'),
  http_status integer,
  request_id text NOT NULL DEFAULT '',
  captured_at timestamptz NOT NULL,
  status text NOT NULL CHECK (status IN ('succeeded', 'failed')),
  response_available boolean NOT NULL DEFAULT false,
  error_code text NOT NULL DEFAULT '',
  error_message text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_report_summary_artifact'::regclass AND conname = 'local_report_summary_artifact_claim_gate_status_check') THEN
    ALTER TABLE local_report_summary_artifact ADD CONSTRAINT local_report_summary_artifact_claim_gate_status_check
      CHECK (claim_gate_status IS NULL OR claim_gate_status IN ('verified', 'legacy_unverified'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_report_summary_artifact'::regclass AND conname = 'local_report_summary_artifact_receipt_fkey') THEN
    ALTER TABLE local_report_summary_artifact ADD CONSTRAINT local_report_summary_artifact_receipt_fkey
      FOREIGN KEY (provider_receipt_id) REFERENCES provider_response_receipt(receipt_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION report_claim_scope_version_exists(edition_id_arg text, version_id_arg text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM local_report_item_placement p
      JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
     WHERE p.edition_id = edition_id_arg AND a.version_id = version_id_arg
  );
$$;

CREATE OR REPLACE FUNCTION report_claim_scope_text_locatable(edition_id_arg text, version_id_arg text, field_arg text, excerpt_arg text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM local_report_item_placement p
      JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
      JOIN local_source_item_version v ON v.version_id = a.version_id
     WHERE p.edition_id = edition_id_arg AND v.version_id = version_id_arg
       AND field_arg IN ('title', 'summary')
       AND position(excerpt_arg IN CASE field_arg WHEN 'title' THEN v.title ELSE v.summary END) > 0
  );
$$;

-- The v1 summary trigger only understands {text,cited_version_ids}.  Keep it
-- as the legacy validator, but let the new typed gate own verified rows.
CREATE OR REPLACE FUNCTION local_report_summary_artifact_validate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  unit jsonb;
  expected_version_ids text[];
  actual_version_ids text[] := ARRAY[]::text[];
  run_edition text;
  run_input_hash text;
  run_provider text;
  run_model text;
  run_prompt_version text;
BEGIN
  IF COALESCE(NEW.claim_gate_status, 'legacy_unverified') = 'verified' THEN
    RETURN NEW;
  END IF;
  IF jsonb_typeof(NEW.overview) <> 'object'
     OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(NEW.overview) AS key) <> ARRAY['cited_version_ids','text']::text[]
     OR jsonb_typeof(NEW.key_changes) <> 'array' OR jsonb_typeof(NEW.uncertainties) <> 'array'
     OR btrim(COALESCE(NEW.output_hash, '')) = '' THEN
    RAISE EXCEPTION 'invalid local report summary artifact shape';
  END IF;
  FOR unit IN SELECT NEW.overview UNION ALL SELECT value FROM jsonb_array_elements(NEW.key_changes)
              UNION ALL SELECT value FROM jsonb_array_elements(NEW.uncertainties) LOOP
    IF jsonb_typeof(unit) <> 'object'
       OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(unit) AS key) <> ARRAY['cited_version_ids','text']::text[]
       OR jsonb_typeof(unit->'text') <> 'string' OR btrim(unit->>'text') = ''
       OR jsonb_typeof(unit->'cited_version_ids') <> 'array' OR jsonb_array_length(unit->'cited_version_ids') = 0 THEN
      RAISE EXCEPTION 'invalid local report summary unit shape';
    END IF;
    SELECT array_agg(value ORDER BY ordinality) INTO expected_version_ids
      FROM jsonb_array_elements_text(unit->'cited_version_ids') WITH ORDINALITY AS values(value, ordinality);
    IF expected_version_ids IS NULL OR EXISTS (SELECT 1 FROM unnest(expected_version_ids) value WHERE btrim(value) = '')
       OR cardinality(expected_version_ids) <> (SELECT COUNT(DISTINCT value) FROM unnest(expected_version_ids) value) THEN
      RAISE EXCEPTION 'local report summary citations must be non-empty and unique';
    END IF;
    actual_version_ids := actual_version_ids || expected_version_ids;
  END LOOP;
  SELECT edition_id, input_hash, provider, model, prompt_version INTO run_edition, run_input_hash, run_provider, run_model, run_prompt_version
    FROM local_report_summary_run WHERE run_id = NEW.run_id;
  IF run_edition IS NULL OR run_edition <> NEW.edition_id THEN RAISE EXCEPTION 'summary artifact run/edition mismatch'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(actual_version_ids) value WHERE NOT EXISTS (
    SELECT 1 FROM local_report_item_placement p JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
    WHERE p.edition_id = NEW.edition_id AND a.version_id = value)) THEN
    RAISE EXCEPTION 'summary artifact cites a version outside the edition';
  END IF;
  IF run_input_hash <> NEW.input_hash OR run_provider <> NEW.provider OR run_model <> NEW.model OR run_prompt_version <> NEW.prompt_version THEN
    RAISE EXCEPTION 'summary artifact metadata differs from run';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION local_report_summary_artifact_claim_gate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  unit jsonb;
  scope jsonb;
  section text;
  claim_id text;
  claim_kind text;
  claim_status text := COALESCE(NEW.claim_gate_status, 'legacy_unverified');
  relation text;
  scope_id text;
  version_id text;
  field_name text;
  excerpt text;
  scope_ids text[];
  premise_ids text[];
  relation_seen_support boolean;
  relation_seen_unknown boolean;
  claim_ids text[] := ARRAY[]::text[];
  run_provider text;
  run_model text;
  run_prompt text;
  receipt_run text;
BEGIN
  IF claim_status = 'legacy_unverified' THEN
    -- Legacy artifacts are accepted only for historical rows or explicitly
    -- marked compatibility writes. They are not eligible for verified reads.
    RETURN NEW;
  END IF;
  IF claim_status <> 'verified' THEN
    RAISE EXCEPTION 'summary claim gate status must be verified or legacy_unverified';
  END IF;
  IF NEW.claim_gate_status = 'verified' AND (jsonb_typeof(NEW.overview) <> 'object' OR jsonb_typeof(NEW.key_changes) <> 'array' OR jsonb_typeof(NEW.uncertainties) <> 'array') THEN
    RAISE EXCEPTION 'verified summary artifact claim sections have invalid shape';
  END IF;
  IF NEW.provider_receipt_id IS NULL THEN
    RAISE EXCEPTION 'verified summary artifact requires provider receipt';
  END IF;
  SELECT run_id INTO receipt_run
    FROM provider_response_receipt
   WHERE receipt_id = NEW.provider_receipt_id
     AND status = 'succeeded'
     AND response_available = TRUE;
  IF receipt_run IS NULL OR receipt_run <> NEW.run_id THEN
    RAISE EXCEPTION 'summary artifact requires a succeeded provider receipt with an available response for the same run';
  END IF;

  FOR section, unit IN
    SELECT 'overview', NEW.overview
    UNION ALL SELECT 'key_changes', value FROM jsonb_array_elements(NEW.key_changes)
    UNION ALL SELECT 'uncertainties', value FROM jsonb_array_elements(NEW.uncertainties)
  LOOP
    IF jsonb_typeof(unit) <> 'object'
       OR NOT (unit ? 'claim_id') OR NOT (unit ? 'kind') OR NOT (unit ? 'text')
       OR NOT (unit ? 'epistemic_status') OR NOT (unit ? 'evidence_scopes') THEN
      RAISE EXCEPTION 'summary claim gate requires typed atomic claim in %', section;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(unit) key
               WHERE key NOT IN ('claim_id','kind','text','epistemic_status','evidence_scopes','premise_scope_ids','inference_support_status')) THEN
      RAISE EXCEPTION 'summary claim contains unknown fields';
    END IF;
    claim_id := unit->>'claim_id';
    claim_kind := unit->>'kind';
    IF claim_id !~ '^claim-[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$' THEN RAISE EXCEPTION 'invalid claim_id'; END IF;
    IF claim_id = ANY(claim_ids) THEN RAISE EXCEPTION 'duplicate claim_id'; END IF;
    claim_ids := array_append(claim_ids, claim_id);
    IF claim_kind NOT IN ('fact', 'source_claim', 'ai_inference', 'uncertainty') THEN RAISE EXCEPTION 'invalid claim kind'; END IF;
    IF btrim(COALESCE(unit->>'text', '')) = '' THEN RAISE EXCEPTION 'claim text is required'; END IF;
    IF unit->>'epistemic_status' NOT IN ('asserted', 'disputed', 'retracted', 'unknown') THEN RAISE EXCEPTION 'invalid claim epistemic_status'; END IF;
    IF jsonb_typeof(unit->'evidence_scopes') <> 'array' OR jsonb_array_length(unit->'evidence_scopes') = 0 THEN RAISE EXCEPTION 'claim evidence scopes are required'; END IF;
    scope_ids := ARRAY[]::text[]; relation_seen_support := false; relation_seen_unknown := false;
    FOR scope IN SELECT value FROM jsonb_array_elements(unit->'evidence_scopes') LOOP
      IF jsonb_typeof(scope) <> 'object' OR NOT (scope ? 'scope_id') OR NOT (scope ? 'version_id') OR NOT (scope ? 'field') OR NOT (scope ? 'text') OR NOT (scope ? 'relation') THEN
        RAISE EXCEPTION 'claim evidence scope shape is invalid';
      END IF;
      scope_id := scope->>'scope_id'; version_id := scope->>'version_id'; field_name := scope->>'field'; excerpt := scope->>'text'; relation := scope->>'relation';
      IF scope_id !~ '^scope-[A-Za-z0-9][A-Za-z0-9_.:-]{0,160}$' THEN RAISE EXCEPTION 'invalid scope_id'; END IF;
      IF field_name NOT IN ('title', 'summary') THEN RAISE EXCEPTION 'scope field must be title or summary'; END IF;
      IF relation NOT IN ('supports', 'contradicts', 'alternative', 'unknown') THEN RAISE EXCEPTION 'invalid claim scope relation'; END IF;
      IF btrim(COALESCE(excerpt, '')) = '' OR NOT report_claim_scope_version_exists(NEW.edition_id, version_id) OR NOT report_claim_scope_text_locatable(NEW.edition_id, version_id, field_name, excerpt) THEN
        RAISE EXCEPTION 'claim evidence scope is not locatable in edition';
      END IF;
      IF scope_id = ANY(scope_ids) THEN RAISE EXCEPTION 'duplicate scope_id'; END IF;
      scope_ids := array_append(scope_ids, scope_id);
      relation_seen_support := relation_seen_support OR relation = 'supports';
      relation_seen_unknown := relation_seen_unknown OR relation = 'unknown';
    END LOOP;
    IF relation_seen_unknown OR NOT relation_seen_support THEN RAISE EXCEPTION 'claim evidence relation gate failed'; END IF;
    IF claim_kind = 'ai_inference' THEN
      IF jsonb_typeof(unit->'premise_scope_ids') <> 'array' OR jsonb_array_length(unit->'premise_scope_ids') = 0 OR unit->>'inference_support_status' <> 'supported' THEN
        RAISE EXCEPTION 'ai inference premise/support gate failed';
      END IF;
      premise_ids := ARRAY(SELECT jsonb_array_elements_text(unit->'premise_scope_ids'));
      IF EXISTS (SELECT 1 FROM unnest(premise_ids) p WHERE NOT (p = ANY(scope_ids))) THEN RAISE EXCEPTION 'ai inference premise scope missing'; END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(unit->'evidence_scopes') candidate_scope
                 WHERE (candidate_scope->>'scope_id') = ANY(premise_ids)
                   AND (candidate_scope->>'relation') <> 'supports') THEN
        RAISE EXCEPTION 'ai inference premise is not a supports scope';
      END IF;
    ELSIF unit ? 'premise_scope_ids' OR unit ? 'inference_support_status' THEN
      RAISE EXCEPTION 'non-inference claim carries inference fields';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(unit->'evidence_scopes') candidate_scope
               WHERE (candidate_scope->>'relation') = 'contradicts'
                 AND unit->>'epistemic_status' NOT IN ('disputed','unknown','retracted')) THEN
      RAISE EXCEPTION 'contradicting scope requires disputed, unknown, or retracted epistemic status';
    END IF;
  END LOOP;

  SELECT provider, model, prompt_version INTO run_provider, run_model, run_prompt FROM local_report_summary_run WHERE run_id = NEW.run_id;
  IF run_provider IS NULL OR run_provider <> NEW.provider OR run_model <> NEW.model OR run_prompt <> NEW.prompt_version THEN
    RAISE EXCEPTION 'summary artifact metadata differs from run';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_report_summary_artifact_validate_trigger ON local_report_summary_artifact;
CREATE TRIGGER local_report_summary_artifact_validate_trigger
BEFORE INSERT ON local_report_summary_artifact
FOR EACH ROW EXECUTE FUNCTION local_report_summary_artifact_validate();

DROP TRIGGER IF EXISTS local_report_summary_artifact_claim_gate_trigger ON local_report_summary_artifact;
CREATE TRIGGER local_report_summary_artifact_claim_gate_trigger
BEFORE INSERT ON local_report_summary_artifact
FOR EACH ROW EXECUTE FUNCTION local_report_summary_artifact_claim_gate();

CREATE OR REPLACE FUNCTION provider_response_receipt_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'provider_response_receipt is append-only';
END;
$$;
DROP TRIGGER IF EXISTS provider_response_receipt_append_only ON provider_response_receipt;
CREATE TRIGGER provider_response_receipt_append_only
BEFORE UPDATE OR DELETE ON provider_response_receipt
FOR EACH ROW EXECUTE FUNCTION provider_response_receipt_append_only_guard();

CREATE TABLE IF NOT EXISTS report_claim_gate_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO report_claim_gate_schema_meta(schema_version)
VALUES ('021_report_claim_gate_v1') ON CONFLICT DO NOTHING;

COMMIT;
