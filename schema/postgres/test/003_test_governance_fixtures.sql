\set ON_ERROR_STOP on

BEGIN;

INSERT INTO service_principal VALUES
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'fixture-test-governance',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO test_governance_policy VALUES
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, 'm1-fixture', repeat('c', 64),
   'fixture-policy-signature', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   ARRAY['00000000-0000-4000-8000-000000000701']::uuid[],
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO test_definition VALUES
  ('10000000-0000-4000-8000-000000000001', 'CTR-005',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('10000000-0000-4000-8000-000000000002', 'PRI-012',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('10000000-0000-4000-8000-000000000003', 'EVA-025',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO test_definition_version VALUES
  ('20000000-0000-4000-8000-000000000001',
   '10000000-0000-4000-8000-000000000001',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, NULL, NULL,
   'M0', 'M0', 'always', false, 'P0', 'phase-exit',
   'fixed-fixture-v1', 'fixed-config-v1', 'machine-oracle-v1', repeat('1', 64),
   'fixture-definition-signature', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   'prospective', ARRAY['00000000-0000-4000-8000-000000000702']::uuid[]),
  ('20000000-0000-4000-8000-000000000002',
   '10000000-0000-4000-8000-000000000002',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, NULL, NULL,
   'M1', 'M1', 'always', true, 'P1', 'none',
   'token-recovery-fixture-v1', 'token-config-v1', 'machine-oracle-v1', repeat('2', 64),
   'fixture-definition-signature', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   'prospective', ARRAY['00000000-0000-4000-8000-000000000703']::uuid[]),
  ('20000000-0000-4000-8000-000000000003',
   '10000000-0000-4000-8000-000000000003',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, NULL, NULL,
   'M2', 'M2', 'always', true, 'P1', 'release',
   'evaluation-fixture-v1', 'evaluation-config-v1', 'machine-oracle-v1', repeat('3', 64),
   'fixture-definition-signature', '2026-08-07 00:00+00',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00', '2026-08-07 00:00+00',
   'prospective', ARRAY['00000000-0000-4000-8000-000000000704']::uuid[]);

INSERT INTO test_catalog_manifest VALUES
  ('30000000-0000-4000-8000-000000000001', 'M1', 'phase-exit',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
   encode(digest(
     '20000000-0000-4000-8000-000000000001|applicable
20000000-0000-4000-8000-000000000002|applicable',
     'sha256'), 'hex'),
   'm1-fixture', repeat('d', 64), 'fixture-catalog-signature',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   ARRAY['00000000-0000-4000-8000-000000000705']::uuid[],
   '2026-08-07 00:01+00', '2026-08-07 00:01+00');

INSERT INTO test_catalog_definition_member VALUES
  ('40000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000001', 'applicable', NULL,
   'P0 definitions are always applicable', '2026-08-07 00:01+00', '2026-08-07 00:01+00'),
  ('40000000-0000-4000-8000-000000000002',
   '30000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000002', 'applicable', NULL,
   'M1 token recovery fixture is applicable', '2026-08-07 00:01+00', '2026-08-07 00:01+00');

COMMIT;

INSERT INTO test_run VALUES
  ('50000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001', 'ae5704b', 'postgres-15.18-fixture',
   'fixture-v1', 'config-v1', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '2026-08-07 00:02+00', '2026-08-07 00:03+00',
   '2026-08-07 00:03+00', '2026-08-07 00:03+00',
   ARRAY['00000000-0000-4000-8000-000000000706']::uuid[]);
INSERT INTO test_result VALUES
  ('60000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000001', 'catalog includes all inherited P0 tests',
   'pass', ARRAY[]::text[], ARRAY['00000000-0000-4000-8000-000000000707']::uuid[],
   '{}'::jsonb, '2026-08-07 00:03+00', '2026-08-07 00:03+00'),
  ('60000000-0000-4000-8000-000000000002',
   '50000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000002', 'single-use replay oracle not yet wired',
   'fail', ARRAY['fixture_pending']::text[], ARRAY['00000000-0000-4000-8000-000000000708']::uuid[],
   '{"blocking":false}'::jsonb, '2026-08-07 00:03+00', '2026-08-07 00:03+00');
INSERT INTO gate_decision VALUES
  ('70000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000001', 'M1', 'phase-exit', 'pass', 2, 0,
   ARRAY['20000000-0000-4000-8000-000000000002']::uuid[],
   ARRAY[]::uuid[], ARRAY[]::uuid[],
   '2026-08-07 00:04+00', '2026-08-07 00:04+00', '2026-08-07 00:04+00',
   ARRAY['00000000-0000-4000-8000-000000000709']::uuid[]);

INSERT INTO test_run VALUES
  ('50000000-0000-4000-8000-000000000002',
   '30000000-0000-4000-8000-000000000001', 'ae5704b', 'postgres-15.18-fixture',
   'fixture-v1', 'config-v1', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '2026-08-07 00:05+00', '2026-08-07 00:06+00',
   '2026-08-07 00:06+00', '2026-08-07 00:06+00',
   ARRAY['00000000-0000-4000-8000-000000000710']::uuid[]);
INSERT INTO test_result VALUES
  ('60000000-0000-4000-8000-000000000003',
   '50000000-0000-4000-8000-000000000002',
   '20000000-0000-4000-8000-000000000001', 'forced P0 gate failure',
   'blocked', ARRAY['p0_blocked']::text[], ARRAY['00000000-0000-4000-8000-000000000711']::uuid[],
   '{}'::jsonb, '2026-08-07 00:06+00', '2026-08-07 00:06+00'),
  ('60000000-0000-4000-8000-000000000004',
   '50000000-0000-4000-8000-000000000002',
   '20000000-0000-4000-8000-000000000002', 'non-blocking fixture pass',
   'pass', ARRAY[]::text[], ARRAY['00000000-0000-4000-8000-000000000712']::uuid[],
   '{}'::jsonb, '2026-08-07 00:06+00', '2026-08-07 00:06+00');
INSERT INTO gate_decision VALUES
  ('70000000-0000-4000-8000-000000000002',
   '30000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000002', 'M1', 'phase-exit', 'blocked', 2, 1,
   ARRAY['20000000-0000-4000-8000-000000000001']::uuid[],
   ARRAY[]::uuid[], ARRAY[]::uuid[],
   '2026-08-07 00:07+00', '2026-08-07 00:07+00', '2026-08-07 00:07+00',
   ARRAY['00000000-0000-4000-8000-000000000713']::uuid[]);

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_definition VALUES
      ('10000000-0000-4000-8000-000000000004', 'CTR-007',
       '2026-08-07 00:08+00', '2026-08-07 00:08+00');
    INSERT INTO test_definition_version VALUES
      ('20000000-0000-4000-8000-000000000004',
       '10000000-0000-4000-8000-000000000004',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, NULL, NULL,
       'M0', 'M0', 'component:optional', false, 'P0', 'phase-exit',
       'fixture-v1', 'config-v1', 'oracle-v1', repeat('4', 64),
       'fixture-signature', '2026-08-07 00:08+00', '2026-08-07 00:08+00',
       '2026-08-07 00:08+00', '2026-08-07 00:08+00', 'prospective',
       ARRAY['00000000-0000-4000-8000-000000000714']::uuid[]);
    RAISE EXCEPTION 'P0 downgrade was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_catalog_manifest VALUES
      ('30000000-0000-4000-8000-000000000002', 'M1', 'phase-exit',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
       encode(digest('20000000-0000-4000-8000-000000000001|applicable', 'sha256'), 'hex'),
       'm1-fixture', repeat('e', 64), 'fixture-catalog-signature',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
       ARRAY['00000000-0000-4000-8000-000000000715']::uuid[],
       '2026-08-07 00:09+00', '2026-08-07 00:09+00');
    INSERT INTO test_catalog_definition_member VALUES
      ('40000000-0000-4000-8000-000000000003',
       '30000000-0000-4000-8000-000000000002',
       '20000000-0000-4000-8000-000000000001', 'applicable', NULL,
       'only one of two definitions', '2026-08-07 00:09+00', '2026-08-07 00:09+00');
    SET CONSTRAINTS test_catalog_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'catalog omission was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test catalog is not a complete fail-closed definition universe' THEN
      RAISE;
    END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_catalog_manifest VALUES
      ('30000000-0000-4000-8000-000000000003', 'M1', 'phase-exit',
       'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
       encode(digest(
         '20000000-0000-4000-8000-000000000001|excluded
20000000-0000-4000-8000-000000000002|applicable', 'sha256'), 'hex'),
       'm1-fixture', repeat('f', 64), 'fixture-catalog-signature',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
       ARRAY['00000000-0000-4000-8000-000000000716']::uuid[],
       '2026-08-07 00:10+00', '2026-08-07 00:10+00');
    INSERT INTO test_catalog_definition_member VALUES
      ('40000000-0000-4000-8000-000000000004',
       '30000000-0000-4000-8000-000000000003',
       '20000000-0000-4000-8000-000000000001', 'excluded', 'P0 cannot be excluded',
       'negative fixture', '2026-08-07 00:10+00', '2026-08-07 00:10+00'),
      ('40000000-0000-4000-8000-000000000005',
       '30000000-0000-4000-8000-000000000003',
       '20000000-0000-4000-8000-000000000002', 'applicable', NULL,
       'P1 member', '2026-08-07 00:10+00', '2026-08-07 00:10+00');
    SET CONSTRAINTS test_catalog_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'P0 catalog exclusion was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test catalog is not a complete fail-closed definition universe' THEN
      RAISE;
    END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_run VALUES
      ('50000000-0000-4000-8000-000000000003',
       '30000000-0000-4000-8000-000000000001', 'ae5704b', 'postgres-15.18-fixture',
       'fixture-v1', 'config-v1', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
       '2026-08-07 00:11+00', '2026-08-07 00:12+00',
       '2026-08-07 00:12+00', '2026-08-07 00:12+00',
       ARRAY['00000000-0000-4000-8000-000000000717']::uuid[]);
    INSERT INTO test_result VALUES
      ('60000000-0000-4000-8000-000000000005',
       '50000000-0000-4000-8000-000000000003',
       '20000000-0000-4000-8000-000000000001', 'incorrectly not applicable',
       'not_applicable', ARRAY['missing_fixture']::text[],
       ARRAY['00000000-0000-4000-8000-000000000718']::uuid[], '{}'::jsonb,
       '2026-08-07 00:12+00', '2026-08-07 00:12+00');
    RAISE EXCEPTION 'applicability mismatch was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test result status contradicts catalog applicability' THEN
      RAISE;
    END IF;
  END;
END;
$$;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_run VALUES
      ('50000000-0000-4000-8000-000000000004',
       '30000000-0000-4000-8000-000000000001', 'ae5704b', 'postgres-15.18-fixture',
       'fixture-v1', 'config-v1', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
       '2026-08-07 00:13+00', '2026-08-07 00:14+00',
       '2026-08-07 00:14+00', '2026-08-07 00:14+00',
       ARRAY['00000000-0000-4000-8000-000000000719']::uuid[]);
    INSERT INTO test_result VALUES
      ('60000000-0000-4000-8000-000000000006',
       '50000000-0000-4000-8000-000000000004',
       '20000000-0000-4000-8000-000000000001', 'pass', 'pass',
       ARRAY[]::text[], ARRAY['00000000-0000-4000-8000-000000000720']::uuid[],
       '{}'::jsonb, '2026-08-07 00:14+00', '2026-08-07 00:14+00'),
      ('60000000-0000-4000-8000-000000000007',
       '50000000-0000-4000-8000-000000000004',
       '20000000-0000-4000-8000-000000000002', 'pass', 'pass',
       ARRAY[]::text[], ARRAY['00000000-0000-4000-8000-000000000721']::uuid[],
       '{}'::jsonb, '2026-08-07 00:14+00', '2026-08-07 00:14+00');
    INSERT INTO gate_decision VALUES
      ('70000000-0000-4000-8000-000000000003',
       '30000000-0000-4000-8000-000000000001',
       '50000000-0000-4000-8000-000000000004', 'M1', 'phase-exit', 'blocked', 2, 0,
       ARRAY[]::uuid[], ARRAY[]::uuid[], ARRAY[]::uuid[],
       '2026-08-07 00:15+00', '2026-08-07 00:15+00', '2026-08-07 00:15+00',
       ARRAY['00000000-0000-4000-8000-000000000722']::uuid[]);
    SET CONSTRAINTS gate_decision_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'incorrect blocked gate was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'gate decision is not closed over catalog results' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SELECT 'TEST GOVERNANCE FIXTURES PASSED' AS result;
