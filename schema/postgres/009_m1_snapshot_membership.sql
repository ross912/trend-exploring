-- M1 snapshot membership profile and as-of binding slice.

BEGIN;

CREATE TYPE snapshot_membership_decision_status AS ENUM ('selected', 'absent', 'disputed');

CREATE TABLE snapshot_membership_profile (
  snapshot_membership_profile_id uuid PRIMARY KEY,
  snapshot_type text NOT NULL CHECK (btrim(snapshot_type) <> ''),
  canonical_scope_key text NOT NULL CHECK (btrim(canonical_scope_key) <> ''),
  profile_revision bigint NOT NULL CHECK (profile_revision > 0),
  profile_activation_decision_id uuid NOT NULL REFERENCES manifest_activation_decision,
  effective_from timestamptz NOT NULL,
  effective_until timestamptz,
  profile_hash text NOT NULL CHECK (profile_hash ~ '^[a-f0-9]{64}$'),
  system_available_at timestamptz NOT NULL,
  CHECK (effective_until IS NULL OR effective_from < effective_until),
  CHECK (effective_from <= system_available_at),
  UNIQUE (snapshot_type, canonical_scope_key, profile_revision)
);

CREATE TABLE snapshot_membership_profile_role (
  snapshot_membership_profile_id uuid NOT NULL REFERENCES snapshot_membership_profile,
  member_role text NOT NULL CHECK (btrim(member_role) <> ''),
  subject_kind text NOT NULL CHECK (btrim(subject_kind) <> ''),
  selected_member_kind text NOT NULL CHECK (btrim(selected_member_kind) <> ''),
  role_schema_hash text NOT NULL CHECK (role_schema_hash ~ '^[a-f0-9]{64}$'),
  PRIMARY KEY (snapshot_membership_profile_id, member_role)
);

CREATE OR REPLACE FUNCTION validate_snapshot_membership_profile_activation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  target_kind text;
  target_id uuid;
  role activation_role;
BEGIN
  SELECT target_manifest_kind, target_manifest_id, activation_role
    INTO target_kind, target_id, role
    FROM manifest_activation_decision
   WHERE manifest_activation_decision_id = NEW.profile_activation_decision_id;
  IF target_kind IS DISTINCT FROM 'snapshot-membership-profile'
     OR target_id IS DISTINCT FROM NEW.snapshot_membership_profile_id
     OR role <> 'authoritative' THEN
    RAISE EXCEPTION 'snapshot membership profile activation is not authoritative or typed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER snapshot_membership_profile_activation_guard
AFTER INSERT ON snapshot_membership_profile
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_snapshot_membership_profile_activation();

CREATE TABLE snapshot_membership_snapshot (
  snapshot_membership_snapshot_id uuid PRIMARY KEY,
  snapshot_type text NOT NULL,
  canonical_scope_key text NOT NULL,
  snapshot_membership_profile_id uuid NOT NULL REFERENCES snapshot_membership_profile,
  authoritative_activation_decision_id uuid NOT NULL REFERENCES manifest_activation_decision,
  linearization_at timestamptz NOT NULL,
  snapshot_frozen_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[a-f0-9]{64}$'),
  CHECK (snapshot_frozen_at <= system_available_at),
  CHECK (as_of <= snapshot_frozen_at),
  UNIQUE (snapshot_type, canonical_scope_key, snapshot_membership_snapshot_id)
);

CREATE TABLE snapshot_membership_universe_member (
  snapshot_membership_universe_member_id uuid PRIMARY KEY,
  snapshot_membership_snapshot_id uuid NOT NULL REFERENCES snapshot_membership_snapshot,
  member_role text NOT NULL CHECK (btrim(member_role) <> ''),
  subject_kind text NOT NULL CHECK (btrim(subject_kind) <> ''),
  member_kind text NOT NULL CHECK (btrim(member_kind) <> ''),
  member_key text NOT NULL CHECK (btrim(member_key) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (snapshot_membership_snapshot_id, member_role, subject_kind, member_kind, member_key)
);

CREATE OR REPLACE FUNCTION validate_snapshot_membership_snapshot_binding()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  profile snapshot_membership_profile%ROWTYPE;
  activation manifest_activation_decision%ROWTYPE;
BEGIN
  SELECT * INTO profile
    FROM snapshot_membership_profile
   WHERE snapshot_membership_profile_id = NEW.snapshot_membership_profile_id;
  SELECT * INTO activation
    FROM manifest_activation_decision
   WHERE manifest_activation_decision_id = NEW.authoritative_activation_decision_id;
  IF NOT FOUND OR activation.target_manifest_kind <> 'snapshot-membership-profile'
     OR activation.target_manifest_id <> NEW.snapshot_membership_profile_id
     OR activation.activation_role <> 'authoritative'
     OR profile.snapshot_type <> NEW.snapshot_type
     OR profile.canonical_scope_key <> NEW.canonical_scope_key
     OR profile.profile_activation_decision_id <> NEW.authoritative_activation_decision_id
     OR profile.effective_from > NEW.linearization_at
     OR profile.effective_from > NEW.as_of
     OR (profile.effective_until IS NOT NULL
       AND (NEW.linearization_at >= profile.effective_until OR NEW.as_of >= profile.effective_until))
     OR activation.effective_from > NEW.linearization_at
     OR activation.effective_from > NEW.as_of
     OR (activation.effective_until IS NOT NULL
       AND (NEW.linearization_at >= activation.effective_until OR NEW.as_of >= activation.effective_until)) THEN
    RAISE EXCEPTION 'snapshot membership profile is stale, shadow, future, or scope-mismatched';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER snapshot_membership_snapshot_binding_guard
BEFORE INSERT ON snapshot_membership_snapshot
FOR EACH ROW EXECUTE FUNCTION validate_snapshot_membership_snapshot_binding();

CREATE TABLE snapshot_membership_unit (
  snapshot_membership_unit_id uuid PRIMARY KEY,
  snapshot_membership_snapshot_id uuid NOT NULL REFERENCES snapshot_membership_snapshot,
  subject_kind text NOT NULL CHECK (btrim(subject_kind) <> ''),
  subject_key text NOT NULL CHECK (btrim(subject_key) <> ''),
  member_role text NOT NULL CHECK (btrim(member_role) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (snapshot_membership_snapshot_id, subject_kind, subject_key, member_role)
);

CREATE TABLE snapshot_membership_decision (
  snapshot_membership_decision_id uuid PRIMARY KEY,
  snapshot_membership_unit_id uuid NOT NULL REFERENCES snapshot_membership_unit,
  decision snapshot_membership_decision_status NOT NULL,
  selected_member_kind text,
  selected_member_key text,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK (
    (decision = 'selected' AND selected_member_kind IS NOT NULL AND selected_member_key IS NOT NULL)
    OR
    (decision <> 'selected' AND selected_member_kind IS NULL AND selected_member_key IS NULL)
  ),
  UNIQUE (snapshot_membership_unit_id)
);

CREATE TABLE snapshot_membership_selected_member (
  snapshot_membership_selected_member_id uuid PRIMARY KEY,
  snapshot_membership_unit_id uuid NOT NULL REFERENCES snapshot_membership_unit,
  selected_member_kind text NOT NULL CHECK (btrim(selected_member_kind) <> ''),
  selected_member_key text NOT NULL CHECK (btrim(selected_member_key) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (snapshot_membership_unit_id)
);

CREATE OR REPLACE FUNCTION validate_snapshot_membership_selected_member()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  decision_row snapshot_membership_decision%ROWTYPE;
BEGIN
  SELECT * INTO decision_row
    FROM snapshot_membership_decision
   WHERE snapshot_membership_unit_id = NEW.snapshot_membership_unit_id;
  IF NOT FOUND OR decision_row.decision <> 'selected'
     OR decision_row.selected_member_kind <> NEW.selected_member_kind
     OR decision_row.selected_member_key <> NEW.selected_member_key THEN
    RAISE EXCEPTION 'selected snapshot member does not close over selected decision';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER snapshot_membership_selected_member_guard
BEFORE INSERT ON snapshot_membership_selected_member
FOR EACH ROW EXECUTE FUNCTION validate_snapshot_membership_selected_member();

CREATE OR REPLACE FUNCTION validate_snapshot_membership_snapshot_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  missing_decisions integer;
  selected_without_child integer;
  child_without_selected integer;
  universe_missing integer;
  universe_extra integer;
  selected_unknown integer;
  invalid_subject_kind integer;
  invalid_selected_member_kind integer;
  profile_role_count integer;
  snapshot_role_count integer;
  universe_role_count integer;
BEGIN
  SELECT count(*) INTO missing_decisions
    FROM snapshot_membership_unit u
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND NOT EXISTS (SELECT 1 FROM snapshot_membership_decision d WHERE d.snapshot_membership_unit_id = u.snapshot_membership_unit_id);
  SELECT count(*) INTO selected_without_child
    FROM snapshot_membership_decision d
    JOIN snapshot_membership_unit u USING (snapshot_membership_unit_id)
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND d.decision = 'selected'
     AND NOT EXISTS (SELECT 1 FROM snapshot_membership_selected_member c WHERE c.snapshot_membership_unit_id = d.snapshot_membership_unit_id);
  SELECT count(*) INTO child_without_selected
    FROM snapshot_membership_selected_member c
    JOIN snapshot_membership_unit u USING (snapshot_membership_unit_id)
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND NOT EXISTS (
       SELECT 1 FROM snapshot_membership_decision d
        WHERE d.snapshot_membership_unit_id = c.snapshot_membership_unit_id
          AND d.decision = 'selected'
     );
  SELECT count(*) INTO universe_missing
    FROM (
      SELECT member_role, subject_kind, member_key
        FROM snapshot_membership_universe_member
       WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
      EXCEPT
      SELECT member_role, subject_kind, subject_key
        FROM snapshot_membership_unit
       WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
    ) missing;
  SELECT count(*) INTO universe_extra
    FROM (
      SELECT member_role, subject_kind, subject_key
        FROM snapshot_membership_unit
       WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
      EXCEPT
      SELECT member_role, subject_kind, member_key
        FROM snapshot_membership_universe_member
       WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
    ) extra;
  SELECT count(*) INTO selected_unknown
    FROM snapshot_membership_selected_member c
    JOIN snapshot_membership_unit u USING (snapshot_membership_unit_id)
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND NOT EXISTS (
       SELECT 1
         FROM snapshot_membership_universe_member v
        WHERE v.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
          AND v.member_role = u.member_role
          AND v.member_kind = c.selected_member_kind
          AND v.member_key = c.selected_member_key
     );
  SELECT count(*) INTO profile_role_count
    FROM snapshot_membership_profile_role r
   WHERE r.snapshot_membership_profile_id = NEW.snapshot_membership_profile_id;
  SELECT count(DISTINCT member_role) INTO snapshot_role_count
    FROM snapshot_membership_unit
   WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id;
  SELECT count(DISTINCT member_role) INTO universe_role_count
    FROM snapshot_membership_universe_member
   WHERE snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id;
  SELECT count(*) INTO invalid_subject_kind
    FROM snapshot_membership_unit u
    JOIN snapshot_membership_profile_role r
      ON r.snapshot_membership_profile_id = NEW.snapshot_membership_profile_id
     AND r.member_role = u.member_role
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND u.subject_kind <> r.subject_kind;
  SELECT count(*) INTO invalid_selected_member_kind
    FROM snapshot_membership_decision d
    JOIN snapshot_membership_unit u USING (snapshot_membership_unit_id)
    JOIN snapshot_membership_profile_role r
      ON r.snapshot_membership_profile_id = NEW.snapshot_membership_profile_id
     AND r.member_role = u.member_role
   WHERE u.snapshot_membership_snapshot_id = NEW.snapshot_membership_snapshot_id
     AND d.decision = 'selected'
     AND d.selected_member_kind <> r.selected_member_kind;
  IF missing_decisions <> 0 OR selected_without_child <> 0 OR child_without_selected <> 0
     OR universe_missing <> 0 OR universe_extra <> 0 OR selected_unknown <> 0
     OR invalid_subject_kind <> 0 OR invalid_selected_member_kind <> 0
     OR profile_role_count = 0 OR snapshot_role_count <> profile_role_count
     OR universe_role_count <> profile_role_count THEN
    RAISE EXCEPTION 'snapshot membership units, decisions, selected members, and profile roles are not closed';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER snapshot_membership_snapshot_closure_guard
AFTER INSERT ON snapshot_membership_snapshot
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_snapshot_membership_snapshot_closure();

DO $$
DECLARE
  immutable_table text;
BEGIN
  FOREACH immutable_table IN ARRAY ARRAY[
    'snapshot_membership_profile', 'snapshot_membership_profile_role',
    'snapshot_membership_snapshot', 'snapshot_membership_universe_member',
    'snapshot_membership_unit',
    'snapshot_membership_decision', 'snapshot_membership_selected_member'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I '
      'FOR EACH ROW EXECUTE FUNCTION reject_row_mutation()',
      immutable_table || '_reject_mutation', immutable_table
    );
  END LOOP;
END;
$$;

COMMIT;
