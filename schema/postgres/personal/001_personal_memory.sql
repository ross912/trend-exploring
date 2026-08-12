-- Personal memory ledger.  This migration is intended to be run only against
-- the personal PostgreSQL database; it has no relation to the global archive.
-- Memory rows are append-only.  A replacement or retraction is represented by
-- another row whose supersedes_entry_id points at the previous head.
BEGIN;

CREATE TABLE IF NOT EXISTS memory_entry (
  memory_entry_id text PRIMARY KEY,
  subject_key text NOT NULL CHECK (btrim(subject_key) <> ''),
  memory_kind text NOT NULL CHECK (memory_kind IN ('belief', 'hypothesis', 'question', 'focus')),
  text text NOT NULL CHECK (btrim(text) <> ''),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  supersedes_entry_id text REFERENCES memory_entry(memory_entry_id),
  status text NOT NULL CHECK (status IN ('active', 'retracted')),
  evidence_version_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  source text NOT NULL CHECK (source IN ('conversation_explicit', 'manual_import')),
  CONSTRAINT memory_entry_not_self_supersede CHECK (supersedes_entry_id IS NULL OR supersedes_entry_id <> memory_entry_id),
  CONSTRAINT memory_entry_evidence_array CHECK (jsonb_typeof(evidence_version_ids) = 'array'),
  CONSTRAINT memory_entry_retraction_shape CHECK (
    (status = 'active') OR (status = 'retracted' AND supersedes_entry_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS memory_entry_subject_head_idx
  ON memory_entry (subject_key, recorded_at DESC, memory_entry_id DESC);
CREATE INDEX IF NOT EXISTS memory_entry_status_idx
  ON memory_entry (status, recorded_at DESC, memory_entry_id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS memory_entry_one_successor_idx
  ON memory_entry (supersedes_entry_id)
  WHERE supersedes_entry_id IS NOT NULL;

CREATE OR REPLACE FUNCTION memory_entry_predecessor_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  predecessor memory_entry%ROWTYPE;
BEGIN
  IF NEW.supersedes_entry_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO predecessor
    FROM memory_entry
   WHERE memory_entry_id = NEW.supersedes_entry_id
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'superseded memory entry does not exist: %', NEW.supersedes_entry_id;
  END IF;
  IF NEW.subject_key <> predecessor.subject_key
     OR NEW.memory_kind <> predecessor.memory_kind THEN
    RAISE EXCEPTION 'superseded memory entry subject or kind differs';
  END IF;
  IF predecessor.status <> 'active' THEN
    RAISE EXCEPTION 'only an active memory entry may be superseded';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS memory_entry_predecessor_guard_trigger ON memory_entry;
CREATE TRIGGER memory_entry_predecessor_guard_trigger
BEFORE INSERT ON memory_entry
FOR EACH ROW EXECUTE FUNCTION memory_entry_predecessor_guard();

CREATE OR REPLACE FUNCTION memory_entry_validate_json()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  item jsonb;
  value text;
  seen text[] := ARRAY[]::text[];
BEGIN
  -- Timestamp is always assigned by the database, including when a caller
  -- attempts to provide a historical value explicitly.
  NEW.recorded_at := now();
  IF jsonb_typeof(NEW.evidence_version_ids) <> 'array' THEN
    RAISE EXCEPTION 'evidence_version_ids must be a JSON array';
  END IF;
  FOR item IN SELECT jsonb_array_elements(NEW.evidence_version_ids) LOOP
    IF jsonb_typeof(item) <> 'string' THEN
      RAISE EXCEPTION 'evidence_version_ids must contain strings only';
    END IF;
    value := item #>> '{}';
    IF btrim(value) = '' THEN
      RAISE EXCEPTION 'evidence_version_ids cannot contain empty strings';
    END IF;
    IF value = ANY(seen) THEN
      RAISE EXCEPTION 'evidence_version_ids must not contain duplicates';
    END IF;
    seen := array_append(seen, value);
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS memory_entry_validate_json_trigger ON memory_entry;
CREATE TRIGGER memory_entry_validate_json_trigger
BEFORE INSERT ON memory_entry
FOR EACH ROW EXECUTE FUNCTION memory_entry_validate_json();

CREATE OR REPLACE FUNCTION memory_entry_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'memory_entry is append-only; replacements and retractions require a new row';
END;
$$;

DROP TRIGGER IF EXISTS memory_entry_immutable_trigger ON memory_entry;
CREATE TRIGGER memory_entry_immutable_trigger
BEFORE UPDATE OR DELETE ON memory_entry
FOR EACH ROW EXECUTE FUNCTION memory_entry_append_only_guard();

COMMIT;
