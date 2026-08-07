\set ON_ERROR_STOP on

BEGIN;

INSERT INTO service_principal VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'fixture-quorum-secondary',
   '2026-08-07 00:00+00', '2026-08-07 00:00+00')
ON CONFLICT (service_principal_id) DO NOTHING;
INSERT INTO governance_signing_key_version VALUES
  ('86000000-0000-4000-8000-000000000001',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'test-governance', 'key-bbbb-v1',
   'active', '2026-08-07 00:00+00', '2027-08-07 00:00+00', '2026-08-07 00:00+00'),
  ('86000000-0000-4000-8000-000000000002',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'test-governance', 'key-aaaa-v1',
   'active', '2026-08-07 00:00+00', '2027-08-07 00:00+00', '2026-08-07 00:00+00');

INSERT INTO approval_decision VALUES
  ('80000000-0000-4000-8000-000000000001', 'test_definition_version',
   '20000000-0000-4000-8000-000000000002', repeat('2', 64), repeat('3', 64),
   'fixture waiver is time-bounded and non-P0', 'does not weaken P0 gates', 'approved',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 2,
   '2026-08-07 00:20+00', '2026-08-07 00:20+00', '2026-08-07 00:20+00',
   'fixture-approval-signature', ARRAY['00000000-0000-4000-8000-000000000801']::uuid[]);
INSERT INTO approval_decision_signer VALUES
  ('80000000-0000-4000-8000-000000000001',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '86000000-0000-4000-8000-000000000001', 'signer-bbbb',
   '2026-08-07 00:20+00', '2026-08-07 00:20+00'),
  ('80000000-0000-4000-8000-000000000001',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '86000000-0000-4000-8000-000000000002', 'signer-aaaa',
   '2026-08-07 00:20+00', '2026-08-07 00:20+00');
INSERT INTO test_waiver VALUES
  ('81000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000002',
   '80000000-0000-4000-8000-000000000001',
   'fixture demonstrates approved P1 waiver only',
   '2026-08-07 00:20+00', '2026-08-08 00:20+00',
   '2026-08-07 00:20+00', '2026-08-07 00:20+00',
   'fixture-waiver-signature', ARRAY['00000000-0000-4000-8000-000000000802']::uuid[]);

INSERT INTO gate_evaluation_unit VALUES
  ('82000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001', 'M1', 'phase-exit', repeat('a', 64),
   2, 2, 'two independent attempts required',
   '2026-08-07 00:21+00', '2026-08-07 00:21+00',
   ARRAY['00000000-0000-4000-8000-000000000803']::uuid[]);
INSERT INTO gate_run_attempt_membership VALUES
  ('83000000-0000-4000-8000-000000000001',
   '82000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000001', 1,
   '2026-08-07 00:22+00', '2026-08-07 00:22+00',
   ARRAY['00000000-0000-4000-8000-000000000804']::uuid[]),
  ('83000000-0000-4000-8000-000000000002',
   '82000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000002', 2,
   '2026-08-07 00:22+00', '2026-08-07 00:22+00',
   ARRAY['00000000-0000-4000-8000-000000000805']::uuid[]);
INSERT INTO gate_evaluation_closure_decision VALUES
  ('84000000-0000-4000-8000-000000000001',
   '82000000-0000-4000-8000-000000000001', 'blocked', 2, 2,
   encode(digest(
     '50000000-0000-4000-8000-000000000001|pass
50000000-0000-4000-8000-000000000002|blocked', 'sha256'), 'hex'),
   '2026-08-07 00:23+00', '2026-08-07 00:23+00', '2026-08-07 00:23+00',
   ARRAY['00000000-0000-4000-8000-000000000806']::uuid[]);
COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO approval_decision VALUES
      ('80000000-0000-4000-8000-000000000003', 'test_definition_version',
       '20000000-0000-4000-8000-000000000002', repeat('4', 64), repeat('5', 64),
       'missing quorum fixture', 'must be rejected', 'approved',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 2,
       '2026-08-07 00:26+00', '2026-08-07 00:26+00', '2026-08-07 00:26+00',
       'invalid-approval-signature', ARRAY['00000000-0000-4000-8000-000000000820']::uuid[]);
    SET CONSTRAINTS approval_decision_quorum_guard IMMEDIATE;
    RAISE EXCEPTION 'approval without signer quorum was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'approval decision lacks an independent active signing quorum' THEN RAISE; END IF;
  END;
END;
$$;

INSERT INTO gate_run_selection_decision VALUES
  ('85000000-0000-4000-8000-000000000001',
   '84000000-0000-4000-8000-000000000001', 'blocked', NULL,
   'one blocking run prevents selecting a passing retry',
   '2026-08-07 00:24+00', '2026-08-07 00:24+00',
   ARRAY['00000000-0000-4000-8000-000000000807']::uuid[]);

INSERT INTO gate_evaluation_unit VALUES
  ('82000000-0000-4000-8000-000000000003',
   '30000000-0000-4000-8000-000000000001', 'M1', 'phase-exit', repeat('c', 64),
   2, 2, 'selection negative fixture',
   '2026-08-07 00:24+00', '2026-08-07 00:24+00',
   ARRAY['00000000-0000-4000-8000-000000000814']::uuid[]);
INSERT INTO gate_run_attempt_membership VALUES
  ('83000000-0000-4000-8000-000000000004',
   '82000000-0000-4000-8000-000000000003',
   '50000000-0000-4000-8000-000000000001', 1,
   '2026-08-07 00:24+00', '2026-08-07 00:24+00',
   ARRAY['00000000-0000-4000-8000-000000000815']::uuid[]),
  ('83000000-0000-4000-8000-000000000005',
   '82000000-0000-4000-8000-000000000003',
   '50000000-0000-4000-8000-000000000002', 2,
   '2026-08-07 00:24+00', '2026-08-07 00:24+00',
   ARRAY['00000000-0000-4000-8000-000000000816']::uuid[]);
INSERT INTO gate_evaluation_closure_decision VALUES
  ('84000000-0000-4000-8000-000000000003',
   '82000000-0000-4000-8000-000000000003', 'blocked', 2, 2,
   encode(digest(
     '50000000-0000-4000-8000-000000000001|pass
50000000-0000-4000-8000-000000000002|blocked', 'sha256'), 'hex'),
   '2026-08-07 00:25+00', '2026-08-07 00:25+00', '2026-08-07 00:25+00',
   ARRAY['00000000-0000-4000-8000-000000000817']::uuid[]);

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO approval_decision VALUES
      ('80000000-0000-4000-8000-000000000002', 'test_definition_version',
       '20000000-0000-4000-8000-000000000001', repeat('1', 64), repeat('4', 64),
       'attempt to waive P0', 'must be rejected', 'approved',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 2,
       '2026-08-07 00:25+00', '2026-08-07 00:25+00', '2026-08-07 00:25+00',
       'fixture-approval-signature', ARRAY['00000000-0000-4000-8000-000000000808']::uuid[]);
    INSERT INTO approval_decision_signer VALUES
      ('80000000-0000-4000-8000-000000000002',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
       '86000000-0000-4000-8000-000000000001', 'signer-bbbb-p0',
       '2026-08-07 00:25+00', '2026-08-07 00:25+00'),
      ('80000000-0000-4000-8000-000000000002',
       'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '86000000-0000-4000-8000-000000000002', 'signer-aaaa-p0',
       '2026-08-07 00:25+00', '2026-08-07 00:25+00');
    INSERT INTO test_waiver VALUES
      ('81000000-0000-4000-8000-000000000002',
       '20000000-0000-4000-8000-000000000001',
       '80000000-0000-4000-8000-000000000002', 'P0 waiver must fail closed',
       '2026-08-07 00:25+00', '2026-08-08 00:25+00',
       '2026-08-07 00:25+00', '2026-08-07 00:25+00',
       'fixture-waiver-signature', ARRAY['00000000-0000-4000-8000-000000000809']::uuid[]);
    RAISE EXCEPTION 'P0 waiver was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test waiver is not permitted for this definition' THEN
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
    INSERT INTO gate_evaluation_unit VALUES
      ('82000000-0000-4000-8000-000000000002',
       '30000000-0000-4000-8000-000000000001', 'M1', 'phase-exit', repeat('b', 64),
       2, 2, 'incomplete negative fixture',
       '2026-08-07 00:26+00', '2026-08-07 00:26+00',
       ARRAY['00000000-0000-4000-8000-000000000810']::uuid[]);
    INSERT INTO gate_run_attempt_membership VALUES
      ('83000000-0000-4000-8000-000000000003',
       '82000000-0000-4000-8000-000000000002',
       '50000000-0000-4000-8000-000000000001', 1,
       '2026-08-07 00:26+00', '2026-08-07 00:26+00',
       ARRAY['00000000-0000-4000-8000-000000000811']::uuid[]);
    INSERT INTO gate_evaluation_closure_decision VALUES
      ('84000000-0000-4000-8000-000000000002',
       '82000000-0000-4000-8000-000000000002', 'closed', 2, 1, repeat('b', 64),
       '2026-08-07 00:27+00', '2026-08-07 00:27+00', '2026-08-07 00:27+00',
       ARRAY['00000000-0000-4000-8000-000000000812']::uuid[]);
    SET CONSTRAINTS gate_evaluation_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'incomplete gate evaluation was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'gate evaluation is not a complete terminal run set' THEN
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
    INSERT INTO gate_run_selection_decision VALUES
      ('85000000-0000-4000-8000-000000000002',
       '84000000-0000-4000-8000-000000000003', 'selected',
       '50000000-0000-4000-8000-000000000001',
       'attempt to select passing run despite blocked evaluation',
       '2026-08-07 00:28+00', '2026-08-07 00:28+00',
       ARRAY['00000000-0000-4000-8000-000000000813']::uuid[]);
    SET CONSTRAINTS gate_run_selection_guard IMMEDIATE;
    RAISE EXCEPTION 'blocked evaluation selected a run';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'gate run selection contradicts evaluation closure' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SELECT 'GATE EVALUATION FIXTURES PASSED' AS result;
