-- EventBase/EventCausalParent infrastructure for the canonical event contract.
-- Run after 001_m1_core.sql.  Event rows are immutable and all polymorphic
-- identities are checked against the typed global identity registry.

BEGIN;

CREATE TYPE event_identity_kind AS ENUM ('object', 'record', 'event');
CREATE TYPE event_valid_time_status AS ENUM ('known', 'unknown', 'not_applicable');
CREATE TYPE event_state_semantics AS ENUM ('exclusive_transition', 'append_only', 'immutable');

CREATE TABLE global_identity_registry (
  global_identity_id uuid PRIMARY KEY,
  identity_kind event_identity_kind NOT NULL,
  concrete_type text NOT NULL CHECK (btrim(concrete_type) <> ''),
  identity_created_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (identity_created_at <= system_available_at),
  UNIQUE (global_identity_id, identity_kind, concrete_type)
);

CREATE TABLE event_type_registry_manifest (
  event_type_registry_version text PRIMARY KEY,
  schema_version text NOT NULL,
  schema_hash text NOT NULL CHECK (schema_hash ~ '^[a-f0-9]{64}$'),
  manifest_signature text NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE event_type_definition (
  event_type_registry_version text NOT NULL
    REFERENCES event_type_registry_manifest,
  event_type text NOT NULL CHECK (btrim(event_type) <> ''),
  state_semantics event_state_semantics NOT NULL,
  state_machine_family text,
  aggregate_kind event_identity_kind NOT NULL,
  aggregate_concrete_type text NOT NULL CHECK (btrim(aggregate_concrete_type) <> ''),
  payload_schema_hash text NOT NULL CHECK (payload_schema_hash ~ '^[a-f0-9]{64}$'),
  PRIMARY KEY (event_type_registry_version, event_type),
  CHECK (
    (state_semantics = 'exclusive_transition' AND state_machine_family IS NOT NULL)
    OR
    (state_semantics <> 'exclusive_transition' AND state_machine_family IS NULL)
  )
);

CREATE TABLE event_base (
  event_id uuid PRIMARY KEY,
  event_type_registry_version text NOT NULL,
  event_type text NOT NULL,
  aggregate_identity_id uuid NOT NULL,
  aggregate_identity_kind event_identity_kind NOT NULL,
  aggregate_concrete_type text NOT NULL,
  event_system_available_at timestamptz NOT NULL,
  valid_effective_at timestamptz,
  valid_time_status event_valid_time_status NOT NULL,
  ingest_domain_id uuid NOT NULL,
  ingest_sequence bigint NOT NULL CHECK (ingest_sequence > 0),
  actor_identity_id uuid,
  actor_identity_kind event_identity_kind,
  actor_concrete_type text,
  rule_record_identity_id uuid,
  rule_record_identity_kind event_identity_kind,
  rule_record_concrete_type text,
  reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
  idempotency_scope text NOT NULL CHECK (btrim(idempotency_scope) <> ''),
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> ''),
  state_machine_family text,
  aggregate_revision bigint CHECK (aggregate_revision IS NULL OR aggregate_revision > 0),
  predecessor_event_id uuid,
  CHECK (
    (valid_time_status = 'known' AND valid_effective_at IS NOT NULL)
    OR
    (valid_time_status IN ('unknown', 'not_applicable') AND valid_effective_at IS NULL)
  ),
  CHECK (actor_identity_id IS NOT NULL OR rule_record_identity_id IS NOT NULL),
  CHECK (
    (actor_identity_id IS NULL AND actor_identity_kind IS NULL AND actor_concrete_type IS NULL)
    OR
    (actor_identity_id IS NOT NULL AND actor_identity_kind IS NOT NULL
      AND actor_concrete_type IS NOT NULL AND btrim(actor_concrete_type) <> '')
  ),
  CHECK (rule_record_identity_id IS NULL OR btrim(rule_record_concrete_type) <> ''),
  CHECK (
    (rule_record_identity_id IS NULL AND rule_record_identity_kind IS NULL
      AND rule_record_concrete_type IS NULL)
    OR
    (rule_record_identity_id IS NOT NULL AND rule_record_identity_kind = 'record'
      AND rule_record_concrete_type IS NOT NULL AND btrim(rule_record_concrete_type) <> '')
  ),
  UNIQUE (ingest_domain_id, ingest_sequence),
  UNIQUE (idempotency_scope, idempotency_key),
  UNIQUE (state_machine_family, aggregate_identity_id, aggregate_revision),
  FOREIGN KEY (aggregate_identity_id, aggregate_identity_kind, aggregate_concrete_type)
    REFERENCES global_identity_registry (global_identity_id, identity_kind, concrete_type),
  FOREIGN KEY (actor_identity_id, actor_identity_kind, actor_concrete_type)
    REFERENCES global_identity_registry (global_identity_id, identity_kind, concrete_type),
  FOREIGN KEY (rule_record_identity_id, rule_record_identity_kind, rule_record_concrete_type)
    REFERENCES global_identity_registry (global_identity_id, identity_kind, concrete_type)
    DEFERRABLE INITIALLY DEFERRED
);

-- The rule identity is always a record.  PostgreSQL cannot express a constant
-- value in the composite FK above, so the trigger below closes that gap.
CREATE OR REPLACE FUNCTION validate_event_base()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  definition event_type_definition%ROWTYPE;
  registry_kind event_identity_kind;
  registry_type text;
  latest_revision bigint;
  predecessor event_base%ROWTYPE;
BEGIN
  SELECT * INTO definition
    FROM event_type_definition d
   WHERE d.event_type_registry_version = NEW.event_type_registry_version
     AND d.event_type = NEW.event_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event type is not present in the signed registry';
  END IF;

  SELECT identity_kind, concrete_type INTO registry_kind, registry_type
    FROM global_identity_registry
   WHERE global_identity_id = NEW.event_id;
  IF NOT FOUND OR registry_kind <> 'event' OR registry_type <> NEW.event_type THEN
    RAISE EXCEPTION 'event identity must be registered as its event type';
  END IF;

  IF definition.aggregate_kind <> NEW.aggregate_identity_kind
     OR definition.aggregate_concrete_type <> NEW.aggregate_concrete_type THEN
    RAISE EXCEPTION 'event aggregate identity does not match registry definition';
  END IF;

  IF NEW.rule_record_identity_id IS NOT NULL AND NEW.rule_record_identity_kind <> 'record' THEN
    RAISE EXCEPTION 'rule identity must be registered as a record';
  END IF;

  IF definition.state_semantics = 'exclusive_transition' THEN
    IF NEW.state_machine_family IS DISTINCT FROM definition.state_machine_family
       OR NEW.aggregate_revision IS NULL THEN
      RAISE EXCEPTION 'exclusive event must carry its registered state machine and revision';
    END IF;

    SELECT max(e.aggregate_revision) INTO latest_revision
      FROM event_base e
     WHERE e.state_machine_family = definition.state_machine_family
       AND e.aggregate_identity_id = NEW.aggregate_identity_id;

    IF NEW.aggregate_revision = 1 THEN
      IF NEW.predecessor_event_id IS NOT NULL OR latest_revision IS NOT NULL THEN
        RAISE EXCEPTION 'initial exclusive event must have no predecessor';
      END IF;
    ELSE
      IF NEW.predecessor_event_id IS NULL OR latest_revision IS DISTINCT FROM NEW.aggregate_revision - 1 THEN
        RAISE EXCEPTION 'exclusive event revision must extend the current expected head';
      END IF;
      SELECT * INTO predecessor FROM event_base WHERE event_id = NEW.predecessor_event_id FOR KEY SHARE;
      IF NOT FOUND
         OR predecessor.aggregate_identity_id <> NEW.aggregate_identity_id
         OR predecessor.state_machine_family <> NEW.state_machine_family
         OR predecessor.aggregate_revision <> NEW.aggregate_revision - 1 THEN
        RAISE EXCEPTION 'exclusive event predecessor is not revision - 1 on the same aggregate';
      END IF;
    END IF;
  ELSIF NEW.state_machine_family IS NOT NULL
     OR NEW.aggregate_revision IS NOT NULL
     OR NEW.predecessor_event_id IS NOT NULL THEN
    RAISE EXCEPTION 'non-exclusive event cannot carry state machine fields';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER event_base_registry_guard
BEFORE INSERT ON event_base
FOR EACH ROW EXECUTE FUNCTION validate_event_base();

CREATE TABLE event_causal_parent (
  event_id uuid NOT NULL REFERENCES event_base,
  parent_event_id uuid NOT NULL REFERENCES event_base,
  edge_system_available_at timestamptz NOT NULL,
  queue_proof_id uuid,
  PRIMARY KEY (event_id, parent_event_id),
  CHECK (event_id <> parent_event_id)
);

CREATE OR REPLACE FUNCTION validate_event_causal_parent()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  child event_base%ROWTYPE;
  parent event_base%ROWTYPE;
  cycle_found boolean;
BEGIN
  -- Lock both endpoints in a deterministic order, preventing concurrent
  -- reverse edges from bypassing the cycle check.
  IF NEW.event_id < NEW.parent_event_id THEN
    PERFORM 1 FROM event_base WHERE event_id = NEW.event_id FOR UPDATE;
    PERFORM 1 FROM event_base WHERE event_id = NEW.parent_event_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM event_base WHERE event_id = NEW.parent_event_id FOR UPDATE;
    PERFORM 1 FROM event_base WHERE event_id = NEW.event_id FOR UPDATE;
  END IF;

  SELECT * INTO child FROM event_base WHERE event_id = NEW.event_id;
  SELECT * INTO parent FROM event_base WHERE event_id = NEW.parent_event_id;
  IF parent.event_system_available_at > child.event_system_available_at THEN
    RAISE EXCEPTION 'causal parent is not available before child';
  END IF;
  IF parent.ingest_domain_id = child.ingest_domain_id
     AND parent.ingest_sequence >= child.ingest_sequence THEN
    RAISE EXCEPTION 'same-domain causal parent must have a lower ingest sequence';
  END IF;
  IF parent.ingest_domain_id <> child.ingest_domain_id AND NEW.queue_proof_id IS NULL THEN
    RAISE EXCEPTION 'cross-domain causal parent requires queue proof';
  END IF;

  WITH RECURSIVE ancestors(event_id) AS (
    SELECT e.parent_event_id
      FROM event_causal_parent e
     WHERE e.event_id = NEW.parent_event_id
    UNION
    SELECT e.parent_event_id
      FROM event_causal_parent e
      JOIN ancestors a ON a.event_id = e.event_id
  )
  SELECT EXISTS (SELECT 1 FROM ancestors WHERE event_id = NEW.event_id)
    INTO cycle_found;
  IF cycle_found THEN
    RAISE EXCEPTION 'event causal parent graph must remain acyclic';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER event_causal_parent_guard
BEFORE INSERT ON event_causal_parent
FOR EACH ROW EXECUTE FUNCTION validate_event_causal_parent();

CREATE OR REPLACE FUNCTION reject_event_infrastructure_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;

DO $$
DECLARE
  immutable_table text;
BEGIN
  FOREACH immutable_table IN ARRAY ARRAY[
    'global_identity_registry',
    'event_type_registry_manifest',
    'event_type_definition',
    'event_base',
    'event_causal_parent'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_event_infrastructure_mutation()',
      immutable_table || '_reject_mutation', immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
