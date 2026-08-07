\set ON_ERROR_STOP on

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO test_result VALUES
      ('9a000000-0000-4000-8000-000000000001',
       '50000000-0000-4000-8000-000000000001',
       '20000000-0000-4000-8000-000000000003',
       'M2 definition is outside the M1 catalog', 'pass', ARRAY[]::text[],
       ARRAY['9a000000-0000-4000-8000-000000000010']::uuid[], '{}'::jsonb,
       '2026-08-07 04:00+00', '2026-08-07 04:00+00');
    RAISE EXCEPTION 'out-of-catalog test result was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test result definition is not in the run catalog' THEN RAISE; END IF;
  END;

  BEGIN
    DELETE FROM test_result
     WHERE test_result_id = '60000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'test result deletion was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'test_result is append-only' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'TEST CATALOG RESULT NEGATIVE FIXTURES PASSED' AS result;
