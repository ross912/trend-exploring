-- Append-only signal lifecycle and point-in-time replay primitives.
--
-- This migration is deliberately independent from the local radar read model:
-- operational detection and retrospective reanalysis are recorded as distinct
-- modes, while proposition-family/signal identities remain stable.  No row in
-- this file is updated to close history; state is projected from StateEvent.
BEGIN;

CREATE TABLE IF NOT EXISTS signal_proposition_family (
  proposition_family_id text PRIMARY KEY,
  family_key text NOT NULL UNIQUE CHECK (btrim(family_key) <> ''),
  proposition_text text NOT NULL CHECK (btrim(proposition_text) <> ''),
  created_as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_manifest_id text NOT NULL CHECK (btrim(input_manifest_id) <> ''),
  method_version text NOT NULL CHECK (btrim(method_version) <> ''),
  capability_version text NOT NULL CHECK (btrim(capability_version) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (system_available_at >= created_as_of)
);

CREATE TABLE IF NOT EXISTS signal (
  signal_id text PRIMARY KEY,
  proposition_family_id text NOT NULL,
  signal_key text NOT NULL CHECK (btrim(signal_key) <> ''),
  first_detected_as_of timestamptz NOT NULL,
  first_detected_system_available_at timestamptz NOT NULL,
  initial_input_manifest_id text NOT NULL CHECK (btrim(initial_input_manifest_id) <> ''),
  initial_method_version text NOT NULL CHECK (btrim(initial_method_version) <> ''),
  initial_capability_version text NOT NULL CHECK (btrim(initial_capability_version) <> ''),
  initial_run_mode text NOT NULL CHECK (initial_run_mode = 'operational_detection'),
  forward_denominator_key text NOT NULL CHECK (btrim(forward_denominator_key) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signal_id, proposition_family_id),
  UNIQUE (proposition_family_id, signal_key),
  FOREIGN KEY (proposition_family_id)
    REFERENCES signal_proposition_family(proposition_family_id),
  CHECK (first_detected_system_available_at >= first_detected_as_of)
);

CREATE TABLE IF NOT EXISTS signal_trigger_event (
  trigger_event_id text PRIMARY KEY,
  event_key text NOT NULL UNIQUE CHECK (btrim(event_key) <> ''),
  signal_id text NOT NULL,
  proposition_family_id text NOT NULL,
  trigger_kind text NOT NULL CHECK (trigger_kind IN ('initial_detection', 'retrigger', 'late_evidence', 'retrospective_review', 'manual')),
  run_mode text NOT NULL CHECK (run_mode IN ('operational_detection', 'retrospective_reanalysis')),
  as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_manifest_id text NOT NULL CHECK (btrim(input_manifest_id) <> ''),
  method_version text NOT NULL CHECK (btrim(method_version) <> ''),
  capability_version text NOT NULL CHECK (btrim(capability_version) <> ''),
  evidence_role text NOT NULL DEFAULT 'unknown' CHECK (evidence_role IN ('support', 'contradictory', 'unknown')),
  evidence_key text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (signal_id, proposition_family_id)
    REFERENCES signal(signal_id, proposition_family_id),
  CHECK (system_available_at >= as_of),
  CHECK (trigger_kind <> 'initial_detection' OR run_mode = 'operational_detection')
);

CREATE UNIQUE INDEX IF NOT EXISTS signal_one_initial_trigger_key
  ON signal_trigger_event(signal_id)
 WHERE trigger_kind = 'initial_detection';

CREATE TABLE IF NOT EXISTS signal_evidence_link (
  evidence_link_id text PRIMARY KEY,
  evidence_key text NOT NULL CHECK (btrim(evidence_key) <> ''),
  signal_id text NOT NULL,
  proposition_family_id text NOT NULL,
  evidence_role text NOT NULL CHECK (evidence_role IN ('support', 'contradictory', 'unknown')),
  as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_manifest_id text NOT NULL CHECK (btrim(input_manifest_id) <> ''),
  method_version text NOT NULL CHECK (btrim(method_version) <> ''),
  capability_version text NOT NULL CHECK (btrim(capability_version) <> ''),
  run_mode text NOT NULL CHECK (run_mode IN ('operational_detection', 'retrospective_reanalysis')),
  late_evidence boolean NOT NULL DEFAULT false,
  evidence_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence_payload) = 'object'),
  evidence_hash text NOT NULL CHECK (evidence_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signal_id, evidence_key, evidence_hash, system_available_at),
  FOREIGN KEY (signal_id, proposition_family_id)
    REFERENCES signal(signal_id, proposition_family_id),
  CHECK (system_available_at >= as_of)
);

CREATE TABLE IF NOT EXISTS signal_state_event (
  state_event_id text PRIMARY KEY,
  event_key text NOT NULL UNIQUE CHECK (btrim(event_key) <> ''),
  signal_id text NOT NULL,
  proposition_family_id text NOT NULL,
  predecessor_state_event_id text,
  trigger_event_id text,
  state_revision integer NOT NULL CHECK (state_revision > 0),
  from_state text CHECK (from_state IS NULL OR from_state IN ('candidate', 'watching', 'strengthening', 'weakening', 'invalidated', 'dormant')),
  to_state text NOT NULL CHECK (to_state IN ('candidate', 'watching', 'strengthening', 'weakening', 'invalidated', 'dormant')),
  reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
  run_mode text NOT NULL CHECK (run_mode IN ('operational_detection', 'retrospective_reanalysis')),
  as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_manifest_id text NOT NULL CHECK (btrim(input_manifest_id) <> ''),
  method_version text NOT NULL CHECK (btrim(method_version) <> ''),
  capability_version text NOT NULL CHECK (btrim(capability_version) <> ''),
  evidence_role text NOT NULL DEFAULT 'unknown' CHECK (evidence_role IN ('support', 'contradictory', 'unknown')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signal_id, state_revision),
  FOREIGN KEY (signal_id, proposition_family_id)
    REFERENCES signal(signal_id, proposition_family_id),
  FOREIGN KEY (predecessor_state_event_id)
    REFERENCES signal_state_event(state_event_id),
  FOREIGN KEY (trigger_event_id)
    REFERENCES signal_trigger_event(trigger_event_id),
  CHECK (system_available_at >= as_of),
  CHECK ((state_revision = 1 AND predecessor_state_event_id IS NULL AND from_state IS NULL AND to_state = 'candidate') OR
         (state_revision > 1 AND predecessor_state_event_id IS NOT NULL AND from_state IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS signal_relation_event (
  relation_event_id text PRIMARY KEY,
  event_key text NOT NULL UNIQUE CHECK (btrim(event_key) <> ''),
  relation_kind text NOT NULL CHECK (relation_kind IN ('merge', 'split')),
  source_signal_id text NOT NULL,
  source_proposition_family_id text NOT NULL,
  target_signal_id text NOT NULL,
  target_proposition_family_id text NOT NULL,
  run_mode text NOT NULL CHECK (run_mode IN ('operational_detection', 'retrospective_reanalysis')),
  as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_manifest_id text NOT NULL CHECK (btrim(input_manifest_id) <> ''),
  method_version text NOT NULL CHECK (btrim(method_version) <> ''),
  capability_version text NOT NULL CHECK (btrim(capability_version) <> ''),
  reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (source_signal_id, source_proposition_family_id)
    REFERENCES signal(signal_id, proposition_family_id),
  FOREIGN KEY (target_signal_id, target_proposition_family_id)
    REFERENCES signal(signal_id, proposition_family_id),
  CHECK (source_signal_id <> target_signal_id),
  CHECK (system_available_at >= as_of)
);

CREATE INDEX IF NOT EXISTS signal_state_event_replay_idx
  ON signal_state_event(signal_id, run_mode, as_of, system_available_at, state_revision);
CREATE INDEX IF NOT EXISTS signal_trigger_event_replay_idx
  ON signal_trigger_event(signal_id, run_mode, as_of, system_available_at, created_at);
CREATE INDEX IF NOT EXISTS signal_evidence_link_replay_idx
  ON signal_evidence_link(signal_id, run_mode, as_of, system_available_at, created_at);
CREATE INDEX IF NOT EXISTS signal_relation_event_replay_idx
  ON signal_relation_event(source_signal_id, target_signal_id, run_mode, as_of, system_available_at);

CREATE OR REPLACE FUNCTION signal_lifecycle_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, lower(TG_OP);
END;
$$;

CREATE OR REPLACE FUNCTION signal_state_event_head_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  current_event signal_state_event%ROWTYPE;
  signal_exists boolean;
BEGIN
  -- Lock the immutable signal identity as the expected-head CAS.  Concurrent
  -- writers therefore cannot both append revision N+1 from the same head.
  SELECT TRUE INTO signal_exists
    FROM signal
   WHERE signal_id = NEW.signal_id
     AND proposition_family_id = NEW.proposition_family_id
   FOR UPDATE;
  IF NOT COALESCE(signal_exists, FALSE) THEN
    RAISE EXCEPTION 'signal state event parent is missing';
  END IF;

  SELECT * INTO current_event
    FROM signal_state_event
   WHERE signal_id = NEW.signal_id
   ORDER BY state_revision DESC
   LIMIT 1;

  IF current_event.state_event_id IS NULL THEN
    IF NEW.state_revision <> 1 OR NEW.from_state IS NOT NULL OR NEW.predecessor_state_event_id IS NOT NULL OR NEW.to_state <> 'candidate' THEN
      RAISE EXCEPTION 'initial signal state must be candidate revision 1';
    END IF;
  ELSE
    IF NEW.state_revision <> current_event.state_revision + 1
       OR NEW.predecessor_state_event_id IS DISTINCT FROM current_event.state_event_id
       OR NEW.from_state IS DISTINCT FROM current_event.to_state THEN
      RAISE EXCEPTION 'signal state expected-head CAS failed';
    END IF;
    IF NEW.system_available_at < current_event.system_available_at THEN
      RAISE EXCEPTION 'signal state system availability cannot move backwards';
    END IF;
    IF NOT (
      (current_event.to_state = 'candidate' AND NEW.to_state IN ('watching', 'strengthening', 'weakening', 'invalidated', 'dormant')) OR
      (current_event.to_state = 'watching' AND NEW.to_state IN ('watching', 'strengthening', 'weakening', 'invalidated', 'dormant')) OR
      (current_event.to_state = 'strengthening' AND NEW.to_state IN ('watching', 'strengthening', 'weakening', 'invalidated', 'dormant')) OR
      (current_event.to_state = 'weakening' AND NEW.to_state IN ('watching', 'strengthening', 'weakening', 'invalidated', 'dormant')) OR
      (current_event.to_state = 'invalidated' AND NEW.to_state = 'dormant') OR
      (current_event.to_state = 'dormant' AND NEW.to_state IN ('watching', 'strengthening', 'dormant'))
    ) THEN
      RAISE EXCEPTION 'invalid signal state transition % -> %', current_event.to_state, NEW.to_state;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'signal_proposition_family', 'signal', 'signal_trigger_event',
    'signal_evidence_link', 'signal_state_event', 'signal_relation_event'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I_append_only_trigger ON %I', relation_name, relation_name);
    EXECUTE format('CREATE TRIGGER %I_append_only_trigger BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION signal_lifecycle_append_only_guard()', relation_name, relation_name);
    EXECUTE format('DROP TRIGGER IF EXISTS %I_no_truncate_trigger ON %I', relation_name, relation_name);
    EXECUTE format('CREATE TRIGGER %I_no_truncate_trigger BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION signal_lifecycle_append_only_guard()', relation_name, relation_name);
  END LOOP;
END $$;

DROP TRIGGER IF EXISTS signal_state_event_head_guard_trigger ON signal_state_event;
CREATE TRIGGER signal_state_event_head_guard_trigger
BEFORE INSERT ON signal_state_event
FOR EACH ROW EXECUTE FUNCTION signal_state_event_head_guard();

CREATE TABLE IF NOT EXISTS signal_lifecycle_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO signal_lifecycle_schema_meta(schema_version)
VALUES ('020_signal_lifecycle_v1') ON CONFLICT DO NOTHING;

COMMIT;
