-- Report-summary structural repair and multi-exchange audit.
--
-- 021 allowed one provider receipt per summary run.  This additive migration
-- keeps that data intact, widens the receipt cardinality to at most the
-- initial exchange plus one repair exchange, and binds a successful artifact
-- only to the final succeeded receipt.  It is intentionally fail-closed when
-- an early/partial 021 relation is present.
BEGIN;

DO $$
DECLARE
  run_rel regclass := to_regclass('local_report_summary_run');
  artifact_rel regclass := to_regclass('local_report_summary_artifact');
  receipt_rel regclass := to_regclass('provider_response_receipt');
  marker_present boolean := false;
  missing text[];
  rows_count bigint;
BEGIN
  IF run_rel IS NULL OR artifact_rel IS NULL OR receipt_rel IS NULL THEN
    RAISE EXCEPTION '022_report_summary_repair requires complete 014/021 schema';
  END IF;

  IF to_regclass('report_claim_gate_schema_meta') IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM report_claim_gate_schema_meta WHERE schema_version = '021_report_claim_gate_v1')
      INTO marker_present;
  END IF;
  IF NOT marker_present THEN
    RAISE EXCEPTION '022_report_summary_repair requires 021_report_claim_gate_v1 marker';
  END IF;

  -- A non-empty early draft must never be silently upgraded.  Empty
  -- relations are safe because the ALTER statements below add every required
  -- field and constraint atomically.
  SELECT COUNT(*) INTO rows_count FROM local_report_summary_run;
  SELECT array_agg(required_name ORDER BY required_name)
    INTO missing
    FROM unnest(ARRAY['run_id','edition_id','idempotency_key','input_hash','provider','model','prompt_version','state']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = run_rel AND attname = required_name AND attnum > 0 AND NOT attisdropped
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in local_report_summary_run; missing columns: %', array_to_string(missing, ', ');
  END IF;

  SELECT COUNT(*) INTO rows_count FROM local_report_summary_artifact;
  SELECT array_agg(required_name ORDER BY required_name)
    INTO missing
    FROM unnest(ARRAY['artifact_id','run_id','edition_id','input_hash','provider','model','prompt_version','overview','key_changes','uncertainties','output_hash']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = artifact_rel AND attname = required_name AND attnum > 0 AND NOT attisdropped
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in local_report_summary_artifact; missing columns: %', array_to_string(missing, ', ');
  END IF;

  SELECT COUNT(*) INTO rows_count FROM provider_response_receipt;
  SELECT array_agg(required_name ORDER BY required_name)
    INTO missing
    FROM unnest(ARRAY['receipt_id','run_id','provider','model','prompt_version','exchange_id','canonical_request_hash','raw_response_hash','captured_at','status']) AS required_name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_attribute
      WHERE attrelid = receipt_rel AND attname = required_name AND attnum > 0 AND NOT attisdropped
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported early-draft data in provider_response_receipt; missing columns: %', array_to_string(missing, ', ');
  END IF;
END $$;

-- Existing 021 rows are initial exchanges.  Keep all values and backfill only
-- additive audit metadata.
ALTER TABLE local_report_summary_run
  ADD COLUMN IF NOT EXISTS retry_policy_version text DEFAULT 'report-summary-repair-v1';
-- Existing rows receive the immutable default through ALTER TABLE; a null
-- value can only come from an unsupported partial schema and is rejected by
-- the fail-closed preflight above.
ALTER TABLE local_report_summary_run
  ALTER COLUMN retry_policy_version SET NOT NULL,
  ALTER COLUMN retry_policy_version SET DEFAULT 'report-summary-repair-v1';

ALTER TABLE provider_response_receipt
  ADD COLUMN IF NOT EXISTS attempt_ordinal integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS exchange_kind text DEFAULT 'initial',
  ADD COLUMN IF NOT EXISTS repair_from_receipt_id text;
DO $$
BEGIN
  -- If a partial 022 attempt already added nullable audit columns, do not
  -- UPDATE append-only receipt rows in place. Refuse the upgrade and require
  -- an operator to repair the incomplete schema explicitly.
  IF EXISTS (SELECT 1 FROM provider_response_receipt WHERE attempt_ordinal IS NULL OR exchange_kind IS NULL) THEN
    RAISE EXCEPTION 'provider_response_receipt contains null 022 audit fields; refusing append-only upgrade';
  END IF;
END $$;
ALTER TABLE provider_response_receipt
  ALTER COLUMN attempt_ordinal SET NOT NULL,
  ALTER COLUMN attempt_ordinal SET DEFAULT 1,
  ALTER COLUMN exchange_kind SET NOT NULL,
  ALTER COLUMN exchange_kind SET DEFAULT 'initial';

-- 021's run_id UNIQUE represented the old one-receipt contract.  Remove that
-- one constraint, then enforce the explicit two-slot exchange identity.
ALTER TABLE provider_response_receipt DROP CONSTRAINT IF EXISTS provider_response_receipt_run_id_key;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'provider_response_receipt'::regclass AND conname = 'provider_response_receipt_run_attempt_key') THEN
    ALTER TABLE provider_response_receipt ADD CONSTRAINT provider_response_receipt_run_attempt_key UNIQUE (run_id, attempt_ordinal);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'provider_response_receipt'::regclass AND conname = 'provider_response_receipt_attempt_check') THEN
    ALTER TABLE provider_response_receipt ADD CONSTRAINT provider_response_receipt_attempt_check CHECK (
      attempt_ordinal IN (1, 2)
      AND ((attempt_ordinal = 1 AND exchange_kind = 'initial') OR (attempt_ordinal = 2 AND exchange_kind = 'repair'))
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'provider_response_receipt'::regclass AND conname = 'provider_response_receipt_repair_parent_fkey') THEN
    ALTER TABLE provider_response_receipt ADD CONSTRAINT provider_response_receipt_repair_parent_fkey
      FOREIGN KEY (repair_from_receipt_id) REFERENCES provider_response_receipt(receipt_id);
  END IF;
END $$;

ALTER TABLE local_report_summary_artifact
  ADD COLUMN IF NOT EXISTS generation_attempt_count integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS repaired boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS repair_from_receipt_id text;
DO $$
BEGIN
  -- Artifacts are immutable too; never backfill their audit columns with an
  -- UPDATE. A nullable partial upgrade is rejected before constraints change.
  IF EXISTS (SELECT 1 FROM local_report_summary_artifact WHERE generation_attempt_count IS NULL OR repaired IS NULL) THEN
    RAISE EXCEPTION 'local_report_summary_artifact contains null 022 audit fields; refusing immutable upgrade';
  END IF;
END $$;
ALTER TABLE local_report_summary_artifact
  ALTER COLUMN generation_attempt_count SET NOT NULL,
  ALTER COLUMN generation_attempt_count SET DEFAULT 1,
  ALTER COLUMN repaired SET NOT NULL,
  ALTER COLUMN repaired SET DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_report_summary_artifact'::regclass AND conname = 'local_report_summary_artifact_generation_attempt_check') THEN
    ALTER TABLE local_report_summary_artifact ADD CONSTRAINT local_report_summary_artifact_generation_attempt_check CHECK (
      (generation_attempt_count = 1 AND repaired = false AND repair_from_receipt_id IS NULL)
      OR (generation_attempt_count = 2 AND repaired = true AND repair_from_receipt_id IS NOT NULL)
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'local_report_summary_artifact'::regclass AND conname = 'local_report_summary_artifact_repair_parent_fkey') THEN
    ALTER TABLE local_report_summary_artifact ADD CONSTRAINT local_report_summary_artifact_repair_parent_fkey
      FOREIGN KEY (repair_from_receipt_id) REFERENCES provider_response_receipt(receipt_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION local_report_summary_repair_audit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  final_attempt integer;
  final_status text;
  final_available boolean;
  final_run text;
  parent_attempt integer;
  parent_run text;
  parent_status text;
  parent_available boolean;
BEGIN
  -- Historical legacy_unverified artifacts may predate provider receipts and
  -- remain readable as compatibility rows.  The v9 typed/verified path below
  -- is the one that requires final-receipt binding and repair lineage.
  IF COALESCE(NEW.claim_gate_status, 'legacy_unverified') = 'legacy_unverified' THEN
    RETURN NEW;
  END IF;
  IF NEW.generation_attempt_count NOT IN (1, 2) THEN
    RAISE EXCEPTION 'summary generation_attempt_count must be 1 or 2';
  END IF;
  IF (NEW.generation_attempt_count = 1 AND (NEW.repaired OR NEW.repair_from_receipt_id IS NOT NULL))
     OR (NEW.generation_attempt_count = 2 AND (NOT NEW.repaired OR NEW.repair_from_receipt_id IS NULL)) THEN
    RAISE EXCEPTION 'summary repair audit fields are inconsistent';
  END IF;
  IF NEW.provider_receipt_id IS NULL THEN
    RAISE EXCEPTION 'summary artifact requires final provider receipt';
  END IF;
  SELECT run_id, attempt_ordinal, status, response_available
    INTO final_run, final_attempt, final_status, final_available
    FROM provider_response_receipt
   WHERE receipt_id = NEW.provider_receipt_id;
  IF final_run IS NULL OR final_run <> NEW.run_id OR final_attempt <> NEW.generation_attempt_count
     OR final_status <> 'succeeded' OR final_available IS NOT TRUE THEN
    RAISE EXCEPTION 'summary artifact requires final succeeded provider receipt for generation attempt';
  END IF;
  IF NEW.generation_attempt_count = 2 THEN
    SELECT run_id, attempt_ordinal, status, response_available
      INTO parent_run, parent_attempt, parent_status, parent_available
      FROM provider_response_receipt
     WHERE receipt_id = NEW.repair_from_receipt_id;
    IF parent_run IS NULL OR parent_run <> NEW.run_id OR parent_attempt <> 1
       OR parent_status <> 'succeeded' OR parent_available IS NOT TRUE THEN
      RAISE EXCEPTION 'summary artifact repair lineage must reference available succeeded initial receipt for same run';
    END IF;
    IF NEW.provider_receipt_id = NEW.repair_from_receipt_id THEN
      RAISE EXCEPTION 'summary artifact final receipt must differ from repair parent';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS local_report_summary_repair_audit_trigger ON local_report_summary_artifact;
CREATE TRIGGER local_report_summary_repair_audit_trigger
BEFORE INSERT ON local_report_summary_artifact
FOR EACH ROW EXECUTE FUNCTION local_report_summary_repair_audit_guard();

CREATE TABLE IF NOT EXISTS report_summary_repair_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO report_summary_repair_schema_meta(schema_version)
VALUES ('022_report_summary_repair_v1') ON CONFLICT DO NOTHING;

COMMIT;
