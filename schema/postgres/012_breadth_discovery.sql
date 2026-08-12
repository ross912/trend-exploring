-- Breadth discovery migration.
--
-- 011 remains the legacy local-radar schema.  This file is deliberately an
-- additive, idempotent migration: it can be applied to a clean 011 database
-- or rerun against a database that already contains these relations. Empty
-- early-draft relations are upgraded in place; non-empty ambiguous drafts are
-- rejected before mutation rather than guessed/backfilled.
BEGIN;

-- An empty table from an early draft can be completed safely.  Once draft
-- rows exist, however, missing columns/lineage constraints make their meaning
-- ambiguous; fail before any ALTER/UPDATE so the transaction leaves the draft
-- untouched.  A complete 012 schema (including its named structural keys) is
-- idempotently accepted on rerun.
DO $$
DECLARE
  rel regclass;
  row_count bigint;
  required_ok boolean;
  structural_ok boolean;
  bad_data boolean;
  present_count integer := 0;
  nonempty_count integer := 0;
BEGIN
  FOREACH rel IN ARRAY ARRAY[to_regclass('local_collection_batch'), to_regclass('local_collection_batch_source'), to_regclass('local_source_fetch_attempt'), to_regclass('local_radar_exploration_item')] LOOP
    -- A missing relation is the clean-install path and needs no preflight.
    CONTINUE WHEN rel IS NULL;
    present_count := present_count + 1;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    nonempty_count := nonempty_count + CASE WHEN row_count > 0 THEN 1 ELSE 0 END;
    IF rel::text = 'local_collection_batch' THEN
      SELECT COUNT(*) = 10 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['batch_id','started_at','completed_at','registry_hash','selected_count','planned_source_count','selected_set_hash','selected_order_hash','status','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_collection_batch_status_check') INTO structural_ok;
    ELSIF rel::text = 'local_collection_batch_source' THEN
      SELECT COUNT(*) = 5 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['batch_id','source_id','source_config_hash','sort_order','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_collection_batch_source_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_collection_batch_source_sort_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_collection_batch_source_source_hash_check') INTO structural_ok;
    ELSIF rel::text = 'local_source_fetch_attempt' THEN
      SELECT COUNT(*) = 15 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['attempt_id','batch_id','source_id','outcome','item_count','capture_id','http_status','discovery_basis','query_conditioned','analysis_policy','source_config_hash','error_code','error_message','started_at','completed_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_source_fetch_attempt_batch_source_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_source_fetch_attempt_capture_cardinality_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_source_fetch_attempt_cardinality_check') INTO structural_ok;
    ELSE
      SELECT COUNT(*) = 9 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['exploration_item_id','snapshot_id','batch_id','version_id','lane','reason','resolution','sort_order','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_radar_exploration_item_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_radar_exploration_item_snapshot_version_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_radar_exploration_item_contract_check') INTO structural_ok;
    END IF;
    IF row_count > 0 AND required_ok AND rel::text = 'local_collection_batch_source'
       THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM local_collection_batch_source WHERE btrim(source_config_hash) = '''')' INTO bad_data;
      IF bad_data THEN
        RAISE EXCEPTION 'unsupported early-draft data in %; source hash is not frozen', rel;
      END IF;
    END IF;
    IF row_count > 0 AND required_ok AND rel::text = 'local_source_fetch_attempt'
       THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM local_source_fetch_attempt WHERE btrim(source_config_hash) = '''' OR discovery_basis <> ''locale_headlines'' OR query_conditioned OR analysis_policy <> ''exploration_only'')' INTO bad_data;
      IF bad_data THEN
        RAISE EXCEPTION 'unsupported early-draft data in %; attempt contract is not frozen', rel;
      END IF;
    END IF;
    IF row_count > 0 AND (NOT required_ok OR NOT structural_ok) THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; refusing migration', rel;
    END IF;
  END LOOP;
  -- A row in only one of the staging relations cannot be interpreted without
  -- the sibling frozen-plan/attempt/membership relations.  Refuse this mixed
  -- draft before any CREATE/ALTER so the original data remains untouched.
  IF nonempty_count > 0 AND present_count < 4 THEN
    RAISE EXCEPTION 'unsupported early-draft data; discovery relation set is incomplete';
  END IF;
END $$;


-- A locale-only exploration publication may reuse the previous signal
-- projection.  Make that lineage explicit so a new revision cannot silently
-- look like a fresh signal analysis batch.
ALTER TABLE local_radar_snapshot ADD COLUMN IF NOT EXISTS signal_projection_status text NOT NULL DEFAULT 'fresh_batch';
ALTER TABLE local_radar_snapshot ADD COLUMN IF NOT EXISTS signal_source_snapshot_id text;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM local_radar_snapshot
     WHERE signal_projection_status NOT IN ('fresh_batch', 'reused_previous')
        OR (signal_projection_status = 'fresh_batch' AND signal_source_snapshot_id IS NOT NULL)
        OR (signal_projection_status = 'reused_previous' AND (signal_source_snapshot_id IS NULL OR signal_source_snapshot_id = snapshot_id))
  ) THEN
    RAISE EXCEPTION 'invalid signal projection lineage; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_radar_snapshot s
     WHERE s.signal_projection_status = 'reused_previous'
       AND NOT EXISTS (SELECT 1 FROM local_radar_snapshot prior WHERE prior.snapshot_id = s.signal_source_snapshot_id)
  ) THEN
    RAISE EXCEPTION 'orphan signal projection source snapshot; refusing migration';
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_snapshot'::regclass AND conname = 'local_radar_snapshot_signal_projection_status_check') THEN
    ALTER TABLE local_radar_snapshot ADD CONSTRAINT local_radar_snapshot_signal_projection_status_check CHECK (
      (signal_projection_status = 'fresh_batch' AND signal_source_snapshot_id IS NULL)
      OR (signal_projection_status = 'reused_previous' AND signal_source_snapshot_id IS NOT NULL AND signal_source_snapshot_id <> snapshot_id)
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_snapshot'::regclass AND conname = 'local_radar_snapshot_signal_projection_status_enum_check') THEN
    ALTER TABLE local_radar_snapshot ADD CONSTRAINT local_radar_snapshot_signal_projection_status_enum_check CHECK (signal_projection_status IN ('fresh_batch', 'reused_previous'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_snapshot'::regclass AND conname = 'local_radar_snapshot_signal_projection_fkey') THEN
    ALTER TABLE local_radar_snapshot ADD CONSTRAINT local_radar_snapshot_signal_projection_fkey
      FOREIGN KEY (signal_source_snapshot_id) REFERENCES local_radar_snapshot(snapshot_id);
  END IF;
END $$;

-- Freeze the discovery contract on both the registry projection and every
-- immutable source-item version.  Existing 011 rows are classified once from
-- their stored source_kind/query_conditioned values; subsequent runs never
-- rewrite a non-empty immutable field.
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS discovery_basis text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS analysis_policy text NOT NULL DEFAULT 'signal_eligible';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS aggregator_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS locale_tag text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS market_label text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS market_label_basis text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS query_topics jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS verification_status text NOT NULL DEFAULT 'unverified';

UPDATE local_source_registry
   SET discovery_basis = CASE WHEN source_kind = 'discovery' AND query_conditioned THEN 'topic_query' ELSE 'editorial_feed' END
 WHERE btrim(discovery_basis) = '';
UPDATE local_source_registry
   SET market_label_basis = CASE WHEN discovery_basis = 'locale_headlines' THEN 'aggregator_locale_label' ELSE 'editorial_scope_label' END
 WHERE btrim(market_label_basis) = '';
UPDATE local_source_registry
   SET query_topics = '[]'::jsonb
 WHERE query_topics IS NULL OR jsonb_typeof(query_topics) <> 'array';

ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS discovery_basis text NOT NULL DEFAULT 'editorial_feed';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS analysis_policy text NOT NULL DEFAULT 'signal_eligible';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS aggregator_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS locale_tag text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS market_label text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS market_label_basis text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS query_topics jsonb NOT NULL DEFAULT '[]'::jsonb;

UPDATE local_source_item i
   SET discovery_basis = COALESCE(r.discovery_basis, CASE WHEN i.source_kind = 'discovery' THEN 'topic_query' ELSE 'editorial_feed' END),
       analysis_policy = COALESCE(r.analysis_policy, 'signal_eligible'),
       aggregator_id = COALESCE(r.aggregator_id, ''),
       locale_tag = COALESCE(r.locale_tag, ''),
       market_label = COALESCE(r.market_label, ''),
       market_label_basis = COALESCE(r.market_label_basis, ''),
       query_topics = COALESCE(r.query_topics, '[]'::jsonb)
  FROM local_source_registry r
 WHERE r.source_id = i.source_id
   AND (i.discovery_basis = 'editorial_feed' OR btrim(i.analysis_policy) = '');

ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS discovery_basis text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS analysis_policy text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS aggregator_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS locale_tag text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS market_label text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS market_label_basis text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS query_topics jsonb NOT NULL DEFAULT '[]'::jsonb;

-- This update is intentionally guarded by the empty marker.  It is the only
-- migration-time interpretation of old versions; capture-time versions are
-- immutable thereafter even if the registry changes.
UPDATE local_source_item_version v
   SET discovery_basis = COALESCE(r.discovery_basis, CASE WHEN v.source_kind = 'discovery' AND v.query_conditioned THEN 'topic_query' ELSE 'editorial_feed' END),
       analysis_policy = COALESCE(r.analysis_policy, 'signal_eligible'),
       aggregator_id = COALESCE(r.aggregator_id, ''),
       locale_tag = COALESCE(r.locale_tag, ''),
       market_label = COALESCE(r.market_label, ''),
       market_label_basis = COALESCE(r.market_label_basis, ''),
       query_topics = COALESCE(r.query_topics, '[]'::jsonb)
  FROM local_source_registry r
 WHERE r.source_id = v.source_id
   AND btrim(v.discovery_basis) = '';
UPDATE local_source_item_version
   SET discovery_basis = CASE WHEN source_kind = 'discovery' AND query_conditioned THEN 'topic_query' ELSE 'editorial_feed' END
 WHERE btrim(discovery_basis) = '';
UPDATE local_source_item_version
   SET analysis_policy = CASE WHEN discovery_basis = 'locale_headlines' THEN 'exploration_only' ELSE 'signal_eligible' END
 WHERE btrim(analysis_policy) = '';
UPDATE local_source_registry
   SET query_topics = '["legacy_query"]'::jsonb
 WHERE discovery_basis = 'topic_query' AND jsonb_array_length(query_topics) = 0;
UPDATE local_source_item_version
   SET query_topics = '["legacy_query"]'::jsonb
 WHERE discovery_basis = 'topic_query' AND jsonb_array_length(query_topics) = 0;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM local_source_registry WHERE discovery_basis NOT IN ('editorial_feed', 'topic_query', 'locale_headlines')) THEN
    RAISE EXCEPTION 'invalid registry discovery_basis; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_source_registry WHERE analysis_policy NOT IN ('signal_eligible', 'exploration_only')) THEN
    RAISE EXCEPTION 'invalid registry analysis_policy; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_source_item_version WHERE discovery_basis NOT IN ('editorial_feed', 'topic_query', 'locale_headlines')) THEN
    RAISE EXCEPTION 'invalid version discovery_basis; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_source_item_version WHERE analysis_policy NOT IN ('signal_eligible', 'exploration_only')) THEN
    RAISE EXCEPTION 'invalid version analysis_policy; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_source_registry WHERE query_topics IS NULL OR jsonb_typeof(query_topics) <> 'array') THEN
    RAISE EXCEPTION 'invalid registry query_topics; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_source_item_version WHERE query_topics IS NULL OR jsonb_typeof(query_topics) <> 'array') THEN
    RAISE EXCEPTION 'invalid version query_topics; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM local_source_registry
     WHERE discovery_basis = 'locale_headlines'
       AND (source_kind <> 'discovery' OR query_conditioned OR btrim(aggregator_id) = ''
            OR btrim(locale_tag) = '' OR btrim(market_label) = ''
            OR market_label_basis <> 'aggregator_locale_label'
            OR jsonb_array_length(query_topics) <> 0)
  ) THEN
    RAISE EXCEPTION 'invalid locale_headlines registry contract; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM local_source_item_version
     WHERE discovery_basis = 'locale_headlines'
       AND (source_kind <> 'discovery' OR query_conditioned OR btrim(aggregator_id) = ''
            OR btrim(locale_tag) = '' OR btrim(market_label) = ''
            OR market_label_basis <> 'aggregator_locale_label'
            OR jsonb_array_length(query_topics) <> 0)
  ) THEN
    RAISE EXCEPTION 'invalid locale_headlines version contract; refusing migration';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_registry'::regclass AND conname = 'local_source_registry_discovery_basis_check') THEN
    ALTER TABLE local_source_registry ADD CONSTRAINT local_source_registry_discovery_basis_check CHECK (discovery_basis IN ('editorial_feed', 'topic_query', 'locale_headlines'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_registry'::regclass AND conname = 'local_source_registry_analysis_policy_check') THEN
    ALTER TABLE local_source_registry ADD CONSTRAINT local_source_registry_analysis_policy_check CHECK (analysis_policy IN ('signal_eligible', 'exploration_only'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_registry'::regclass AND conname = 'local_source_registry_query_topics_array_check') THEN
    ALTER TABLE local_source_registry ADD CONSTRAINT local_source_registry_query_topics_array_check CHECK (jsonb_typeof(query_topics) = 'array');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_registry'::regclass AND conname = 'local_source_registry_discovery_contract_check') THEN
    ALTER TABLE local_source_registry ADD CONSTRAINT local_source_registry_discovery_contract_check CHECK (
      (discovery_basis <> 'locale_headlines' OR (source_kind = 'discovery' AND query_conditioned = false AND analysis_policy = 'exploration_only' AND btrim(aggregator_id) <> '' AND btrim(locale_tag) <> '' AND btrim(market_label) <> '' AND market_label_basis = 'aggregator_locale_label' AND jsonb_array_length(query_topics) = 0))
      AND (discovery_basis <> 'topic_query' OR (source_kind = 'discovery' AND query_conditioned = true AND analysis_policy = 'signal_eligible' AND jsonb_array_length(query_topics) > 0))
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item'::regclass AND conname = 'local_source_item_discovery_basis_check') THEN
    ALTER TABLE local_source_item ADD CONSTRAINT local_source_item_discovery_basis_check CHECK (discovery_basis IN ('editorial_feed', 'topic_query', 'locale_headlines'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item'::regclass AND conname = 'local_source_item_analysis_policy_check') THEN
    ALTER TABLE local_source_item ADD CONSTRAINT local_source_item_analysis_policy_check CHECK (analysis_policy IN ('signal_eligible', 'exploration_only'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_discovery_basis_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_discovery_basis_check CHECK (discovery_basis IN ('editorial_feed', 'topic_query', 'locale_headlines'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_analysis_policy_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_analysis_policy_check CHECK (analysis_policy IN ('signal_eligible', 'exploration_only'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_query_topics_array_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_query_topics_array_check CHECK (jsonb_typeof(query_topics) = 'array');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_discovery_contract_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_discovery_contract_check CHECK (
      (discovery_basis <> 'locale_headlines' OR (source_kind = 'discovery' AND query_conditioned = false AND analysis_policy = 'exploration_only' AND btrim(aggregator_id) <> '' AND btrim(locale_tag) <> '' AND btrim(market_label) <> '' AND market_label_basis = 'aggregator_locale_label' AND jsonb_array_length(query_topics) = 0))
      AND (discovery_basis <> 'topic_query' OR (source_kind = 'discovery' AND query_conditioned = true AND analysis_policy = 'signal_eligible' AND jsonb_array_length(query_topics) > 0))
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS local_collection_batch (
  batch_id text PRIMARY KEY,
  started_at timestamptz NOT NULL,
  completed_at timestamptz,
  registry_hash text NOT NULL,
  selected_count integer NOT NULL DEFAULT 0 CHECK (selected_count >= 0),
  planned_source_count integer NOT NULL DEFAULT 0 CHECK (planned_source_count >= 0),
  selected_set_hash text NOT NULL DEFAULT '',
  selected_order_hash text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'frozen', 'published', 'failed', 'not_run')),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS planned_source_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS selected_set_hash text NOT NULL DEFAULT '';
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS selected_order_hash text NOT NULL DEFAULT '';
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS batch_id text;
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS started_at timestamptz;
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS completed_at timestamptz;
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS registry_hash text NOT NULL DEFAULT '';
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS selected_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'running';
ALTER TABLE local_collection_batch ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND conname = 'local_collection_batch_status_check') THEN
    ALTER TABLE local_collection_batch DROP CONSTRAINT local_collection_batch_status_check;
  END IF;
  ALTER TABLE local_collection_batch ADD CONSTRAINT local_collection_batch_status_check CHECK (status IN ('running', 'frozen', 'published', 'failed', 'not_run'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS local_collection_batch_source (
  batch_id text NOT NULL REFERENCES local_collection_batch(batch_id) ON DELETE CASCADE,
  source_id text NOT NULL REFERENCES local_source_registry(source_id),
  source_config_hash text NOT NULL,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id, source_id),
  UNIQUE (batch_id, sort_order),
  CHECK (btrim(source_config_hash) <> '')
);

ALTER TABLE local_collection_batch_source ADD COLUMN IF NOT EXISTS batch_id text;
ALTER TABLE local_collection_batch_source ADD COLUMN IF NOT EXISTS source_id text;
ALTER TABLE local_collection_batch_source ADD COLUMN IF NOT EXISTS source_config_hash text NOT NULL DEFAULT '';
ALTER TABLE local_collection_batch_source ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;
ALTER TABLE local_collection_batch_source ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS local_source_fetch_attempt (
  attempt_id text PRIMARY KEY,
  batch_id text NOT NULL REFERENCES local_collection_batch(batch_id) ON DELETE CASCADE,
  source_id text NOT NULL REFERENCES local_source_registry(source_id),
  outcome text NOT NULL CHECK (outcome IN ('succeeded_with_items', 'succeeded_empty', 'failed')),
  item_count integer NOT NULL DEFAULT 0 CHECK (item_count >= 0),
  capture_id text CONSTRAINT local_source_fetch_attempt_capture_fkey REFERENCES local_source_capture(capture_id),
  http_status integer CONSTRAINT local_source_fetch_attempt_http_status_check CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  discovery_basis text NOT NULL CHECK (discovery_basis = 'locale_headlines'),
  query_conditioned boolean NOT NULL DEFAULT false CHECK (query_conditioned = false),
  analysis_policy text NOT NULL CHECK (analysis_policy = 'exploration_only'),
  source_config_hash text NOT NULL,
  error_code text NOT NULL DEFAULT '',
  error_message text NOT NULL DEFAULT '',
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (batch_id, source_id),
  CHECK ((outcome = 'succeeded_with_items' AND capture_id IS NOT NULL) OR (outcome <> 'succeeded_with_items' AND capture_id IS NULL)),
  CHECK ((outcome = 'failed' AND (btrim(error_code) <> '' OR btrim(error_message) <> '')) OR outcome <> 'failed'),
  CHECK ((outcome = 'succeeded_with_items' AND item_count > 0) OR (outcome IN ('succeeded_empty', 'failed') AND item_count = 0))
);

ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS attempt_id text;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS batch_id text;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS source_id text;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS outcome text NOT NULL DEFAULT 'failed';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS item_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS capture_id text;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS http_status integer;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS started_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS completed_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_batch_source_fkey')
     AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_pkey') THEN
    ALTER TABLE local_source_fetch_attempt
      ADD CONSTRAINT local_source_fetch_attempt_batch_source_fkey
      FOREIGN KEY (batch_id, source_id) REFERENCES local_collection_batch_source(batch_id, source_id);
  END IF;
END $$;

-- Upgrade an early 012 draft without rewriting attempt history.
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS discovery_basis text NOT NULL DEFAULT 'locale_headlines';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS query_conditioned boolean NOT NULL DEFAULT false;
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS analysis_policy text NOT NULL DEFAULT 'exploration_only';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS source_config_hash text NOT NULL DEFAULT '';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS error_code text NOT NULL DEFAULT '';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS error_message text NOT NULL DEFAULT '';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS config_hash text NOT NULL DEFAULT '';
ALTER TABLE local_source_fetch_attempt ADD COLUMN IF NOT EXISTS error text NOT NULL DEFAULT '';
UPDATE local_source_fetch_attempt
   SET source_config_hash = COALESCE(NULLIF(source_config_hash, ''), NULLIF(config_hash, ''), 'legacy_config')
 WHERE btrim(source_config_hash) = '';
UPDATE local_source_fetch_attempt
   SET error_code = 'legacy_error', error_message = error
 WHERE outcome = 'failed' AND btrim(error_code) = '' AND btrim(error_message) = '' AND btrim(error) <> '';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_item_cardinality_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_item_cardinality_check
      CHECK ((outcome = 'succeeded_with_items' AND item_count > 0) OR (outcome IN ('succeeded_empty', 'failed') AND item_count = 0));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS local_source_fetch_attempt_batch_idx
  ON local_source_fetch_attempt (batch_id, outcome, source_id);

CREATE TABLE IF NOT EXISTS local_radar_exploration_item (
  exploration_item_id text PRIMARY KEY,
  snapshot_id text NOT NULL REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE,
  batch_id text NOT NULL REFERENCES local_collection_batch(batch_id),
  version_id text NOT NULL REFERENCES local_source_item_version(version_id),
  lane text NOT NULL CHECK (lane = 'locale_frontier'),
  reason text NOT NULL CHECK (reason = 'topic_unconditioned_locale_sample'),
  resolution text NOT NULL CHECK (resolution IN ('resolved', 'unresolved')),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, version_id),
  UNIQUE (snapshot_id, sort_order),
  UNIQUE (batch_id, version_id)
);

ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS exploration_item_id text;
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS snapshot_id text;
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS batch_id text;
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS version_id text;
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS lane text NOT NULL DEFAULT 'locale_frontier';
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS reason text NOT NULL DEFAULT 'topic_unconditioned_locale_sample';
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS resolution text NOT NULL DEFAULT 'unresolved';
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;
ALTER TABLE local_radar_exploration_item ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

-- Empty draft tables may carry incompatible capture/status checks.  Remove
-- only those checks while there are no rows to reinterpret; non-empty drafts
-- were rejected by the preflight above.
DO $$
DECLARE
  constraint_name text;
BEGIN
  -- Drop child keys first so parent PKs can be rebuilt below.
  IF to_regclass('local_source_fetch_attempt') IS NOT NULL AND (SELECT COUNT(*) FROM local_source_fetch_attempt) = 0 THEN
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND contype IN ('p', 'u', 'f') LOOP
      EXECUTE format('ALTER TABLE local_source_fetch_attempt DROP CONSTRAINT %I', constraint_name);
    END LOOP;
  END IF;
  IF to_regclass('local_radar_exploration_item') IS NOT NULL AND (SELECT COUNT(*) FROM local_radar_exploration_item) = 0 THEN
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND contype IN ('p', 'u', 'f') LOOP
      EXECUTE format('ALTER TABLE local_radar_exploration_item DROP CONSTRAINT %I', constraint_name);
    END LOOP;
  END IF;
  IF to_regclass('local_collection_batch_source') IS NOT NULL AND (SELECT COUNT(*) FROM local_collection_batch_source) = 0 THEN
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND contype IN ('c', 'p', 'u', 'f') LOOP
      EXECUTE format('ALTER TABLE local_collection_batch_source DROP CONSTRAINT %I', constraint_name);
    END LOOP;
  END IF;
  IF to_regclass('local_collection_batch') IS NOT NULL AND (SELECT COUNT(*) FROM local_collection_batch) = 0 THEN
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND contype = 'c' LOOP
      EXECUTE format('ALTER TABLE local_collection_batch DROP CONSTRAINT %I', constraint_name);
    END LOOP;
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND contype IN ('p', 'u', 'f') LOOP
      EXECUTE format('ALTER TABLE local_collection_batch DROP CONSTRAINT %I', constraint_name);
    END LOOP;
  END IF;
  IF to_regclass('local_source_fetch_attempt') IS NOT NULL AND (SELECT COUNT(*) FROM local_source_fetch_attempt) = 0 THEN
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND contype = 'c' LOOP
      EXECUTE format('ALTER TABLE local_source_fetch_attempt DROP CONSTRAINT %I', constraint_name);
    END LOOP;
    ALTER TABLE local_source_fetch_attempt ALTER COLUMN capture_id DROP NOT NULL;
  END IF;
  IF to_regclass('local_radar_exploration_item') IS NOT NULL AND (SELECT COUNT(*) FROM local_radar_exploration_item) = 0 THEN
    -- Child keys were dropped at the start of this block; retain this branch
    -- for checks after an early draft had no key constraints.
    FOR constraint_name IN SELECT conname FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND contype = 'c' LOOP
      EXECUTE format('ALTER TABLE local_radar_exploration_item DROP CONSTRAINT %I', constraint_name);
    END LOOP;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS local_radar_exploration_item_snapshot_idx
  ON local_radar_exploration_item (snapshot_id, sort_order);

-- Existing staging rows are checked before adding the stronger lineage
-- constraints.  Orphans are never silently detached or repaired.
-- Complete empty early-draft relations with frozen columns/constraints.  The
-- preflight at the file head guarantees this block never guesses over rows.
DO $$
BEGIN
  ALTER TABLE local_collection_batch ALTER COLUMN batch_id SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN started_at SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN registry_hash SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN selected_count SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN planned_source_count SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN selected_set_hash SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN selected_order_hash SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN status SET NOT NULL;
  ALTER TABLE local_collection_batch ALTER COLUMN created_at SET NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND conname = 'local_collection_batch_pkey') THEN
    ALTER TABLE local_collection_batch ADD CONSTRAINT local_collection_batch_pkey PRIMARY KEY (batch_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND conname = 'local_collection_batch_selected_count_check') THEN
    ALTER TABLE local_collection_batch ADD CONSTRAINT local_collection_batch_selected_count_check CHECK (selected_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND conname = 'local_collection_batch_planned_source_count_check') THEN
    ALTER TABLE local_collection_batch ADD CONSTRAINT local_collection_batch_planned_source_count_check CHECK (planned_source_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch'::regclass AND conname = 'local_collection_batch_status_check') THEN
    ALTER TABLE local_collection_batch ADD CONSTRAINT local_collection_batch_status_check CHECK (status IN ('running', 'frozen', 'published', 'failed', 'not_run'));
  END IF;

  ALTER TABLE local_collection_batch_source ALTER COLUMN batch_id SET NOT NULL;
  ALTER TABLE local_collection_batch_source ALTER COLUMN source_id SET NOT NULL;
  ALTER TABLE local_collection_batch_source ALTER COLUMN source_config_hash SET NOT NULL;
  ALTER TABLE local_collection_batch_source ALTER COLUMN sort_order SET NOT NULL;
  ALTER TABLE local_collection_batch_source ALTER COLUMN created_at SET NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_pkey') THEN
    ALTER TABLE local_collection_batch_source ADD CONSTRAINT local_collection_batch_source_pkey PRIMARY KEY (batch_id, source_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_sort_key') THEN
    ALTER TABLE local_collection_batch_source ADD CONSTRAINT local_collection_batch_source_sort_key UNIQUE (batch_id, sort_order);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_source_hash_check') THEN
    ALTER TABLE local_collection_batch_source ADD CONSTRAINT local_collection_batch_source_source_hash_check CHECK (btrim(source_config_hash) <> '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_batch_fkey') THEN
    ALTER TABLE local_collection_batch_source ADD CONSTRAINT local_collection_batch_source_batch_fkey FOREIGN KEY (batch_id) REFERENCES local_collection_batch(batch_id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_collection_batch_source'::regclass AND conname = 'local_collection_batch_source_registry_fkey') THEN
    ALTER TABLE local_collection_batch_source ADD CONSTRAINT local_collection_batch_source_registry_fkey FOREIGN KEY (source_id) REFERENCES local_source_registry(source_id);
  END IF;

  ALTER TABLE local_source_fetch_attempt ALTER COLUMN attempt_id SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN batch_id SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN source_id SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN outcome SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN item_count SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN discovery_basis SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN query_conditioned SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN analysis_policy SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN source_config_hash SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN error_code SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN error_message SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN started_at SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN completed_at SET NOT NULL;
  ALTER TABLE local_source_fetch_attempt ALTER COLUMN created_at SET NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_pkey') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_pkey PRIMARY KEY (attempt_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_batch_source_key') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_batch_source_key UNIQUE (batch_id, source_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_outcome_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_outcome_check CHECK (outcome IN ('succeeded_with_items', 'succeeded_empty', 'failed'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_item_count_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_item_count_check CHECK (item_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_contract_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_contract_check CHECK (discovery_basis = 'locale_headlines' AND query_conditioned = false AND analysis_policy = 'exploration_only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_source_hash_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_source_hash_check CHECK (btrim(source_config_hash) <> '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_capture_cardinality_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_capture_cardinality_check CHECK ((outcome = 'succeeded_with_items' AND capture_id IS NOT NULL) OR (outcome IN ('succeeded_empty', 'failed') AND capture_id IS NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_error_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_error_check CHECK ((outcome = 'failed' AND (btrim(error_code) <> '' OR btrim(error_message) <> '')) OR outcome <> 'failed');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_cardinality_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_cardinality_check CHECK ((outcome = 'succeeded_with_items' AND item_count > 0) OR (outcome IN ('succeeded_empty', 'failed') AND item_count = 0));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_batch_source_fkey') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_batch_source_fkey FOREIGN KEY (batch_id, source_id) REFERENCES local_collection_batch_source(batch_id, source_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND confrelid = 'local_source_capture'::regclass) THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_capture_fkey FOREIGN KEY (capture_id) REFERENCES local_source_capture(capture_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_http_status_check') THEN
    ALTER TABLE local_source_fetch_attempt ADD CONSTRAINT local_source_fetch_attempt_http_status_check CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599);
  END IF;

  ALTER TABLE local_radar_exploration_item ALTER COLUMN exploration_item_id SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN snapshot_id SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN batch_id SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN version_id SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN lane SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN reason SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN resolution SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN sort_order SET NOT NULL;
  ALTER TABLE local_radar_exploration_item ALTER COLUMN created_at SET NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_pkey') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_pkey PRIMARY KEY (exploration_item_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_snapshot_version_key') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_snapshot_version_key UNIQUE (snapshot_id, version_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_snapshot_order_key') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_snapshot_order_key UNIQUE (snapshot_id, sort_order);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_batch_version_key') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_batch_version_key UNIQUE (batch_id, version_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_contract_check') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_contract_check CHECK (lane = 'locale_frontier' AND reason = 'topic_unconditioned_locale_sample' AND resolution IN ('resolved', 'unresolved') AND sort_order >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_snapshot_fkey') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_snapshot_fkey FOREIGN KEY (snapshot_id) REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_batch_fkey') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_batch_fkey FOREIGN KEY (batch_id) REFERENCES local_collection_batch(batch_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_version_fkey') THEN
    ALTER TABLE local_radar_exploration_item ADD CONSTRAINT local_radar_exploration_item_version_fkey FOREIGN KEY (version_id) REFERENCES local_source_item_version(version_id);
  END IF;
END $$;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM local_source_fetch_attempt WHERE outcome NOT IN ('succeeded_with_items', 'succeeded_empty', 'failed') OR item_count < 0 OR (outcome = 'succeeded_with_items' AND (item_count <= 0 OR capture_id IS NULL)) OR (outcome IN ('succeeded_empty', 'failed') AND (item_count <> 0 OR capture_id IS NOT NULL)) OR (outcome = 'failed' AND btrim(error_code) = '' AND btrim(error_message) = '')) THEN
    RAISE EXCEPTION 'invalid fetch attempt enum/cardinality; refusing migration';
  END IF;
  IF EXISTS (SELECT 1 FROM local_radar_exploration_item WHERE lane <> 'locale_frontier' OR reason <> 'topic_unconditioned_locale_sample' OR resolution NOT IN ('resolved', 'unresolved') OR sort_order < 0) THEN
    RAISE EXCEPTION 'invalid exploration membership contract; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM local_source_fetch_attempt a
    LEFT JOIN local_collection_batch b ON b.batch_id = a.batch_id
    LEFT JOIN local_source_registry r ON r.source_id = a.source_id
    WHERE b.batch_id IS NULL OR r.source_id IS NULL
  ) THEN
    RAISE EXCEPTION 'fetch attempt lineage missing; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM local_radar_exploration_item e
    LEFT JOIN local_radar_snapshot s ON s.snapshot_id = e.snapshot_id
    LEFT JOIN local_collection_batch b ON b.batch_id = e.batch_id
    LEFT JOIN local_source_item_version v ON v.version_id = e.version_id
    WHERE s.snapshot_id IS NULL OR b.batch_id IS NULL OR v.version_id IS NULL
  ) THEN
    RAISE EXCEPTION 'exploration item lineage missing; refusing migration';
  END IF;
END $$;

COMMIT;
