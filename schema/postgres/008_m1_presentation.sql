-- M1 typed claim-slot and presentation render-plan identity slice.
-- Depends on 001_m1_core.sql and 007_m1_coverage_item.sql.

BEGIN;

CREATE TYPE claim_generation_decision_status AS ENUM ('claim', 'no_claim', 'failed');
CREATE TYPE presentation_content_kind AS ENUM ('title', 'body', 'claim');

CREATE OR REPLACE FUNCTION m1_claim_generation_key(
  p_presentation_event_id uuid,
  p_claim_slot_manifest_id uuid,
  p_container_identity_id uuid,
  p_channel text,
  p_locale text,
  p_ordinal integer,
  p_manifest_hash text
)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT p_presentation_event_id::text || '|' || p_claim_slot_manifest_id::text || '|'
    || p_container_identity_id::text || '|' || p_channel || '|' || p_locale || '|'
    || p_ordinal::text || '|' || p_manifest_hash;
$$;

CREATE TABLE claim_generation_unit (
  claim_generation_unit_id uuid PRIMARY KEY,
  presentation_event_id uuid NOT NULL,
  claim_slot_manifest_id uuid NOT NULL,
  container_identity_id uuid NOT NULL,
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  ordinal integer NOT NULL CHECK (ordinal > 0),
  minimum_required boolean NOT NULL,
  maximum_ordinal integer NOT NULL CHECK (maximum_ordinal >= ordinal),
  claim_slot_manifest_hash text NOT NULL CHECK (claim_slot_manifest_hash ~ '^[a-f0-9]{64}$'),
  generation_key text GENERATED ALWAYS AS (
    m1_claim_generation_key(presentation_event_id, claim_slot_manifest_id,
      container_identity_id, channel, locale, ordinal, claim_slot_manifest_hash)
  ) STORED,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (generation_key),
  UNIQUE (presentation_event_id, claim_slot_manifest_id, container_identity_id, channel, locale, ordinal)
);

CREATE OR REPLACE FUNCTION validate_claim_generation_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  generation_key text;
BEGIN
  generation_key := m1_claim_generation_key(
    NEW.presentation_event_id, NEW.claim_slot_manifest_id, NEW.container_identity_id,
    NEW.channel, NEW.locale, NEW.ordinal, NEW.claim_slot_manifest_hash
  );
  IF NEW.claim_generation_unit_id <> m1_uuid5(
    'f2a83d84-3b92-5d5f-9c37-9d8a5f4e2b10', generation_key
  ) THEN
    RAISE EXCEPTION 'claim generation unit id does not match canonical slot key';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER claim_generation_identity_guard
BEFORE INSERT ON claim_generation_unit
FOR EACH ROW EXECUTE FUNCTION validate_claim_generation_identity();

CREATE TABLE claim_generation_decision (
  claim_generation_decision_id uuid PRIMARY KEY,
  claim_generation_unit_id uuid NOT NULL REFERENCES claim_generation_unit,
  decision claim_generation_decision_status NOT NULL,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (claim_generation_unit_id)
);

CREATE TABLE presentation_render_plan (
  presentation_render_plan_id uuid PRIMARY KEY,
  presentation_event_id uuid NOT NULL,
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  plan_hash text NOT NULL CHECK (plan_hash ~ '^[a-f0-9]{64}$'),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (presentation_event_id)
);

CREATE TABLE presentation_content_unit (
  presentation_content_unit_id uuid PRIMARY KEY,
  presentation_render_plan_id uuid NOT NULL REFERENCES presentation_render_plan,
  container_identity_id uuid NOT NULL,
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  item_order integer NOT NULL CHECK (item_order > 0),
  content_kind presentation_content_kind NOT NULL,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  as_of timestamptz NOT NULL,
  run_mode run_mode NOT NULL,
  input_record_ids uuid[] NOT NULL,
  CHECK (recorded_at <= system_available_at),
  UNIQUE (presentation_render_plan_id, channel, locale, container_identity_id, item_order)
);

CREATE TABLE presentation_title_content (
  presentation_content_unit_id uuid PRIMARY KEY REFERENCES presentation_content_unit,
  title_text text NOT NULL CHECK (btrim(title_text) <> '')
);

CREATE TABLE presentation_body_content (
  presentation_content_unit_id uuid PRIMARY KEY REFERENCES presentation_content_unit,
  body_text text NOT NULL CHECK (btrim(body_text) <> '')
);

CREATE TABLE presentation_claim_content (
  presentation_content_unit_id uuid PRIMARY KEY REFERENCES presentation_content_unit,
  claim_id uuid NOT NULL
);

CREATE TABLE presentation_source_identity_registry (
  source_record_identity_id uuid PRIMARY KEY,
  identity_kind text NOT NULL CHECK (btrim(identity_kind) <> ''),
  concrete_type text NOT NULL CHECK (btrim(concrete_type) <> ''),
  source_hash text NOT NULL CHECK (source_hash ~ '^[a-f0-9]{64}$'),
  effective_from timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (effective_from <= system_available_at)
);

CREATE TABLE presentation_claim_citation (
  claim_citation_id uuid PRIMARY KEY,
  presentation_event_id uuid NOT NULL,
  presentation_render_plan_id uuid NOT NULL REFERENCES presentation_render_plan,
  presentation_content_unit_id uuid NOT NULL REFERENCES presentation_content_unit,
  claim_id uuid NOT NULL,
  source_record_identity_id uuid NOT NULL,
  citation_role text NOT NULL CHECK (citation_role IN ('entails', 'source_asserts', 'context', 'contradicts')),
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  displayed_text_hash text NOT NULL CHECK (displayed_text_hash ~ '^[a-f0-9]{64}$'),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (source_record_identity_id) REFERENCES presentation_source_identity_registry,
  UNIQUE (presentation_event_id, presentation_content_unit_id, source_record_identity_id, locale)
);

CREATE TABLE presentation_raw_source_listing_reference (
  raw_source_listing_reference_id uuid PRIMARY KEY,
  presentation_event_id uuid NOT NULL,
  presentation_render_plan_id uuid NOT NULL REFERENCES presentation_render_plan,
  presentation_content_unit_id uuid NOT NULL REFERENCES presentation_content_unit,
  source_record_identity_id uuid NOT NULL,
  source_metadata_field text NOT NULL CHECK (btrim(source_metadata_field) <> ''),
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  displayed_text_hash text NOT NULL CHECK (displayed_text_hash ~ '^[a-f0-9]{64}$'),
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  FOREIGN KEY (source_record_identity_id) REFERENCES presentation_source_identity_registry,
  UNIQUE (presentation_event_id, presentation_content_unit_id, source_record_identity_id, locale)
);

CREATE OR REPLACE FUNCTION validate_presentation_content_child()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  expected presentation_content_kind;
  actual presentation_content_kind;
BEGIN
  SELECT content_kind INTO expected
    FROM presentation_content_unit
   WHERE presentation_content_unit_id = NEW.presentation_content_unit_id;
  actual := CASE TG_TABLE_NAME
    WHEN 'presentation_title_content' THEN 'title'::presentation_content_kind
    WHEN 'presentation_body_content' THEN 'body'::presentation_content_kind
    WHEN 'presentation_claim_content' THEN 'claim'::presentation_content_kind
  END;
  IF expected IS NULL OR expected <> actual THEN
    RAISE EXCEPTION 'presentation content child kind does not match content unit';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER presentation_title_child_kind_guard
BEFORE INSERT ON presentation_title_content
FOR EACH ROW EXECUTE FUNCTION validate_presentation_content_child();
CREATE TRIGGER presentation_body_child_kind_guard
BEFORE INSERT ON presentation_body_content
FOR EACH ROW EXECUTE FUNCTION validate_presentation_content_child();
CREATE TRIGGER presentation_claim_child_kind_guard
BEFORE INSERT ON presentation_claim_content
FOR EACH ROW EXECUTE FUNCTION validate_presentation_content_child();

CREATE OR REPLACE FUNCTION validate_presentation_content_closure()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  expected presentation_content_kind;
  child_count integer;
BEGIN
  SELECT content_kind INTO expected
    FROM presentation_content_unit
   WHERE presentation_content_unit_id = NEW.presentation_content_unit_id;
  SELECT count(*) INTO child_count
    FROM (
      SELECT presentation_content_unit_id FROM presentation_title_content
       WHERE presentation_content_unit_id = NEW.presentation_content_unit_id
      UNION ALL
      SELECT presentation_content_unit_id FROM presentation_body_content
       WHERE presentation_content_unit_id = NEW.presentation_content_unit_id
      UNION ALL
      SELECT presentation_content_unit_id FROM presentation_claim_content
       WHERE presentation_content_unit_id = NEW.presentation_content_unit_id
    ) children;
  IF expected IS NULL OR child_count <> 1 THEN
    RAISE EXCEPTION 'presentation content unit must have exactly one kind-specific child';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER presentation_content_closure_guard
AFTER INSERT ON presentation_content_unit
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_presentation_content_closure();

CREATE TABLE source_text_ref (
  source_text_ref_id uuid PRIMARY KEY,
  presentation_event_id uuid NOT NULL,
  presentation_render_plan_id uuid NOT NULL REFERENCES presentation_render_plan,
  presentation_content_unit_id uuid NOT NULL REFERENCES presentation_content_unit,
  channel text NOT NULL CHECK (btrim(channel) <> ''),
  locale text NOT NULL CHECK (btrim(locale) <> ''),
  claim_citation_id uuid,
  raw_source_listing_reference_id uuid,
  recorded_at timestamptz NOT NULL,
  system_available_at timestamptz NOT NULL,
  CHECK (recorded_at <= system_available_at),
  CHECK ((claim_citation_id IS NULL) <> (raw_source_listing_reference_id IS NULL))
);

CREATE OR REPLACE FUNCTION validate_presentation_source_text_ref()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  plan presentation_render_plan%ROWTYPE;
  content presentation_content_unit%ROWTYPE;
  claim_child presentation_claim_content%ROWTYPE;
  citation presentation_claim_citation%ROWTYPE;
  listing presentation_raw_source_listing_reference%ROWTYPE;
BEGIN
  IF (NEW.claim_citation_id IS NULL) = (NEW.raw_source_listing_reference_id IS NULL) THEN
    RAISE EXCEPTION 'source text ref requires exactly one typed child' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO plan FROM presentation_render_plan
   WHERE presentation_render_plan_id = NEW.presentation_render_plan_id;
  SELECT * INTO content FROM presentation_content_unit
   WHERE presentation_content_unit_id = NEW.presentation_content_unit_id;
  IF NOT FOUND OR plan.presentation_render_plan_id IS NULL
     OR plan.presentation_event_id <> NEW.presentation_event_id
     OR content.presentation_render_plan_id <> plan.presentation_render_plan_id
     OR NEW.channel <> plan.channel OR NEW.locale <> plan.locale
     OR NEW.channel <> content.channel OR NEW.locale <> content.locale THEN
    RAISE EXCEPTION 'source text ref plan/content/channel/locale binding is inconsistent';
  END IF;

  IF NEW.claim_citation_id IS NOT NULL THEN
    SELECT * INTO citation FROM presentation_claim_citation
     WHERE claim_citation_id = NEW.claim_citation_id;
    SELECT * INTO claim_child FROM presentation_claim_content
     WHERE presentation_content_unit_id = NEW.presentation_content_unit_id;
    IF citation.claim_citation_id IS NULL OR claim_child.presentation_content_unit_id IS NULL
       OR content.content_kind <> 'claim'
       OR citation.presentation_event_id <> NEW.presentation_event_id
       OR citation.presentation_event_id <> plan.presentation_event_id
       OR citation.presentation_render_plan_id <> NEW.presentation_render_plan_id
       OR citation.presentation_content_unit_id <> NEW.presentation_content_unit_id
       OR citation.channel <> NEW.channel OR citation.locale <> NEW.locale
       OR claim_child.claim_id <> citation.claim_id THEN
      RAISE EXCEPTION 'claim citation is not typed to the same presentation event/content claim';
    END IF;
  ELSE
    SELECT * INTO listing FROM presentation_raw_source_listing_reference
     WHERE raw_source_listing_reference_id = NEW.raw_source_listing_reference_id;
    IF listing.raw_source_listing_reference_id IS NULL
       OR listing.presentation_event_id <> NEW.presentation_event_id
       OR listing.presentation_event_id <> plan.presentation_event_id
       OR listing.presentation_render_plan_id <> NEW.presentation_render_plan_id
       OR listing.presentation_content_unit_id <> NEW.presentation_content_unit_id
       OR listing.channel <> NEW.channel OR listing.locale <> NEW.locale THEN
      RAISE EXCEPTION 'raw source listing reference is not typed to the same presentation event/content';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER source_text_ref_binding_guard
BEFORE INSERT ON source_text_ref
FOR EACH ROW EXECUTE FUNCTION validate_presentation_source_text_ref();

DO $$
DECLARE
  immutable_table text;
BEGIN
  FOREACH immutable_table IN ARRAY ARRAY[
    'claim_generation_unit', 'claim_generation_decision', 'presentation_render_plan',
    'presentation_source_identity_registry',
    'presentation_content_unit', 'presentation_title_content', 'presentation_body_content',
    'presentation_claim_content', 'presentation_claim_citation',
    'presentation_raw_source_listing_reference', 'source_text_ref'
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
