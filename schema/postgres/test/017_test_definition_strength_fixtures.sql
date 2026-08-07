\set ON_ERROR_STOP on

INSERT INTO test_definition VALUES
  ('10000000-0000-4000-8000-000000000201', 'CTR-007A',
   '2026-08-07 03:10+00', '2026-08-07 03:10+00');
INSERT INTO test_definition_version VALUES
  ('20000000-0000-4000-8000-000000000201',
   '10000000-0000-4000-8000-000000000201',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, NULL, NULL,
   'M0', 'M0', 'always', false, 'P0', 'phase-exit',
   'strength-fixture-v1', 'strength-config-v1', 'strength-oracle-v1', repeat('a', 64),
   'fixture-definition-signature', '2026-08-07 03:10+00',
   '2026-08-07 03:10+00', '2026-08-07 03:10+00', '2026-08-07 03:10+00',
   'prospective', ARRAY['00000000-0000-4000-8000-000000000901']::uuid[]);

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_definition_version VALUES
      ('20000000-0000-4000-8000-000000000202',
       '10000000-0000-4000-8000-000000000201',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 2,
       '20000000-0000-4000-8000-000000000201', 1,
       'M1', 'M1', 'always', false, 'P0', 'phase-exit',
       'strength-fixture-v2', 'strength-config-v2', 'strength-oracle-v2', repeat('b', 64),
       'fixture-definition-signature', '2026-08-07 03:11+00',
       '2026-08-07 03:11+00', '2026-08-07 03:11+00', '2026-08-07 03:11+00',
       'prospective', ARRAY['00000000-0000-4000-8000-000000000902']::uuid[]);
    RAISE EXCEPTION 'introduced phase shift was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test definition introduced phase cannot move later' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO test_definition_version VALUES
      ('20000000-0000-4000-8000-000000000203',
       '10000000-0000-4000-8000-000000000201',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 2,
       '20000000-0000-4000-8000-000000000201', 1,
       'M0', 'M0', 'always', true, 'P1', 'phase-exit',
       'strength-fixture-v2', 'strength-config-v2', 'strength-oracle-v2', repeat('c', 64),
       'fixture-definition-signature', '2026-08-07 03:12+00',
       '2026-08-07 03:12+00', '2026-08-07 03:12+00', '2026-08-07 03:12+00',
       'prospective', ARRAY['00000000-0000-4000-8000-000000000903']::uuid[]);
    RAISE EXCEPTION 'P0 to P1 downgrade was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'P0 test definition strength cannot be downgraded' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO test_definition_version VALUES
      ('20000000-0000-4000-8000-000000000204',
       '10000000-0000-4000-8000-000000000201',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 2,
       '20000000-0000-4000-8000-000000000201', 1,
       'M0', 'M0', 'always', false, 'P0', 'none',
       'strength-fixture-v2', 'strength-config-v2', 'strength-oracle-v2', repeat('d', 64),
       'fixture-definition-signature', '2026-08-07 03:13+00',
       '2026-08-07 03:13+00', '2026-08-07 03:13+00', '2026-08-07 03:13+00',
       'prospective', ARRAY['00000000-0000-4000-8000-000000000904']::uuid[]);
    RAISE EXCEPTION 'blocking to none downgrade was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'blocking test definition cannot be downgraded to none' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO test_definition_version VALUES
      ('20000000-0000-4000-8000-000000000205',
       '10000000-0000-4000-8000-000000000201',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 2,
       '20000000-0000-4000-8000-000000000201', 1,
       'M0', 'M0', 'predicate:optional', false, 'P0', 'phase-exit',
       'strength-fixture-v2', 'strength-config-v2', 'strength-oracle-v2', repeat('e', 64),
       'fixture-definition-signature', '2026-08-07 03:14+00',
       '2026-08-07 03:14+00', '2026-08-07 03:14+00', '2026-08-07 03:14+00',
       'prospective', ARRAY['00000000-0000-4000-8000-000000000905']::uuid[]);
    RAISE EXCEPTION 'P0 applicability weakening was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'P0 test definition applicability cannot be weakened' THEN RAISE; END IF;
  END;
END;
$$;

SELECT count(*) AS preserved_strong_versions
  FROM test_definition_version
 WHERE test_definition_version_id = '20000000-0000-4000-8000-000000000201';
SELECT 'TEST DEFINITION STRENGTH FIXTURES PASSED' AS result;
