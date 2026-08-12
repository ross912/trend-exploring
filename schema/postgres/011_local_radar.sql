-- Local product vertical slice. This migration is intentionally small and
-- disposable; it is not the complete production schema.
BEGIN;

CREATE TABLE IF NOT EXISTS local_radar_snapshot (
  snapshot_id text PRIMARY KEY,
  surface_id text NOT NULL,
  revision integer NOT NULL CHECK (revision > 0),
  comparison_watermark text NOT NULL,
  method_epoch text NOT NULL,
  rights_epoch bigint NOT NULL CHECK (rights_epoch > 0),
  render_plan_hash text NOT NULL,
  snapshot_status text NOT NULL CHECK (snapshot_status IN ('published', 'recomputing', 'unavailable')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (surface_id, revision)
);

CREATE TABLE IF NOT EXISTS local_radar_card (
  card_id text PRIMARY KEY,
  snapshot_id text NOT NULL CONSTRAINT local_event_candidate_snapshot_id_fkey REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE,
  signal_type text NOT NULL,
  title text NOT NULL,
  summary text NOT NULL,
  metric_label text NOT NULL,
  metric_value text NOT NULL,
  source_count integer NOT NULL CHECK (source_count >= 0),
  stance text NOT NULL,
  action_stage text NOT NULL,
  evidence_label text NOT NULL,
  source_name text NOT NULL DEFAULT '',
  source_url text NOT NULL DEFAULT '',
  source_language text NOT NULL DEFAULT '',
  source_region text NOT NULL DEFAULT '',
  original_title text NOT NULL DEFAULT '',
  original_summary text NOT NULL DEFAULT '',
  translation_status text NOT NULL DEFAULT 'not_needed',
  translation_artifact_id text NOT NULL DEFAULT '',
  translated_at timestamptz,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, sort_order)
);

CREATE INDEX IF NOT EXISTS local_radar_card_snapshot_order_idx
  ON local_radar_card (snapshot_id, sort_order);

ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_name text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_url text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_language text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_region text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS original_title text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS original_summary text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS translation_status text NOT NULL DEFAULT 'not_needed';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS translation_artifact_id text NOT NULL DEFAULT '';
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS translated_at timestamptz;

CREATE TABLE IF NOT EXISTS local_source_item (
  item_key text PRIMARY KEY,
  source_id text NOT NULL,
  source_name text NOT NULL,
  language text NOT NULL,
  region text NOT NULL DEFAULT '未标注',
  publisher_name text NOT NULL DEFAULT '',
  publisher_url text NOT NULL DEFAULT '',
  publisher_id text NOT NULL DEFAULT '',
  publisher_identity_status text NOT NULL DEFAULT 'unresolved' CHECK (publisher_identity_status IN ('configured', 'observed_domain', 'unresolved')),
  source_kind text NOT NULL DEFAULT 'configured' CHECK (source_kind IN ('configured', 'discovery')),
  capture_id text,
  title text NOT NULL,
  summary text NOT NULL,
  source_url text NOT NULL,
  published_at timestamptz,
  fetched_at timestamptz NOT NULL,
  captured_at timestamptz NOT NULL,
  content_hash text NOT NULL,
  UNIQUE (source_id, source_url)
);

ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS region text NOT NULL DEFAULT '未标注';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS publisher_name text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS publisher_url text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS publisher_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS publisher_identity_status text NOT NULL DEFAULT 'unresolved';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS source_kind text NOT NULL DEFAULT 'configured';
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS capture_id text;
ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS captured_at timestamptz;
UPDATE local_source_item SET captured_at = fetched_at WHERE captured_at IS NULL;
ALTER TABLE local_source_item ALTER COLUMN captured_at SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_item'::regclass
       AND conname = 'local_source_item_publisher_identity_status_check'
  ) THEN
    ALTER TABLE local_source_item
      ADD CONSTRAINT local_source_item_publisher_identity_status_check
      CHECK (publisher_identity_status IN ('configured', 'observed_domain', 'unresolved'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS local_source_item_published_idx
  ON local_source_item (published_at DESC NULLS LAST, fetched_at DESC);

CREATE TABLE IF NOT EXISTS local_source_capture (
  capture_id text PRIMARY KEY,
  source_id text NOT NULL,
  source_url text NOT NULL,
  source_kind text NOT NULL DEFAULT 'configured' CHECK (source_kind IN ('configured', 'discovery')),
  rights_scope text NOT NULL DEFAULT 'metadata_short_summary_link',
  captured_at timestamptz NOT NULL,
  http_status integer NOT NULL CHECK (http_status BETWEEN 100 AND 599),
  content_type text NOT NULL DEFAULT '',
  content_bytes integer NOT NULL CHECK (content_bytes >= 0),
  body_hash text NOT NULL,
  storage_status text NOT NULL CHECK (storage_status IN ('stored', 'metadata_only', 'not_captured')),
  storage_uri text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- capture_id is the observation identity. Do not collapse two explicitly
-- distinct captures merely because a source emitted the same body at the same
-- timestamp (for example, a replayed fixture).
ALTER TABLE local_source_capture DROP CONSTRAINT IF EXISTS local_source_capture_source_id_body_hash_captured_at_key;

CREATE INDEX IF NOT EXISTS local_source_capture_source_time_idx
  ON local_source_capture (source_id, captured_at DESC);

CREATE TABLE IF NOT EXISTS local_source_item_version (
  version_id text PRIMARY KEY,
  item_key text NOT NULL REFERENCES local_source_item(item_key) ON DELETE CASCADE,
  capture_id text NOT NULL REFERENCES local_source_capture(capture_id),
  source_id text NOT NULL,
  source_name text NOT NULL DEFAULT '',
  language text NOT NULL DEFAULT '',
  region text NOT NULL DEFAULT '未标注',
  publisher_name text NOT NULL DEFAULT '',
  publisher_url text NOT NULL DEFAULT '',
  publisher_id text NOT NULL DEFAULT '',
  publisher_identity_status text NOT NULL DEFAULT 'unresolved',
  source_kind text NOT NULL DEFAULT 'configured',
  query_conditioned boolean NOT NULL DEFAULT false,
  -- Qualification metadata is frozen either at capture time or, for rows
  -- that predate this lineage table, once from the then-current projection.
  lineage_metadata_basis text NOT NULL DEFAULT 'capture_time',
  title text NOT NULL,
  summary text NOT NULL,
  source_url text NOT NULL,
  published_at timestamptz,
  fetched_at timestamptz NOT NULL,
  captured_at timestamptz NOT NULL,
  content_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_key, capture_id)
);

-- Older staging databases used (item_key, content_hash, captured_at). The
-- capture itself is the immutable observation identity, so migrate the
-- constraint without touching the retained history.
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS fetched_at timestamptz;
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS source_name text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS language text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS region text NOT NULL DEFAULT '未标注';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS publisher_name text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS publisher_url text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS publisher_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS publisher_identity_status text NOT NULL DEFAULT 'unresolved';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS source_kind text NOT NULL DEFAULT 'configured';
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS query_conditioned boolean NOT NULL DEFAULT false;
ALTER TABLE local_source_item_version ADD COLUMN IF NOT EXISTS lineage_metadata_basis text NOT NULL DEFAULT '';
UPDATE local_source_item_version SET fetched_at = captured_at WHERE fetched_at IS NULL;
ALTER TABLE local_source_item_version ALTER COLUMN fetched_at SET NOT NULL;
ALTER TABLE local_source_item_version DROP CONSTRAINT IF EXISTS local_source_item_version_item_key_content_hash_captured_at_key;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM local_source_item_version
     GROUP BY item_key, capture_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'local_source_item_version item/capture duplicate; refusing migration';
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'local_source_item_version'::regclass
       AND conname = 'local_source_item_version_item_key_capture_id_key'
  ) THEN
    ALTER TABLE local_source_item_version
      ADD CONSTRAINT local_source_item_version_item_key_capture_id_key UNIQUE (item_key, capture_id);
  END IF;
END $$;

-- Before adding composite lineage constraints, refuse to silently reinterpret
-- any existing staging history. The database is disposable, but history is
-- still append-only: a conflict is an explicit migration stop, not a delete.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM local_source_item i
     WHERE i.capture_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
           FROM local_source_capture c
          WHERE c.capture_id = i.capture_id
            AND c.source_id = i.source_id
       )
  ) THEN
    RAISE EXCEPTION 'local_source_item capture/source lineage conflict; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_source_item_version v
     WHERE NOT EXISTS (
         SELECT 1
           FROM local_source_capture c
          WHERE c.capture_id = v.capture_id
            AND c.source_id = v.source_id
       )
  ) THEN
    RAISE EXCEPTION 'local_source_item_version capture/source lineage conflict; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_source_item_version v
     WHERE NOT EXISTS (
         SELECT 1
           FROM local_source_item i
          WHERE i.item_key = v.item_key
            AND i.source_id = v.source_id
            AND i.source_url = v.source_url
       )
  ) THEN
    RAISE EXCEPTION 'local_source_item_version item/source/link lineage conflict; refusing migration';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_capture'::regclass
       AND conname = 'local_source_capture_capture_id_source_id_key'
  ) THEN
    ALTER TABLE local_source_capture
      ADD CONSTRAINT local_source_capture_capture_id_source_id_key UNIQUE (capture_id, source_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_item'::regclass
       AND conname = 'local_source_item_item_key_source_id_source_url_key'
  ) THEN
    ALTER TABLE local_source_item
      ADD CONSTRAINT local_source_item_item_key_source_id_source_url_key UNIQUE (item_key, source_id, source_url);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_item'::regclass
       AND conname = 'local_source_item_capture_source_fkey'
  ) THEN
    ALTER TABLE local_source_item
      ADD CONSTRAINT local_source_item_capture_source_fkey
      FOREIGN KEY (capture_id, source_id)
      REFERENCES local_source_capture (capture_id, source_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_item_version'::regclass
       AND conname = 'local_source_item_version_capture_source_fkey'
  ) THEN
    ALTER TABLE local_source_item_version
      ADD CONSTRAINT local_source_item_version_capture_source_fkey
      FOREIGN KEY (capture_id, source_id)
      REFERENCES local_source_capture (capture_id, source_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'local_source_item_version'::regclass
       AND conname = 'local_source_item_version_item_source_link_fkey'
  ) THEN
    ALTER TABLE local_source_item_version
      ADD CONSTRAINT local_source_item_version_item_source_link_fkey
      FOREIGN KEY (item_key, source_id, source_url)
      REFERENCES local_source_item (item_key, source_id, source_url);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS local_source_item_version_item_time_idx
  ON local_source_item_version (item_key, captured_at DESC);

CREATE TABLE IF NOT EXISTS local_source_registry (
  source_id text PRIMARY KEY,
  source_name text NOT NULL,
  source_url text NOT NULL,
  language text NOT NULL,
  region text NOT NULL,
  publisher_region text NOT NULL DEFAULT '',
  publisher_id text NOT NULL DEFAULT '',
  region_basis text NOT NULL DEFAULT 'editorial_scope_label',
  query_conditioned boolean NOT NULL DEFAULT false,
  source_kind text NOT NULL DEFAULT 'configured' CHECK (source_kind IN ('configured', 'discovery')),
  enabled boolean NOT NULL DEFAULT true,
  last_fetch_at timestamptz,
  last_item_count integer NOT NULL DEFAULT 0 CHECK (last_item_count >= 0),
  last_error text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS source_kind text NOT NULL DEFAULT 'configured';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS publisher_id text NOT NULL DEFAULT '';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS region_basis text NOT NULL DEFAULT 'editorial_scope_label';
ALTER TABLE local_source_registry ADD COLUMN IF NOT EXISTS query_conditioned boolean NOT NULL DEFAULT false;

-- Backfill immutable qualification metadata for pre-lineage rows from the
-- current projection once. `lineage_metadata_basis` is the migration marker:
-- rerunning this migration cannot rewrite a frozen row after the registry or
-- current projection changes. New captures write these fields at capture
-- time.
UPDATE local_source_item_version v
   SET source_name = i.source_name, language = i.language, region = i.region,
       publisher_name = i.publisher_name, publisher_url = i.publisher_url, publisher_id = i.publisher_id,
       publisher_identity_status = i.publisher_identity_status, source_kind = i.source_kind,
       query_conditioned = COALESCE(r.query_conditioned, false),
       lineage_metadata_basis = 'migration_current_projection'
  FROM local_source_item i
  LEFT JOIN local_source_registry r ON r.source_id = i.source_id
 WHERE v.item_key = i.item_key AND COALESCE(v.lineage_metadata_basis, '') = '';
ALTER TABLE local_source_item_version ALTER COLUMN lineage_metadata_basis SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_publisher_identity_status_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_publisher_identity_status_check CHECK (publisher_identity_status IN ('configured', 'observed_domain', 'unresolved'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_source_kind_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_source_kind_check CHECK (source_kind IN ('configured', 'discovery'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_source_item_version'::regclass AND conname = 'local_source_item_version_lineage_metadata_basis_check') THEN
    ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_lineage_metadata_basis_check CHECK (lineage_metadata_basis IN ('capture_time', 'migration_current_projection'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS local_radar_trend (
  trend_id text PRIMARY KEY,
  snapshot_id text NOT NULL REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE,
  topic_key text NOT NULL,
  topic text NOT NULL,
  topic_language text NOT NULL,
  topic_kind text NOT NULL DEFAULT 'term' CHECK (topic_kind IN ('term', 'phrase')),
  signal_state text NOT NULL CHECK (signal_state IN ('rising', 'new', 'watching')),
  summary text NOT NULL,
  mention_count integer NOT NULL CHECK (mention_count >= 0),
  recent_mention_count integer NOT NULL CHECK (recent_mention_count >= 0),
  prior_mention_count integer NOT NULL CHECK (prior_mention_count >= 0),
  source_count integer NOT NULL CHECK (source_count >= 0),
  region_count integer NOT NULL CHECK (region_count >= 0),
  language_count integer NOT NULL CHECK (language_count >= 0),
  growth_rate numeric,
  window_hours integer NOT NULL CHECK (window_hours > 0),
  recent_window_hours integer NOT NULL CHECK (recent_window_hours > 0),
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  source_names jsonb NOT NULL DEFAULT '[]'::jsonb,
  regions jsonb NOT NULL DEFAULT '[]'::jsonb,
  languages jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, sort_order)
);

ALTER TABLE local_radar_trend ADD COLUMN IF NOT EXISTS topic_kind text NOT NULL DEFAULT 'term';
ALTER TABLE local_radar_trend ADD COLUMN IF NOT EXISTS semantic_status text NOT NULL DEFAULT 'statistical_candidate';
ALTER TABLE local_radar_trend ADD COLUMN IF NOT EXISTS topic_label text NOT NULL DEFAULT '';
ALTER TABLE local_radar_trend ADD COLUMN IF NOT EXISTS topic_explanation text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS local_radar_trend_snapshot_order_idx
  ON local_radar_trend (snapshot_id, sort_order);

-- Event candidates are a snapshot-bound, deterministic text-similarity
-- pre-layer.  They are not event confirmations or trend records.
CREATE TABLE IF NOT EXISTS local_event_candidate (
  candidate_id text PRIMARY KEY,
  snapshot_id text NOT NULL REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE,
  candidate_key text NOT NULL,
  candidate_status text NOT NULL CONSTRAINT local_event_candidate_candidate_status_check CHECK (candidate_status = 'event_candidate'),
  label text NOT NULL,
  language text NOT NULL,
  matching_method text NOT NULL,
  explanation text NOT NULL,
  member_count integer NOT NULL CONSTRAINT local_event_candidate_member_count_check CHECK (member_count >= 0),
  dedup_source_count integer NOT NULL CONSTRAINT local_event_candidate_dedup_source_count_check CHECK (dedup_source_count >= 0),
  qualifying_source_count integer NOT NULL CONSTRAINT local_event_candidate_qualifying_source_count_check CHECK (qualifying_source_count >= 2),
  query_conditioned_evidence_count integer NOT NULL CONSTRAINT local_event_candidate_query_conditioned_evidence_count_check CHECK (query_conditioned_evidence_count >= 0),
  first_published_at timestamptz NOT NULL,
  last_published_at timestamptz NOT NULL,
  time_span_hours numeric NOT NULL CONSTRAINT local_event_candidate_time_span_check CHECK (time_span_hours >= 0),
  shared_anchors jsonb NOT NULL DEFAULT '[]'::jsonb,
  shared_phrases jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence_items jsonb NOT NULL DEFAULT '[]'::jsonb,
  member_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb,
  qualifying_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb,
  query_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb,
  sort_order integer NOT NULL CONSTRAINT local_event_candidate_sort_order_check CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT local_event_candidate_time_order_check CHECK (first_published_at <= last_published_at),
  CONSTRAINT local_event_candidate_json_arrays_check CHECK (jsonb_typeof(shared_anchors) = 'array' AND jsonb_typeof(shared_phrases) = 'array' AND jsonb_typeof(evidence_items) = 'array'),
  CONSTRAINT local_event_candidate_key_arrays_check CHECK (jsonb_typeof(member_item_keys) = 'array' AND jsonb_typeof(qualifying_item_keys) = 'array' AND jsonb_typeof(query_item_keys) = 'array'),
  CONSTRAINT local_event_candidate_member_cardinality_check CHECK (jsonb_array_length(member_item_keys) = member_count),
  CONSTRAINT local_event_candidate_qualifying_cardinality_check CHECK (jsonb_array_length(qualifying_item_keys) = qualifying_source_count),
  CONSTRAINT local_event_candidate_query_cardinality_check CHECK (jsonb_array_length(query_item_keys) = query_conditioned_evidence_count),
  CONSTRAINT local_event_candidate_evidence_cardinality_check CHECK (jsonb_array_length(evidence_items) = member_count),
  CONSTRAINT local_event_candidate_snapshot_candidate_key_key UNIQUE (snapshot_id, candidate_key),
  CONSTRAINT local_event_candidate_snapshot_sort_order_key UNIQUE (snapshot_id, sort_order)
);

ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS candidate_key text;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS candidate_status text NOT NULL DEFAULT 'event_candidate';
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS label text NOT NULL DEFAULT '';
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS language text NOT NULL DEFAULT '';
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS matching_method text NOT NULL DEFAULT 'deterministic_anchor_similarity_v1';
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS explanation text NOT NULL DEFAULT '';
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS member_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS dedup_source_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS qualifying_source_count integer NOT NULL DEFAULT 2;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS query_conditioned_evidence_count integer NOT NULL DEFAULT 0;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS first_published_at timestamptz;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS last_published_at timestamptz;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS time_span_hours numeric NOT NULL DEFAULT 0;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS shared_anchors jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS shared_phrases jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS evidence_items jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS member_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS qualifying_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS query_item_keys jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE local_event_candidate ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;

-- Existing staging tables may predate the CREATE TABLE contract. Refuse a
-- silent reinterpretation of nullable rows, then carry the same NOT NULL
-- guarantees onto the upgraded relation.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM local_event_candidate
     WHERE candidate_key IS NULL OR candidate_status IS NULL OR label IS NULL
        OR language IS NULL OR matching_method IS NULL OR explanation IS NULL
        OR member_count IS NULL OR dedup_source_count IS NULL
        OR qualifying_source_count IS NULL OR query_conditioned_evidence_count IS NULL
        OR first_published_at IS NULL OR last_published_at IS NULL
        OR time_span_hours IS NULL OR shared_anchors IS NULL OR shared_phrases IS NULL
        OR evidence_items IS NULL OR member_item_keys IS NULL
        OR qualifying_item_keys IS NULL OR query_item_keys IS NULL OR sort_order IS NULL
  ) THEN
    RAISE EXCEPTION 'local_event_candidate NULL required field; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_event_candidate
     WHERE btrim(candidate_key) = '' OR candidate_status <> 'event_candidate'
        OR btrim(label) = '' OR btrim(language) = '' OR btrim(matching_method) = ''
        OR member_count < 0 OR dedup_source_count < 0 OR qualifying_source_count < 2
        OR query_conditioned_evidence_count < 0 OR time_span_hours < 0 OR sort_order < 0
        OR first_published_at > last_published_at
  ) THEN
    RAISE EXCEPTION 'local_event_candidate invalid scalar field; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_event_candidate
     WHERE jsonb_typeof(shared_anchors) <> 'array'
        OR jsonb_typeof(shared_phrases) <> 'array'
        OR jsonb_typeof(evidence_items) <> 'array'
        OR jsonb_typeof(member_item_keys) <> 'array'
        OR jsonb_typeof(qualifying_item_keys) <> 'array'
        OR jsonb_typeof(query_item_keys) <> 'array'
  ) THEN
    RAISE EXCEPTION 'local_event_candidate invalid JSON shape; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_event_candidate
     WHERE jsonb_array_length(member_item_keys) <> member_count
        OR jsonb_array_length(qualifying_item_keys) <> qualifying_source_count
        OR jsonb_array_length(query_item_keys) <> query_conditioned_evidence_count
        OR jsonb_array_length(evidence_items) <> member_count
  ) THEN
    RAISE EXCEPTION 'local_event_candidate invalid JSON cardinality; refusing migration';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM local_event_candidate e
      LEFT JOIN local_radar_snapshot s ON s.snapshot_id = e.snapshot_id
     WHERE s.snapshot_id IS NULL
  ) THEN
    RAISE EXCEPTION 'local_event_candidate snapshot lineage missing; refusing migration';
  END IF;
END $$;

ALTER TABLE local_event_candidate
  ALTER COLUMN candidate_key SET NOT NULL,
  ALTER COLUMN candidate_status SET NOT NULL,
  ALTER COLUMN label SET NOT NULL,
  ALTER COLUMN language SET NOT NULL,
  ALTER COLUMN matching_method SET NOT NULL,
  ALTER COLUMN explanation SET NOT NULL,
  ALTER COLUMN member_count SET NOT NULL,
  ALTER COLUMN dedup_source_count SET NOT NULL,
  ALTER COLUMN qualifying_source_count SET NOT NULL,
  ALTER COLUMN query_conditioned_evidence_count SET NOT NULL,
  ALTER COLUMN first_published_at SET NOT NULL,
  ALTER COLUMN last_published_at SET NOT NULL,
  ALTER COLUMN time_span_hours SET NOT NULL,
  ALTER COLUMN shared_anchors SET NOT NULL,
  ALTER COLUMN shared_phrases SET NOT NULL,
  ALTER COLUMN evidence_items SET NOT NULL,
  ALTER COLUMN member_item_keys SET NOT NULL,
  ALTER COLUMN qualifying_item_keys SET NOT NULL,
  ALTER COLUMN query_item_keys SET NOT NULL,
  ALTER COLUMN sort_order SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_snapshot_id_fkey') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_snapshot_candidate_key_key') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_snapshot_candidate_key_key UNIQUE (snapshot_id, candidate_key);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_snapshot_sort_order_key') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_snapshot_sort_order_key UNIQUE (snapshot_id, sort_order);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_candidate_status_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_candidate_status_check CHECK (candidate_status = 'event_candidate');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_member_count_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_member_count_check CHECK (member_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_dedup_source_count_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_dedup_source_count_check CHECK (dedup_source_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_qualifying_source_count_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_qualifying_source_count_check CHECK (qualifying_source_count >= 2);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_query_conditioned_evidence_count_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_query_conditioned_evidence_count_check CHECK (query_conditioned_evidence_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_time_span_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_time_span_check CHECK (time_span_hours >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_sort_order_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_sort_order_check CHECK (sort_order >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_time_order_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_time_order_check CHECK (first_published_at <= last_published_at);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_key_arrays_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_key_arrays_check CHECK (jsonb_typeof(member_item_keys) = 'array' AND jsonb_typeof(qualifying_item_keys) = 'array' AND jsonb_typeof(query_item_keys) = 'array');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_json_arrays_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_json_arrays_check CHECK (jsonb_typeof(shared_anchors) = 'array' AND jsonb_typeof(shared_phrases) = 'array' AND jsonb_typeof(evidence_items) = 'array');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_member_cardinality_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_member_cardinality_check CHECK (jsonb_array_length(member_item_keys) = member_count);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_qualifying_cardinality_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_qualifying_cardinality_check CHECK (jsonb_array_length(qualifying_item_keys) = qualifying_source_count);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_query_cardinality_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_query_cardinality_check CHECK (jsonb_array_length(query_item_keys) = query_conditioned_evidence_count);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_event_candidate'::regclass AND conname = 'local_event_candidate_evidence_cardinality_check') THEN
    ALTER TABLE local_event_candidate ADD CONSTRAINT local_event_candidate_evidence_cardinality_check CHECK (jsonb_array_length(evidence_items) = member_count);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS local_event_candidate_snapshot_order_idx
  ON local_event_candidate (snapshot_id, sort_order);

CREATE TABLE IF NOT EXISTS local_translation_artifact (
  artifact_id text PRIMARY KEY,
  item_key text NOT NULL REFERENCES local_source_item(item_key) ON DELETE CASCADE,
  source_language text NOT NULL,
  target_language text NOT NULL,
  original_content_hash text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  translated_title text NOT NULL,
  translated_summary text NOT NULL,
  validation_status text NOT NULL CHECK (validation_status IN ('mechanical_pass', 'needs_review', 'failed')),
  status text NOT NULL CHECK (status IN ('translated', 'failed')),
  error_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_key, target_language, original_content_hash, provider, model)
);

CREATE INDEX IF NOT EXISTS local_translation_artifact_item_idx
  ON local_translation_artifact (item_key, target_language, created_at DESC);

COMMIT;
