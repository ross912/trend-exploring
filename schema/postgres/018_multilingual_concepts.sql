-- Multilingual concept linkage and participation candidates.
--
-- Translation is a derived input, not a replacement for an immutable source
-- version.  Concept mappings are evidence with a provider/model/prompt and
-- input/output hashes; they never merge events or claims.  A participation
-- candidate is admitted only after two source languages and two publishers
-- are independently present.
BEGIN;

DO $$
DECLARE
  rel regclass;
  row_count bigint;
  required_ok boolean;
  structural_ok boolean;
BEGIN
  IF to_regclass('local_source_item_version') IS NULL THEN
    RAISE EXCEPTION 'local_source_item_version is required; refusing 018 migration';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
     WHERE attrelid = 'local_source_item_version'::regclass
       AND attname = 'analysis_policy' AND attnum > 0 AND NOT attisdropped
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_attribute
     WHERE attrelid = 'local_source_item_version'::regclass
       AND attname = 'query_conditioned' AND attnum > 0 AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'breadth qualification metadata is required; apply 012_breadth_discovery before 018';
  END IF;

  FOREACH rel IN ARRAY ARRAY[
    to_regclass('local_multilingual_translation_input'),
    to_regclass('local_multilingual_concept_mapping'),
    to_regclass('local_multilingual_participation_candidate')
  ] LOOP
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF rel::text = 'local_multilingual_translation_input' THEN
      SELECT COUNT(*) = 13 INTO required_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'artifact_id','source_version_id','item_key','source_content_hash',
           'source_language','target_language','provider','model','prompt_version',
           'input_hash','output_hash','translated_text','created_at'
         ]);
      SELECT EXISTS (
               SELECT 1 FROM pg_constraint
                WHERE conrelid = rel AND contype = 'p'
                  AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'artifact_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND EXISTS (
               SELECT 1 FROM pg_constraint c
                WHERE c.conrelid = rel AND c.contype = 'u'
                  AND c.conkey = ARRAY[
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'source_version_id' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'source_content_hash' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'target_language' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'provider' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'model' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'prompt_version' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'input_hash' AND attnum > 0 AND NOT attisdropped),
                    (SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'output_hash' AND attnum > 0 AND NOT attisdropped)
                  ]::smallint[]
             )
         AND EXISTS (
               SELECT 1 FROM pg_constraint c
                WHERE c.conrelid = rel AND c.contype = 'f'
                  AND c.confrelid = 'local_source_item_version'::regclass
                  AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'source_version_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND (SELECT COUNT(*) FROM pg_constraint WHERE conrelid = rel AND contype = 'c') >= 9
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_translation_input_lineage_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_translation_input_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_translation_input_no_truncate_trigger')
        INTO structural_ok;
    ELSIF rel::text = 'local_multilingual_concept_mapping' THEN
      SELECT COUNT(*) = 18 INTO required_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'mapping_id','source_version_id','item_key','source_content_hash',
           'source_language','target_language','target_canonical_label',
           'canonical_concept_key','relation','translation_artifact_id',
           'provider','model','prompt_version','prompt_hash','input_hash',
           'output_hash','derived_from_translation','created_at'
         ]);
      SELECT EXISTS (
               SELECT 1 FROM pg_constraint
                WHERE conrelid = rel AND contype = 'p'
                  AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'mapping_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND EXISTS (
               SELECT 1 FROM pg_constraint c
                WHERE c.conrelid = rel AND c.contype = 'f'
                  AND c.confrelid = 'local_source_item_version'::regclass
                  AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'source_version_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND EXISTS (
               SELECT 1 FROM pg_constraint c
                WHERE c.conrelid = rel AND c.contype = 'f'
                  AND c.confrelid = 'local_multilingual_translation_input'::regclass
                  AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'translation_artifact_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND (SELECT COUNT(*) FROM pg_constraint WHERE conrelid = rel AND contype = 'c') >= 14
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_concept_mapping_lineage_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_mapping_translation_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_mapping_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_mapping_no_truncate_trigger')
        INTO structural_ok;
    ELSE
      SELECT COUNT(*) = 25 INTO required_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'candidate_id','candidate_status','candidate_kind','canonical_concept_key',
           'target_language','target_canonical_label','relation_set',
           'member_mapping_ids','member_version_ids','languages','publishers',
           'source_language_count','publisher_count','member_count',
           'query_conditioned_version_ids','exploration_only_version_ids',
           'signal_eligible_version_ids','query_conditioned_count',
           'exploration_only_count','signal_eligible_count','evidence',
           'merge_policy','event_merge_allowed','claim_merge_allowed','created_at'
         ]);
      SELECT EXISTS (
               SELECT 1 FROM pg_constraint
                WHERE conrelid = rel AND contype = 'p'
                  AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel AND attname = 'candidate_id' AND attnum > 0 AND NOT attisdropped)]::smallint[]
             )
         AND (SELECT COUNT(*) FROM pg_constraint WHERE conrelid = rel AND contype = 'c') >= 20
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_candidate_guard_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_candidate_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND NOT tgisinternal AND tgname = 'local_multilingual_candidate_no_truncate_trigger')
        INTO structural_ok;
    END IF;
    -- Existing rows are not the only migration hazard.  An empty relation
    -- with an early-draft shape must fail closed too; CREATE TABLE IF NOT
    -- EXISTS below cannot safely repair missing keys, checks, or guards.
    IF NOT required_ok OR NOT structural_ok THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; refusing 018 migration', rel;
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS local_multilingual_translation_input (
  artifact_id text PRIMARY KEY,
  source_version_id text NOT NULL REFERENCES local_source_item_version(version_id),
  item_key text NOT NULL,
  source_content_hash text NOT NULL,
  source_language text NOT NULL,
  target_language text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  input_hash text NOT NULL,
  output_hash text NOT NULL,
  translated_text text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_version_id, source_content_hash, target_language, provider,
          model, prompt_version, input_hash, output_hash),
  CHECK (btrim(artifact_id) <> ''),
  CHECK (btrim(source_content_hash) <> ''),
  CHECK (btrim(source_language) <> ''),
  CHECK (btrim(target_language) <> ''),
  CHECK (btrim(provider) <> ''),
  CHECK (btrim(model) <> ''),
  CHECK (btrim(prompt_version) <> ''),
  CHECK (btrim(input_hash) <> ''),
  CHECK (btrim(output_hash) <> '')
);

CREATE TABLE IF NOT EXISTS local_multilingual_concept_mapping (
  mapping_id text PRIMARY KEY,
  source_version_id text NOT NULL REFERENCES local_source_item_version(version_id),
  item_key text NOT NULL,
  source_content_hash text NOT NULL,
  source_language text NOT NULL,
  target_language text NOT NULL,
  target_canonical_label text NOT NULL,
  canonical_concept_key text NOT NULL,
  relation text NOT NULL CHECK (relation IN ('exact_alias','translation_equivalent','related_not_equivalent','unknown')),
  translation_artifact_id text REFERENCES local_multilingual_translation_input(artifact_id),
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  prompt_hash text NOT NULL,
  input_hash text NOT NULL,
  output_hash text NOT NULL,
  derived_from_translation boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (btrim(mapping_id) <> ''),
  CHECK (btrim(source_content_hash) <> ''),
  CHECK (btrim(source_language) <> ''),
  CHECK (btrim(target_language) <> ''),
  CHECK (btrim(target_canonical_label) <> ''),
  CHECK (btrim(canonical_concept_key) <> ''),
  CHECK (btrim(provider) <> ''),
  CHECK (btrim(model) <> ''),
  CHECK (btrim(prompt_version) <> ''),
  CHECK (btrim(prompt_hash) <> ''),
  CHECK (btrim(input_hash) <> ''),
  CHECK (btrim(output_hash) <> ''),
  CHECK ((derived_from_translation = false AND translation_artifact_id IS NULL)
      OR (derived_from_translation = true AND translation_artifact_id IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS local_multilingual_mapping_concept_idx
  ON local_multilingual_concept_mapping(canonical_concept_key, target_language, source_language);
CREATE INDEX IF NOT EXISTS local_multilingual_mapping_source_idx
  ON local_multilingual_concept_mapping(source_version_id, source_content_hash);

CREATE TABLE IF NOT EXISTS local_multilingual_participation_candidate (
  candidate_id text PRIMARY KEY,
  candidate_status text NOT NULL CHECK (candidate_status = 'cross_language_participation'),
  candidate_kind text NOT NULL CHECK (candidate_kind = 'concept_participation'),
  canonical_concept_key text NOT NULL,
  target_language text NOT NULL,
  target_canonical_label text NOT NULL,
  relation_set jsonb NOT NULL,
  member_mapping_ids jsonb NOT NULL,
  member_version_ids jsonb NOT NULL,
  languages jsonb NOT NULL,
  publishers jsonb NOT NULL,
  source_language_count integer NOT NULL CHECK (source_language_count >= 2),
  publisher_count integer NOT NULL CHECK (publisher_count >= 2),
  member_count integer NOT NULL CHECK (member_count >= 2),
  query_conditioned_version_ids jsonb NOT NULL,
  exploration_only_version_ids jsonb NOT NULL,
  signal_eligible_version_ids jsonb NOT NULL,
  query_conditioned_count integer NOT NULL CHECK (query_conditioned_count >= 0),
  exploration_only_count integer NOT NULL CHECK (exploration_only_count >= 0),
  signal_eligible_count integer NOT NULL CHECK (signal_eligible_count >= 0),
  evidence jsonb NOT NULL,
  merge_policy text NOT NULL CHECK (merge_policy = 'participation_only'),
  event_merge_allowed boolean NOT NULL DEFAULT false CHECK (event_merge_allowed = false),
  claim_merge_allowed boolean NOT NULL DEFAULT false CHECK (claim_merge_allowed = false),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(relation_set) = 'array'),
  CHECK (jsonb_typeof(member_mapping_ids) = 'array'),
  CHECK (jsonb_typeof(member_version_ids) = 'array'),
  CHECK (jsonb_typeof(languages) = 'array'),
  CHECK (jsonb_typeof(publishers) = 'array'),
  CHECK (jsonb_typeof(query_conditioned_version_ids) = 'array'),
  CHECK (jsonb_typeof(exploration_only_version_ids) = 'array'),
  CHECK (jsonb_typeof(signal_eligible_version_ids) = 'array'),
  CHECK (jsonb_typeof(evidence) = 'array')
);

CREATE OR REPLACE FUNCTION local_multilingual_source_lineage_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  source_record local_source_item_version%ROWTYPE;
BEGIN
  SELECT * INTO source_record
    FROM local_source_item_version
   WHERE version_id = NEW.source_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'multilingual source version does not exist';
  END IF;
  IF source_record.item_key <> NEW.item_key
     OR source_record.content_hash <> NEW.source_content_hash
     OR source_record.language <> NEW.source_language THEN
    RAISE EXCEPTION 'multilingual source lineage is immutable and does not match source version';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_multilingual_translation_input_lineage_trigger ON local_multilingual_translation_input;
CREATE TRIGGER local_multilingual_translation_input_lineage_trigger
BEFORE INSERT OR UPDATE ON local_multilingual_translation_input
FOR EACH ROW EXECUTE FUNCTION local_multilingual_source_lineage_guard();

DROP TRIGGER IF EXISTS local_multilingual_concept_mapping_lineage_trigger ON local_multilingual_concept_mapping;
CREATE TRIGGER local_multilingual_concept_mapping_lineage_trigger
BEFORE INSERT OR UPDATE ON local_multilingual_concept_mapping
FOR EACH ROW EXECUTE FUNCTION local_multilingual_source_lineage_guard();

CREATE OR REPLACE FUNCTION local_multilingual_mapping_lineage_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  translation_record local_multilingual_translation_input%ROWTYPE;
BEGIN
  IF NEW.derived_from_translation THEN
    SELECT * INTO translation_record
      FROM local_multilingual_translation_input
     WHERE artifact_id = NEW.translation_artifact_id;
    IF NOT FOUND
       OR translation_record.source_version_id <> NEW.source_version_id
       OR translation_record.source_content_hash <> NEW.source_content_hash
       OR translation_record.source_language <> NEW.source_language THEN
      RAISE EXCEPTION 'concept mapping translation lineage does not match immutable source version';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_multilingual_mapping_translation_trigger ON local_multilingual_concept_mapping;
CREATE TRIGGER local_multilingual_mapping_translation_trigger
BEFORE INSERT OR UPDATE ON local_multilingual_concept_mapping
FOR EACH ROW EXECUTE FUNCTION local_multilingual_mapping_lineage_guard();

CREATE OR REPLACE FUNCTION local_multilingual_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; create a new derived record instead of %', TG_TABLE_NAME, lower(TG_OP);
END;
$$;

DROP TRIGGER IF EXISTS local_multilingual_translation_input_immutable_trigger ON local_multilingual_translation_input;
CREATE TRIGGER local_multilingual_translation_input_immutable_trigger
BEFORE UPDATE OR DELETE ON local_multilingual_translation_input
FOR EACH ROW EXECUTE FUNCTION local_multilingual_append_only_guard();
DROP TRIGGER IF EXISTS local_multilingual_translation_input_no_truncate_trigger ON local_multilingual_translation_input;
CREATE TRIGGER local_multilingual_translation_input_no_truncate_trigger
BEFORE TRUNCATE ON local_multilingual_translation_input
FOR EACH STATEMENT EXECUTE FUNCTION local_multilingual_append_only_guard();

DROP TRIGGER IF EXISTS local_multilingual_mapping_immutable_trigger ON local_multilingual_concept_mapping;
CREATE TRIGGER local_multilingual_mapping_immutable_trigger
BEFORE UPDATE OR DELETE ON local_multilingual_concept_mapping
FOR EACH ROW EXECUTE FUNCTION local_multilingual_append_only_guard();
DROP TRIGGER IF EXISTS local_multilingual_mapping_no_truncate_trigger ON local_multilingual_concept_mapping;
CREATE TRIGGER local_multilingual_mapping_no_truncate_trigger
BEFORE TRUNCATE ON local_multilingual_concept_mapping
FOR EACH STATEMENT EXECUTE FUNCTION local_multilingual_append_only_guard();

CREATE OR REPLACE FUNCTION local_multilingual_candidate_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  mapping_ids text[];
  mapping_count integer;
  language_count integer;
  publisher_count_local integer;
  expected_query text[];
  expected_exploration text[];
  expected_signal text[];
  expected_languages text[];
  expected_publishers text[];
  mapping_record record;
BEGIN
  IF jsonb_typeof(NEW.member_mapping_ids) <> 'array'
     OR jsonb_typeof(NEW.member_version_ids) <> 'array'
     OR jsonb_typeof(NEW.languages) <> 'array'
     OR jsonb_typeof(NEW.publishers) <> 'array' THEN
    RAISE EXCEPTION 'multilingual candidate membership fields must be arrays';
  END IF;
  SELECT array_agg(value ORDER BY value) INTO mapping_ids
    FROM jsonb_array_elements_text(NEW.member_mapping_ids) AS each(value);
  IF mapping_ids IS NULL OR cardinality(mapping_ids) = 0 THEN
    RAISE EXCEPTION 'multilingual candidate has no mapping evidence';
  END IF;
  IF cardinality(mapping_ids) <> cardinality(ARRAY(SELECT DISTINCT unnest(mapping_ids))) THEN
    RAISE EXCEPTION 'multilingual candidate mapping ids are duplicated';
  END IF;
  SELECT COUNT(*) INTO mapping_count
    FROM local_multilingual_concept_mapping m
   WHERE m.mapping_id = ANY(mapping_ids)
     AND m.relation IN ('exact_alias','translation_equivalent')
     AND m.canonical_concept_key = NEW.canonical_concept_key
     AND m.target_language = NEW.target_language
     AND m.target_canonical_label = NEW.target_canonical_label;
  IF mapping_count <> cardinality(mapping_ids) THEN
    RAISE EXCEPTION 'multilingual candidate contains unknown, rejected, or mismatched mapping evidence';
  END IF;

  SELECT COUNT(DISTINCT m.source_language), COUNT(DISTINCT v.publisher_id)
    INTO language_count, publisher_count_local
    FROM local_multilingual_concept_mapping m
    JOIN local_source_item_version v ON v.version_id = m.source_version_id
   WHERE m.mapping_id = ANY(mapping_ids)
     AND btrim(v.publisher_id) <> '';
  IF language_count < 2 OR publisher_count_local < 2 THEN
    RAISE EXCEPTION 'cross-language candidate requires two languages and two publishers';
  END IF;
  IF NEW.source_language_count <> language_count OR NEW.publisher_count <> publisher_count_local
     OR NEW.member_count <> cardinality(mapping_ids) THEN
    RAISE EXCEPTION 'multilingual candidate counts do not match immutable evidence';
  END IF;

  SELECT array_agg(DISTINCT m.source_language ORDER BY m.source_language),
         array_agg(DISTINCT v.publisher_id ORDER BY v.publisher_id)
    INTO expected_languages, expected_publishers
    FROM local_multilingual_concept_mapping m
    JOIN local_source_item_version v ON v.version_id = m.source_version_id
   WHERE m.mapping_id = ANY(mapping_ids);
  IF NEW.languages <> to_jsonb(expected_languages)
     OR NEW.publishers <> to_jsonb(expected_publishers) THEN
    RAISE EXCEPTION 'multilingual candidate language/publisher sets do not match immutable evidence';
  END IF;

  SELECT array_agg(m.source_version_id ORDER BY m.source_version_id) FILTER (WHERE v.query_conditioned),
         array_agg(m.source_version_id ORDER BY m.source_version_id) FILTER (WHERE v.analysis_policy = 'exploration_only'),
         array_agg(m.source_version_id ORDER BY m.source_version_id) FILTER (WHERE v.analysis_policy = 'signal_eligible')
    INTO expected_query, expected_exploration, expected_signal
    FROM local_multilingual_concept_mapping m
    JOIN local_source_item_version v ON v.version_id = m.source_version_id
   WHERE m.mapping_id = ANY(mapping_ids);
  expected_query := COALESCE(expected_query, ARRAY[]::text[]);
  expected_exploration := COALESCE(expected_exploration, ARRAY[]::text[]);
  expected_signal := COALESCE(expected_signal, ARRAY[]::text[]);
  IF NEW.query_conditioned_version_ids <> to_jsonb(expected_query)
     OR NEW.exploration_only_version_ids <> to_jsonb(expected_exploration)
     OR NEW.signal_eligible_version_ids <> to_jsonb(expected_signal)
     OR NEW.query_conditioned_count <> cardinality(expected_query)
     OR NEW.exploration_only_count <> cardinality(expected_exploration)
     OR NEW.signal_eligible_count <> cardinality(expected_signal) THEN
    RAISE EXCEPTION 'multilingual candidate query/exploration qualification does not match immutable evidence';
  END IF;

  -- Keep every mapping tied to a distinct source version; this is evidence
  -- participation, never a translated-text event or claim merge.
  IF EXISTS (
    SELECT 1
      FROM local_multilingual_concept_mapping m
     WHERE m.mapping_id = ANY(mapping_ids)
     GROUP BY m.source_version_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'multilingual candidate repeats a source version';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_multilingual_candidate_guard_trigger ON local_multilingual_participation_candidate;
CREATE TRIGGER local_multilingual_candidate_guard_trigger
BEFORE INSERT OR UPDATE ON local_multilingual_participation_candidate
FOR EACH ROW EXECUTE FUNCTION local_multilingual_candidate_guard();

DROP TRIGGER IF EXISTS local_multilingual_candidate_immutable_trigger ON local_multilingual_participation_candidate;
CREATE TRIGGER local_multilingual_candidate_immutable_trigger
BEFORE UPDATE OR DELETE ON local_multilingual_participation_candidate
FOR EACH ROW EXECUTE FUNCTION local_multilingual_append_only_guard();
DROP TRIGGER IF EXISTS local_multilingual_candidate_no_truncate_trigger ON local_multilingual_participation_candidate;
CREATE TRIGGER local_multilingual_candidate_no_truncate_trigger
BEFORE TRUNCATE ON local_multilingual_participation_candidate
FOR EACH STATEMENT EXECUTE FUNCTION local_multilingual_append_only_guard();

CREATE TABLE IF NOT EXISTS local_multilingual_concept_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_multilingual_concept_schema_meta(schema_version)
VALUES ('018_multilingual_concepts_v1') ON CONFLICT DO NOTHING;

COMMIT;
