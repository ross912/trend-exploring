\set ON_ERROR_STOP on

INSERT INTO service_principal (
  service_principal_id, principal_name, identity_created_at, system_available_at
) VALUES
  ('a6000000-0000-4000-8000-000000000001', 'global-radar-worker',
   '2026-08-07 06:00+00', '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000002', 'global-correction-reviewer',
   '2026-08-07 06:00+00', '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000003', 'global-training-runner',
   '2026-08-07 06:00+00', '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000004', 'personal-ui',
   '2026-08-07 06:00+00', '2026-08-07 06:00+00');

INSERT INTO global_service_principal (
  global_service_principal_id, principal_name, role_key,
  effective_from, expires_at, system_available_at
) VALUES
  ('a6000000-0000-4000-8000-000000000001', 'global-radar-worker', 'radar',
   '2026-08-07 06:00+00', NULL, '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000002', 'global-correction-reviewer', 'correction',
   '2026-08-07 06:00+00', NULL, '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000003', 'global-training-runner', 'training',
   '2026-08-07 06:00+00', NULL, '2026-08-07 06:00+00');

INSERT INTO global_service_principal_database_role (
  global_service_principal_id, database_role_name, recorded_at, system_available_at
) VALUES
  ('a6000000-0000-4000-8000-000000000001', current_user, '2026-08-07 06:00+00', '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000002', current_user, '2026-08-07 06:00+00', '2026-08-07 06:00+00'),
  ('a6000000-0000-4000-8000-000000000003', current_user, '2026-08-07 06:00+00', '2026-08-07 06:00+00');

SELECT set_config('m1.service_principal', 'global-radar-worker', false);

INSERT INTO personal_scope VALUES
  ('aa000000-0000-4000-8000-000000000022', 'user-a', 1,
   '2026-08-07 06:00+00', '2026-08-07 06:00+00');
INSERT INTO private_query_context VALUES
  ('bb000000-0000-4000-8000-000000000022',
   'aa000000-0000-4000-8000-000000000022', 'private canary question',
   '2026-08-07 06:01+00', '2026-08-07 06:01+00');

INSERT INTO global_query_execution VALUES
  ('cc000000-0000-4000-8000-000000000022', 'neutral_query',
   'public energy storage policy', 120,
   '2026-08-07 06:02+00', '2026-08-07 06:02+00');

INSERT INTO public_only_input_snapshot VALUES
  ('dd000000-0000-4000-8000-000000000022',
   '2026-08-07 06:03+00', '2026-08-07 06:03+00', '2026-08-07 06:03+00',
   0, 'global', repeat('a', 64));
INSERT INTO public_only_input_member VALUES
  ('ee000000-0000-4000-8000-000000000022',
   'dd000000-0000-4000-8000-000000000022',
   'ff000000-0000-4000-8000-000000000022', 'public_record', 'global', 0,
   '2026-08-07 06:03+00', '2026-08-07 06:03+00');

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    PERFORM set_config('m1.service_principal', 'personal-ui', false);
    INSERT INTO global_query_execution VALUES
      ('cc000000-0000-4000-8000-000000000024', 'neutral_query',
       'public energy storage policy', 120,
       '2026-08-07 06:03+00', '2026-08-07 06:03+00');
    RAISE EXCEPTION 'personal service identity entered global query execution';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'global data access requires an authorized global service principal' THEN RAISE; END IF;
  END;

  PERFORM set_config('m1.service_principal', 'global-radar-worker', false);

  BEGIN
    INSERT INTO global_query_execution VALUES
      ('cc000000-0000-4000-8000-000000000023', 'public_only_input_snapshot',
       'private_query_context:canary', 120,
       '2026-08-07 06:04+00', '2026-08-07 06:04+00');
    RAISE EXCEPTION 'private payload entered global query execution';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public_only_input_snapshot VALUES
      ('dd000000-0000-4000-8000-000000000023',
       '2026-08-07 06:05+00', '2026-08-07 06:05+00', '2026-08-07 06:05+00',
       1, 'global', repeat('b', 64));
    RAISE EXCEPTION 'private lineage entered public-only snapshot';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public_only_input_member VALUES
      ('ee000000-0000-4000-8000-000000000023',
       'dd000000-0000-4000-8000-000000000022',
       'ff000000-0000-4000-8000-000000000023', 'private_query_context', 'personal', 1,
       '2026-08-07 06:06+00', '2026-08-07 06:06+00');
    RAISE EXCEPTION 'personal member entered public-only snapshot';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE global_query_execution SET payload = 'tampered'
     WHERE global_query_execution_id = 'cc000000-0000-4000-8000-000000000022';
    RAISE EXCEPTION 'global query execution mutation was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'global_query_execution is append-only' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'DATA DOMAIN FIXTURES PASSED' AS result;
