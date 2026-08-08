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
  snapshot_id text NOT NULL REFERENCES local_radar_snapshot(snapshot_id) ON DELETE CASCADE,
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

CREATE TABLE IF NOT EXISTS local_source_item (
  item_key text PRIMARY KEY,
  source_id text NOT NULL,
  source_name text NOT NULL,
  language text NOT NULL,
  region text NOT NULL DEFAULT '未标注',
  title text NOT NULL,
  summary text NOT NULL,
  source_url text NOT NULL,
  published_at timestamptz,
  fetched_at timestamptz NOT NULL,
  content_hash text NOT NULL,
  UNIQUE (source_id, source_url)
);

ALTER TABLE local_source_item ADD COLUMN IF NOT EXISTS region text NOT NULL DEFAULT '未标注';

CREATE INDEX IF NOT EXISTS local_source_item_published_idx
  ON local_source_item (published_at DESC NULLS LAST, fetched_at DESC);

CREATE TABLE IF NOT EXISTS local_source_registry (
  source_id text PRIMARY KEY,
  source_name text NOT NULL,
  source_url text NOT NULL,
  language text NOT NULL,
  region text NOT NULL,
  publisher_region text NOT NULL DEFAULT '',
  enabled boolean NOT NULL DEFAULT true,
  last_fetch_at timestamptz,
  last_item_count integer NOT NULL DEFAULT 0 CHECK (last_item_count >= 0),
  last_error text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

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

CREATE INDEX IF NOT EXISTS local_radar_trend_snapshot_order_idx
  ON local_radar_trend (snapshot_id, sort_order);

COMMIT;
