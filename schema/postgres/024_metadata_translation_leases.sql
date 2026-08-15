-- Metadata-only translation worker leases, crash reconciliation and audit.
--
-- This migration is additive.  It never widens the rights boundary: rows in
-- local_metadata_translation_run contain only immutable source title/summary
-- inputs, while full text remains owned by the article archive pipeline.
BEGIN;

DO $$
DECLARE
  run_rel regclass := to_regclass('local_metadata_translation_run');
  artifact_rel regclass := to_regclass('local_translation_artifact');
  missing_run text[];
  missing_artifact text[];
BEGIN
  IF run_rel IS NULL THEN
    RAISE EXCEPTION '024_metadata_translation_leases requires 016_local_fulltext_translation';
  END IF;
  IF artifact_rel IS NULL THEN
    RAISE EXCEPTION '024_metadata_translation_leases requires local_translation_artifact';
  END IF;
  SELECT array_agg(required_name ORDER BY required_name)
    INTO missing_run
    FROM unnest(ARRAY['run_id','source_version_id','item_key','source_content_hash','target_language','provider','model','prompt_version','state','attempt_count','input_chars','prompt_tokens','completion_tokens','error_reason','started_at','finished_at','created_at','updated_at']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = run_rel AND attnum > 0 AND NOT attisdropped AND attname = required_name
   );
  IF missing_run IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in local_metadata_translation_run; missing columns: %', array_to_string(missing_run, ', ');
  END IF;
  SELECT array_agg(required_name ORDER BY required_name)
    INTO missing_artifact
    FROM unnest(ARRAY['artifact_id','source_version_id','item_key','source_language','target_language','original_content_hash','provider','model','translated_title','translated_summary','validation_status','status','error_reason','created_at']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = artifact_rel AND attnum > 0 AND NOT attisdropped AND attname = required_name
   );
  IF missing_artifact IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in local_translation_artifact; missing columns: %', array_to_string(missing_artifact, ', ');
  END IF;
END $$;

-- Bind every metadata artifact to the prompt/version that produced it.  The
-- pre-024 table keyed artifacts only by provider/model, which meant a later
-- prompt could not coexist with (or be distinguished from) an older output.
ALTER TABLE local_translation_artifact
  ADD COLUMN IF NOT EXISTS prompt_version text;

UPDATE local_translation_artifact t
   SET prompt_version = COALESCE(
     NULLIF(btrim(t.prompt_version), ''),
     (
       SELECT r.prompt_version
         FROM local_metadata_translation_run r
        WHERE r.source_version_id = t.source_version_id
          AND r.item_key = t.item_key
          AND r.source_content_hash = t.original_content_hash
          AND r.target_language = t.target_language
          AND r.provider = t.provider
          AND r.model = t.model
        ORDER BY r.created_at ASC, r.run_id ASC
        LIMIT 1
     ),
     'legacy-metadata-translation-v0'
   )
 WHERE t.prompt_version IS NULL OR btrim(t.prompt_version) = '';

ALTER TABLE local_translation_artifact
  ALTER COLUMN prompt_version SET DEFAULT 'metadata-translation-v1',
  ALTER COLUMN prompt_version SET NOT NULL;

-- Replace the pre-024 uniqueness key with one that includes prompt_version.
-- Resolve the generated legacy constraint name instead of assuming a server
-- naming convention, then make the replacement idempotent for bootstrap reruns.
DO $$
DECLARE
  legacy_constraint text;
BEGIN
  SELECT c.conname
    INTO legacy_constraint
    FROM pg_constraint c
   WHERE c.conrelid = 'local_translation_artifact'::regclass
     AND c.contype = 'u'
     AND pg_get_constraintdef(c.oid) = 'UNIQUE (item_key, target_language, original_content_hash, provider, model)'
   LIMIT 1;
  IF legacy_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE local_translation_artifact DROP CONSTRAINT %I', legacy_constraint);
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'local_translation_artifact'::regclass
       AND conname = 'local_translation_artifact_lineage_unique'
  ) THEN
    ALTER TABLE local_translation_artifact
      ADD CONSTRAINT local_translation_artifact_lineage_unique
      UNIQUE (item_key, target_language, original_content_hash, provider, model, prompt_version);
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

-- Batch jobs are mutable only while running (heartbeats/counters and one
-- owner-bound terminal transition).  The application predicates every write
-- by owner_id; this trigger supplies the database-side transition and
-- append-only guard so an arbitrary writer cannot rewrite terminal history.
CREATE OR REPLACE FUNCTION local_translation_batch_job_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'local_translation_batch_job is append-only; deletion is forbidden';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.job_id IS DISTINCT FROM OLD.job_id
       OR NEW.singleton_key IS DISTINCT FROM OLD.singleton_key
       OR NEW.owner_id IS DISTINCT FROM OLD.owner_id
       OR NEW.requested_limit IS DISTINCT FROM OLD.requested_limit
       OR NEW.daily_character_limit IS DISTINCT FROM OLD.daily_character_limit
       OR NEW.started_at IS DISTINCT FROM OLD.started_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'local_translation_batch_job identity/configuration is immutable';
    END IF;
    IF OLD.state <> 'running' THEN
      RAISE EXCEPTION 'local_translation_batch_job terminal rows are immutable';
    END IF;
    IF NEW.state NOT IN ('running','succeeded','failed','blocked','interrupted') THEN
      RAISE EXCEPTION 'local_translation_batch_job state transition is invalid';
    END IF;
    IF NEW.queued_count < OLD.queued_count
       OR NEW.examined_count < OLD.examined_count
       OR NEW.translated_count < OLD.translated_count
       OR NEW.failed_count < OLD.failed_count
       OR NEW.blocked_count < OLD.blocked_count
       OR NEW.input_chars < OLD.input_chars THEN
      RAISE EXCEPTION 'local_translation_batch_job counters cannot decrease';
    END IF;
    IF NEW.translated_count + NEW.failed_count + NEW.blocked_count > NEW.examined_count THEN
      RAISE EXCEPTION 'local_translation_batch_job terminal counters are inconsistent';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS local_translation_batch_job_guard_trigger ON local_translation_batch_job;
CREATE TRIGGER local_translation_batch_job_guard_trigger
  BEFORE UPDATE OR DELETE ON local_translation_batch_job
  FOR EACH ROW EXECUTE FUNCTION local_translation_batch_job_guard();
DROP TRIGGER IF EXISTS local_translation_batch_job_truncate_guard_trigger ON local_translation_batch_job;
CREATE TRIGGER local_translation_batch_job_truncate_guard_trigger
  BEFORE TRUNCATE ON local_translation_batch_job
  EXECUTE FUNCTION local_translation_batch_job_guard();

-- Attempts are an immutable audit stream.  A terminal job remains queryable,
-- but its per-item claimed/heartbeat/reconciled rows cannot be edited or
-- removed, including via TRUNCATE.
DROP TRIGGER IF EXISTS local_translation_batch_attempt_immutable_trigger ON local_translation_batch_attempt;
CREATE TRIGGER local_translation_batch_attempt_immutable_trigger
  BEFORE UPDATE OR DELETE ON local_translation_batch_attempt
  FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();
DROP TRIGGER IF EXISTS local_translation_batch_attempt_truncate_guard_trigger ON local_translation_batch_attempt;
CREATE TRIGGER local_translation_batch_attempt_truncate_guard_trigger
  BEFORE TRUNCATE ON local_translation_batch_attempt
  EXECUTE FUNCTION local_article_immutable_guard();

CREATE TABLE IF NOT EXISTS local_translation_lease_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_translation_lease_schema_meta(schema_version)
VALUES ('024_metadata_translation_leases_v1') ON CONFLICT DO NOTHING;

COMMIT;
