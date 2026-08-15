-- Metadata-only translation worker leases, crash reconciliation and audit.
--
-- This migration is additive.  It never widens the rights boundary: rows in
-- local_metadata_translation_run contain only immutable source title/summary
-- inputs, while full text remains owned by the article archive pipeline.
BEGIN;

DO $$
BEGIN
  IF to_regclass('local_metadata_translation_run') IS NULL THEN
    RAISE EXCEPTION '024_metadata_translation_leases requires 016_local_fulltext_translation';
  END IF;
  IF to_regclass('local_translation_artifact') IS NULL THEN
    RAISE EXCEPTION '024_metadata_translation_leases requires local_translation_artifact';
  END IF;
END $$;

ALTER TABLE local_metadata_translation_run
  ADD COLUMN IF NOT EXISTS lease_owner text,
  ADD COLUMN IF NOT EXISTS heartbeat_at timestamptz,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz;

-- Existing running rows are retained as owned leases.  A migration cannot
-- safely claim them; initialize the lease from their original start time so
-- only already-expired work is recoverable on the next worker cycle.
UPDATE local_metadata_translation_run
   SET lease_owner = COALESCE(NULLIF(btrim(lease_owner), ''), 'legacy-metadata-owner'),
       heartbeat_at = COALESCE(heartbeat_at, started_at, created_at, now()),
       lease_expires_at = COALESCE(lease_expires_at, COALESCE(started_at, created_at, now()) + interval '15 minutes')
 WHERE lease_owner IS NULL OR btrim(lease_owner) = '' OR heartbeat_at IS NULL OR lease_expires_at IS NULL;

ALTER TABLE local_metadata_translation_run
  ALTER COLUMN lease_owner SET DEFAULT 'legacy-metadata-owner',
  ALTER COLUMN lease_owner SET NOT NULL,
  ALTER COLUMN heartbeat_at SET DEFAULT now(),
  ALTER COLUMN heartbeat_at SET NOT NULL,
  ALTER COLUMN lease_expires_at SET DEFAULT (now() + interval '15 minutes'),
  ALTER COLUMN lease_expires_at SET NOT NULL;

ALTER TABLE local_metadata_translation_run DROP CONSTRAINT IF EXISTS local_metadata_translation_run_state_check;
ALTER TABLE local_metadata_translation_run
  ADD CONSTRAINT local_metadata_translation_run_state_check
  CHECK (state IN ('pending','running','succeeded','failed','budget_blocked','credential_blocked','interrupted'));

-- The old check required every non-running row to have finished_at.  A
-- requeued interrupted row is deliberately terminal in the audit trail and
-- remains eligible for a later owner to claim.
ALTER TABLE local_metadata_translation_run DROP CONSTRAINT IF EXISTS local_metadata_translation_run_terminal_check;
ALTER TABLE local_metadata_translation_run
  ADD CONSTRAINT local_metadata_translation_run_terminal_check CHECK (
    (state IN ('pending','running') AND finished_at IS NULL)
    OR (state IN ('succeeded','failed','budget_blocked','credential_blocked','interrupted') AND finished_at IS NOT NULL)
  );

CREATE INDEX IF NOT EXISTS local_metadata_translation_run_lease_idx
  ON local_metadata_translation_run (state, lease_expires_at, heartbeat_at, run_id);

-- A batch is the single-flight unit shared by the browser, launchd and
-- ingestion.  The partial unique index is the database-side race barrier.
CREATE TABLE IF NOT EXISTS local_translation_batch_job (
  job_id text PRIMARY KEY,
  singleton_key text NOT NULL DEFAULT 'metadata',
  owner_id text NOT NULL,
  state text NOT NULL CHECK (state IN ('running','succeeded','failed','blocked','interrupted')),
  requested_limit integer NOT NULL CHECK (requested_limit BETWEEN 1 AND 100),
  daily_character_limit integer NOT NULL CHECK (daily_character_limit BETWEEN 1 AND 200000),
  queued_count integer NOT NULL DEFAULT 0 CHECK (queued_count >= 0),
  examined_count integer NOT NULL DEFAULT 0 CHECK (examined_count >= 0),
  translated_count integer NOT NULL DEFAULT 0 CHECK (translated_count >= 0),
  failed_count integer NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
  blocked_count integer NOT NULL DEFAULT 0 CHECK (blocked_count >= 0),
  input_chars integer NOT NULL DEFAULT 0 CHECK (input_chars >= 0),
  error_reason text NOT NULL DEFAULT '',
  started_at timestamptz NOT NULL DEFAULT now(),
  heartbeat_at timestamptz NOT NULL DEFAULT now(),
  lease_expires_at timestamptz NOT NULL DEFAULT (now() + interval '15 minutes'),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((state = 'running' AND finished_at IS NULL) OR (state <> 'running' AND finished_at IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS local_translation_batch_job_singleflight_idx
  ON local_translation_batch_job(singleton_key) WHERE state = 'running';
CREATE INDEX IF NOT EXISTS local_translation_batch_job_recent_idx
  ON local_translation_batch_job(created_at DESC, job_id DESC);

-- Per-item audit is intentionally separate from the mutable queue row.  It
-- records each claim/recovery/terminal transition without storing provider
-- secrets or prompt bodies.
CREATE TABLE IF NOT EXISTS local_translation_batch_attempt (
  attempt_id text PRIMARY KEY,
  job_id text REFERENCES local_translation_batch_job(job_id),
  run_id text REFERENCES local_metadata_translation_run(run_id),
  owner_id text NOT NULL,
  event text NOT NULL CHECK (event IN ('claimed','heartbeat','succeeded','failed','blocked','interrupted','reconciled')),
  error_reason text NOT NULL DEFAULT '',
  input_chars integer NOT NULL DEFAULT 0 CHECK (input_chars >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS local_translation_batch_attempt_job_idx
  ON local_translation_batch_attempt(job_id, created_at, attempt_id);

CREATE TABLE IF NOT EXISTS local_translation_lease_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_translation_lease_schema_meta(schema_version)
VALUES ('024_metadata_translation_leases_v1') ON CONFLICT DO NOTHING;

COMMIT;
