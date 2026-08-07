\set ON_ERROR_STOP on

DO $$
DECLARE
  table_count integer;
  unguarded_count integer;
BEGIN
  SELECT count(*) INTO table_count
    FROM information_schema.tables
   WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
  IF table_count NOT IN (47, 62, 64, 85) THEN
    RAISE EXCEPTION 'expected 47 tables after EventBase migration (or 62/64/85 after M1 extensions), found %', table_count;
  END IF;

  SELECT count(*) INTO unguarded_count
    FROM information_schema.tables t
   WHERE t.table_schema = 'public'
     AND t.table_type = 'BASE TABLE'
     AND NOT EXISTS (
       SELECT 1
         FROM pg_trigger trigger_row
         JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
         JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = t.table_schema
          AND relation.relname = t.table_name
          AND NOT trigger_row.tgisinternal
          AND trigger_row.tgname IN (
            t.table_name || '_reject_mutation',
            t.table_name || '_reject_event_mutation'
          )
     );
  IF unguarded_count <> 0 THEN
    RAISE EXCEPTION '% tables lack append-only triggers', unguarded_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_class r ON r.oid = c.conrelid
     WHERE r.relname = 'event_base'
       AND c.contype = 'f'
       AND pg_get_constraintdef(c.oid) LIKE '%aggregate_identity_id%global_identity_registry%'
  ) THEN
    RAISE EXCEPTION 'typed aggregate identity FK is missing';
  END IF;
END;
$$;

SELECT 'EVENT BASE SMOKE PASSED' AS result;
