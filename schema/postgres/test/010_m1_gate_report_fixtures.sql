\set ON_ERROR_STOP on

INSERT INTO test_run VALUES
  ('98000000-0000-4000-8000-000000000001',
   '97000000-0000-4000-8000-000000000001', 'signed-import-fixture',
   'postgres-15.18-fixture', 'fixture-v1', 'config-v1',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '2026-08-07 03:00+00', '2026-08-07 03:01+00',
   '2026-08-07 03:01+00', '2026-08-07 03:01+00',
   ARRAY['98000000-0000-4000-8000-000000000010']::uuid[]);
INSERT INTO test_result VALUES
  ('98000000-0000-4000-8000-000000000001',
   '98000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000001', 'inherited M0 P0 passed',
   'pass', ARRAY[]::text[], ARRAY['98000000-0000-4000-8000-000000000011']::uuid[],
   '{}'::jsonb, '2026-08-07 03:01+00', '2026-08-07 03:01+00'),
  ('98000000-0000-4000-8000-000000000002',
   '98000000-0000-4000-8000-000000000001',
   '97000000-0000-4000-8000-000000000002', 'imported M1 P0 passed',
   'pass', ARRAY[]::text[], ARRAY['98000000-0000-4000-8000-000000000012']::uuid[],
   '{}'::jsonb, '2026-08-07 03:01+00', '2026-08-07 03:01+00');

DO $$
DECLARE
  report jsonb;
BEGIN
  report := evaluate_m1_phase_exit_gate(
    '97000000-0000-4000-8000-000000000001',
    '98000000-0000-4000-8000-000000000001'
  );
  IF report->>'decision' <> 'pass'
     OR (report->>'requiredCount')::integer <> 2
     OR (report->>'missingCount')::integer <> 0 THEN
    RAISE EXCEPTION 'M1 phase-exit pass report is wrong: %', report;
  END IF;
END;
$$;

INSERT INTO test_run VALUES
  ('98000000-0000-4000-8000-000000000002',
   '97000000-0000-4000-8000-000000000001', 'signed-import-fixture',
   'postgres-15.18-fixture', 'fixture-v1', 'config-v1',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '2026-08-07 03:02+00', '2026-08-07 03:03+00',
   '2026-08-07 03:03+00', '2026-08-07 03:03+00',
   ARRAY['98000000-0000-4000-8000-000000000020']::uuid[]);
INSERT INTO test_result VALUES
  ('98000000-0000-4000-8000-000000000003',
   '98000000-0000-4000-8000-000000000002',
   '20000000-0000-4000-8000-000000000001', 'only one required result',
   'pass', ARRAY[]::text[], ARRAY['98000000-0000-4000-8000-000000000021']::uuid[],
   '{}'::jsonb, '2026-08-07 03:03+00', '2026-08-07 03:03+00');

DO $$
DECLARE
  report jsonb;
BEGIN
  report := evaluate_m1_phase_exit_gate(
    '97000000-0000-4000-8000-000000000001',
    '98000000-0000-4000-8000-000000000002'
  );
  IF report->>'decision' <> 'blocked'
     OR (report->>'missingCount')::integer <> 1 THEN
    RAISE EXCEPTION 'M1 phase-exit incomplete report is wrong: %', report;
  END IF;
END;
$$;

SELECT 'M1 GATE REPORT FIXTURES PASSED' AS result;
