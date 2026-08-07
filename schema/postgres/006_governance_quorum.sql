-- Governance approval quorum slice for CTR-009.
-- ApprovalDecision.quorum_count is not trusted by itself: an approved
-- decision must close over independent, purpose-bound active signing keys.

BEGIN;

CREATE TYPE governance_key_state AS ENUM ('active', 'revoked', 'compromised');

CREATE TABLE governance_signing_key_version (
  signing_key_version_id uuid PRIMARY KEY,
  service_principal_id uuid NOT NULL REFERENCES service_principal,
  key_purpose text NOT NULL CHECK (key_purpose = 'test-governance'),
  key_fingerprint text NOT NULL CHECK (btrim(key_fingerprint) <> ''),
  key_state governance_key_state NOT NULL,
  authorized_manifest_kinds text[] NOT NULL DEFAULT ARRAY['test-governance']::text[],
  effective_from timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (cardinality(authorized_manifest_kinds) > 0),
  CHECK (effective_from < expires_at),
  CHECK (effective_from <= system_available_at)
);

CREATE OR REPLACE FUNCTION assert_manifest_signature_authorized(
  p_manifest_kind text,
  p_manifest_signature text,
  p_owner_service_principal_id uuid,
  p_signing_key_version_id uuid,
  p_signed_at timestamptz,
  p_effective_from timestamptz,
  p_system_available_at timestamptz,
  p_signature_verified boolean
)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  signing_key governance_signing_key_version%ROWTYPE;
BEGIN
  -- Cryptographic verification remains an ingress responsibility; this
  -- function closes the database-side authorization/lifecycle boundary.
  IF NOT p_signature_verified
     OR btrim(coalesce(p_manifest_signature, '')) = ''
     OR p_signing_key_version_id IS NULL
     OR p_signed_at IS NULL THEN
    RAISE EXCEPTION 'manifest signature is not verified';
  END IF;

  SELECT * INTO signing_key
    FROM governance_signing_key_version
   WHERE signing_key_version_id = p_signing_key_version_id
   FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'manifest signing key does not exist';
  END IF;

  IF signing_key.key_state <> 'active'
     OR signing_key.key_purpose <> 'test-governance'
     OR NOT (p_manifest_kind = ANY (signing_key.authorized_manifest_kinds))
     OR p_signed_at < signing_key.effective_from
     OR p_signed_at >= signing_key.expires_at
     OR p_effective_from < signing_key.effective_from
     OR p_effective_from >= signing_key.expires_at
     OR p_signed_at > p_system_available_at
     OR p_owner_service_principal_id IS NULL THEN
    RAISE EXCEPTION 'manifest signing key is not currently authorized';
  END IF;
  RETURN true;
END;
$$;

CREATE TABLE approval_decision_signer (
  approval_decision_id uuid NOT NULL
    REFERENCES approval_decision DEFERRABLE INITIALLY DEFERRED,
  signer_service_principal_id uuid NOT NULL REFERENCES service_principal,
  signing_key_version_id uuid NOT NULL
    REFERENCES governance_signing_key_version DEFERRABLE INITIALLY DEFERRED,
  signature text NOT NULL CHECK (btrim(signature) <> ''),
  signed_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  PRIMARY KEY (approval_decision_id, signer_service_principal_id),
  UNIQUE (approval_decision_id, signing_key_version_id),
  CHECK (signed_at <= system_available_at)
);

CREATE OR REPLACE FUNCTION validate_approval_decision_quorum()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  signer_count integer;
  distinct_signer_count integer;
  invalid_signer_count integer;
BEGIN
  SELECT count(*), count(DISTINCT s.signer_service_principal_id)
    INTO signer_count, distinct_signer_count
    FROM approval_decision_signer s
   WHERE s.approval_decision_id = NEW.approval_decision_id;

  SELECT count(*) INTO invalid_signer_count
    FROM approval_decision_signer s
    JOIN governance_signing_key_version k
      ON k.signing_key_version_id = s.signing_key_version_id
   WHERE s.approval_decision_id = NEW.approval_decision_id
     AND (k.service_principal_id <> s.signer_service_principal_id
       OR k.key_purpose <> 'test-governance'
       OR k.key_state <> 'active'
       OR s.signed_at < k.effective_from
       OR s.signed_at >= k.expires_at);

  IF NEW.decision = 'approved'
     AND (signer_count < NEW.quorum_count
       OR distinct_signer_count < NEW.quorum_count
       OR invalid_signer_count <> 0) THEN
    RAISE EXCEPTION 'approval decision lacks an independent active signing quorum';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER approval_decision_quorum_guard
AFTER INSERT ON approval_decision
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_approval_decision_quorum();

CREATE OR REPLACE FUNCTION reject_governance_quorum_mutation()
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
    'governance_signing_key_version',
    'approval_decision_signer'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_governance_quorum_mutation()',
      immutable_table || '_reject_mutation', immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
