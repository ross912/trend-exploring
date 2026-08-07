\set ON_ERROR_STOP on

BEGIN;

INSERT INTO manifest_series VALUES
  ('aa000000-0000-4000-8000-000000000091', 'snapshot-membership-profile', 'source-registry',
   '2026-08-07 05:30+00', '2026-08-07 05:30+00');
INSERT INTO manifest_activation_decision VALUES
  ('bb000000-0000-4000-8000-000000000091',
   'aa000000-0000-4000-8000-000000000091', 'snapshot-membership-profile',
   'cc000000-0000-4000-8000-000000000091', 'authoritative',
   '2026-08-07 00:00+00', '2026-08-07 02:00+00', 1, NULL, NULL,
   '2026-08-07 05:30+00', '2026-08-07 05:30+00'),
  ('bb000000-0000-4000-8000-000000000092',
   'aa000000-0000-4000-8000-000000000091', 'snapshot-membership-profile',
   'cc000000-0000-4000-8000-000000000092', 'authoritative',
   '2026-08-07 02:00+00', NULL, 2,
   'bb000000-0000-4000-8000-000000000091', 1,
   '2026-08-07 05:31+00', '2026-08-07 05:31+00');

INSERT INTO snapshot_membership_profile VALUES
  ('cc000000-0000-4000-8000-000000000091', 'SourceRegistrySnapshot', 'source-registry', 1,
   'bb000000-0000-4000-8000-000000000091', '2026-08-07 00:00+00', '2026-08-07 02:00+00',
   repeat('1', 64), '2026-08-07 05:32+00'),
  ('cc000000-0000-4000-8000-000000000092', 'SourceRegistrySnapshot', 'source-registry', 2,
   'bb000000-0000-4000-8000-000000000092', '2026-08-07 02:00+00', NULL,
   repeat('2', 64), '2026-08-07 05:32+00');

INSERT INTO snapshot_membership_profile_role VALUES
  ('cc000000-0000-4000-8000-000000000091', 'source_endpoint_version', 'record', 'source_endpoint_version', repeat('3', 64)),
  ('cc000000-0000-4000-8000-000000000092', 'source_endpoint_version', 'record', 'source_endpoint_version', repeat('4', 64)),
  ('cc000000-0000-4000-8000-000000000092', 'owner_group', 'record', 'owner_group', repeat('5', 64));

INSERT INTO snapshot_membership_snapshot VALUES
  ('dd000000-0000-4000-8000-000000000091', 'SourceRegistrySnapshot', 'source-registry',
   'cc000000-0000-4000-8000-000000000091', 'bb000000-0000-4000-8000-000000000091',
   '2026-08-07 01:00+00', '2026-08-07 01:01+00', '2026-08-07 01:00+00', '2026-08-07 01:01+00',
   repeat('6', 64));
INSERT INTO snapshot_membership_universe_member VALUES
  ('12000000-0000-4000-8000-000000000091',
   'dd000000-0000-4000-8000-000000000091', 'source_endpoint_version',
   'record', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 01:00+00', '2026-08-07 01:00+00');
INSERT INTO snapshot_membership_unit VALUES
  ('ee000000-0000-4000-8000-000000000091', 'dd000000-0000-4000-8000-000000000091',
   'record', 'endpoint-v2', 'source_endpoint_version',
   '2026-08-07 01:00+00', '2026-08-07 01:00+00', '2026-08-07 01:00+00', 'prospective', ARRAY[]::uuid[]);
INSERT INTO snapshot_membership_decision VALUES
  ('ff000000-0000-4000-8000-000000000091', 'ee000000-0000-4000-8000-000000000091',
   'selected', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 01:00+00', '2026-08-07 01:00+00');
INSERT INTO snapshot_membership_selected_member VALUES
  ('11000000-0000-4000-8000-000000000091', 'ee000000-0000-4000-8000-000000000091',
   'source_endpoint_version', 'endpoint-v2', '2026-08-07 01:00+00', '2026-08-07 01:00+00');

INSERT INTO snapshot_membership_snapshot VALUES
  ('dd000000-0000-4000-8000-000000000092', 'SourceRegistrySnapshot', 'source-registry',
   'cc000000-0000-4000-8000-000000000092', 'bb000000-0000-4000-8000-000000000092',
   '2026-08-07 03:00+00', '2026-08-07 03:01+00', '2026-08-07 03:00+00', '2026-08-07 03:01+00',
   repeat('7', 64));
INSERT INTO snapshot_membership_universe_member VALUES
  ('12000000-0000-4000-8000-000000000092',
   'dd000000-0000-4000-8000-000000000092', 'source_endpoint_version',
   'record', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00'),
  ('12000000-0000-4000-8000-000000000093',
   'dd000000-0000-4000-8000-000000000092', 'owner_group',
   'record', 'owner_group', 'owner-a', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
INSERT INTO snapshot_membership_unit VALUES
  ('ee000000-0000-4000-8000-000000000092', 'dd000000-0000-4000-8000-000000000092',
   'record', 'endpoint-v2', 'source_endpoint_version',
   '2026-08-07 03:00+00', '2026-08-07 03:00+00', '2026-08-07 03:00+00', 'prospective', ARRAY[]::uuid[]),
  ('ee000000-0000-4000-8000-000000000093', 'dd000000-0000-4000-8000-000000000092',
   'record', 'owner-a', 'owner_group',
   '2026-08-07 03:00+00', '2026-08-07 03:00+00', '2026-08-07 03:00+00', 'prospective', ARRAY[]::uuid[]);
INSERT INTO snapshot_membership_decision VALUES
  ('ff000000-0000-4000-8000-000000000092', 'ee000000-0000-4000-8000-000000000092',
   'selected', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00'),
  ('ff000000-0000-4000-8000-000000000093', 'ee000000-0000-4000-8000-000000000093',
   'absent', NULL, NULL, '2026-08-07 03:00+00', '2026-08-07 03:00+00');
INSERT INTO snapshot_membership_selected_member VALUES
  ('11000000-0000-4000-8000-000000000092', 'ee000000-0000-4000-8000-000000000092',
   'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00');

COMMIT;

DO $$
DECLARE
  message_text text;
BEGIN
  BEGIN
    INSERT INTO snapshot_membership_snapshot VALUES
      ('dd000000-0000-4000-8000-000000000093', 'SourceRegistrySnapshot', 'source-registry',
       'cc000000-0000-4000-8000-000000000091', 'bb000000-0000-4000-8000-000000000091',
       '2026-08-07 03:00+00', '2026-08-07 03:01+00', '2026-08-07 03:00+00', '2026-08-07 03:01+00',
       repeat('8', 64));
    RAISE EXCEPTION 'stale profile activation was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'snapshot membership profile is stale, shadow, future, or scope-mismatched' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO snapshot_membership_snapshot VALUES
      ('dd000000-0000-4000-8000-000000000094', 'SourceRegistrySnapshot', 'source-registry',
       'cc000000-0000-4000-8000-000000000092', 'bb000000-0000-4000-8000-000000000092',
       '2026-08-07 03:00+00', '2026-08-07 03:01+00', '2026-08-07 03:00+00', '2026-08-07 03:01+00',
       repeat('9', 64));
    INSERT INTO snapshot_membership_universe_member VALUES
      ('12000000-0000-4000-8000-000000000094',
       'dd000000-0000-4000-8000-000000000094', 'source_endpoint_version',
       'record', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00'),
      ('12000000-0000-4000-8000-000000000095',
       'dd000000-0000-4000-8000-000000000094', 'owner_group',
       'record', 'owner_group', 'owner-a', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
    INSERT INTO snapshot_membership_unit VALUES
      ('ee000000-0000-4000-8000-000000000094', 'dd000000-0000-4000-8000-000000000094',
       'record', 'endpoint-v2', 'source_endpoint_version',
       '2026-08-07 03:00+00', '2026-08-07 03:00+00', '2026-08-07 03:00+00', 'prospective', ARRAY[]::uuid[]);
    INSERT INTO snapshot_membership_decision VALUES
      ('ff000000-0000-4000-8000-000000000094', 'ee000000-0000-4000-8000-000000000094',
       'selected', 'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
    INSERT INTO snapshot_membership_selected_member VALUES
      ('11000000-0000-4000-8000-000000000094', 'ee000000-0000-4000-8000-000000000094',
       'source_endpoint_version', 'endpoint-v2', '2026-08-07 03:00+00', '2026-08-07 03:00+00');
    SET CONSTRAINTS snapshot_membership_snapshot_closure_guard IMMEDIATE;
    RAISE EXCEPTION 'snapshot missing new profile role was accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS message_text = MESSAGE_TEXT;
    IF message_text <> 'snapshot membership units, decisions, selected members, and profile roles are not closed' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'SNAPSHOT MEMBERSHIP FIXTURES PASSED' AS result;
