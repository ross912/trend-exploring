-- Raw archive immutability upgrade.
--
-- 011 is the clean-install definition; this migration is the narrow, safe
-- upgrade for databases that already contain source captures/items/versions.
-- It never deletes or rewrites retained rows.  A missing or ambiguous
-- item/version relationship fails closed before triggers or constraints are
-- changed.
BEGIN;

DO $$
DECLARE
  parent_item_attnum smallint;
  child_item_attnum smallint;
  fk_count integer;
  fk_name text;
  fk_delete_action "char";
  fk_attnums smallint[];
BEGIN
  IF to_regclass('local_source_capture') IS NULL
     OR to_regclass('local_source_item') IS NULL
     OR to_regclass('local_source_item_version') IS NULL THEN
    RAISE EXCEPTION 'raw archive relations are incomplete; refusing 017 upgrade';
  END IF;

  SELECT attnum INTO parent_item_attnum
    FROM pg_attribute
   WHERE attrelid = 'local_source_item'::regclass
     AND attname = 'item_key'
     AND NOT attisdropped;
  SELECT attnum INTO child_item_attnum
    FROM pg_attribute
   WHERE attrelid = 'local_source_item_version'::regclass
     AND attname = 'item_key'
     AND NOT attisdropped;
  IF parent_item_attnum IS NULL OR child_item_attnum IS NULL THEN
    RAISE EXCEPTION 'local_source_item.item_key is missing; refusing 017 upgrade';
  END IF;

  SELECT COUNT(*) INTO fk_count
    FROM pg_constraint c
   WHERE c.conrelid = 'local_source_item_version'::regclass
     AND c.confrelid = 'local_source_item'::regclass
     AND c.contype = 'f'
     AND c.conkey = ARRAY[child_item_attnum]::smallint[]
     AND c.confkey = ARRAY[parent_item_attnum]::smallint[];
  IF fk_count <> 1 THEN
    RAISE EXCEPTION 'local_source_item_version item FK is absent or ambiguous; refusing 017 upgrade';
  END IF;

  SELECT c.conname, c.confdeltype, c.conkey
    INTO fk_name, fk_delete_action, fk_attnums
    FROM pg_constraint c
   WHERE c.conrelid = 'local_source_item_version'::regclass
     AND c.confrelid = 'local_source_item'::regclass
     AND c.contype = 'f'
     AND c.conkey = ARRAY[child_item_attnum]::smallint[]
     AND c.confkey = ARRAY[parent_item_attnum]::smallint[]
   LIMIT 1;
  IF fk_attnums IS DISTINCT FROM ARRAY[child_item_attnum]::smallint[]
     OR fk_delete_action NOT IN ('a', 'r', 'c') THEN
    RAISE EXCEPTION 'local_source_item_version item FK has unsupported shape; refusing 017 upgrade';
  END IF;

  -- The legacy relation used ON DELETE CASCADE.  Replace only that known
  -- action with the default restrictive action; no retained row is touched.
  IF fk_delete_action = 'c' THEN
    EXECUTE format('ALTER TABLE local_source_item_version DROP CONSTRAINT %I', fk_name);
    EXECUTE 'ALTER TABLE local_source_item_version ADD CONSTRAINT local_source_item_version_item_key_fkey FOREIGN KEY (item_key) REFERENCES local_source_item(item_key) ON DELETE RESTRICT';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION local_raw_archive_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; use a compliance tombstone/revocation event instead of %',
    TG_TABLE_NAME, lower(TG_OP);
END;
$$;

CREATE OR REPLACE FUNCTION local_source_item_delete_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'local_source_item is a mutable projection but DELETE is forbidden; raw history is append-only';
END;
$$;

DROP TRIGGER IF EXISTS local_source_capture_append_only_trigger ON local_source_capture;
CREATE TRIGGER local_source_capture_append_only_trigger
BEFORE UPDATE OR DELETE ON local_source_capture
FOR EACH ROW EXECUTE FUNCTION local_raw_archive_append_only_guard();
DROP TRIGGER IF EXISTS local_source_capture_no_truncate_trigger ON local_source_capture;
CREATE TRIGGER local_source_capture_no_truncate_trigger
BEFORE TRUNCATE ON local_source_capture
FOR EACH STATEMENT EXECUTE FUNCTION local_raw_archive_append_only_guard();

DROP TRIGGER IF EXISTS local_source_item_version_append_only_trigger ON local_source_item_version;
CREATE TRIGGER local_source_item_version_append_only_trigger
BEFORE UPDATE OR DELETE ON local_source_item_version
FOR EACH ROW EXECUTE FUNCTION local_raw_archive_append_only_guard();
DROP TRIGGER IF EXISTS local_source_item_version_no_truncate_trigger ON local_source_item_version;
CREATE TRIGGER local_source_item_version_no_truncate_trigger
BEFORE TRUNCATE ON local_source_item_version
FOR EACH STATEMENT EXECUTE FUNCTION local_raw_archive_append_only_guard();

-- local_source_item is the mutable current projection and remains updateable
-- for ingest.  Its destructive operations are blocked so they cannot erase
-- raw history; future compliance deletion must be a separate append-only
-- tombstone/revocation event.
DROP TRIGGER IF EXISTS local_source_item_delete_guard_trigger ON local_source_item;
CREATE TRIGGER local_source_item_delete_guard_trigger
BEFORE DELETE ON local_source_item
FOR EACH ROW EXECUTE FUNCTION local_source_item_delete_guard();
DROP TRIGGER IF EXISTS local_source_item_no_truncate_trigger ON local_source_item;
CREATE TRIGGER local_source_item_no_truncate_trigger
BEFORE TRUNCATE ON local_source_item
FOR EACH STATEMENT EXECUTE FUNCTION local_source_item_delete_guard();

CREATE TABLE IF NOT EXISTS local_raw_archive_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_raw_archive_schema_meta(schema_version)
VALUES ('017_raw_archive_immutability_v1') ON CONFLICT DO NOTHING;

COMMIT;
