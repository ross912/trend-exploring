\set ON_ERROR_STOP on

DO $$
DECLARE
  table_count integer;
  unguarded_count integer;
BEGIN
  SELECT count(*) INTO table_count
    FROM information_schema.tables
   WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
  IF table_count NOT IN (41, 64, 85, 86, 87, 90, 91, 92) THEN
    RAISE EXCEPTION 'expected 41 tables after standalone governance slice or 64/85/86/87/90/91/92 in full M1 stack, found %', table_count;
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
          AND trigger_row.tgname = t.table_name || '_reject_mutation'
     );
  IF unguarded_count <> 0 THEN
    RAISE EXCEPTION '% tables lack append-only triggers', unguarded_count;
  END IF;
END;
$$;

SELECT 'GOVERNANCE QUORUM SMOKE PASSED' AS result;
