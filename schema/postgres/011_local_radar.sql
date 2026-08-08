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
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, sort_order)
);

CREATE INDEX IF NOT EXISTS local_radar_card_snapshot_order_idx
  ON local_radar_card (snapshot_id, sort_order);

COMMIT;
