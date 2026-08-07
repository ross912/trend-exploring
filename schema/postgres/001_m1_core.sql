-- M1 executable schema slice for PostgreSQL 15+.
-- Client-generated UUIDs are required; no database-side random ID extension is assumed.

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE activation_role AS ENUM ('authoritative', 'shadow');
CREATE TYPE credential_state AS ENUM ('active', 'revoked', 'compromised');
CREATE TYPE response_member_outcome AS ENUM ('success', 'failed', 'missing');
CREATE TYPE token_use_mode AS ENUM ('single_use', 'multi_use');
CREATE TYPE token_use_outcome AS ENUM ('accepted', 'rejected');
CREATE TYPE terminal_decision AS ENUM ('selected', 'not_selected', 'failed');
CREATE TYPE run_mode AS ENUM (
  'prospective',
  'operational_replay',
  'archive_replay',
  'retrospective_reanalysis'
);

CREATE TABLE manifest_series (
  manifest_series_id uuid PRIMARY KEY,
  manifest_kind text NOT NULL,
  canonical_scope_key text NOT NULL,
  identity_created_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (identity_created_at <= system_available_at),
  UNIQUE (manifest_kind, canonical_scope_key)
);

CREATE TABLE manifest_activation_decision (
  manifest_activation_decision_id uuid PRIMARY KEY,
  manifest_series_id uuid NOT NULL REFERENCES manifest_series,
  target_manifest_kind text NOT NULL,
  target_manifest_id uuid NOT NULL,
  activation_role activation_role NOT NULL,
  effective_from timestamptz NOT NULL,
  effective_until timestamptz,
  aggregate_revision bigint NOT NULL CHECK (aggregate_revision > 0),
  predecessor_decision_id uuid,
  predecessor_revision bigint,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (effective_until IS NULL OR effective_from < effective_until),
  CHECK (
    (aggregate_revision = 1 AND predecessor_decision_id IS NULL AND predecessor_revision IS NULL)
    OR
    (aggregate_revision > 1 AND predecessor_decision_id IS NOT NULL
      AND predecessor_revision = aggregate_revision - 1)
  ),
  UNIQUE (manifest_series_id, aggregate_revision),
  UNIQUE (manifest_activation_decision_id, manifest_series_id, aggregate_revision),
  FOREIGN KEY (predecessor_decision_id, manifest_series_id, predecessor_revision)
    REFERENCES manifest_activation_decision
      (manifest_activation_decision_id, manifest_series_id, aggregate_revision)
    DEFERRABLE INITIALLY DEFERRED
);

ALTER TABLE manifest_activation_decision
  ADD CONSTRAINT manifest_authoritative_range_exclusion
  EXCLUDE USING gist (
    manifest_series_id WITH =,
    tstzrange(effective_from, effective_until, '[)') WITH &&
  ) WHERE (activation_role = 'authoritative');

CREATE OR REPLACE FUNCTION validate_manifest_predecessor()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  predecessor_revision bigint;
BEGIN
  IF NEW.aggregate_revision = 1 THEN
    RETURN NEW;
  END IF;

  SELECT aggregate_revision INTO predecessor_revision
    FROM manifest_activation_decision
   WHERE manifest_activation_decision_id = NEW.predecessor_decision_id
     AND manifest_series_id = NEW.manifest_series_id;

  IF predecessor_revision IS NULL OR predecessor_revision <> NEW.aggregate_revision - 1 THEN
    RAISE EXCEPTION 'manifest predecessor must be revision - 1';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION lock_manifest_series_for_activation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  current_revision bigint;
BEGIN
  PERFORM 1
    FROM manifest_series
   WHERE manifest_series_id = NEW.manifest_series_id
   FOR UPDATE;
  SELECT max(aggregate_revision) INTO current_revision
    FROM manifest_activation_decision
   WHERE manifest_series_id = NEW.manifest_series_id;
  IF NEW.aggregate_revision = 1 AND current_revision IS NOT NULL THEN
    RAISE EXCEPTION 'manifest activation series already has an initial decision';
  END IF;
  IF NEW.aggregate_revision > 1
     AND current_revision IS DISTINCT FROM NEW.aggregate_revision - 1 THEN
    RAISE EXCEPTION 'manifest activation revision is not the expected head';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER manifest_activation_head_guard
BEFORE INSERT ON manifest_activation_decision
FOR EACH ROW EXECUTE FUNCTION lock_manifest_series_for_activation();

CREATE CONSTRAINT TRIGGER manifest_predecessor_guard
AFTER INSERT ON manifest_activation_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_manifest_predecessor();

CREATE TABLE service_principal (
  service_principal_id uuid PRIMARY KEY,
  principal_name text NOT NULL UNIQUE,
  identity_created_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (identity_created_at <= system_available_at)
);

CREATE TABLE service_principal_credential_version (
  service_principal_credential_version_id uuid PRIMARY KEY,
  service_principal_id uuid NOT NULL REFERENCES service_principal,
  credential_fingerprint text NOT NULL,
  audience text NOT NULL,
  allowed_scopes text[] NOT NULL CHECK (cardinality(allowed_scopes) > 0),
  effective_from timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from < expires_at),
  CHECK (recorded_at <= system_available_at),
  UNIQUE (service_principal_id, credential_fingerprint)
);

CREATE OR REPLACE FUNCTION lock_credential_version_for_state_event()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1
    FROM service_principal_credential_version
   WHERE service_principal_credential_version_id = NEW.service_principal_credential_version_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'credential version does not exist';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE service_principal_credential_state_event (
  service_principal_credential_state_event_id uuid PRIMARY KEY,
  service_principal_credential_version_id uuid NOT NULL
    REFERENCES service_principal_credential_version,
  aggregate_revision bigint NOT NULL CHECK (aggregate_revision > 0),
  predecessor_event_id uuid,
  predecessor_revision bigint,
  from_state credential_state NOT NULL,
  to_state credential_state NOT NULL,
  revocation_domain_id uuid NOT NULL,
  revocation_epoch bigint NOT NULL CHECK (revocation_epoch >= 0),
  reason_code text NOT NULL,
  valid_at timestamptz NOT NULL,
  ingest_domain_id uuid NOT NULL,
  ingest_sequence bigint NOT NULL CHECK (ingest_sequence > 0),
  event_system_available_at timestamptz NOT NULL,
  CHECK (
    (aggregate_revision = 1 AND predecessor_event_id IS NULL AND predecessor_revision IS NULL
      AND from_state = 'active' AND to_state = 'active')
    OR
    (aggregate_revision > 1 AND predecessor_event_id IS NOT NULL
      AND predecessor_revision = aggregate_revision - 1
      AND from_state = 'active' AND to_state IN ('revoked', 'compromised'))
  ),
  UNIQUE (ingest_domain_id, ingest_sequence),
  UNIQUE (service_principal_credential_version_id, aggregate_revision),
  UNIQUE (
    service_principal_credential_state_event_id,
    service_principal_credential_version_id,
    aggregate_revision,
    to_state
  ),
  FOREIGN KEY (
    predecessor_event_id,
    service_principal_credential_version_id,
    predecessor_revision,
    from_state
  ) REFERENCES service_principal_credential_state_event (
    service_principal_credential_state_event_id,
    service_principal_credential_version_id,
    aggregate_revision,
    to_state
  ) DEFERRABLE INITIALLY DEFERRED
);

CREATE TRIGGER credential_state_event_parent_lock_guard
BEFORE INSERT ON service_principal_credential_state_event
FOR EACH ROW EXECUTE FUNCTION lock_credential_version_for_state_event();

CREATE VIEW current_service_principal_credential_state AS
SELECT DISTINCT ON (service_principal_credential_version_id)
  service_principal_credential_version_id,
  to_state AS current_state,
  aggregate_revision,
  revocation_domain_id,
  revocation_epoch,
  event_system_available_at
FROM service_principal_credential_state_event
ORDER BY service_principal_credential_version_id, aggregate_revision DESC;

CREATE OR REPLACE FUNCTION assert_service_principal_credential_usable(
  p_credential_version_id uuid,
  p_audience text,
  p_scope text,
  p_at timestamptz
)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  credential_record service_principal_credential_version%ROWTYPE;
  current_state_record current_service_principal_credential_state%ROWTYPE;
BEGIN
  SELECT * INTO credential_record
    FROM service_principal_credential_version
   WHERE service_principal_credential_version_id = p_credential_version_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'credential version does not exist';
  END IF;

  SELECT * INTO current_state_record
    FROM current_service_principal_credential_state
   WHERE service_principal_credential_version_id = p_credential_version_id;

  IF NOT FOUND
     OR current_state_record.current_state <> 'active'
     OR credential_record.audience <> p_audience
     OR NOT (p_scope = ANY (credential_record.allowed_scopes))
     OR p_at < credential_record.effective_from
     OR p_at >= credential_record.expires_at THEN
    RAISE EXCEPTION 'credential is not currently usable';
  END IF;
  RETURN true;
END;
$$;

CREATE TABLE model_invocation (
  model_invocation_id uuid PRIMARY KEY,
  task_manifest_id uuid NOT NULL,
  provider_id uuid NOT NULL,
  model_id uuid NOT NULL,
  outbound_payload_manifest_id uuid NOT NULL,
  provider_context_snapshot_id uuid,
  owner_scope_id uuid NOT NULL,
  revocation_dependency_set_hash text NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE TABLE provider_response_set_profile (
  provider_response_set_profile_id uuid PRIMARY KEY,
  response_mode text NOT NULL,
  member_kind text NOT NULL,
  minimum_members integer NOT NULL CHECK (minimum_members > 0),
  maximum_members integer CHECK (maximum_members IS NULL OR maximum_members >= minimum_members),
  continuation_required boolean NOT NULL,
  schema_version text NOT NULL,
  schema_hash text NOT NULL,
  manifest_signature text NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  input_record_ids uuid[] NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL
);

CREATE TABLE provider_response_set (
  provider_response_set_id uuid PRIMARY KEY,
  model_invocation_id uuid NOT NULL UNIQUE REFERENCES model_invocation,
  provider_response_set_profile_id uuid NOT NULL REFERENCES provider_response_set_profile,
  expected_member_count integer NOT NULL CHECK (expected_member_count > 0),
  member_set_hash text NOT NULL CHECK (member_set_hash ~ '^[a-f0-9]{64}$'),
  frozen_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (frozen_at <= recorded_at AND recorded_at <= system_available_at),
  UNIQUE (
    provider_response_set_id,
    model_invocation_id,
    provider_response_set_profile_id
  ),
  UNIQUE (
    provider_response_set_id,
    model_invocation_id,
    provider_response_set_profile_id,
    expected_member_count,
    member_set_hash
  )
);

CREATE TABLE provider_response_member_unit (
  provider_response_member_unit_id uuid PRIMARY KEY,
  model_invocation_id uuid NOT NULL REFERENCES model_invocation,
  provider_response_set_profile_id uuid NOT NULL REFERENCES provider_response_set_profile,
  provider_response_set_id uuid NOT NULL,
  member_key text NOT NULL,
  ordinal integer NOT NULL CHECK (ordinal > 0),
  page_key text,
  shard_key text,
  continuation_expected boolean NOT NULL DEFAULT false,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (model_invocation_id, member_key),
  UNIQUE (model_invocation_id, ordinal),
  UNIQUE (provider_response_member_unit_id, model_invocation_id),
  FOREIGN KEY (
    provider_response_set_id,
    model_invocation_id,
    provider_response_set_profile_id
  ) REFERENCES provider_response_set (
    provider_response_set_id,
    model_invocation_id,
    provider_response_set_profile_id
  )
);

CREATE TABLE provider_response_member_decision (
  provider_response_member_decision_id uuid PRIMARY KEY,
  provider_response_member_unit_id uuid NOT NULL UNIQUE,
  model_invocation_id uuid NOT NULL,
  outcome response_member_outcome NOT NULL,
  reason_code text,
  continuation_closed boolean NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK ((outcome = 'success') = (reason_code IS NULL)),
  FOREIGN KEY (provider_response_member_unit_id, model_invocation_id)
    REFERENCES provider_response_member_unit
      (provider_response_member_unit_id, model_invocation_id),
  UNIQUE (provider_response_member_decision_id, model_invocation_id, outcome)
);

CREATE TABLE provider_response_receipt (
  provider_response_receipt_id uuid PRIMARY KEY,
  provider_response_member_decision_id uuid NOT NULL UNIQUE,
  model_invocation_id uuid NOT NULL,
  outcome response_member_outcome NOT NULL DEFAULT 'success',
  response_mode text NOT NULL,
  captured_exchange_id text NOT NULL,
  authenticated_peer text NOT NULL,
  provider_job_id text,
  raw_response_hash text NOT NULL,
  accepted_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (accepted_at <= system_available_at),
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (provider_response_member_decision_id, model_invocation_id, outcome)
    REFERENCES provider_response_member_decision
      (provider_response_member_decision_id, model_invocation_id, outcome),
  CONSTRAINT provider_receipt_success_only CHECK (outcome = 'success'),
  UNIQUE (
    provider_response_receipt_id,
    provider_response_member_decision_id,
    model_invocation_id
  )
);

CREATE TABLE model_output_artifact (
  model_output_artifact_id uuid PRIMARY KEY,
  provider_response_member_decision_id uuid NOT NULL UNIQUE,
  provider_response_receipt_id uuid NOT NULL UNIQUE,
  model_invocation_id uuid NOT NULL,
  raw_content_hash text NOT NULL,
  storage_uri text NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (
    provider_response_receipt_id,
    provider_response_member_decision_id,
    model_invocation_id
  ) REFERENCES provider_response_receipt (
    provider_response_receipt_id,
    provider_response_member_decision_id,
    model_invocation_id
  )
);

CREATE TABLE provider_response_set_closure (
  provider_response_set_id uuid PRIMARY KEY REFERENCES provider_response_set,
  closed_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL
);

CREATE OR REPLACE FUNCTION validate_response_plan_timing()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  invocation_recorded_at timestamptz;
  invocation_available_at timestamptz;
BEGIN
  SELECT recorded_at, system_available_at
    INTO invocation_recorded_at, invocation_available_at
    FROM model_invocation
   WHERE model_invocation_id = NEW.model_invocation_id;

  IF TG_TABLE_NAME = 'provider_response_set' THEN
    IF NEW.frozen_at > invocation_recorded_at
       OR NEW.system_available_at > invocation_available_at THEN
      RAISE EXCEPTION 'response plan must be frozen and available by invocation';
    END IF;
  ELSIF TG_TABLE_NAME = 'provider_response_member_unit' THEN
    IF NEW.recorded_at > invocation_recorded_at
       OR NEW.system_available_at > invocation_available_at THEN
      RAISE EXCEPTION 'response member universe must exist by invocation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER response_plan_timing_guard
AFTER INSERT ON provider_response_set
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_response_plan_timing();

CREATE CONSTRAINT TRIGGER response_member_timing_guard
AFTER INSERT ON provider_response_member_unit
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_response_plan_timing();

CREATE OR REPLACE FUNCTION prevent_response_append_after_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  set_id uuid;
BEGIN
  SELECT provider_response_set_id
    INTO set_id
    FROM provider_response_set
   WHERE model_invocation_id = NEW.model_invocation_id
   FOR UPDATE;

  IF set_id IS NULL THEN
    RAISE EXCEPTION 'provider response set does not exist for invocation';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM provider_response_set_closure c
     WHERE c.provider_response_set_id = set_id
  ) THEN
    RAISE EXCEPTION 'provider response set is already closed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION lock_response_set_for_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1
    FROM provider_response_set
   WHERE provider_response_set_id = NEW.provider_response_set_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'provider response set does not exist';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER response_set_closure_lock_guard
BEFORE INSERT ON provider_response_set_closure
FOR EACH ROW EXECUTE FUNCTION lock_response_set_for_closure();

CREATE TRIGGER response_member_unit_closed_guard
BEFORE INSERT ON provider_response_member_unit
FOR EACH ROW EXECUTE FUNCTION prevent_response_append_after_closure();

CREATE TRIGGER response_member_decision_closed_guard
BEFORE INSERT ON provider_response_member_decision
FOR EACH ROW EXECUTE FUNCTION prevent_response_append_after_closure();

CREATE TRIGGER response_receipt_closed_guard
BEFORE INSERT ON provider_response_receipt
FOR EACH ROW EXECUTE FUNCTION prevent_response_append_after_closure();

CREATE TRIGGER response_output_closed_guard
BEFORE INSERT ON model_output_artifact
FOR EACH ROW EXECUTE FUNCTION prevent_response_append_after_closure();

CREATE OR REPLACE FUNCTION validate_provider_response_set_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  unit_count integer;
  decision_count integer;
  successful_count integer;
  output_count integer;
  open_continuations integer;
  profile_min integer;
  profile_max integer;
  calculated_member_set_hash text;
  set_invocation_id uuid;
  set_profile_id uuid;
  set_expected_member_count integer;
  set_member_set_hash text;
BEGIN
  SELECT model_invocation_id, provider_response_set_profile_id,
         expected_member_count, member_set_hash
    INTO set_invocation_id, set_profile_id,
         set_expected_member_count, set_member_set_hash
    FROM provider_response_set
   WHERE provider_response_set_id = NEW.provider_response_set_id;

  SELECT minimum_members, maximum_members
    INTO profile_min, profile_max
    FROM provider_response_set_profile
   WHERE provider_response_set_profile_id = set_profile_id;

  SELECT count(*) INTO unit_count
    FROM provider_response_member_unit
   WHERE model_invocation_id = set_invocation_id
     AND provider_response_set_profile_id = set_profile_id
     AND provider_response_set_id = NEW.provider_response_set_id;

  SELECT count(d.provider_response_member_decision_id),
         count(*) FILTER (WHERE d.outcome = 'success'),
         count(*) FILTER (WHERE u.continuation_expected AND NOT d.continuation_closed)
    INTO decision_count, successful_count, open_continuations
    FROM provider_response_member_unit u
    LEFT JOIN provider_response_member_decision d
      ON d.provider_response_member_unit_id = u.provider_response_member_unit_id
   WHERE u.model_invocation_id = set_invocation_id
     AND u.provider_response_set_profile_id = set_profile_id
     AND u.provider_response_set_id = NEW.provider_response_set_id;

  SELECT count(*) INTO output_count
    FROM model_output_artifact
   WHERE model_invocation_id = set_invocation_id;

  SELECT encode(
           digest(
             string_agg(
               u.provider_response_member_unit_id::text || '|' ||
               encode(convert_to(u.member_key, 'UTF8'), 'hex') || '|' ||
               u.ordinal::text || '|' ||
               CASE WHEN u.page_key IS NULL THEN '-'
                    ELSE encode(convert_to(u.page_key, 'UTF8'), 'hex') END || '|' ||
               CASE WHEN u.shard_key IS NULL THEN '-'
                    ELSE encode(convert_to(u.shard_key, 'UTF8'), 'hex') END || '|' ||
               CASE WHEN u.continuation_expected THEN '1' ELSE '0' END,
               E'\n' ORDER BY u.ordinal
             ),
             'sha256'
           ),
           'hex'
         )
    INTO calculated_member_set_hash
    FROM provider_response_member_unit u
   WHERE u.model_invocation_id = set_invocation_id
     AND u.provider_response_set_profile_id = set_profile_id
     AND u.provider_response_set_id = NEW.provider_response_set_id;

  IF unit_count <> set_expected_member_count
     OR decision_count <> unit_count
     OR output_count <> successful_count
     OR open_continuations <> 0
     OR calculated_member_set_hash IS DISTINCT FROM set_member_set_hash
     OR unit_count < profile_min
     OR (profile_max IS NOT NULL AND unit_count > profile_max) THEN
    RAISE EXCEPTION 'provider response set is not closed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER provider_response_set_closure_guard
AFTER INSERT ON provider_response_set_closure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_provider_response_set_closure();

CREATE TABLE token_use_policy_manifest (
  token_use_policy_manifest_id uuid PRIMARY KEY,
  token_type text NOT NULL,
  action text NOT NULL,
  use_mode token_use_mode NOT NULL,
  maximum_uses integer,
  require_cursor_monotonicity boolean NOT NULL,
  schema_version text NOT NULL,
  schema_hash text NOT NULL,
  manifest_signature text NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  input_record_ids uuid[] NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (
    (use_mode = 'single_use' AND maximum_uses = 1)
    OR (use_mode = 'multi_use' AND maximum_uses IS NOT NULL AND maximum_uses > 1)
  ),
  UNIQUE (token_type, action, effective_from),
  UNIQUE (token_use_policy_manifest_id, token_type, action)
);

CREATE TABLE presentation_capability_token (
  presentation_capability_token_id uuid PRIMARY KEY,
  token_use_policy_manifest_id uuid NOT NULL REFERENCES token_use_policy_manifest,
  token_type text NOT NULL,
  action text NOT NULL,
  jti text NOT NULL UNIQUE,
  subject_id uuid NOT NULL,
  head_id uuid,
  query_shape_hash text,
  scope_binding_hash text GENERATED ALWAYS AS (
    encode(
      digest(
        token_type || '|' || action || '|' || subject_id::text || '|' ||
        coalesce(head_id::text, '-') || '|' || coalesce(query_shape_hash, '-'),
        'sha256'
      ),
      'hex'
    )
  ) STORED,
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  token_use_epoch bigint NOT NULL CHECK (token_use_epoch >= 0),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (issued_at < expires_at),
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (token_use_policy_manifest_id, token_type, action)
    REFERENCES token_use_policy_manifest
      (token_use_policy_manifest_id, token_type, action),
  UNIQUE (presentation_capability_token_id, scope_binding_hash)
);

CREATE TABLE token_use_unit (
  token_use_unit_id uuid PRIMARY KEY,
  presentation_capability_token_id uuid NOT NULL REFERENCES presentation_capability_token,
  scope_binding_hash text NOT NULL,
  request_nonce text NOT NULL,
  cursor_ordinal bigint,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  UNIQUE (presentation_capability_token_id, request_nonce),
  FOREIGN KEY (presentation_capability_token_id, scope_binding_hash)
    REFERENCES presentation_capability_token
      (presentation_capability_token_id, scope_binding_hash)
);

CREATE TABLE token_use_decision (
  token_use_decision_id uuid PRIMARY KEY,
  token_use_unit_id uuid NOT NULL UNIQUE REFERENCES token_use_unit,
  outcome token_use_outcome NOT NULL,
  reason_code text,
  decided_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK ((outcome = 'accepted') = (reason_code IS NULL)),
  CHECK (decided_at <= system_available_at),
  CHECK (recorded_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_token_use_decision()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  token_id uuid;
  policy_mode token_use_mode;
  allowed_uses integer;
  accepted_uses integer;
  current_cursor bigint;
  prior_cursor bigint;
  enforce_cursor_monotonicity boolean;
  token_issued_at timestamptz;
  token_expires_at timestamptz;
  issued_epoch bigint;
  current_epoch bigint;
BEGIN
  SELECT t.presentation_capability_token_id, p.use_mode, p.maximum_uses,
         u.cursor_ordinal, p.require_cursor_monotonicity,
         t.issued_at, t.expires_at, t.token_use_epoch
    INTO token_id, policy_mode, allowed_uses, current_cursor,
         enforce_cursor_monotonicity, token_issued_at, token_expires_at, issued_epoch
    FROM token_use_unit u
    JOIN presentation_capability_token t
      ON t.presentation_capability_token_id = u.presentation_capability_token_id
    JOIN token_use_policy_manifest p
      ON p.token_use_policy_manifest_id = t.token_use_policy_manifest_id
   WHERE u.token_use_unit_id = NEW.token_use_unit_id
   FOR UPDATE OF t;

  IF NEW.outcome <> 'accepted' THEN
    RETURN NEW;
  END IF;

  SELECT max(token_use_epoch) INTO current_epoch FROM token_use_ledger_checkpoint;
  IF current_epoch IS NULL OR issued_epoch <> current_epoch THEN
    RAISE EXCEPTION 'token use epoch is stale or unavailable';
  END IF;
  IF NEW.decided_at < token_issued_at OR NEW.decided_at >= token_expires_at THEN
    RAISE EXCEPTION 'token is not valid at decision time';
  END IF;

  SELECT count(*) INTO accepted_uses
    FROM token_use_decision d
    JOIN token_use_unit u ON u.token_use_unit_id = d.token_use_unit_id
   WHERE u.presentation_capability_token_id = token_id
     AND d.outcome = 'accepted';

  IF accepted_uses > allowed_uses THEN
    RAISE EXCEPTION 'token use limit exceeded';
  END IF;

  IF policy_mode = 'multi_use' AND enforce_cursor_monotonicity THEN
    IF current_cursor IS NULL THEN
      RAISE EXCEPTION 'multi-use token requires cursor ordinal';
    END IF;
    SELECT max(u.cursor_ordinal) INTO prior_cursor
      FROM token_use_decision d
      JOIN token_use_unit u ON u.token_use_unit_id = d.token_use_unit_id
     WHERE u.presentation_capability_token_id = token_id
       AND d.outcome = 'accepted'
       AND d.token_use_decision_id <> NEW.token_use_decision_id;
    IF prior_cursor IS NOT NULL AND current_cursor <= prior_cursor THEN
      RAISE EXCEPTION 'multi-use cursor must advance monotonically';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER token_use_guard
AFTER INSERT ON token_use_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_token_use_decision();

CREATE TABLE token_use_ledger_checkpoint (
  token_use_ledger_checkpoint_id uuid PRIMARY KEY,
  token_use_epoch bigint NOT NULL UNIQUE CHECK (token_use_epoch >= 0),
  accepted_jti_set_hash text NOT NULL,
  accepted_use_count bigint NOT NULL CHECK (accepted_use_count >= 0),
  previous_checkpoint_id uuid,
  predecessor_epoch bigint,
  snapshot_frozen_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (
    (token_use_epoch = 0 AND previous_checkpoint_id IS NULL AND predecessor_epoch IS NULL)
    OR (token_use_epoch > 0 AND previous_checkpoint_id IS NOT NULL
      AND predecessor_epoch = token_use_epoch - 1)
  ),
  UNIQUE (token_use_ledger_checkpoint_id, token_use_epoch),
  UNIQUE (token_use_epoch, accepted_use_count),
  FOREIGN KEY (previous_checkpoint_id, predecessor_epoch)
    REFERENCES token_use_ledger_checkpoint
      (token_use_ledger_checkpoint_id, token_use_epoch)
    DEFERRABLE INITIALLY DEFERRED
);

ALTER TABLE presentation_capability_token
  ADD CONSTRAINT presentation_token_epoch_checkpoint_fk
  FOREIGN KEY (token_use_epoch)
  REFERENCES token_use_ledger_checkpoint (token_use_epoch)
  DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE evaluation_arm_manifest (
  evaluation_arm_manifest_id uuid PRIMARY KEY,
  arm_key text NOT NULL,
  scope_snapshot_id uuid NOT NULL,
  outcome_frame_manifest_id uuid NOT NULL,
  cutoff_at timestamptz NOT NULL,
  k integer NOT NULL CHECK (k > 0),
  schema_version text NOT NULL,
  schema_hash text NOT NULL,
  manifest_signature text NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  input_record_ids uuid[] NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  UNIQUE (scope_snapshot_id, arm_key, cutoff_at)
);

CREATE TABLE evaluation_arm_generation_unit (
  evaluation_arm_generation_unit_id uuid PRIMARY KEY,
  evaluation_arm_manifest_id uuid NOT NULL REFERENCES evaluation_arm_manifest,
  ordinal integer NOT NULL CHECK (ordinal > 0),
  candidate_ref uuid NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  UNIQUE (evaluation_arm_manifest_id, ordinal),
  UNIQUE (evaluation_arm_generation_unit_id, evaluation_arm_manifest_id)
);

CREATE TABLE evaluation_arm_generation_decision (
  evaluation_arm_generation_decision_id uuid PRIMARY KEY,
  evaluation_arm_generation_unit_id uuid NOT NULL UNIQUE,
  evaluation_arm_manifest_id uuid NOT NULL,
  outcome terminal_decision NOT NULL,
  reason_code text,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  FOREIGN KEY (evaluation_arm_generation_unit_id, evaluation_arm_manifest_id)
    REFERENCES evaluation_arm_generation_unit
      (evaluation_arm_generation_unit_id, evaluation_arm_manifest_id),
  CHECK ((outcome = 'selected') = (reason_code IS NULL))
);

CREATE TABLE evaluation_obligation (
  evaluation_obligation_id uuid PRIMARY KEY,
  evaluation_arm_manifest_id uuid NOT NULL REFERENCES evaluation_arm_manifest,
  evaluation_arm_generation_unit_id uuid NOT NULL,
  candidate_ref uuid NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (evaluation_arm_manifest_id, candidate_ref),
  UNIQUE (
    evaluation_obligation_id,
    evaluation_arm_manifest_id,
    evaluation_arm_generation_unit_id,
    candidate_ref
  ),
  FOREIGN KEY (
    evaluation_arm_generation_unit_id,
    evaluation_arm_manifest_id
  ) REFERENCES evaluation_arm_generation_unit (
    evaluation_arm_generation_unit_id,
    evaluation_arm_manifest_id
  )
);

CREATE TABLE evaluation_snapshot_decision (
  evaluation_snapshot_decision_id uuid PRIMARY KEY,
  evaluation_obligation_id uuid NOT NULL UNIQUE REFERENCES evaluation_obligation,
  decision text NOT NULL CHECK (decision IN ('captured', 'missed')),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE TABLE evaluation_result (
  evaluation_result_id uuid PRIMARY KEY,
  evaluation_obligation_id uuid NOT NULL UNIQUE REFERENCES evaluation_obligation,
  result_code text NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE TABLE evaluation_arm_output_snapshot (
  evaluation_arm_output_snapshot_id uuid PRIMARY KEY,
  evaluation_arm_manifest_id uuid NOT NULL UNIQUE REFERENCES evaluation_arm_manifest,
  ordered_candidate_refs uuid[] NOT NULL,
  member_set_hash text NOT NULL CHECK (member_set_hash ~ '^[a-f0-9]{64}$'),
  snapshot_frozen_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (cardinality(ordered_candidate_refs) > 0)
);

CREATE OR REPLACE FUNCTION validate_evaluation_arm_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  manifest_k integer;
  generation_count integer;
  terminal_count integer;
  selected_count integer;
  output_count integer;
  output_distinct_count integer;
  obligation_count integer;
  captured_snapshot_count integer;
  result_count integer;
  selected_mismatch_count integer;
  obligation_mismatch_count integer;
BEGIN
  SELECT k INTO manifest_k
    FROM evaluation_arm_manifest
   WHERE evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id;

  IF manifest_k IS NULL THEN
    RAISE EXCEPTION 'evaluation arm manifest does not exist';
  END IF;

  SELECT count(*),
         count(d.evaluation_arm_generation_decision_id),
         count(*) FILTER (WHERE d.outcome = 'selected')
    INTO generation_count, terminal_count, selected_count
    FROM evaluation_arm_generation_unit u
    LEFT JOIN evaluation_arm_generation_decision d
      ON d.evaluation_arm_generation_unit_id = u.evaluation_arm_generation_unit_id
   WHERE u.evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id;

  output_count := cardinality(NEW.ordered_candidate_refs);
  SELECT count(DISTINCT candidate_ref)
    INTO output_distinct_count
    FROM unnest(NEW.ordered_candidate_refs) AS candidate_ref;

  SELECT count(*) INTO obligation_count
    FROM evaluation_obligation
   WHERE evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id;

  SELECT count(*) INTO captured_snapshot_count
    FROM evaluation_snapshot_decision d
    JOIN evaluation_obligation o
      ON o.evaluation_obligation_id = d.evaluation_obligation_id
   WHERE o.evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id
     AND d.decision = 'captured';

  SELECT count(*) INTO result_count
    FROM evaluation_result r
    JOIN evaluation_obligation o
      ON o.evaluation_obligation_id = r.evaluation_obligation_id
   WHERE o.evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id;

  SELECT count(*) INTO selected_mismatch_count
    FROM (
      SELECT u.candidate_ref
        FROM evaluation_arm_generation_unit u
        JOIN evaluation_arm_generation_decision d
          ON d.evaluation_arm_generation_unit_id = u.evaluation_arm_generation_unit_id
       WHERE u.evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id
         AND d.outcome = 'selected'
      EXCEPT
      SELECT candidate_ref FROM unnest(NEW.ordered_candidate_refs) AS candidate_ref
      UNION ALL
      SELECT candidate_ref FROM unnest(NEW.ordered_candidate_refs) AS candidate_ref
      EXCEPT
      SELECT u.candidate_ref
        FROM evaluation_arm_generation_unit u
        JOIN evaluation_arm_generation_decision d
          ON d.evaluation_arm_generation_unit_id = u.evaluation_arm_generation_unit_id
       WHERE u.evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id
         AND d.outcome = 'selected'
    ) AS mismatch;

  SELECT count(*) INTO obligation_mismatch_count
    FROM (
      SELECT candidate_ref
        FROM evaluation_obligation
       WHERE evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id
      EXCEPT
      SELECT candidate_ref FROM unnest(NEW.ordered_candidate_refs) AS candidate_ref
      UNION ALL
      SELECT candidate_ref FROM unnest(NEW.ordered_candidate_refs) AS candidate_ref
      EXCEPT
      SELECT candidate_ref
        FROM evaluation_obligation
       WHERE evaluation_arm_manifest_id = NEW.evaluation_arm_manifest_id
    ) AS mismatch;

  IF generation_count <> terminal_count
     OR selected_count <> manifest_k
     OR output_count <> manifest_k
     OR output_distinct_count <> output_count
     OR obligation_count <> output_count
     OR captured_snapshot_count <> obligation_count
     OR result_count <> obligation_count
     OR selected_mismatch_count <> 0
     OR obligation_mismatch_count <> 0 THEN
    RAISE EXCEPTION 'evaluation arm output/obligation/result sets are not closed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER evaluation_arm_output_closure_guard
AFTER INSERT ON evaluation_arm_output_snapshot
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_evaluation_arm_closure();

CREATE TYPE test_phase AS ENUM ('M0', 'M1', 'M2', 'M3', 'M4', 'M5');
CREATE TYPE test_severity AS ENUM ('P0', 'P1');
CREATE TYPE test_blocking_mode AS ENUM (
  'phase-exit',
  'normal-edition',
  'service-claim',
  'release',
  'capability-claim',
  'version-promotion',
  'none'
);
CREATE TYPE test_catalog_membership AS ENUM ('applicable', 'excluded');
CREATE TYPE test_result_status AS ENUM ('pass', 'fail', 'blocked', 'not_applicable');
CREATE TYPE gate_decision_status AS ENUM ('pass', 'blocked');

CREATE TABLE test_definition (
  test_id uuid PRIMARY KEY,
  test_code text NOT NULL UNIQUE CHECK (test_code ~ '^[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?$'),
  identity_created_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (identity_created_at <= system_available_at)
);

CREATE TABLE test_governance_policy (
  test_governance_policy_version uuid PRIMARY KEY,
  policy_revision bigint NOT NULL UNIQUE CHECK (policy_revision > 0),
  schema_version text NOT NULL,
  schema_hash text NOT NULL CHECK (schema_hash ~ '^[a-f0-9]{64}$'),
  manifest_signature text NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  input_record_ids uuid[] NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE test_definition_version (
  test_definition_version_id uuid PRIMARY KEY,
  test_id uuid NOT NULL REFERENCES test_definition,
  test_governance_policy_version uuid NOT NULL REFERENCES test_governance_policy,
  definition_revision bigint NOT NULL CHECK (definition_revision > 0),
  supersedes_version_id uuid,
  supersedes_revision bigint,
  introduced_phase test_phase NOT NULL,
  run_on_or_after test_phase NOT NULL,
  applicability_predicate text NOT NULL CHECK (btrim(applicability_predicate) <> ''),
  waiver_allowed boolean NOT NULL,
  severity test_severity NOT NULL,
  blocking test_blocking_mode NOT NULL,
  fixture_contract text NOT NULL CHECK (btrim(fixture_contract) <> ''),
  config_contract text NOT NULL CHECK (btrim(config_contract) <> ''),
  oracle_spec text NOT NULL CHECK (btrim(oracle_spec) <> ''),
  definition_hash text NOT NULL CHECK (definition_hash ~ '^[a-f0-9]{64}$'),
  manifest_signature text NOT NULL,
  valid_from timestamptz NOT NULL,
  system_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (system_from <= system_available_at),
  CHECK (valid_from <= as_of),
  CHECK (run_on_or_after >= introduced_phase),
  CHECK (severity <> 'P0' OR (applicability_predicate = 'always' AND NOT waiver_allowed)),
  CHECK (severity <> 'P0' OR blocking <> 'none'),
  CHECK (
    (definition_revision = 1 AND supersedes_version_id IS NULL AND supersedes_revision IS NULL)
    OR
    (definition_revision > 1 AND supersedes_version_id IS NOT NULL
      AND supersedes_revision = definition_revision - 1)
  ),
  UNIQUE (test_id, definition_revision),
  UNIQUE (test_definition_version_id, test_id, definition_revision),
  FOREIGN KEY (supersedes_version_id, test_id, supersedes_revision)
    REFERENCES test_definition_version
      (test_definition_version_id, test_id, definition_revision)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE OR REPLACE FUNCTION validate_test_definition_strength()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  predecessor test_definition_version%ROWTYPE;
BEGIN
  IF NEW.definition_revision = 1 THEN
    RETURN NEW;
  END IF;

  SELECT * INTO predecessor
    FROM test_definition_version
   WHERE test_definition_version_id = NEW.supersedes_version_id
     AND test_id = NEW.test_id
     AND definition_revision = NEW.supersedes_revision;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF NEW.introduced_phase > predecessor.introduced_phase THEN
    RAISE EXCEPTION 'test definition introduced phase cannot move later';
  END IF;
  IF predecessor.severity = 'P0' AND NEW.severity <> 'P0' THEN
    RAISE EXCEPTION 'P0 test definition strength cannot be downgraded';
  END IF;
  IF predecessor.blocking <> 'none' AND NEW.blocking = 'none' THEN
    RAISE EXCEPTION 'blocking test definition cannot be downgraded to none';
  END IF;
  IF predecessor.severity = 'P0' AND NEW.applicability_predicate <> 'always' THEN
    RAISE EXCEPTION 'P0 test definition applicability cannot be weakened';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_definition_strength_guard
BEFORE INSERT OR UPDATE ON test_definition_version
FOR EACH ROW EXECUTE FUNCTION validate_test_definition_strength();

CREATE TABLE test_catalog_manifest (
  test_catalog_manifest_id uuid PRIMARY KEY,
  target_phase test_phase NOT NULL,
  target_gate test_blocking_mode NOT NULL,
  test_governance_policy_version uuid NOT NULL REFERENCES test_governance_policy,
  definitions_universe_hash text NOT NULL CHECK (definitions_universe_hash ~ '^[a-f0-9]{64}$'),
  schema_version text NOT NULL,
  schema_hash text NOT NULL CHECK (schema_hash ~ '^[a-f0-9]{64}$'),
  manifest_signature text NOT NULL,
  owner_service_principal_id uuid NOT NULL REFERENCES service_principal,
  input_record_ids uuid[] NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE test_catalog_definition_member (
  test_catalog_definition_member_id uuid PRIMARY KEY,
  test_catalog_manifest_id uuid NOT NULL REFERENCES test_catalog_manifest,
  test_definition_version_id uuid NOT NULL REFERENCES test_definition_version,
  membership test_catalog_membership NOT NULL,
  exclusion_reason text,
  applicability_evidence text NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (
    (membership = 'applicable' AND exclusion_reason IS NULL)
    OR
    (membership = 'excluded' AND btrim(coalesce(exclusion_reason, '')) <> '')
  ),
  UNIQUE (test_catalog_manifest_id, test_definition_version_id)
);

CREATE OR REPLACE FUNCTION validate_test_catalog_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  expected_count integer;
  member_count integer;
  p0_excluded_count integer;
  policy_mismatch_count integer;
  set_mismatch_count integer;
  calculated_hash text;
BEGIN
  WITH latest AS (
    SELECT DISTINCT ON (test_id)
           test_definition_version_id, test_id, introduced_phase,
           severity, test_governance_policy_version
      FROM test_definition_version
     ORDER BY test_id, definition_revision DESC
  )
  SELECT count(*) INTO expected_count
    FROM latest
   WHERE introduced_phase <= NEW.target_phase;

  SELECT count(*) INTO member_count
    FROM test_catalog_definition_member
   WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id;

  SELECT count(*) INTO p0_excluded_count
    FROM test_catalog_definition_member m
    JOIN test_definition_version v
      ON v.test_definition_version_id = m.test_definition_version_id
   WHERE m.test_catalog_manifest_id = NEW.test_catalog_manifest_id
     AND m.membership = 'excluded'
     AND v.severity = 'P0';

  SELECT count(*) INTO policy_mismatch_count
    FROM test_catalog_definition_member m
    JOIN test_definition_version v
      ON v.test_definition_version_id = m.test_definition_version_id
   WHERE m.test_catalog_manifest_id = NEW.test_catalog_manifest_id
     AND v.test_governance_policy_version <> NEW.test_governance_policy_version;

  WITH expected AS (
    SELECT DISTINCT ON (test_id) test_definition_version_id
      FROM test_definition_version
     ORDER BY test_id, definition_revision DESC
  ),
  expected_for_phase AS (
    SELECT e.test_definition_version_id
      FROM expected e
      JOIN test_definition_version v USING (test_definition_version_id)
     WHERE v.introduced_phase <= NEW.target_phase
  ),
  mismatch AS (
    SELECT test_definition_version_id FROM expected_for_phase
    EXCEPT
    SELECT test_definition_version_id
      FROM test_catalog_definition_member
     WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id
    UNION ALL
    SELECT test_definition_version_id
      FROM test_catalog_definition_member
     WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id
    EXCEPT
    SELECT test_definition_version_id FROM expected_for_phase
  )
  SELECT count(*) INTO set_mismatch_count FROM mismatch;

  SELECT encode(
           digest(
             string_agg(
               test_definition_version_id::text || '|' || membership::text,
               E'\n' ORDER BY test_definition_version_id
             ),
             'sha256'
           ),
           'hex'
         )
    INTO calculated_hash
    FROM test_catalog_definition_member
   WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id;

  IF expected_count = 0
     OR member_count <> expected_count
     OR p0_excluded_count <> 0
     OR policy_mismatch_count <> 0
     OR set_mismatch_count <> 0
     OR calculated_hash IS DISTINCT FROM NEW.definitions_universe_hash THEN
    RAISE EXCEPTION 'test catalog is not a complete fail-closed definition universe';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER test_catalog_closure_guard
AFTER INSERT ON test_catalog_manifest
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_test_catalog_closure();

CREATE TABLE test_run (
  test_run_id uuid PRIMARY KEY,
  test_catalog_manifest_id uuid NOT NULL REFERENCES test_catalog_manifest,
  code_revision text NOT NULL,
  environment_fingerprint text NOT NULL,
  fixture_version text NOT NULL,
  config_version text NOT NULL,
  executor_service_principal_id uuid NOT NULL REFERENCES service_principal,
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (started_at <= completed_at),
  CHECK (recorded_at <= system_available_at),
  UNIQUE (test_run_id, test_catalog_manifest_id)
);

CREATE TABLE test_result (
  test_result_id uuid PRIMARY KEY,
  test_run_id uuid NOT NULL REFERENCES test_run,
  test_definition_version_id uuid NOT NULL REFERENCES test_definition_version,
  actual text NOT NULL CHECK (btrim(actual) <> ''),
  result test_result_status NOT NULL,
  reason_codes text[] NOT NULL,
  log_artifact_ids uuid[] NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (
    (result = 'pass' AND cardinality(reason_codes) = 0)
    OR
    (result <> 'pass' AND cardinality(reason_codes) > 0)
  ),
  UNIQUE (test_run_id, test_definition_version_id)
);

CREATE OR REPLACE FUNCTION validate_test_result_membership()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  catalog_membership test_catalog_membership;
BEGIN
  SELECT m.membership INTO catalog_membership
    FROM test_run r
    JOIN test_catalog_definition_member m
      ON m.test_catalog_manifest_id = r.test_catalog_manifest_id
   WHERE r.test_run_id = NEW.test_run_id
     AND m.test_definition_version_id = NEW.test_definition_version_id;

  IF catalog_membership IS NULL THEN
    RAISE EXCEPTION 'test result definition is not in the run catalog';
  END IF;

  IF (catalog_membership = 'excluded' AND NEW.result <> 'not_applicable')
     OR (catalog_membership = 'applicable' AND NEW.result = 'not_applicable') THEN
    RAISE EXCEPTION 'test result status contradicts catalog applicability';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_result_membership_guard
BEFORE INSERT ON test_result
FOR EACH ROW EXECUTE FUNCTION validate_test_result_membership();

CREATE TABLE gate_decision (
  gate_decision_id uuid PRIMARY KEY,
  test_catalog_manifest_id uuid NOT NULL,
  test_run_id uuid NOT NULL,
  target_phase test_phase NOT NULL,
  target_gate test_blocking_mode NOT NULL,
  decision gate_decision_status NOT NULL,
  required_result_count integer NOT NULL CHECK (required_result_count >= 0),
  blocking_result_count integer NOT NULL CHECK (blocking_result_count >= 0),
  unpassed_definition_version_ids uuid[] NOT NULL,
  test_waiver_ids uuid[] NOT NULL CHECK (cardinality(test_waiver_ids) = 0),
  approval_decision_ids uuid[] NOT NULL CHECK (cardinality(approval_decision_ids) = 0),
  decided_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (test_run_id, test_catalog_manifest_id)
    REFERENCES test_run (test_run_id, test_catalog_manifest_id),
  UNIQUE (test_catalog_manifest_id, test_run_id)
);

CREATE OR REPLACE FUNCTION validate_gate_decision_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  catalog_phase test_phase;
  catalog_gate test_blocking_mode;
  applicable_count integer;
  member_count integer;
  result_count integer;
  blocking_count integer;
  unpassed_ids uuid[];
BEGIN
  SELECT target_phase, target_gate
    INTO catalog_phase, catalog_gate
    FROM test_catalog_manifest
   WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id;

  IF catalog_phase IS NULL
     OR catalog_phase <> NEW.target_phase
     OR catalog_gate <> NEW.target_gate THEN
    RAISE EXCEPTION 'gate decision target does not match catalog';
  END IF;

  SELECT count(*) INTO member_count
    FROM test_catalog_definition_member
   WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id;

  SELECT count(*) INTO applicable_count
    FROM test_catalog_definition_member
   WHERE test_catalog_manifest_id = NEW.test_catalog_manifest_id
     AND membership = 'applicable';

  SELECT count(*) INTO result_count
    FROM test_result
   WHERE test_run_id = NEW.test_run_id;

  SELECT count(*) INTO blocking_count
    FROM test_catalog_definition_member m
    JOIN test_definition_version v
      ON v.test_definition_version_id = m.test_definition_version_id
    JOIN test_result r
      ON r.test_run_id = NEW.test_run_id
     AND r.test_definition_version_id = m.test_definition_version_id
   WHERE m.test_catalog_manifest_id = NEW.test_catalog_manifest_id
     AND m.membership = 'applicable'
     AND r.result IN ('fail', 'blocked')
     AND (v.blocking = NEW.target_gate
       OR (v.blocking = 'phase-exit' AND NEW.target_gate = 'phase-exit'));

  SELECT coalesce(array_agg(m.test_definition_version_id ORDER BY m.test_definition_version_id), ARRAY[]::uuid[])
    INTO unpassed_ids
    FROM test_catalog_definition_member m
    JOIN test_result r
      ON r.test_run_id = NEW.test_run_id
     AND r.test_definition_version_id = m.test_definition_version_id
   WHERE m.test_catalog_manifest_id = NEW.test_catalog_manifest_id
     AND m.membership = 'applicable'
     AND r.result IN ('fail', 'blocked');

  IF member_count <> result_count
     OR NEW.required_result_count <> applicable_count
     OR NEW.blocking_result_count <> blocking_count
     OR NEW.unpassed_definition_version_ids <> unpassed_ids
     OR ((blocking_count = 0) <> (NEW.decision = 'pass')) THEN
    RAISE EXCEPTION 'gate decision is not closed over catalog results';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER gate_decision_closure_guard
AFTER INSERT ON gate_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_gate_decision_closure();

CREATE TYPE approval_status AS ENUM ('approved', 'rejected');
CREATE TYPE gate_evaluation_status AS ENUM ('closed', 'blocked');
CREATE TYPE gate_selection_status AS ENUM ('selected', 'blocked');

CREATE TABLE approval_decision (
  approval_decision_id uuid PRIMARY KEY,
  subject_kind text NOT NULL,
  subject_id uuid NOT NULL,
  old_hash text NOT NULL CHECK (old_hash ~ '^[a-f0-9]{64}$'),
  new_hash text NOT NULL CHECK (new_hash ~ '^[a-f0-9]{64}$'),
  structured_diff text NOT NULL CHECK (btrim(structured_diff) <> ''),
  impact_summary text NOT NULL CHECK (btrim(impact_summary) <> ''),
  decision approval_status NOT NULL,
  approver_service_principal_id uuid NOT NULL REFERENCES service_principal,
  quorum_count integer NOT NULL CHECK (quorum_count > 0),
  effective_from timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  manifest_signature text NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE test_waiver (
  waiver_id uuid PRIMARY KEY,
  test_definition_version_id uuid NOT NULL REFERENCES test_definition_version,
  approval_decision_id uuid NOT NULL REFERENCES approval_decision,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  manifest_signature text NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (issued_at < expires_at),
  CHECK (recorded_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_test_waiver()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  definition_severity test_severity;
  definition_waiver_allowed boolean;
  approval_result approval_status;
BEGIN
  SELECT v.severity, v.waiver_allowed
    INTO definition_severity, definition_waiver_allowed
    FROM test_definition_version v
   WHERE v.test_definition_version_id = NEW.test_definition_version_id;

  SELECT decision INTO approval_result
    FROM approval_decision
   WHERE approval_decision_id = NEW.approval_decision_id;

  IF definition_severity IS NULL
     OR definition_severity = 'P0'
     OR NOT definition_waiver_allowed
     OR approval_result IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'test waiver is not permitted for this definition';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_waiver_guard
BEFORE INSERT ON test_waiver
FOR EACH ROW EXECUTE FUNCTION validate_test_waiver();

CREATE TABLE gate_evaluation_unit (
  gate_evaluation_unit_id uuid PRIMARY KEY,
  test_catalog_manifest_id uuid NOT NULL REFERENCES test_catalog_manifest,
  target_phase test_phase NOT NULL,
  target_gate test_blocking_mode NOT NULL,
  input_hash text NOT NULL CHECK (input_hash ~ '^[a-f0-9]{64}$'),
  expected_run_count integer NOT NULL CHECK (expected_run_count > 0),
  max_attempts integer NOT NULL CHECK (max_attempts >= expected_run_count),
  retry_policy text NOT NULL CHECK (btrim(retry_policy) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (test_catalog_manifest_id, target_phase, target_gate, input_hash)
);

CREATE TABLE gate_run_attempt_membership (
  gate_run_attempt_membership_id uuid PRIMARY KEY,
  gate_evaluation_unit_id uuid NOT NULL REFERENCES gate_evaluation_unit,
  test_run_id uuid NOT NULL REFERENCES test_run,
  attempt_ordinal integer NOT NULL CHECK (attempt_ordinal > 0),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (gate_evaluation_unit_id, attempt_ordinal),
  UNIQUE (gate_evaluation_unit_id, test_run_id)
);

CREATE OR REPLACE FUNCTION validate_gate_run_attempt_membership()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  unit_catalog_id uuid;
  run_catalog_id uuid;
BEGIN
  SELECT test_catalog_manifest_id INTO unit_catalog_id
    FROM gate_evaluation_unit
   WHERE gate_evaluation_unit_id = NEW.gate_evaluation_unit_id;
  SELECT test_catalog_manifest_id INTO run_catalog_id
    FROM test_run
   WHERE test_run_id = NEW.test_run_id;

  IF unit_catalog_id IS NULL
     OR run_catalog_id IS NULL
     OR unit_catalog_id <> run_catalog_id THEN
    RAISE EXCEPTION 'gate run attempt is outside the evaluation catalog';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER gate_run_attempt_catalog_guard
BEFORE INSERT ON gate_run_attempt_membership
FOR EACH ROW EXECUTE FUNCTION validate_gate_run_attempt_membership();

CREATE TABLE gate_evaluation_closure_decision (
  gate_evaluation_closure_decision_id uuid PRIMARY KEY,
  gate_evaluation_unit_id uuid NOT NULL UNIQUE REFERENCES gate_evaluation_unit,
  status gate_evaluation_status NOT NULL,
  expected_run_count integer NOT NULL CHECK (expected_run_count > 0),
  observed_run_count integer NOT NULL CHECK (observed_run_count >= 0),
  result_set_hash text NOT NULL CHECK (result_set_hash ~ '^[a-f0-9]{64}$'),
  closed_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_gate_evaluation_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  unit_expected_count integer;
  member_count integer;
  terminal_count integer;
  blocked_count integer;
  calculated_hash text;
  unit_catalog_id uuid;
BEGIN
  SELECT expected_run_count, test_catalog_manifest_id
    INTO unit_expected_count, unit_catalog_id
    FROM gate_evaluation_unit
   WHERE gate_evaluation_unit_id = NEW.gate_evaluation_unit_id;

  SELECT count(*) INTO member_count
    FROM gate_run_attempt_membership
   WHERE gate_evaluation_unit_id = NEW.gate_evaluation_unit_id;

  SELECT count(*) INTO terminal_count
    FROM gate_run_attempt_membership m
    JOIN gate_decision g
      ON g.test_run_id = m.test_run_id
     AND g.test_catalog_manifest_id = unit_catalog_id
   WHERE m.gate_evaluation_unit_id = NEW.gate_evaluation_unit_id;

  SELECT count(*) INTO blocked_count
    FROM gate_run_attempt_membership m
    JOIN gate_decision g
      ON g.test_run_id = m.test_run_id
     AND g.test_catalog_manifest_id = unit_catalog_id
   WHERE m.gate_evaluation_unit_id = NEW.gate_evaluation_unit_id
     AND g.decision = 'blocked';

  SELECT encode(
           digest(
             string_agg(
               m.test_run_id::text || '|' || g.decision::text,
               E'\n' ORDER BY m.attempt_ordinal
             ),
             'sha256'
           ),
           'hex'
         )
    INTO calculated_hash
    FROM gate_run_attempt_membership m
    JOIN gate_decision g
      ON g.test_run_id = m.test_run_id
     AND g.test_catalog_manifest_id = unit_catalog_id
   WHERE m.gate_evaluation_unit_id = NEW.gate_evaluation_unit_id;

  IF NEW.expected_run_count <> unit_expected_count
     OR NEW.observed_run_count <> member_count
     OR member_count <> unit_expected_count
     OR terminal_count <> member_count
     OR calculated_hash IS DISTINCT FROM NEW.result_set_hash
     OR NEW.status <> (CASE WHEN blocked_count > 0
                        THEN 'blocked'::gate_evaluation_status
                        ELSE 'closed'::gate_evaluation_status END) THEN
    RAISE EXCEPTION 'gate evaluation is not a complete terminal run set';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER gate_evaluation_closure_guard
AFTER INSERT ON gate_evaluation_closure_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_gate_evaluation_closure();

CREATE TABLE gate_run_selection_decision (
  gate_run_selection_decision_id uuid PRIMARY KEY,
  gate_evaluation_closure_decision_id uuid NOT NULL UNIQUE
    REFERENCES gate_evaluation_closure_decision,
  selection_status gate_selection_status NOT NULL,
  selected_test_run_id uuid REFERENCES test_run,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (
    (selection_status = 'selected' AND selected_test_run_id IS NOT NULL)
    OR
    (selection_status = 'blocked' AND selected_test_run_id IS NULL)
  )
);

CREATE OR REPLACE FUNCTION validate_gate_run_selection()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  closure_status gate_evaluation_status;
  unit_id uuid;
  selected_membership_count integer;
  selected_gate_status gate_decision_status;
BEGIN
  SELECT c.status, c.gate_evaluation_unit_id
    INTO closure_status, unit_id
    FROM gate_evaluation_closure_decision c
   WHERE c.gate_evaluation_closure_decision_id = NEW.gate_evaluation_closure_decision_id;

  SELECT count(*) INTO selected_membership_count
    FROM gate_run_attempt_membership m
   WHERE m.gate_evaluation_unit_id = unit_id
     AND m.test_run_id = NEW.selected_test_run_id;

  SELECT g.decision INTO selected_gate_status
    FROM gate_run_attempt_membership m
    JOIN gate_evaluation_unit u ON u.gate_evaluation_unit_id = m.gate_evaluation_unit_id
    JOIN gate_decision g
      ON g.test_run_id = m.test_run_id
     AND g.test_catalog_manifest_id = u.test_catalog_manifest_id
   WHERE m.gate_evaluation_unit_id = unit_id
     AND m.test_run_id = NEW.selected_test_run_id;

  IF closure_status = 'blocked'
     AND (NEW.selection_status <> 'blocked' OR NEW.selected_test_run_id IS NOT NULL)
     OR closure_status = 'closed'
     AND (NEW.selection_status <> 'selected'
       OR selected_membership_count <> 1
       OR selected_gate_status <> 'pass') THEN
    RAISE EXCEPTION 'gate run selection contradicts evaluation closure';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER gate_run_selection_guard
AFTER INSERT ON gate_run_selection_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_gate_run_selection();

CREATE OR REPLACE FUNCTION reject_row_mutation()
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
    'manifest_series',
    'manifest_activation_decision',
    'service_principal',
    'service_principal_credential_version',
    'service_principal_credential_state_event',
    'model_invocation',
    'provider_response_set_profile',
    'provider_response_set',
    'provider_response_member_unit',
    'provider_response_member_decision',
    'provider_response_receipt',
    'model_output_artifact',
    'provider_response_set_closure',
    'token_use_policy_manifest',
    'presentation_capability_token',
    'token_use_unit',
    'token_use_decision',
    'token_use_ledger_checkpoint',
    'evaluation_arm_manifest',
    'evaluation_arm_generation_unit',
    'evaluation_arm_generation_decision',
    'evaluation_obligation',
    'evaluation_snapshot_decision',
    'evaluation_result',
    'evaluation_arm_output_snapshot',
    'test_definition',
    'test_governance_policy',
    'test_definition_version',
    'test_catalog_manifest',
    'test_catalog_definition_member',
    'test_run',
    'test_result',
    'gate_decision',
    'approval_decision',
    'test_waiver',
    'gate_evaluation_unit',
    'gate_run_attempt_membership',
    'gate_evaluation_closure_decision',
    'gate_run_selection_decision'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_row_mutation()',
      immutable_table || '_reject_mutation',
      immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
