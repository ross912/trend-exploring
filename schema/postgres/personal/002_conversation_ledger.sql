-- Append-only personal conversation ledger.
--
-- This migration is intentionally scoped to the personal database.  It keeps
-- enough immutable material to answer "what was visible then" without
-- retaining provider credentials or relying on the mutable global archive.
BEGIN;

CREATE TABLE IF NOT EXISTS conversation_thread (
  thread_id text PRIMARY KEY,
  owner_principal text NOT NULL CHECK (btrim(owner_principal) <> ''),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS conversation_turn (
  turn_id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES conversation_thread(thread_id),
  predecessor_turn_id text REFERENCES conversation_turn(turn_id),
  owner_principal text NOT NULL CHECK (btrim(owner_principal) <> ''),
  turn_ordinal bigint NOT NULL CHECK (turn_ordinal > 0),
  as_of timestamptz NOT NULL,
  private_query_context_hash text NOT NULL CHECK (private_query_context_hash ~ '^[a-f0-9]{64}$'),
  answer_status text NOT NULL CHECK (answer_status IN ('generated', 'not_generated', 'failed', 'privacy_blocked')),
  record_hash text NOT NULL CHECK (record_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversation_turn_not_self_predecessor CHECK (predecessor_turn_id IS NULL OR predecessor_turn_id <> turn_id),
  UNIQUE (thread_id, turn_ordinal),
  UNIQUE (thread_id, predecessor_turn_id)
);

CREATE TABLE IF NOT EXISTS conversation_query_plan (
  query_plan_id text PRIMARY KEY,
  turn_id text NOT NULL UNIQUE REFERENCES conversation_turn(turn_id),
  owner_principal text NOT NULL CHECK (btrim(owner_principal) <> ''),
  neutralizer_version text NOT NULL CHECK (btrim(neutralizer_version) <> ''),
  neutral_query text,
  plan_json jsonb NOT NULL CHECK (jsonb_typeof(plan_json) = 'object'),
  plan_hash text NOT NULL CHECK (plan_hash ~ '^[a-f0-9]{64}$'),
  as_of timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS conversation_evidence_snapshot (
  evidence_snapshot_id text PRIMARY KEY,
  turn_id text NOT NULL UNIQUE REFERENCES conversation_turn(turn_id),
  owner_principal text NOT NULL CHECK (btrim(owner_principal) <> ''),
  as_of timestamptz NOT NULL,
  snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[a-f0-9]{64}$'),
  item_count integer NOT NULL DEFAULT 0 CHECK (item_count >= 0),
  closure_hash text NOT NULL DEFAULT repeat('0', 64) CHECK (closure_hash ~ '^[a-f0-9]{64}$'),
  finalized boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Keep this migration safe to re-run over the first ledger prototype.  Rows
-- from that prototype remain deliberately unfinalized and therefore replay
-- fail-closed until a fresh append writes a complete closure.
ALTER TABLE conversation_evidence_snapshot
  ADD COLUMN IF NOT EXISTS item_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS closure_hash text NOT NULL DEFAULT repeat('0', 64),
  ADD COLUMN IF NOT EXISTS finalized boolean NOT NULL DEFAULT false;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'conversation_evidence_snapshot'::regclass AND conname = 'conversation_evidence_snapshot_item_count_check') THEN
    ALTER TABLE conversation_evidence_snapshot ADD CONSTRAINT conversation_evidence_snapshot_item_count_check CHECK (item_count >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'conversation_evidence_snapshot'::regclass AND conname = 'conversation_evidence_snapshot_closure_hash_check') THEN
    ALTER TABLE conversation_evidence_snapshot ADD CONSTRAINT conversation_evidence_snapshot_closure_hash_check CHECK (closure_hash ~ '^[a-f0-9]{64}$');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS conversation_evidence_item (
  evidence_snapshot_id text NOT NULL REFERENCES conversation_evidence_snapshot(evidence_snapshot_id),
  ordinal integer NOT NULL CHECK (ordinal >= 0),
  evidence_scope text NOT NULL CHECK (evidence_scope IN ('global', 'personal_memory')),
  evidence_version_id text NOT NULL CHECK (btrim(evidence_version_id) <> ''),
  memory_entry_id text,
  content_hash text NOT NULL CHECK (content_hash ~ '^[a-f0-9]{64}$'),
  evidence_json jsonb NOT NULL CHECK (jsonb_typeof(evidence_json) = 'object'),
  PRIMARY KEY (evidence_snapshot_id, ordinal),
  CHECK ((evidence_scope = 'global' AND memory_entry_id IS NULL) OR
         (evidence_scope = 'personal_memory' AND memory_entry_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS conversation_provider_receipt (
  provider_receipt_id text PRIMARY KEY,
  turn_id text NOT NULL REFERENCES conversation_turn(turn_id),
  attempt_ordinal integer NOT NULL CHECK (attempt_ordinal > 0),
  provider_name text NOT NULL CHECK (btrim(provider_name) <> ''),
  model text NOT NULL CHECK (btrim(model) <> ''),
  status text NOT NULL CHECK (status IN ('succeeded', 'failed', 'not_attempted')),
  request_hash text NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  response_hash text CHECK (response_hash IS NULL OR response_hash ~ '^[a-f0-9]{64}$'),
  response_json jsonb CHECK (response_json IS NULL OR jsonb_typeof(response_json) = 'object'),
  error_code text,
  error_hash text CHECK (error_hash IS NULL OR error_hash ~ '^[a-f0-9]{64}$'),
  provider_receipt_json jsonb CHECK (provider_receipt_json IS NULL OR jsonb_typeof(provider_receipt_json) = 'object'),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (turn_id, attempt_ordinal)
);

ALTER TABLE conversation_provider_receipt
  ADD COLUMN IF NOT EXISTS provider_receipt_json jsonb;

CREATE OR REPLACE FUNCTION conversation_turn_predecessor_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  predecessor conversation_turn%ROWTYPE;
  thread_owner text;
BEGIN
  IF NEW.predecessor_turn_id IS NULL THEN
    IF NEW.turn_ordinal <> 1 THEN
      RAISE EXCEPTION 'first conversation turn must have ordinal 1';
    END IF;
    SELECT owner_principal INTO thread_owner
      FROM conversation_thread WHERE thread_id = NEW.thread_id;
    IF thread_owner IS NULL OR thread_owner <> NEW.owner_principal THEN
      RAISE EXCEPTION 'conversation thread owner does not match turn owner';
    END IF;
    RETURN NEW;
  END IF;

  SELECT * INTO predecessor
    FROM conversation_turn
   WHERE turn_id = NEW.predecessor_turn_id
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'conversation predecessor does not exist';
  END IF;
  IF predecessor.thread_id <> NEW.thread_id
     OR predecessor.owner_principal <> NEW.owner_principal
     OR NEW.turn_ordinal <> predecessor.turn_ordinal + 1 THEN
    RAISE EXCEPTION 'conversation predecessor is not the immediate turn in the same owner thread';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS conversation_turn_predecessor_guard_trigger ON conversation_turn;
CREATE TRIGGER conversation_turn_predecessor_guard_trigger
BEFORE INSERT ON conversation_turn
FOR EACH ROW EXECUTE FUNCTION conversation_turn_predecessor_guard();

CREATE OR REPLACE FUNCTION conversation_owner_binding_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  turn_owner text;
  snapshot_owner text;
  snapshot_finalized boolean;
BEGIN
  IF TG_TABLE_NAME = 'conversation_query_plan' THEN
    SELECT owner_principal INTO turn_owner FROM conversation_turn WHERE turn_id = NEW.turn_id;
    IF turn_owner IS NULL OR turn_owner <> NEW.owner_principal THEN
      RAISE EXCEPTION 'query plan owner does not match turn';
    END IF;
  ELSIF TG_TABLE_NAME = 'conversation_evidence_snapshot' THEN
    SELECT owner_principal INTO turn_owner FROM conversation_turn WHERE turn_id = NEW.turn_id;
    IF turn_owner IS NULL OR turn_owner <> NEW.owner_principal THEN
      RAISE EXCEPTION 'evidence snapshot owner does not match turn';
    END IF;
  ELSIF TG_TABLE_NAME = 'conversation_evidence_item' THEN
    SELECT owner_principal, finalized INTO snapshot_owner, snapshot_finalized
      FROM conversation_evidence_snapshot
     WHERE evidence_snapshot_id = NEW.evidence_snapshot_id;
    IF snapshot_owner IS NULL THEN
      RAISE EXCEPTION 'evidence snapshot does not exist';
    END IF;
    IF snapshot_finalized THEN
      RAISE EXCEPTION 'finalized evidence snapshot is immutable';
    END IF;
  ELSIF TG_TABLE_NAME = 'conversation_provider_receipt' THEN
    SELECT owner_principal INTO turn_owner FROM conversation_turn WHERE turn_id = NEW.turn_id;
    -- Provider receipts do not carry a second owner field; the turn FK is the
    -- binding.  This branch deliberately only checks that the parent exists.
    IF turn_owner IS NULL THEN
      RAISE EXCEPTION 'provider receipt turn does not exist';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS conversation_query_plan_owner_guard ON conversation_query_plan;
CREATE TRIGGER conversation_query_plan_owner_guard
BEFORE INSERT ON conversation_query_plan
FOR EACH ROW EXECUTE FUNCTION conversation_owner_binding_guard();

DROP TRIGGER IF EXISTS conversation_evidence_snapshot_owner_guard ON conversation_evidence_snapshot;
CREATE TRIGGER conversation_evidence_snapshot_owner_guard
BEFORE INSERT ON conversation_evidence_snapshot
FOR EACH ROW EXECUTE FUNCTION conversation_owner_binding_guard();

DROP TRIGGER IF EXISTS conversation_evidence_item_owner_guard ON conversation_evidence_item;
CREATE TRIGGER conversation_evidence_item_owner_guard
BEFORE INSERT ON conversation_evidence_item
FOR EACH ROW EXECUTE FUNCTION conversation_owner_binding_guard();

DROP TRIGGER IF EXISTS conversation_provider_receipt_owner_guard ON conversation_provider_receipt;
CREATE TRIGGER conversation_provider_receipt_owner_guard
BEFORE INSERT ON conversation_provider_receipt
FOR EACH ROW EXECUTE FUNCTION conversation_owner_binding_guard();

CREATE OR REPLACE FUNCTION conversation_ledger_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  actual_count integer;
  min_ordinal integer;
  max_ordinal integer;
BEGIN
  -- A snapshot is initially written open, then receives exactly one
  -- controlled false->true transition after all items are inserted in the
  -- same transaction.  No other update is allowed.
  IF TG_TABLE_NAME = 'conversation_evidence_snapshot' AND TG_OP = 'UPDATE'
     AND OLD.finalized = false AND NEW.finalized = true
     AND NEW.evidence_snapshot_id = OLD.evidence_snapshot_id
     AND NEW.turn_id = OLD.turn_id
     AND NEW.owner_principal = OLD.owner_principal
     AND NEW.as_of = OLD.as_of
     AND NEW.snapshot_hash = OLD.snapshot_hash
     AND NEW.created_at = OLD.created_at THEN
    SELECT count(*)::integer, min(ordinal), max(ordinal)
      INTO actual_count, min_ordinal, max_ordinal
      FROM conversation_evidence_item
     WHERE evidence_snapshot_id = NEW.evidence_snapshot_id;
    IF actual_count <> NEW.item_count
       OR (NEW.item_count = 0 AND (min_ordinal IS NOT NULL OR max_ordinal IS NOT NULL))
       OR (NEW.item_count > 0 AND (min_ordinal <> 0 OR max_ordinal <> NEW.item_count - 1))
       OR NEW.closure_hash <> NEW.snapshot_hash THEN
      RAISE EXCEPTION 'evidence snapshot closure is incomplete';
    END IF;
    IF NEW.item_count > 0 AND EXISTS (
      SELECT 1
        FROM generate_series(0, GREATEST(NEW.item_count - 1, 0)) AS expected(ordinal)
       WHERE NOT EXISTS (
         SELECT 1 FROM conversation_evidence_item item
          WHERE item.evidence_snapshot_id = NEW.evidence_snapshot_id
            AND item.ordinal = expected.ordinal
       )
    ) THEN
      RAISE EXCEPTION 'evidence snapshot ordinals are not contiguous';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION '% is append-only; updates and deletes are forbidden', TG_TABLE_NAME;
END;
$$;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'conversation_thread', 'conversation_turn', 'conversation_query_plan',
    'conversation_evidence_snapshot', 'conversation_evidence_item',
    'conversation_provider_receipt'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', table_name || '_immutable_trigger', table_name);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION conversation_ledger_append_only_guard()', table_name || '_immutable_trigger', table_name);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', table_name || '_truncate_trigger', table_name);
    EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION conversation_ledger_append_only_guard()', table_name || '_truncate_trigger', table_name);
  END LOOP;
END;
$$;

CREATE INDEX IF NOT EXISTS conversation_turn_thread_order_idx
  ON conversation_turn (thread_id, turn_ordinal);
CREATE INDEX IF NOT EXISTS conversation_receipt_turn_idx
  ON conversation_provider_receipt (turn_id, attempt_ordinal);

COMMIT;
