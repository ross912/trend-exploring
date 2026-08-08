-- M1 private/global data-domain enforcement slice.

BEGIN;

CREATE TYPE data_domain AS ENUM ('personal', 'global');
CREATE TYPE global_query_payload_class AS ENUM ('neutral_query', 'public_only_input_snapshot');

CREATE TABLE global_service_principal (
  global_service_principal_id uuid PRIMARY KEY REFERENCES service_principal,
  principal_name text NOT NULL UNIQUE REFERENCES service_principal(principal_name),
  role_key text NOT NULL CHECK (btrim(role_key) <> ''),
  effective_from timestamptz NOT NULL,
  expires_at timestamptz,
  system_available_at timestamptz NOT NULL,
  CHECK (expires_at IS NULL OR effective_from < expires_at),
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE global_service_principal_database_role (
  global_service_principal_id uuid PRIMARY KEY REFERENCES global_service_principal,
  database_role_name text NOT NULL CHECK (btrim(database_role_name) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE TABLE personal_scope (
  personal_scope_id uuid PRIMARY KEY,
  owner_principal_key text NOT NULL CHECK (btrim(owner_principal_key) <> ''),
  authz_epoch bigint NOT NULL CHECK (authz_epoch > 0),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

CREATE TABLE private_query_context (
  private_query_context_id uuid PRIMARY KEY,
  personal_scope_id uuid NOT NULL REFERENCES personal_scope,
  query_text text NOT NULL CHECK (btrim(query_text) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at)
);

ALTER TABLE personal_scope ENABLE ROW LEVEL SECURITY;
ALTER TABLE private_query_context ENABLE ROW LEVEL SECURITY;
CREATE POLICY personal_scope_owner_policy ON personal_scope
  USING (owner_principal_key = current_setting('m1.owner_principal', true));
CREATE POLICY private_query_context_owner_policy ON private_query_context
  USING (EXISTS (
    SELECT 1 FROM personal_scope p
     WHERE p.personal_scope_id = private_query_context.personal_scope_id
       AND p.owner_principal_key = current_setting('m1.owner_principal', true)
  ));

CREATE TABLE global_query_execution (
  global_query_execution_id uuid PRIMARY KEY,
  payload_class global_query_payload_class NOT NULL,
  payload text NOT NULL CHECK (btrim(payload) <> ''),
  retention_seconds integer NOT NULL CHECK (retention_seconds BETWEEN 1 AND 300),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (payload_class = 'neutral_query')
);

CREATE TABLE public_only_input_snapshot (
  public_only_input_snapshot_id uuid PRIMARY KEY,
  snapshot_frozen_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  private_lineage_count integer NOT NULL CHECK (private_lineage_count = 0),
  source_domain data_domain NOT NULL CHECK (source_domain = 'global'),
  snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[a-f0-9]{64}$'),
  CHECK (as_of <= snapshot_frozen_at),
  CHECK (snapshot_frozen_at <= system_available_at)
);

CREATE TABLE public_only_input_member (
  public_only_input_member_id uuid PRIMARY KEY,
  public_only_input_snapshot_id uuid NOT NULL REFERENCES public_only_input_snapshot,
  source_record_id uuid NOT NULL,
  source_record_kind text NOT NULL CHECK (btrim(source_record_kind) <> ''),
  source_domain data_domain NOT NULL CHECK (source_domain = 'global'),
  private_lineage_count integer NOT NULL CHECK (private_lineage_count = 0),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (public_only_input_snapshot_id, source_record_id, source_record_kind)
);

CREATE OR REPLACE FUNCTION assert_global_service_principal(p_at timestamptz)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  session_principal text := current_setting('m1.service_principal', true);
  principal_id uuid;
BEGIN
  SELECT global_service_principal_id INTO principal_id
    FROM global_service_principal
   WHERE principal_name = session_principal
     AND effective_from <= p_at
     AND (expires_at IS NULL OR p_at < expires_at);
  IF principal_id IS NULL OR NOT EXISTS (
    SELECT 1
      FROM global_service_principal_database_role r
     WHERE r.global_service_principal_id = principal_id
       AND r.database_role_name = current_user
  ) THEN
    RAISE EXCEPTION 'global data access requires an authorized global service principal';
  END IF;
  RETURN principal_id;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_global_service_principal()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM assert_global_service_principal(NEW.system_available_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER global_query_execution_identity_guard
BEFORE INSERT ON global_query_execution
FOR EACH ROW EXECUTE FUNCTION enforce_global_service_principal();

CREATE TRIGGER public_only_input_snapshot_identity_guard
BEFORE INSERT ON public_only_input_snapshot
FOR EACH ROW EXECUTE FUNCTION enforce_global_service_principal();

CREATE TRIGGER public_only_input_member_identity_guard
BEFORE INSERT ON public_only_input_member
FOR EACH ROW EXECUTE FUNCTION enforce_global_service_principal();

CREATE OR REPLACE FUNCTION reject_data_domain_mutation()
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
    'global_service_principal', 'global_service_principal_database_role', 'personal_scope', 'private_query_context', 'global_query_execution',
    'public_only_input_snapshot', 'public_only_input_member'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_data_domain_mutation()',
      immutable_table || '_reject_mutation', immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
