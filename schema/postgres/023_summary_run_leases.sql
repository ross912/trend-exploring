-- Summary-run leases, heartbeats, and crash recovery.
--
-- 014/021/022 keep the summary projection append-oriented, but a process
-- crash between a provider response and artifact commit used to leave a
-- run in `running` forever.  This migration adds an owner-bound lease and
-- heartbeat without rewriting receipts or artifacts.  Recovery changes only
-- an expired running row to `interrupted`; a receipt is never an artifact.
BEGIN;

DO $$
DECLARE
  run_rel regclass := to_regclass('local_report_summary_run');
  marker_present boolean := false;
  missing text[];
BEGIN
  IF run_rel IS NULL THEN
    RAISE EXCEPTION '023_summary_run_leases requires local_report_summary_run';
  END IF;
  IF to_regclass('report_summary_repair_schema_meta') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM report_summary_repair_schema_meta
       WHERE schema_version = '022_report_summary_repair_v1'
    ) INTO marker_present;
  END IF;
  -- A 023 install over the complete 014 schema is technically safe, but
  -- bootstrap should normally apply 021/022 first.  Require the marker when
  -- that table exists so a partial 022 upgrade cannot be hidden.
  IF to_regclass('report_summary_repair_schema_meta') IS NOT NULL AND NOT marker_present THEN
    RAISE EXCEPTION '023_summary_run_leases requires 022_report_summary_repair_v1 marker';
  END IF;
  SELECT array_agg(required_name ORDER BY required_name) INTO missing
    FROM unnest(ARRAY['run_id','edition_id','idempotency_key','input_hash','provider','model','prompt_version','retry_policy_version','state']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = run_rel AND attnum > 0 AND NOT attisdropped AND attname = required_name
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in local_report_summary_run; missing columns: %', array_to_string(missing, ', ');
  END IF;
END $$;

ALTER TABLE local_report_summary_run
  ADD COLUMN IF NOT EXISTS lease_owner text,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS heartbeat_at timestamptz;

-- Existing rows are immutable with respect to their identity and receipts,
-- but the additive lease fields can be initialized in place.  Running rows
-- inherit their original start time so the first scheduled cycle can recover
-- an old crash immediately after this migration.
UPDATE local_report_summary_run
   SET lease_owner = COALESCE(NULLIF(btrim(lease_owner), ''), 'legacy-summary-owner'),
       heartbeat_at = COALESCE(heartbeat_at, started_at),
       lease_expires_at = COALESCE(lease_expires_at, started_at + interval '10 minutes')
 WHERE lease_owner IS NULL OR btrim(lease_owner) = '' OR heartbeat_at IS NULL OR lease_expires_at IS NULL;

ALTER TABLE local_report_summary_run
  ALTER COLUMN lease_owner SET DEFAULT 'legacy-summary-owner',
  ALTER COLUMN lease_owner SET NOT NULL,
  ALTER COLUMN lease_expires_at SET DEFAULT (now() + interval '10 minutes'),
  ALTER COLUMN lease_expires_at SET NOT NULL,
  ALTER COLUMN heartbeat_at SET DEFAULT now(),
  ALTER COLUMN heartbeat_at SET NOT NULL;

-- 014's terminal-state check predates interrupted recovery.  Replace it
-- without touching any row values.
ALTER TABLE local_report_summary_run DROP CONSTRAINT IF EXISTS local_report_summary_run_state_check;
ALTER TABLE local_report_summary_run
  ADD CONSTRAINT local_report_summary_run_state_check CHECK (state IN ('running', 'succeeded', 'failed', 'blocked', 'interrupted'));
ALTER TABLE local_report_summary_run DROP CONSTRAINT IF EXISTS local_report_summary_run_terminal_check;
ALTER TABLE local_report_summary_run
  ADD CONSTRAINT local_report_summary_run_terminal_check CHECK (
    (state = 'running' AND finished_at IS NULL AND btrim(error_reason) = '')
    OR (state = 'succeeded' AND finished_at IS NOT NULL AND btrim(error_reason) = '')
    OR (state IN ('failed', 'blocked', 'interrupted') AND finished_at IS NOT NULL AND btrim(error_reason) <> '')
  );

-- Keep lease ownership immutable.  Heartbeats may advance timestamps while a
-- run is running; a terminal transition may retain the owner/timestamps for
-- audit, but cannot rewrite identity or lease owner.
CREATE OR REPLACE FUNCTION local_report_summary_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.run_id <> OLD.run_id OR NEW.edition_id <> OLD.edition_id
     OR NEW.idempotency_key <> OLD.idempotency_key OR NEW.input_hash <> OLD.input_hash
     OR NEW.provider <> OLD.provider OR NEW.model <> OLD.model
     OR NEW.prompt_version <> OLD.prompt_version OR NEW.retry_policy_version <> OLD.retry_policy_version
     OR NEW.started_at <> OLD.started_at OR NEW.created_at <> OLD.created_at
     OR NEW.lease_owner <> OLD.lease_owner THEN
    RAISE EXCEPTION 'local report summary run identity/input/lease owner is immutable';
  END IF;
  IF OLD.state <> 'running' THEN
    IF NEW.state <> OLD.state OR NEW.finished_at <> OLD.finished_at OR NEW.error_reason <> OLD.error_reason
       OR NEW.lease_expires_at <> OLD.lease_expires_at OR NEW.heartbeat_at <> OLD.heartbeat_at THEN
      RAISE EXCEPTION 'terminal local report summary run is immutable';
    END IF;
  ELSE
    IF NEW.state NOT IN ('running', 'succeeded', 'failed', 'blocked', 'interrupted') THEN
      RAISE EXCEPTION 'invalid local report summary run state transition';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE INDEX IF NOT EXISTS local_report_summary_run_recovery_idx
  ON local_report_summary_run (state, lease_expires_at, heartbeat_at);

CREATE TABLE IF NOT EXISTS report_summary_lease_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO report_summary_lease_schema_meta(schema_version)
VALUES ('023_summary_run_leases_v1') ON CONFLICT DO NOTHING;

COMMIT;
