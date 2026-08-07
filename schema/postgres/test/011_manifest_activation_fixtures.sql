\set ON_ERROR_STOP on

BEGIN;

INSERT INTO manifest_series VALUES
  ('be000000-0000-4000-8000-000000000001', 'fixture-manifest', 'scope-a',
   '2026-08-07 04:00+00', '2026-08-07 04:00+00');
INSERT INTO manifest_activation_decision VALUES
  ('be100000-0000-4000-8000-000000000001',
   'be000000-0000-4000-8000-000000000001', 'fixture-manifest',
   'be200000-0000-4000-8000-000000000001', 'authoritative',
   '2026-08-07 04:00+00', '2026-08-07 05:00+00', 1, NULL, NULL,
   '2026-08-07 04:00+00', '2026-08-07 04:00+00'),
  ('be100000-0000-4000-8000-000000000002',
   'be000000-0000-4000-8000-000000000001', 'fixture-manifest',
   'be200000-0000-4000-8000-000000000002', 'shadow',
   '2026-08-07 05:00+00', NULL, 2,
   'be100000-0000-4000-8000-000000000001', 1,
   '2026-08-07 05:00+00', '2026-08-07 05:00+00');
COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO manifest_activation_decision VALUES
      ('be100000-0000-4000-8000-000000000003',
       'be000000-0000-4000-8000-000000000001', 'fixture-manifest',
       'be200000-0000-4000-8000-000000000003', 'shadow',
       '2026-08-07 06:00+00', NULL, 4,
       'be100000-0000-4000-8000-000000000001', 3,
       '2026-08-07 06:00+00', '2026-08-07 06:00+00');
    RAISE EXCEPTION 'manifest activation revision jump was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'manifest activation revision is not the expected head' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO manifest_activation_decision VALUES
      ('be100000-0000-4000-8000-000000000003',
       'be000000-0000-4000-8000-000000000001', 'fixture-manifest',
       'be200000-0000-4000-8000-000000000003', 'authoritative',
       '2026-08-07 04:30+00', '2026-08-07 05:30+00', 3,
       'be100000-0000-4000-8000-000000000002', 2,
       '2026-08-07 06:00+00', '2026-08-07 06:00+00');
    RAISE EXCEPTION 'overlapping authoritative activation was accepted';
  EXCEPTION WHEN exclusion_violation THEN
    NULL;
  END;
END;
$$;

SELECT 'MANIFEST ACTIVATION FIXTURES PASSED' AS result;
