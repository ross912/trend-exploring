-- Local report ledger vertical slice.
--
-- This migration deliberately contains facts needed to schedule and publish
-- two daily raw-listing editions.  It does not create an AI summary, claim,
-- or UI projection.  The relations are append-only except for the explicit
-- scheduled -> published/failed state transitions on slots and attempts.
BEGIN;

-- Empty early-draft relations can be replaced safely.  A non-empty relation
-- with an incompatible shape is refused before any mutation so a migration
-- can never guess the meaning of retained rows.
DO $$
DECLARE
  relname text;
  rel regclass;
  row_count bigint;
  required_ok boolean;
  structural_ok boolean;
  marker_present boolean := false;
BEGIN
  IF to_regclass('local_report_ledger_schema_meta') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM local_report_ledger_schema_meta WHERE schema_version = ''013_local_report_ledger_v1'')' INTO marker_present;
  END IF;
  -- First inspect every existing relation while all regclass values are
  -- alive.  This avoids the stale-OID/cache failure caused by dropping a
  -- parent during the same FOREACH loop that still holds its child OID.
  FOREACH relname IN ARRAY ARRAY[
    'local_report_schedule_slot', 'local_report_publication_attempt',
    'local_reportable_arrival', 'local_report_edition',
    'local_report_item_placement'
  ] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF row_count > 0 AND NOT marker_present THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; schema marker is absent', relname;
    END IF;
    IF relname = 'local_report_schedule_slot' THEN
      SELECT COUNT(*) = 12 INTO required_ok FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['slot_id','kind','timezone','window_start','window_end','scheduled_at','configured_data_cutoff','config_hash','state','failure_reason','created_at','updated_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_kind_scheduled_at_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_kind_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_timezone_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_positive_window_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_configured_cutoff_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_state_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_window_end_scheduled_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_schedule_slot_failure_reason_check')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_schedule_slot_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_slot_commit_constraint_trigger') INTO structural_ok;
    ELSIF relname = 'local_report_publication_attempt' THEN
      SELECT COUNT(*) = 10 INTO required_ok FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['attempt_id','slot_id','idempotency_key','payload_hash','state','started_at','finished_at','failure_reason','created_at','updated_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_publication_attempt_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_publication_attempt_idempotency_key_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_publication_attempt_slot_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_publication_attempt_state_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_publication_attempt_terminal_check')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_publication_attempt_guard_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_attempt_commit_constraint_trigger') INTO structural_ok;
    ELSIF relname = 'local_reportable_arrival' THEN
      SELECT COUNT(*) = 10 INTO required_ok FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['arrival_id','version_id','item_key','capture_id','content_hash','information_arrival_at','nominal_slot_id','arrival_kind','created_at','updated_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_reportable_arrival_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_reportable_arrival_version_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_reportable_arrival_version_id_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_reportable_arrival_slot_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_reportable_arrival_kind_check')
         AND EXISTS (SELECT 1 FROM pg_class c WHERE c.relname = 'local_reportable_arrival_first_seen_item_key' AND c.relkind = 'i')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_reportable_arrival_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_reportable_arrival_lineage_trigger') INTO structural_ok;
    ELSIF relname = 'local_report_edition' THEN
      SELECT COUNT(*) = 18 INTO required_ok FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['edition_id','slot_id','attempt_id','nominal_window_start','nominal_window_end','configured_data_cutoff','processing_frontier','selection_completeness_frontier','data_cutoff','comparison_watermark','publication_committed_at','edition_status','reason_codes','summary_status','payload_hash','item_count','created_at','updated_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_slot_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_attempt_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_slot_id_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_attempt_id_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_positive_window_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_configured_cutoff_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_data_cutoff_window_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_data_cutoff_min_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_comparison_watermark_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_lag_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_item_count_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_status_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_summary_status_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_reason_codes_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_edition_status_reason_check')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_edition_immutable_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_edition_commit_constraint_trigger') INTO structural_ok;
    ELSE
      SELECT COUNT(*) = 8 INTO required_ok FROM pg_attribute
       WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
         AND attname = ANY (ARRAY['placement_id','edition_id','arrival_id','nominal_slot_id','sort_order','placement_kind','reason_codes','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_pkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_arrival_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_edition_id_sort_order_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_edition_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_arrival_id_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_slot_fkey')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_edition_id_arrival_id_key')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_sort_order_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_kind_check')
         AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'local_report_item_placement_reason_codes_check')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_item_placement_contract_trigger')
         AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = rel AND tgname = 'local_report_item_placement_immutable_trigger') INTO structural_ok;
    END IF;
    IF (marker_present AND (NOT required_ok OR NOT structural_ok)) OR (row_count > 0 AND NOT marker_present) THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; refusing migration', relname;
    END IF;
  END LOOP;

  -- Empty incomplete drafts are safe to replace.  Drop children first and
  -- without CASCADE so a complete non-empty parent can never be erased.
  FOREACH relname IN ARRAY ARRAY[
    'local_report_item_placement', 'local_report_edition',
    'local_reportable_arrival', 'local_report_publication_attempt',
    'local_report_schedule_slot'
  ] LOOP
    rel := to_regclass(relname);
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF row_count = 0 AND NOT marker_present THEN
      -- With no exact schema marker, every empty report relation is an early
      -- draft (even if it happens to have a primary key).  Rebuild it in
      -- dependency order; no retained rows can be lost.
      EXECUTE format('DROP TABLE %I', relname);
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS local_report_schedule_slot (
  slot_id text PRIMARY KEY,
  kind text NOT NULL CONSTRAINT local_report_schedule_slot_kind_check CHECK (kind IN ('morning', 'evening')),
  timezone text NOT NULL CONSTRAINT local_report_schedule_slot_timezone_check CHECK (timezone = 'Asia/Shanghai'),
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  scheduled_at timestamptz NOT NULL,
  configured_data_cutoff timestamptz NOT NULL,
  config_hash text NOT NULL,
  state text NOT NULL CONSTRAINT local_report_schedule_slot_state_check CHECK (state IN ('scheduled', 'published', 'failed')),
  failure_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, scheduled_at),
  CONSTRAINT local_report_schedule_slot_positive_window_check CHECK (window_start < window_end),
  CONSTRAINT local_report_schedule_slot_window_end_scheduled_check CHECK (window_end = scheduled_at),
  CONSTRAINT local_report_schedule_slot_configured_cutoff_check CHECK (configured_data_cutoff <= scheduled_at),
  CONSTRAINT local_report_schedule_slot_failure_reason_check CHECK ((state = 'failed' AND btrim(failure_reason) <> '') OR (state <> 'failed' AND btrim(failure_reason) = ''))
);

CREATE TABLE IF NOT EXISTS local_report_publication_attempt (
  attempt_id text PRIMARY KEY,
  slot_id text NOT NULL CONSTRAINT local_report_publication_attempt_slot_fkey REFERENCES local_report_schedule_slot(slot_id),
  idempotency_key text NOT NULL UNIQUE,
  payload_hash text NOT NULL,
  state text NOT NULL CONSTRAINT local_report_publication_attempt_state_check CHECK (state IN ('running', 'published', 'failed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  failure_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT local_report_publication_attempt_terminal_check CHECK (
    (state = 'running' AND finished_at IS NULL AND btrim(failure_reason) = '')
    OR (state = 'published' AND finished_at IS NOT NULL AND btrim(failure_reason) = '')
    OR (state = 'failed' AND finished_at IS NOT NULL AND btrim(failure_reason) <> '')
  )
);

CREATE TABLE IF NOT EXISTS local_reportable_arrival (
  arrival_id text PRIMARY KEY,
  version_id text NOT NULL CONSTRAINT local_reportable_arrival_version_fkey UNIQUE REFERENCES local_source_item_version(version_id),
  item_key text NOT NULL,
  capture_id text NOT NULL,
  content_hash text NOT NULL,
  information_arrival_at timestamptz NOT NULL,
  nominal_slot_id text NOT NULL CONSTRAINT local_reportable_arrival_slot_fkey REFERENCES local_report_schedule_slot(slot_id),
  arrival_kind text NOT NULL CONSTRAINT local_reportable_arrival_kind_check CHECK (arrival_kind IN ('first_seen', 'content_update')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS local_reportable_arrival_frontier_idx
  ON local_reportable_arrival (information_arrival_at, arrival_id);
CREATE INDEX IF NOT EXISTS local_reportable_arrival_item_idx
  ON local_reportable_arrival (item_key, information_arrival_at DESC, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS local_reportable_arrival_first_seen_item_key
  ON local_reportable_arrival (item_key) WHERE arrival_kind = 'first_seen';

CREATE TABLE IF NOT EXISTS local_report_edition (
  edition_id text PRIMARY KEY,
  slot_id text NOT NULL CONSTRAINT local_report_edition_slot_fkey UNIQUE REFERENCES local_report_schedule_slot(slot_id),
  attempt_id text NOT NULL CONSTRAINT local_report_edition_attempt_fkey UNIQUE REFERENCES local_report_publication_attempt(attempt_id),
  nominal_window_start timestamptz NOT NULL,
  nominal_window_end timestamptz NOT NULL,
  configured_data_cutoff timestamptz NOT NULL,
  processing_frontier timestamptz NOT NULL,
  selection_completeness_frontier timestamptz NOT NULL,
  data_cutoff timestamptz NOT NULL,
  comparison_watermark timestamptz NOT NULL,
  publication_committed_at timestamptz NOT NULL DEFAULT now(),
  edition_status text NOT NULL CONSTRAINT local_report_edition_status_check CHECK (edition_status IN ('normal', 'degraded')),
  reason_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  summary_status text NOT NULL DEFAULT 'not_generated' CONSTRAINT local_report_edition_summary_status_check CHECK (summary_status = 'not_generated'),
  payload_hash text NOT NULL,
  item_count integer NOT NULL DEFAULT 0 CHECK (item_count >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT local_report_edition_positive_window_check CHECK (nominal_window_start < nominal_window_end),
  CONSTRAINT local_report_edition_configured_cutoff_check CHECK (configured_data_cutoff <= nominal_window_end),
  CONSTRAINT local_report_edition_data_cutoff_window_check CHECK (data_cutoff <= nominal_window_end),
  CONSTRAINT local_report_edition_data_cutoff_min_check CHECK (data_cutoff = LEAST(configured_data_cutoff, processing_frontier, selection_completeness_frontier)),
  CONSTRAINT local_report_edition_comparison_watermark_check CHECK (comparison_watermark <= data_cutoff),
  CONSTRAINT local_report_edition_lag_check CHECK (nominal_window_end - data_cutoff <= interval '60 minutes'),
  CONSTRAINT local_report_edition_reason_codes_check CHECK (jsonb_typeof(reason_codes) = 'array'),
  CONSTRAINT local_report_edition_status_reason_check CHECK (
    (edition_status = 'normal' AND jsonb_array_length(reason_codes) = 0)
    OR (edition_status = 'degraded' AND jsonb_array_length(reason_codes) > 0
        AND reason_codes <@ '["DEGRADED_COVERAGE", "DEGRADED_PROCESSING"]'::jsonb)
  )
);

CREATE TABLE IF NOT EXISTS local_report_item_placement (
  placement_id text PRIMARY KEY,
  edition_id text NOT NULL CONSTRAINT local_report_item_placement_edition_fkey REFERENCES local_report_edition(edition_id) ON DELETE CASCADE,
  arrival_id text NOT NULL CONSTRAINT local_report_item_placement_arrival_fkey UNIQUE REFERENCES local_reportable_arrival(arrival_id),
  nominal_slot_id text NOT NULL CONSTRAINT local_report_item_placement_slot_fkey REFERENCES local_report_schedule_slot(slot_id),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  placement_kind text NOT NULL CONSTRAINT local_report_item_placement_kind_check CHECK (placement_kind IN ('normal', 'PROCESSING_BACKFILL')),
  reason_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (edition_id, sort_order),
  UNIQUE (edition_id, arrival_id),
  CONSTRAINT local_report_item_placement_reason_codes_check CHECK (jsonb_typeof(reason_codes) = 'array')
);

CREATE OR REPLACE FUNCTION local_report_schedule_slot_immutable_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.slot_id <> OLD.slot_id OR NEW.kind <> OLD.kind OR NEW.timezone <> OLD.timezone
     OR NEW.window_start <> OLD.window_start OR NEW.window_end <> OLD.window_end
     OR NEW.scheduled_at <> OLD.scheduled_at OR NEW.configured_data_cutoff <> OLD.configured_data_cutoff
     OR NEW.config_hash <> OLD.config_hash THEN
    RAISE EXCEPTION 'local_report_schedule_slot identity/window/config is immutable';
  END IF;
  IF OLD.state = 'published' AND NEW.state <> OLD.state THEN
    RAISE EXCEPTION 'published report slot is immutable';
  END IF;
  IF OLD.state = 'failed' AND NEW.state <> OLD.state THEN
    RAISE EXCEPTION 'failed report slot is immutable';
  END IF;
  IF OLD.state = 'scheduled' AND NEW.state NOT IN ('scheduled', 'published', 'failed') THEN
    RAISE EXCEPTION 'invalid report slot state transition';
  END IF;
  IF OLD.state = 'scheduled' AND NEW.state = 'failed' AND btrim(NEW.failure_reason) = '' THEN
    RAISE EXCEPTION 'failed report slot requires a reason';
  END IF;
  IF OLD.state = 'scheduled' AND NEW.state <> 'failed' AND btrim(NEW.failure_reason) <> '' THEN
    RAISE EXCEPTION 'non-failed report slot cannot carry a failure reason';
  END IF;
  IF OLD.state = 'failed' AND NEW.failure_reason <> OLD.failure_reason THEN
    RAISE EXCEPTION 'failed report slot reason is immutable';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION local_report_publication_attempt_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.attempt_id <> OLD.attempt_id OR NEW.slot_id <> OLD.slot_id
     OR NEW.idempotency_key <> OLD.idempotency_key OR NEW.payload_hash <> OLD.payload_hash
     OR NEW.started_at <> OLD.started_at OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'local_report_publication_attempt identity is immutable';
  END IF;
  IF OLD.state = 'published' AND NEW.state <> OLD.state THEN
    RAISE EXCEPTION 'published report attempt is immutable';
  END IF;
  IF OLD.state = 'failed' AND NEW.state <> OLD.state THEN
    RAISE EXCEPTION 'failed report attempt is immutable';
  END IF;
  IF OLD.state IN ('published', 'failed')
     AND (NEW.finished_at IS DISTINCT FROM OLD.finished_at OR NEW.failure_reason <> OLD.failure_reason) THEN
    RAISE EXCEPTION 'terminal report attempt fields are immutable';
  END IF;
  IF OLD.state = 'running' AND NEW.state NOT IN ('running', 'published', 'failed') THEN
    RAISE EXCEPTION 'invalid report attempt state transition';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION local_reportable_arrival_lineage_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  expected_item_key text;
  expected_capture_id text;
  expected_content_hash text;
  expected_created_at timestamptz;
  slot_start timestamptz;
  slot_end timestamptz;
BEGIN
  SELECT item_key, capture_id, content_hash, created_at
    INTO expected_item_key, expected_capture_id, expected_content_hash, expected_created_at
    FROM local_source_item_version
   WHERE version_id = NEW.version_id;
  IF NOT FOUND OR NEW.item_key <> expected_item_key OR NEW.capture_id <> expected_capture_id
     OR NEW.content_hash <> expected_content_hash OR NEW.information_arrival_at <> expected_created_at THEN
    RAISE EXCEPTION 'local_reportable_arrival lineage differs from immutable source version';
  END IF;
  SELECT window_start, window_end INTO slot_start, slot_end
    FROM local_report_schedule_slot WHERE slot_id = NEW.nominal_slot_id;
  IF NOT FOUND OR NEW.information_arrival_at < slot_start OR NEW.information_arrival_at >= slot_end THEN
    RAISE EXCEPTION 'local_reportable_arrival nominal slot does not contain information_arrival_at';
  END IF;
  IF NEW.arrival_kind = 'first_seen' AND EXISTS (
       SELECT 1 FROM local_reportable_arrival WHERE item_key = NEW.item_key
     ) THEN
    RAISE EXCEPTION 'first_seen arrival already exists for item';
  END IF;
  IF NEW.arrival_kind = 'content_update' AND NOT EXISTS (
       SELECT 1 FROM local_reportable_arrival WHERE item_key = NEW.item_key
     ) THEN
    RAISE EXCEPTION 'content_update arrival requires a prior controlled arrival';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION local_report_immutable_row_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;

CREATE OR REPLACE FUNCTION local_report_attempt_commit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.state = 'published' AND (SELECT COUNT(*) FROM local_report_edition WHERE attempt_id = NEW.attempt_id) <> 1 THEN
    RAISE EXCEPTION 'published report attempt must bind exactly one edition';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION local_report_edition_commit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  attempt_state text;
  slot_state text;
  placement_count integer;
  expected_order integer;
BEGIN
  SELECT state INTO attempt_state FROM local_report_publication_attempt WHERE attempt_id = NEW.attempt_id;
  SELECT state INTO slot_state FROM local_report_schedule_slot WHERE slot_id = NEW.slot_id;
  IF attempt_state <> 'published' OR slot_state <> 'published' THEN
    RAISE EXCEPTION 'report edition must bind published attempt and published slot';
  END IF;
  IF (SELECT slot_id FROM local_report_publication_attempt WHERE attempt_id = NEW.attempt_id) <> NEW.slot_id
     OR NEW.nominal_window_start <> (SELECT window_start FROM local_report_schedule_slot WHERE slot_id = NEW.slot_id)
     OR NEW.nominal_window_end <> (SELECT window_end FROM local_report_schedule_slot WHERE slot_id = NEW.slot_id)
     OR NEW.configured_data_cutoff <> (SELECT configured_data_cutoff FROM local_report_schedule_slot WHERE slot_id = NEW.slot_id) THEN
    RAISE EXCEPTION 'report edition owner/window differs from frozen slot contract';
  END IF;
  SELECT COUNT(*), COALESCE(MIN(sort_order), 0) INTO placement_count, expected_order
    FROM local_report_item_placement WHERE edition_id = NEW.edition_id;
  IF placement_count <> NEW.item_count OR expected_order <> 0
     OR EXISTS (SELECT 1 FROM local_report_item_placement WHERE edition_id = NEW.edition_id AND sort_order <> (SELECT COUNT(*) FROM local_report_item_placement p2 WHERE p2.edition_id = NEW.edition_id AND p2.sort_order < local_report_item_placement.sort_order)) THEN
    RAISE EXCEPTION 'report edition placements are incomplete or non-contiguous';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION local_report_placement_contract_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  edition_slot text;
  arrival_slot text;
BEGIN
  SELECT slot_id INTO edition_slot FROM local_report_edition WHERE edition_id = NEW.edition_id;
  SELECT nominal_slot_id INTO arrival_slot FROM local_reportable_arrival WHERE arrival_id = NEW.arrival_id;
  IF edition_slot IS NULL OR arrival_slot IS NULL OR NEW.nominal_slot_id <> arrival_slot THEN
    RAISE EXCEPTION 'report placement nominal slot lineage differs';
  END IF;
  IF edition_slot = arrival_slot THEN
    IF NEW.placement_kind <> 'normal' OR NEW.reason_codes <> '[]'::jsonb THEN
      RAISE EXCEPTION 'same-slot placement must be normal with no reason code';
    END IF;
  ELSIF NEW.placement_kind <> 'PROCESSING_BACKFILL' OR NOT (NEW.reason_codes ? 'PROCESSING_BACKFILL')
        OR NOT (NEW.reason_codes <@ '["PROCESSING_BACKFILL"]'::jsonb) THEN
    RAISE EXCEPTION 'cross-slot placement must be PROCESSING_BACKFILL';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION local_report_slot_commit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  edition_count integer;
BEGIN
  SELECT COUNT(*) INTO edition_count FROM local_report_edition WHERE slot_id = NEW.slot_id;
  IF NEW.state = 'published' AND edition_count <> 1 THEN
    RAISE EXCEPTION 'published report slot must bind exactly one edition';
  END IF;
  IF NEW.state IN ('scheduled', 'failed') AND edition_count <> 0 THEN
    RAISE EXCEPTION 'scheduled/failed report slot cannot bind an edition';
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS local_report_schedule_slot_immutable_trigger ON local_report_schedule_slot;
CREATE TRIGGER local_report_schedule_slot_immutable_trigger BEFORE UPDATE ON local_report_schedule_slot
FOR EACH ROW EXECUTE FUNCTION local_report_schedule_slot_immutable_guard();
DROP TRIGGER IF EXISTS local_report_publication_attempt_guard_trigger ON local_report_publication_attempt;
CREATE TRIGGER local_report_publication_attempt_guard_trigger BEFORE UPDATE ON local_report_publication_attempt
FOR EACH ROW EXECUTE FUNCTION local_report_publication_attempt_guard();
DROP TRIGGER IF EXISTS local_reportable_arrival_immutable_trigger ON local_reportable_arrival;
CREATE TRIGGER local_reportable_arrival_immutable_trigger BEFORE UPDATE OR DELETE ON local_reportable_arrival
FOR EACH ROW EXECUTE FUNCTION local_report_immutable_row_guard();
DROP TRIGGER IF EXISTS local_reportable_arrival_lineage_trigger ON local_reportable_arrival;
CREATE TRIGGER local_reportable_arrival_lineage_trigger BEFORE INSERT ON local_reportable_arrival
FOR EACH ROW EXECUTE FUNCTION local_reportable_arrival_lineage_guard();
DROP TRIGGER IF EXISTS local_report_item_placement_contract_trigger ON local_report_item_placement;
CREATE TRIGGER local_report_item_placement_contract_trigger BEFORE INSERT ON local_report_item_placement
FOR EACH ROW EXECUTE FUNCTION local_report_placement_contract_guard();
DROP TRIGGER IF EXISTS local_report_edition_immutable_trigger ON local_report_edition;
CREATE TRIGGER local_report_edition_immutable_trigger BEFORE UPDATE OR DELETE ON local_report_edition
FOR EACH ROW EXECUTE FUNCTION local_report_immutable_row_guard();
DROP TRIGGER IF EXISTS local_report_item_placement_immutable_trigger ON local_report_item_placement;
CREATE TRIGGER local_report_item_placement_immutable_trigger BEFORE UPDATE OR DELETE ON local_report_item_placement
FOR EACH ROW EXECUTE FUNCTION local_report_immutable_row_guard();
DROP TRIGGER IF EXISTS local_report_attempt_commit_constraint_trigger ON local_report_publication_attempt;
CREATE CONSTRAINT TRIGGER local_report_attempt_commit_constraint_trigger
  AFTER INSERT OR UPDATE OF state ON local_report_publication_attempt
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_report_attempt_commit_guard();
DROP TRIGGER IF EXISTS local_report_edition_commit_constraint_trigger ON local_report_edition;
CREATE CONSTRAINT TRIGGER local_report_edition_commit_constraint_trigger
  AFTER INSERT ON local_report_edition
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_report_edition_commit_guard();
DROP TRIGGER IF EXISTS local_report_slot_commit_constraint_trigger ON local_report_schedule_slot;
CREATE CONSTRAINT TRIGGER local_report_slot_commit_constraint_trigger
  AFTER INSERT OR UPDATE OF state ON local_report_schedule_slot
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION local_report_slot_commit_guard();

CREATE TABLE IF NOT EXISTS local_report_ledger_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_report_ledger_schema_meta (schema_version)
VALUES ('013_local_report_ledger_v1')
ON CONFLICT (schema_version) DO NOTHING;

COMMIT;
