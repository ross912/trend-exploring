-- M1 deterministic CoverageItem identity and generation-unit slice.

BEGIN;

CREATE TYPE coverage_item_kind AS ENUM (
  'event_cluster',
  'observation_series_snapshot',
  'concept_cluster_delta',
  'claim_relation_delta',
  'actor_action'
);

CREATE OR REPLACE FUNCTION m1_uuid5(p_namespace uuid, p_name text)
RETURNS uuid LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  bytes bytea;
  hex text;
BEGIN
  bytes := substring(digest(uuid_send(p_namespace) || convert_to(p_name, 'UTF8'), 'sha1') FROM 1 FOR 16);
  bytes := set_byte(bytes, 6, (get_byte(bytes, 6) & 15) | 80);
  bytes := set_byte(bytes, 8, (get_byte(bytes, 8) & 63) | 128);
  hex := encode(bytes, 'hex');
  RETURN (substr(hex, 1, 8) || '-' || substr(hex, 9, 4) || '-' || substr(hex, 13, 4)
       || '-' || substr(hex, 17, 4) || '-' || substr(hex, 21, 12))::uuid;
END;
$$;

CREATE OR REPLACE FUNCTION m1_coverage_projection_key(
  p_scope_snapshot_id uuid,
  p_coverage_policy_version text,
  p_projection_semantics_version text,
  p_item_kind coverage_item_kind,
  p_typed_input_refs jsonb,
  p_primary_stratum_version_ids uuid[],
  p_projection_role text
)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT p_scope_snapshot_id::text || '|' || p_coverage_policy_version || '|'
    || p_projection_semantics_version || '|' || p_item_kind::text || '|'
    || p_typed_input_refs::text || '|'
    || array_to_string(p_primary_stratum_version_ids::text[], ',') || '|'
    || p_projection_role;
$$;

CREATE OR REPLACE FUNCTION m1_coverage_generation_key(
  p_coverage_item_id uuid,
  p_detector_version_id uuid,
  p_generation_semantics_version text
)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT p_coverage_item_id::text || '|' || p_detector_version_id::text || '|'
    || p_generation_semantics_version;
$$;

CREATE TABLE coverage_policy_registry (
  coverage_policy_version text PRIMARY KEY CHECK (btrim(coverage_policy_version) <> ''),
  policy_hash text NOT NULL CHECK (policy_hash ~ '^[a-f0-9]{64}$'),
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE coverage_projection_role_registry (
  projection_role text PRIMARY KEY CHECK (btrim(projection_role) <> ''),
  role_kind text NOT NULL CHECK (btrim(role_kind) <> ''),
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE coverage_item (
  coverage_item_id uuid PRIMARY KEY,
  scope_snapshot_id uuid NOT NULL,
  coverage_policy_version text NOT NULL REFERENCES coverage_policy_registry,
  projection_semantics_version text NOT NULL CHECK (btrim(projection_semantics_version) <> ''),
  item_kind coverage_item_kind NOT NULL,
  typed_input_refs jsonb NOT NULL CHECK (
    jsonb_typeof(typed_input_refs) = 'object'
    AND typed_input_refs ? 'typedInputKind'
    AND typed_input_refs ? 'typedInputKey'
    AND btrim(typed_input_refs ->> 'typedInputKey') <> ''
    AND typed_input_refs ->> 'typedInputKind' = item_kind::text
  ),
  primary_stratum_version_ids uuid[] NOT NULL CHECK (cardinality(primary_stratum_version_ids) > 0),
  projection_role text NOT NULL REFERENCES coverage_projection_role_registry,
  coverage_projection_key text GENERATED ALWAYS AS (
    m1_coverage_projection_key(scope_snapshot_id, coverage_policy_version,
      projection_semantics_version, item_kind, typed_input_refs,
      primary_stratum_version_ids, projection_role)
  ) STORED,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (coverage_projection_key)
);

CREATE OR REPLACE FUNCTION validate_coverage_item_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  projection_key text;
BEGIN
  projection_key := m1_coverage_projection_key(
    NEW.scope_snapshot_id, NEW.coverage_policy_version,
    NEW.projection_semantics_version, NEW.item_kind, NEW.typed_input_refs,
    NEW.primary_stratum_version_ids, NEW.projection_role
  );
  IF NEW.coverage_item_id <> m1_uuid5(
    '0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', projection_key
  ) THEN
    RAISE EXCEPTION 'coverage item id does not match canonical projection key';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER coverage_item_identity_guard
BEFORE INSERT ON coverage_item
FOR EACH ROW EXECUTE FUNCTION validate_coverage_item_identity();

CREATE TABLE coverage_generation_unit (
  generation_unit_id uuid PRIMARY KEY,
  coverage_item_id uuid NOT NULL REFERENCES coverage_item,
  detector_version_id uuid NOT NULL,
  generation_semantics_version text NOT NULL CHECK (btrim(generation_semantics_version) <> ''),
  generation_key text GENERATED ALWAYS AS (
    m1_coverage_generation_key(coverage_item_id, detector_version_id, generation_semantics_version)
  ) STORED,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (generation_key)
);

CREATE OR REPLACE FUNCTION validate_coverage_generation_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  generation_key text;
BEGIN
  generation_key := m1_coverage_generation_key(
    NEW.coverage_item_id, NEW.detector_version_id, NEW.generation_semantics_version
  );
  IF NEW.generation_unit_id <> m1_uuid5(
    '0f2d5a1e-6a7e-5f43-9f0f-6e0a9bb5c1d5', generation_key
  ) THEN
    RAISE EXCEPTION 'coverage generation unit id does not match canonical generation key';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER coverage_generation_identity_guard
BEFORE INSERT ON coverage_generation_unit
FOR EACH ROW EXECUTE FUNCTION validate_coverage_generation_identity();

CREATE TABLE coverage_watermark_gap (
  coverage_watermark_gap_id uuid PRIMARY KEY,
  coverage_item_id uuid NOT NULL UNIQUE REFERENCES coverage_item,
  gap_state text NOT NULL CHECK (gap_state IN ('open', 'closed', 'superseded')),
  reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_coverage_item_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  generation_count integer;
  gap_count integer;
  gap_state_value text;
BEGIN
  SELECT count(*) INTO generation_count
    FROM coverage_generation_unit
   WHERE coverage_item_id = NEW.coverage_item_id;
  SELECT count(*), max(gap_state) INTO gap_count, gap_state_value
    FROM coverage_watermark_gap
   WHERE coverage_item_id = NEW.coverage_item_id;
  IF generation_count + gap_count <> 1
     OR (gap_count = 1 AND gap_state_value <> 'open') THEN
    RAISE EXCEPTION 'coverage item requires exactly one generation unit or open watermark gap';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER coverage_item_closure_guard
AFTER INSERT ON coverage_item
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_coverage_item_closure();

CREATE CONSTRAINT TRIGGER coverage_generation_closure_guard
AFTER INSERT ON coverage_generation_unit
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_coverage_item_closure();

CREATE CONSTRAINT TRIGGER coverage_watermark_gap_closure_guard
AFTER INSERT ON coverage_watermark_gap
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_coverage_item_closure();

CREATE TRIGGER coverage_item_reject_mutation
BEFORE UPDATE OR DELETE ON coverage_item
FOR EACH ROW EXECUTE FUNCTION reject_row_mutation();

CREATE TRIGGER coverage_generation_unit_reject_mutation
BEFORE UPDATE OR DELETE ON coverage_generation_unit
FOR EACH ROW EXECUTE FUNCTION reject_row_mutation();

CREATE TRIGGER coverage_policy_registry_reject_mutation
BEFORE UPDATE OR DELETE ON coverage_policy_registry
FOR EACH ROW EXECUTE FUNCTION reject_row_mutation();

CREATE TRIGGER coverage_projection_role_registry_reject_mutation
BEFORE UPDATE OR DELETE ON coverage_projection_role_registry
FOR EACH ROW EXECUTE FUNCTION reject_row_mutation();

CREATE TRIGGER coverage_watermark_gap_reject_mutation
BEFORE UPDATE OR DELETE ON coverage_watermark_gap
FOR EACH ROW EXECUTE FUNCTION reject_row_mutation();

COMMIT;
