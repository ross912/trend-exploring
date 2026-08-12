-- Local report AI-summary projection.
--
-- This migration is deliberately additive.  A summary run/artifact never
-- updates an edition, a placement, or an archived version.  The tables below
-- retain every attempt (including blocked and failed attempts) and make a
-- successful artifact immutable and independently addressable.
BEGIN;

DO $$
DECLARE
  relname text;
  rel regclass;
  row_count bigint;
  marker_present boolean := false;
  required_ok boolean;
  structural_ok boolean;
BEGIN
  IF to_regclass('local_report_summary_schema_meta') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM local_report_summary_schema_meta WHERE schema_version = ''014_local_report_summary_v1'')'
      INTO marker_present;
  END IF;

  FOREACH relname IN ARRAY ARRAY['local_report_summary_artifact', 'local_report_summary_run'] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF row_count > 0 AND NOT marker_present THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; schema marker is absent', relname;
    END IF;

    IF relname = 'local_report_summary_run' THEN
      SELECT COUNT(*) = 13 INTO required_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['run_id','edition_id','idempotency_key','input_hash','provider','model','prompt_version','state','started_at','finished_at','error_reason','created_at','updated_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_run_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_run_idempotency_key_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_run_edition_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_run_state_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_run_terminal_check')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_summary_run_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_summary_run_commit_constraint_trigger') INTO structural_ok;
    ELSE
      SELECT COUNT(*) = 12 INTO required_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['artifact_id','run_id','edition_id','input_hash','provider','model','prompt_version','overview','key_changes','uncertainties','output_hash','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_artifact_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_artifact_run_id_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_artifact_run_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_summary_artifact_edition_fkey')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_summary_artifact_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_summary_artifact_validate_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_summary_artifact_commit_constraint_trigger') INTO structural_ok;
    END IF;
    IF (marker_present AND (NOT required_ok OR NOT structural_ok)) OR (row_count > 0 AND NOT marker_present) THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; refusing migration', relname;
    END IF;
  END LOOP;

  -- Empty early drafts are safe to replace.  Drop the child first so a
  -- complete, non-empty parent can never be removed accidentally.
  FOREACH relname IN ARRAY ARRAY['local_report_summary_artifact', 'local_report_summary_run'] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF row_count = 0 AND NOT marker_present THEN
      EXECUTE format('DROP TABLE %I', relname);
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS local_report_summary_run (
  run_id text PRIMARY KEY,
  edition_id text NOT NULL CONSTRAINT local_report_summary_run_edition_fkey REFERENCES local_report_edition(edition_id),
  idempotency_key text NOT NULL UNIQUE,
  input_hash text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  state text NOT NULL CONSTRAINT local_report_summary_run_state_check CHECK (state IN ('running', 'succeeded', 'failed', 'blocked')),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  error_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT local_report_summary_run_terminal_check CHECK (
    (state = 'running' AND finished_at IS NULL AND btrim(error_reason) = '')
    OR (state = 'succeeded' AND finished_at IS NOT NULL AND btrim(error_reason) = '')
    OR (state IN ('failed', 'blocked') AND finished_at IS NOT NULL AND btrim(error_reason) <> '')
  )
);

CREATE TABLE IF NOT EXISTS local_report_summary_artifact (
  artifact_id text PRIMARY KEY,
  run_id text NOT NULL,
  edition_id text NOT NULL CONSTRAINT local_report_summary_artifact_edition_fkey REFERENCES local_report_edition(edition_id),
  input_hash text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  overview jsonb NOT NULL,
  key_changes jsonb NOT NULL,
  uncertainties jsonb NOT NULL,
  output_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT local_report_summary_artifact_run_id_key UNIQUE (run_id),
  CONSTRAINT local_report_summary_artifact_run_fkey FOREIGN KEY (run_id) REFERENCES local_report_summary_run(run_id)
);

CREATE OR REPLACE FUNCTION local_report_summary_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.run_id <> OLD.run_id OR NEW.edition_id <> OLD.edition_id
     OR NEW.idempotency_key <> OLD.idempotency_key OR NEW.input_hash <> OLD.input_hash
     OR NEW.provider <> OLD.provider OR NEW.model <> OLD.model
     OR NEW.prompt_version <> OLD.prompt_version OR NEW.started_at <> OLD.started_at
     OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'local report summary run identity/input is immutable';
  END IF;
  IF OLD.state <> 'running' THEN
    IF NEW.state <> OLD.state OR NEW.finished_at <> OLD.finished_at OR NEW.error_reason <> OLD.error_reason THEN
      RAISE EXCEPTION 'terminal local report summary run is immutable';
    END IF;
  ELSE
    IF NEW.state NOT IN ('running', 'succeeded', 'failed', 'blocked') THEN
      RAISE EXCEPTION 'invalid local report summary run state transition';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION local_report_summary_artifact_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'local report summary artifact is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION local_report_summary_artifact_validate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  unit jsonb;
  citation text;
  expected_version_ids text[];
  actual_version_ids text[] := ARRAY[]::text[];
  run_edition text;
  run_input_hash text;
  run_provider text;
  run_model text;
  run_prompt_version text;
BEGIN
  IF jsonb_typeof(NEW.overview) <> 'object'
     OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(NEW.overview) AS key) <> ARRAY['cited_version_ids','text']::text[]
     OR jsonb_typeof(NEW.key_changes) <> 'array'
     OR jsonb_typeof(NEW.uncertainties) <> 'array'
     OR btrim(COALESCE(NEW.output_hash, '')) = '' THEN
    RAISE EXCEPTION 'invalid local report summary artifact shape';
  END IF;
  IF btrim(COALESCE(NEW.input_hash, '')) = '' OR btrim(COALESCE(NEW.provider, '')) = ''
     OR btrim(COALESCE(NEW.model, '')) = '' OR btrim(COALESCE(NEW.prompt_version, '')) = '' THEN
    RAISE EXCEPTION 'local report summary artifact metadata is required';
  END IF;

  FOR unit IN SELECT NEW.overview UNION ALL SELECT value FROM jsonb_array_elements(NEW.key_changes)
              UNION ALL SELECT value FROM jsonb_array_elements(NEW.uncertainties) LOOP
    IF jsonb_typeof(unit) <> 'object'
       OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(unit) AS key) <> ARRAY['cited_version_ids','text']::text[]
       OR jsonb_typeof(unit->'text') <> 'string' OR btrim(unit->>'text') = ''
       OR jsonb_typeof(unit->'cited_version_ids') <> 'array'
       OR jsonb_array_length(unit->'cited_version_ids') = 0 THEN
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

  SELECT edition_id, input_hash, provider, model, prompt_version
    INTO run_edition, run_input_hash, run_provider, run_model, run_prompt_version
    FROM local_report_summary_run WHERE run_id = NEW.run_id;
  IF run_edition IS NULL OR run_edition <> NEW.edition_id THEN
    RAISE EXCEPTION 'summary artifact run/edition mismatch';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(actual_version_ids) value
    WHERE NOT EXISTS (
      SELECT 1
        FROM local_report_item_placement p
        JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
       WHERE p.edition_id = NEW.edition_id AND a.version_id = value
    )
  ) THEN
    RAISE EXCEPTION 'summary artifact cites a version outside the edition';
  END IF;
  IF run_input_hash <> NEW.input_hash OR run_provider <> NEW.provider OR run_model <> NEW.model OR run_prompt_version <> NEW.prompt_version THEN
    RAISE EXCEPTION 'summary artifact metadata differs from run';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION local_report_summary_commit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  artifact_count integer;
  run_state text;
  current_run_id text := to_jsonb(NEW)->>'run_id';
  current_state text := to_jsonb(NEW)->>'state';
BEGIN
  IF TG_TABLE_NAME = 'local_report_summary_run' THEN
    SELECT COUNT(*) INTO artifact_count FROM local_report_summary_artifact WHERE run_id = current_run_id;
    IF current_state = 'succeeded' AND artifact_count <> 1 THEN
      RAISE EXCEPTION 'succeeded summary run must have exactly one artifact';
    ELSIF current_state <> 'succeeded' AND artifact_count <> 0 THEN
      RAISE EXCEPTION 'non-succeeded summary run cannot have an artifact';
    END IF;
  ELSE
    SELECT state INTO run_state FROM local_report_summary_run WHERE run_id = current_run_id;
    SELECT COUNT(*) INTO artifact_count FROM local_report_summary_artifact WHERE run_id = current_run_id;
    IF run_state <> 'succeeded' OR artifact_count <> 1 THEN
      RAISE EXCEPTION 'summary artifact requires one succeeded run';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_report_summary_run_immutable_trigger ON local_report_summary_run;
CREATE TRIGGER local_report_summary_run_immutable_trigger
BEFORE UPDATE ON local_report_summary_run
FOR EACH ROW EXECUTE FUNCTION local_report_summary_run_guard();

DROP TRIGGER IF EXISTS local_report_summary_artifact_immutable_trigger ON local_report_summary_artifact;
CREATE TRIGGER local_report_summary_artifact_immutable_trigger
BEFORE UPDATE OR DELETE ON local_report_summary_artifact
FOR EACH ROW EXECUTE FUNCTION local_report_summary_artifact_guard();

DROP TRIGGER IF EXISTS local_report_summary_artifact_validate_trigger ON local_report_summary_artifact;
CREATE TRIGGER local_report_summary_artifact_validate_trigger
BEFORE INSERT ON local_report_summary_artifact
FOR EACH ROW EXECUTE FUNCTION local_report_summary_artifact_validate();

DROP TRIGGER IF EXISTS local_report_summary_run_commit_constraint_trigger ON local_report_summary_run;
CREATE CONSTRAINT TRIGGER local_report_summary_run_commit_constraint_trigger
AFTER INSERT OR UPDATE OF state ON local_report_summary_run
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_report_summary_commit_guard();

DROP TRIGGER IF EXISTS local_report_summary_artifact_commit_constraint_trigger ON local_report_summary_artifact;
CREATE CONSTRAINT TRIGGER local_report_summary_artifact_commit_constraint_trigger
AFTER INSERT ON local_report_summary_artifact
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_report_summary_commit_guard();

CREATE TABLE IF NOT EXISTS local_report_summary_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_report_summary_schema_meta (schema_version)
VALUES ('014_local_report_summary_v1')
ON CONFLICT (schema_version) DO NOTHING;

COMMIT;
