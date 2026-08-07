-- M1 source/rights/archive vertical slice.
-- Covers collection-opportunity denominator, purpose separation, immutable raw
-- item versions, storage modes, preservation restore, format migration and the
-- language-evaluation contract used by the M1 phase-exit tests.

BEGIN;

CREATE TYPE ownership_relation_status AS ENUM ('known', 'unknown');
CREATE TYPE collection_opportunity_state AS ENUM ('scheduled', 'succeeded', 'failed', 'excluded', 'missed');
CREATE TYPE purpose_authorization_decision AS ENUM ('allow', 'deny');
CREATE TYPE raw_storage_mode AS ENUM ('full_bytes', 'licensed_excerpt', 'metadata_only', 'external_pointer');
CREATE TYPE artifact_binding_state AS ENUM ('active', 'revoked');

CREATE TABLE owner_group (
  owner_group_id uuid PRIMARY KEY,
  owner_group_key text NOT NULL UNIQUE,
  system_available_at timestamptz NOT NULL
);

CREATE TABLE publisher_account (
  publisher_account_id uuid PRIMARY KEY,
  publisher_account_key text NOT NULL UNIQUE,
  owner_group_id uuid REFERENCES owner_group,
  ownership_relation ownership_relation_status NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (ownership_relation = 'known' OR owner_group_id IS NULL)
);

CREATE TABLE collection_opportunity (
  collection_opportunity_id uuid PRIMARY KEY,
  source_endpoint_id uuid NOT NULL,
  publisher_account_id uuid,
  planned_for timestamptz NOT NULL,
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  planned_cadence text NOT NULL CHECK (btrim(planned_cadence) <> ''),
  acquisition_purpose text NOT NULL DEFAULT 'O_acquire'
    CHECK (acquisition_purpose = 'O_acquire'),
  system_available_at timestamptz NOT NULL,
  CHECK (window_start < window_end),
  CHECK (window_start <= planned_for AND planned_for < window_end),
  UNIQUE (source_endpoint_id, planned_for)
);

CREATE TABLE collection_opportunity_state_event (
  collection_opportunity_state_event_id uuid PRIMARY KEY,
  collection_opportunity_id uuid NOT NULL REFERENCES collection_opportunity,
  aggregate_revision bigint NOT NULL CHECK (aggregate_revision > 0),
  predecessor_event_id uuid,
  predecessor_revision bigint,
  from_state collection_opportunity_state NOT NULL,
  to_state collection_opportunity_state NOT NULL,
  reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
  valid_at timestamptz NOT NULL,
  event_system_available_at timestamptz NOT NULL,
  UNIQUE (collection_opportunity_id, aggregate_revision),
  UNIQUE (
    collection_opportunity_state_event_id,
    collection_opportunity_id,
    aggregate_revision,
    to_state
  ),
  CHECK (
    (aggregate_revision = 1 AND predecessor_event_id IS NULL AND predecessor_revision IS NULL
      AND from_state = 'scheduled')
    OR
    (aggregate_revision > 1 AND predecessor_event_id IS NOT NULL
      AND predecessor_revision = aggregate_revision - 1)
  ),
  FOREIGN KEY (
    predecessor_event_id,
    collection_opportunity_id,
    predecessor_revision,
    from_state
  ) REFERENCES collection_opportunity_state_event (
    collection_opportunity_state_event_id,
    collection_opportunity_id,
    aggregate_revision,
    to_state
  ) DEFERRABLE INITIALLY DEFERRED
);

CREATE OR REPLACE FUNCTION lock_collection_opportunity_for_state_event()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  current_revision bigint;
BEGIN
  PERFORM 1 FROM collection_opportunity
   WHERE collection_opportunity_id = NEW.collection_opportunity_id
   FOR UPDATE;
  SELECT max(aggregate_revision) INTO current_revision
    FROM collection_opportunity_state_event
   WHERE collection_opportunity_id = NEW.collection_opportunity_id;
  IF NEW.aggregate_revision = 1 AND current_revision IS NOT NULL THEN
    RAISE EXCEPTION 'collection opportunity already has a state head';
  END IF;
  IF NEW.aggregate_revision > 1
     AND current_revision IS DISTINCT FROM NEW.aggregate_revision - 1 THEN
    RAISE EXCEPTION 'collection opportunity state revision is not the expected head';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER collection_opportunity_state_head_guard
BEFORE INSERT ON collection_opportunity_state_event
FOR EACH ROW EXECUTE FUNCTION lock_collection_opportunity_for_state_event();

CREATE TABLE capture (
  capture_id uuid PRIMARY KEY,
  collection_opportunity_id uuid NOT NULL REFERENCES collection_opportunity,
  capture_status text NOT NULL CHECK (capture_status IN ('success', 'failed', 'empty')),
  raw_item_id uuid,
  observed_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  UNIQUE (collection_opportunity_id)
);

CREATE TABLE raw_item (
  raw_item_id uuid PRIMARY KEY,
  source_endpoint_id uuid NOT NULL,
  source_item_key text NOT NULL,
  identity_created_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  UNIQUE (source_endpoint_id, source_item_key),
  CHECK (identity_created_at <= system_available_at)
);

CREATE TABLE raw_item_version (
  raw_item_version_id uuid PRIMARY KEY,
  raw_item_id uuid NOT NULL REFERENCES raw_item,
  version_ordinal bigint NOT NULL CHECK (version_ordinal > 0),
  previous_version_id uuid,
  title_text text NOT NULL,
  body_checksum text NOT NULL CHECK (body_checksum ~ '^[a-f0-9]{64}$'),
  source_published_at timestamptz,
  version_observed_at timestamptz NOT NULL,
  version_available_at timestamptz NOT NULL,
  item_first_seen_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (version_observed_at <= version_available_at),
  CHECK (item_first_seen_at <= version_observed_at),
  CHECK (
    (version_ordinal = 1 AND previous_version_id IS NULL)
    OR
    (version_ordinal > 1 AND previous_version_id IS NOT NULL)
  ),
  UNIQUE (raw_item_id, version_ordinal),
  UNIQUE (raw_item_version_id, raw_item_id, version_ordinal),
  FOREIGN KEY (previous_version_id)
    REFERENCES raw_item_version (raw_item_version_id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE OR REPLACE FUNCTION validate_raw_item_version_head()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  current_ordinal bigint;
  previous_item_id uuid;
  previous_ordinal bigint;
BEGIN
  SELECT max(version_ordinal) INTO current_ordinal
    FROM raw_item_version
   WHERE raw_item_id = NEW.raw_item_id;
  IF NEW.version_ordinal > 1
     AND current_ordinal IS DISTINCT FROM NEW.version_ordinal - 1 THEN
    RAISE EXCEPTION 'raw item version must extend the current ordinal head';
  END IF;
  IF NEW.previous_version_id IS NOT NULL THEN
    SELECT raw_item_id, version_ordinal INTO previous_item_id, previous_ordinal
      FROM raw_item_version
     WHERE raw_item_version_id = NEW.previous_version_id;
    IF previous_item_id IS DISTINCT FROM NEW.raw_item_id
       OR previous_ordinal IS DISTINCT FROM NEW.version_ordinal - 1 THEN
      RAISE EXCEPTION 'raw item version predecessor is not the prior version';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER raw_item_version_head_guard
BEFORE INSERT ON raw_item_version
FOR EACH ROW EXECUTE FUNCTION validate_raw_item_version_head();

CREATE TABLE purpose_authorization (
  purpose_authorization_id uuid PRIMARY KEY,
  raw_item_version_id uuid NOT NULL REFERENCES raw_item_version,
  purpose text NOT NULL CHECK (
    purpose IN (
      'O_acquire', 'O_extract', 'O_model:local', 'O_model:provider',
      'O_train', 'O_signal', 'O_display', 'O_prevalence'
    )
  ),
  processor_key text NOT NULL CHECK (btrim(processor_key) <> ''),
  decision purpose_authorization_decision NOT NULL,
  rights_grant_key text,
  authorized_scope_key text,
  allowed_transform text,
  max_display_chars integer CHECK (max_display_chars IS NULL OR max_display_chars >= 0),
  checked_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revocation_epoch bigint NOT NULL CHECK (revocation_epoch >= 0),
  deny_reason text,
  system_available_at timestamptz NOT NULL,
  CHECK (checked_at < expires_at),
  CHECK (
    (decision = 'allow' AND rights_grant_key IS NOT NULL AND authorized_scope_key IS NOT NULL
      AND deny_reason IS NULL)
    OR
    (decision = 'deny' AND btrim(coalesce(deny_reason, '')) <> '')
  ),
  UNIQUE (raw_item_version_id, purpose, processor_key)
);

CREATE OR REPLACE FUNCTION assert_purpose_authorized(
  p_raw_item_version_id uuid,
  p_purpose text,
  p_processor_key text,
  p_at timestamptz,
  p_display_chars integer DEFAULT 0,
  p_transform text DEFAULT 'identity'
)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_authorization purpose_authorization%ROWTYPE;
BEGIN
  SELECT * INTO v_authorization
    FROM purpose_authorization
   WHERE raw_item_version_id = p_raw_item_version_id
     AND purpose = p_purpose
     AND processor_key = p_processor_key;
  IF NOT FOUND
     OR v_authorization.decision <> 'allow'
     OR p_at < v_authorization.checked_at
     OR p_at >= v_authorization.expires_at
     OR (p_purpose = 'O_display' AND (v_authorization.max_display_chars IS NULL
       OR p_display_chars > v_authorization.max_display_chars))
     OR (v_authorization.allowed_transform IS NOT NULL
       AND v_authorization.allowed_transform <> p_transform) THEN
    IF p_purpose = 'O_train' THEN
      RAISE EXCEPTION 'PURPOSE_TRAIN_DENIED';
    ELSE
      RAISE EXCEPTION 'PURPOSE_%_DENIED', upper(replace(split_part(p_purpose, ':', 1), 'O_', ''));
    END IF;
  END IF;
  RETURN true;
END;
$$;

CREATE TABLE preservation_manifest_version (
  preservation_manifest_version_id uuid PRIMARY KEY,
  preservation_policy_version text NOT NULL,
  checksum_algorithm text NOT NULL,
  schema_version text NOT NULL,
  schema_hash text NOT NULL CHECK (schema_hash ~ '^[a-f0-9]{64}$'),
  manifest_signature text NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE storage_blob (
  storage_blob_id uuid PRIMARY KEY,
  content_checksum text NOT NULL CHECK (content_checksum ~ '^[a-f0-9]{64}$'),
  byte_length bigint NOT NULL CHECK (byte_length > 0),
  encryption_key_version text NOT NULL,
  system_available_at timestamptz NOT NULL
);

CREATE TABLE raw_artifact (
  raw_artifact_id uuid PRIMARY KEY,
  raw_item_version_id uuid REFERENCES raw_item_version,
  storage_mode raw_storage_mode NOT NULL,
  storage_blob_id uuid REFERENCES storage_blob DEFERRABLE INITIALLY DEFERRED,
  content_checksum text CHECK (content_checksum ~ '^[a-f0-9]{64}$'),
  excerpt_text text,
  metadata_checksum text CHECK (metadata_checksum ~ '^[a-f0-9]{64}$'),
  external_uri text,
  preservation_manifest_version_id uuid REFERENCES preservation_manifest_version,
  derived_from_artifact_id uuid REFERENCES raw_artifact DEFERRABLE INITIALLY DEFERRED,
  system_available_at timestamptz NOT NULL,
  CHECK (
    (storage_mode = 'full_bytes'
      AND storage_blob_id IS NOT NULL AND content_checksum IS NOT NULL
      AND excerpt_text IS NULL AND preservation_manifest_version_id IS NOT NULL
      AND external_uri IS NULL)
    OR
    (storage_mode = 'licensed_excerpt'
      AND storage_blob_id IS NOT NULL AND content_checksum IS NOT NULL
      AND excerpt_text IS NOT NULL AND preservation_manifest_version_id IS NOT NULL
      AND external_uri IS NULL)
    OR
    (storage_mode = 'metadata_only' AND storage_blob_id IS NULL
      AND content_checksum IS NULL AND excerpt_text IS NULL
      AND metadata_checksum IS NOT NULL AND external_uri IS NULL
      AND preservation_manifest_version_id IS NULL)
    OR
    (storage_mode = 'external_pointer' AND storage_blob_id IS NULL
      AND content_checksum IS NULL AND excerpt_text IS NULL
      AND metadata_checksum IS NULL AND external_uri IS NOT NULL
      AND preservation_manifest_version_id IS NULL)
  )
);

CREATE TABLE artifact_blob_binding (
  artifact_blob_binding_id uuid PRIMARY KEY,
  raw_artifact_id uuid NOT NULL REFERENCES raw_artifact DEFERRABLE INITIALLY DEFERRED,
  storage_blob_id uuid NOT NULL REFERENCES storage_blob,
  binding_revision bigint NOT NULL CHECK (binding_revision > 0),
  binding_state artifact_binding_state NOT NULL,
  legal_identity_key text NOT NULL,
  system_available_at timestamptz NOT NULL,
  UNIQUE (raw_artifact_id, binding_revision)
);

CREATE OR REPLACE FUNCTION validate_raw_artifact_mode()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  active_binding_count integer;
  binding_blob_id uuid;
BEGIN
  SELECT count(*)
    INTO active_binding_count
    FROM artifact_blob_binding
   WHERE raw_artifact_id = NEW.raw_artifact_id
     AND binding_state = 'active';
  SELECT storage_blob_id INTO binding_blob_id
    FROM artifact_blob_binding
   WHERE raw_artifact_id = NEW.raw_artifact_id
     AND binding_state = 'active'
   ORDER BY artifact_blob_binding_id
   LIMIT 1;
  IF NEW.storage_mode IN ('full_bytes', 'licensed_excerpt')
     AND (active_binding_count <> 1 OR binding_blob_id <> NEW.storage_blob_id) THEN
    RAISE EXCEPTION 'raw artifact content mode requires one active matching blob binding';
  END IF;
  IF NEW.storage_mode IN ('metadata_only', 'external_pointer') AND active_binding_count <> 0 THEN
    RAISE EXCEPTION 'metadata-only or external-pointer artifact cannot have a content binding';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER raw_artifact_mode_guard
AFTER INSERT ON raw_artifact
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_raw_artifact_mode();

CREATE TABLE restore_test_event (
  restore_test_event_id uuid PRIMARY KEY,
  preservation_manifest_version_id uuid NOT NULL REFERENCES preservation_manifest_version,
  raw_artifact_id uuid NOT NULL REFERENCES raw_artifact,
  restored_checksum text NOT NULL CHECK (restored_checksum ~ '^[a-f0-9]{64}$'),
  stable_ids_match boolean NOT NULL,
  foreign_keys_match boolean NOT NULL,
  rights_match boolean NOT NULL,
  deletion_checkpoint_match boolean NOT NULL,
  rpo_seconds integer NOT NULL CHECK (rpo_seconds >= 0),
  rto_seconds integer NOT NULL CHECK (rto_seconds >= 0),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (stable_ids_match AND foreign_keys_match AND rights_match AND deletion_checkpoint_match)
);

CREATE TABLE format_migration_event (
  format_migration_event_id uuid PRIMARY KEY,
  source_raw_artifact_id uuid NOT NULL REFERENCES raw_artifact,
  derivative_raw_artifact_id uuid NOT NULL REFERENCES raw_artifact,
  source_checksum text NOT NULL CHECK (source_checksum ~ '^[a-f0-9]{64}$'),
  parser_tool_provenance text NOT NULL CHECK (btrim(parser_tool_provenance) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (source_raw_artifact_id <> derivative_raw_artifact_id),
  CHECK (recorded_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_format_migration()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  source_checksum text;
  derivative_parent uuid;
BEGIN
  SELECT source_artifact.content_checksum, derivative_artifact.derived_from_artifact_id
    INTO source_checksum, derivative_parent
    FROM raw_artifact AS source_artifact
    JOIN raw_artifact AS derivative_artifact
      ON derivative_artifact.raw_artifact_id = NEW.derivative_raw_artifact_id
   WHERE source_artifact.raw_artifact_id = NEW.source_raw_artifact_id;
  IF source_checksum IS NULL OR source_checksum <> NEW.source_checksum
     OR derivative_parent IS DISTINCT FROM NEW.source_raw_artifact_id THEN
    RAISE EXCEPTION 'format migration provenance does not preserve the source artifact';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER format_migration_guard
BEFORE INSERT ON format_migration_event
FOR EACH ROW EXECUTE FUNCTION validate_format_migration();

CREATE TABLE language_evaluation_manifest (
  language_evaluation_manifest_id uuid PRIMARY KEY,
  contract_document_path text NOT NULL,
  contract_document_version text NOT NULL,
  contract_document_hash text NOT NULL CHECK (contract_document_hash ~ '^[a-f0-9]{64}$'),
  language_keys text[] NOT NULL CHECK (cardinality(language_keys) > 0),
  minimum_sample_size integer NOT NULL CHECK (minimum_sample_size > 0),
  severe_semantic_reversal_threshold numeric NOT NULL CHECK (severe_semantic_reversal_threshold >= 0),
  double_review_required boolean NOT NULL,
  manifest_signature text NOT NULL,
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE OR REPLACE FUNCTION reject_m1_source_mutation()
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
    'owner_group', 'publisher_account', 'collection_opportunity',
    'collection_opportunity_state_event', 'capture', 'raw_item',
    'raw_item_version', 'purpose_authorization', 'preservation_manifest_version',
    'storage_blob', 'raw_artifact', 'artifact_blob_binding', 'restore_test_event',
    'format_migration_event', 'language_evaluation_manifest'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_m1_source_mutation()',
      immutable_table || '_reject_mutation', immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
