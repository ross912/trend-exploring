-- World-change candidate ledger v2.
--
-- This migration is additive and safe to run repeatedly on a clean database.
-- A detector run and its candidate/channel rows are append-only evidence.  The
-- schema intentionally stores per-channel evidence and lineage, not a score,
-- confidence, forecast, or prediction.
BEGIN;

-- Refuse to reinterpret a non-empty early draft relation.  Empty malformed
-- drafts are safe to replace because no evidence would be discarded.
DO $$
DECLARE
  relname text;
  rel regclass;
  row_count bigint;
  shape_ok boolean;
BEGIN
  FOREACH relname IN ARRAY ARRAY[
    'world_change_candidate_channel',
    'world_change_candidate',
    'world_change_run'
  ] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF relname = 'world_change_run' THEN
      SELECT COUNT(*) IN (8, 10) INTO shape_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'run_id','as_of','input_cutoff','input_hash','detector_version',
           'status','validated_precision','validation_manifest_hash','payload_hash','created_at'
         ]);
      shape_ok := shape_ok AND EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = rel AND conname = 'world_change_run_pkey'
      );
    ELSIF relname = 'world_change_candidate' THEN
      SELECT COUNT(*) = 23 INTO shape_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'run_id','candidate_key','label','candidate_status','detector_version',
           'qualifying_publisher_ids','qualifying_publisher_count',
           'qualifying_version_ids','channel_count','channels','evidence_items',
           'contradicting_evidence','missing_channels','alternative_explanations',
           'next_verification','query_conditioned_evidence_count',
           'exploration_evidence_count','observed_publisher_ids',
           'first_published_at','last_published_at','analysis_as_of',
           'sort_order','created_at'
         ]);
      shape_ok := shape_ok AND EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = rel AND conname = 'world_change_candidate_pkey'
      );
    ELSE
      SELECT COUNT(*) = 9 INTO shape_ok
        FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY[
           'run_id','candidate_key','channel','version_ids','publisher_ids',
           'evidence','supporting_evidence','contradicting_evidence','created_at'
         ]);
      shape_ok := shape_ok AND EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = rel AND conname = 'world_change_candidate_channel_pkey'
      );
    END IF;
    IF row_count > 0 AND NOT shape_ok THEN
      RAISE EXCEPTION 'unsupported non-empty early draft in %; refusing 019 migration', relname;
    END IF;
  END LOOP;

  -- Drop only empty malformed drafts, child first, so a rerun can establish
  -- the frozen shape without ever discarding evidence.
  FOREACH relname IN ARRAY ARRAY[
    'world_change_candidate_channel',
    'world_change_candidate',
    'world_change_run'
  ] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF row_count = 0 THEN
      IF relname = 'world_change_run' THEN
        SELECT COUNT(*) IN (8, 10) INTO shape_ok
          FROM pg_attribute
         WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
           AND attname = ANY (ARRAY[
             'run_id','as_of','input_cutoff','input_hash','detector_version',
             'status','validated_precision','validation_manifest_hash','payload_hash','created_at'
           ]);
      ELSIF relname = 'world_change_candidate' THEN
        SELECT COUNT(*) = 23 INTO shape_ok
          FROM pg_attribute
         WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
           AND attname = ANY (ARRAY[
             'run_id','candidate_key','label','candidate_status','detector_version',
             'qualifying_publisher_ids','qualifying_publisher_count',
             'qualifying_version_ids','channel_count','channels','evidence_items',
             'contradicting_evidence','missing_channels','alternative_explanations',
             'next_verification','query_conditioned_evidence_count',
             'exploration_evidence_count','observed_publisher_ids',
             'first_published_at','last_published_at','analysis_as_of',
             'sort_order','created_at'
           ]);
      ELSE
        SELECT COUNT(*) = 9 INTO shape_ok
          FROM pg_attribute
         WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
           AND attname = ANY (ARRAY[
             'run_id','candidate_key','channel','version_ids','publisher_ids',
             'evidence','supporting_evidence','contradicting_evidence','created_at'
           ]);
      END IF;
      IF NOT shape_ok THEN
        EXECUTE format('DROP TABLE %I', relname);
      END IF;
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS world_change_run (
  run_id text PRIMARY KEY,
  as_of timestamptz NOT NULL,
  input_cutoff timestamptz NOT NULL,
  input_hash text NOT NULL CHECK (btrim(input_hash) <> ''),
  detector_version text NOT NULL CHECK (btrim(detector_version) <> ''),
  status text NOT NULL CHECK (status IN ('warming_up', 'evaluated')),
  validated_precision boolean,
  validation_manifest_hash text,
  payload_hash text NOT NULL CHECK (btrim(payload_hash) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (run_id, input_hash)
  ,CHECK ((detector_version = 'world_change_detector_v2'
           AND validated_precision IS TRUE
           AND validation_manifest_hash = '216e3da7c4f6a45c83764d1883ae4738bdfb6411509d4877fa68f400f842c483')
       OR (detector_version <> 'world_change_detector_v2'
           AND COALESCE(validated_precision, FALSE) IS FALSE
           AND validation_manifest_hash IS NULL))
);

-- Additive upgrade for databases created by the original v1 migration.  Old
-- rows remain explicitly non-public (false/null); no historical row is
-- rewritten as v2.
ALTER TABLE world_change_run ADD COLUMN IF NOT EXISTS validated_precision boolean;
ALTER TABLE world_change_run ADD COLUMN IF NOT EXISTS validation_manifest_hash text;
-- Historical v1 rows intentionally remain byte-for-byte immutable.  NULL in
-- the additive precision columns is already fail-closed (the public gate
-- treats it as false), so do not rewrite those rows under the append-only
-- trigger while applying this migration.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'world_change_run'::regclass AND conname = 'world_change_run_precision_manifest_check') THEN
    ALTER TABLE world_change_run ADD CONSTRAINT world_change_run_precision_manifest_check CHECK (
      (detector_version = 'world_change_detector_v2' AND validated_precision IS TRUE AND validation_manifest_hash = '216e3da7c4f6a45c83764d1883ae4738bdfb6411509d4877fa68f400f842c483')
      OR (detector_version <> 'world_change_detector_v2' AND COALESCE(validated_precision, FALSE) IS FALSE AND validation_manifest_hash IS NULL)
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS world_change_candidate (
  run_id text NOT NULL REFERENCES world_change_run(run_id),
  candidate_key text NOT NULL,
  label text NOT NULL CHECK (btrim(label) <> ''),
  candidate_status text NOT NULL CHECK (candidate_status IN ('candidate', 'convergence_candidate')),
  detector_version text NOT NULL CHECK (btrim(detector_version) <> ''),
  qualifying_publisher_ids jsonb NOT NULL,
  qualifying_publisher_count integer NOT NULL CHECK (qualifying_publisher_count >= 2),
  qualifying_version_ids jsonb NOT NULL,
  channel_count integer NOT NULL CHECK (channel_count >= 1 AND channel_count <= 5),
  channels jsonb NOT NULL,
  evidence_items jsonb NOT NULL,
  contradicting_evidence jsonb NOT NULL,
  missing_channels jsonb NOT NULL,
  alternative_explanations jsonb NOT NULL,
  next_verification jsonb NOT NULL,
  query_conditioned_evidence_count integer NOT NULL CHECK (query_conditioned_evidence_count >= 0),
  exploration_evidence_count integer NOT NULL CHECK (exploration_evidence_count >= 0),
  observed_publisher_ids jsonb NOT NULL,
  first_published_at timestamptz,
  last_published_at timestamptz,
  analysis_as_of timestamptz NOT NULL,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, candidate_key),
  UNIQUE (run_id, sort_order),
  CHECK (jsonb_typeof(qualifying_publisher_ids) = 'array'),
  CHECK (jsonb_typeof(qualifying_version_ids) = 'array'),
  CHECK (jsonb_typeof(channels) = 'object'),
  CHECK (jsonb_typeof(evidence_items) = 'array'),
  CHECK (jsonb_typeof(contradicting_evidence) = 'array'),
  CHECK (jsonb_typeof(missing_channels) = 'array'),
  CHECK (jsonb_typeof(alternative_explanations) = 'array'),
  CHECK (jsonb_typeof(next_verification) = 'array'),
  CHECK (jsonb_typeof(observed_publisher_ids) = 'array'),
  CHECK ((candidate_status = 'convergence_candidate' AND channel_count >= 2)
      OR candidate_status = 'candidate')
);

CREATE TABLE IF NOT EXISTS world_change_candidate_channel (
  run_id text NOT NULL,
  candidate_key text NOT NULL,
  channel text NOT NULL CHECK (channel IN (
    'technical_capability', 'capital_commitment', 'policy_action',
    'real_world_adoption', 'public_discussion'
  )),
  version_ids jsonb NOT NULL,
  publisher_ids jsonb NOT NULL,
  evidence jsonb NOT NULL,
  supporting_evidence jsonb NOT NULL,
  contradicting_evidence jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, candidate_key, channel),
  FOREIGN KEY (run_id, candidate_key)
    REFERENCES world_change_candidate(run_id, candidate_key),
  CHECK (jsonb_typeof(version_ids) = 'array'),
  CHECK (jsonb_typeof(publisher_ids) = 'array'),
  CHECK (jsonb_typeof(evidence) = 'array'),
  CHECK (jsonb_typeof(supporting_evidence) = 'array'),
  CHECK (jsonb_typeof(contradicting_evidence) = 'array')
);

CREATE INDEX IF NOT EXISTS world_change_run_latest_idx
  ON world_change_run(status, as_of DESC, created_at DESC, run_id ASC);
CREATE INDEX IF NOT EXISTS world_change_candidate_run_order_idx
  ON world_change_candidate(run_id, sort_order ASC);
CREATE INDEX IF NOT EXISTS world_change_channel_lookup_idx
  ON world_change_candidate_channel(channel, run_id, candidate_key);

CREATE OR REPLACE FUNCTION world_change_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; updates and deletes are forbidden', TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS world_change_run_append_only ON world_change_run;
CREATE TRIGGER world_change_run_append_only
BEFORE UPDATE OR DELETE ON world_change_run
FOR EACH ROW EXECUTE FUNCTION world_change_append_only_guard();

DROP TRIGGER IF EXISTS world_change_candidate_append_only ON world_change_candidate;
CREATE TRIGGER world_change_candidate_append_only
BEFORE UPDATE OR DELETE ON world_change_candidate
FOR EACH ROW EXECUTE FUNCTION world_change_append_only_guard();

DROP TRIGGER IF EXISTS world_change_channel_append_only ON world_change_candidate_channel;
CREATE TRIGGER world_change_channel_append_only
BEFORE UPDATE OR DELETE ON world_change_candidate_channel
FOR EACH ROW EXECUTE FUNCTION world_change_append_only_guard();

COMMENT ON TABLE world_change_run IS
  'Append-only detector runs; evidence is multi-channel and not a prediction.';
COMMENT ON TABLE world_change_candidate IS
  'Evidence-first world-change candidates; deliberately has no score/confidence/forecast.';
COMMENT ON TABLE world_change_candidate_channel IS
  'Per-channel evidence and version_id lineage for five independent world-change channels.';

COMMIT;
