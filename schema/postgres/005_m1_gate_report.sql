-- Database-side M1 phase-exit report.  It evaluates only applicable
-- phase-exit members of the supplied signed catalog and never treats a
-- missing result or not-applicable result as success.

BEGIN;

CREATE OR REPLACE FUNCTION evaluate_m1_phase_exit_gate(
  p_test_catalog_manifest_id uuid,
  p_test_run_id uuid
)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  catalog_phase test_phase;
  catalog_gate test_blocking_mode;
  run_catalog_id uuid;
  required_count integer;
  observed_count integer;
  missing_count integer;
  blocking_count integer;
  required_ids uuid[];
BEGIN
  SELECT target_phase, target_gate
    INTO catalog_phase, catalog_gate
    FROM test_catalog_manifest
   WHERE test_catalog_manifest_id = p_test_catalog_manifest_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'M1 phase-exit catalog does not exist';
  END IF;
  IF catalog_gate <> 'phase-exit' THEN
    RAISE EXCEPTION 'M1 phase-exit report requires a phase-exit catalog';
  END IF;

  SELECT test_catalog_manifest_id INTO run_catalog_id
    FROM test_run
   WHERE test_run_id = p_test_run_id;
  IF NOT FOUND OR run_catalog_id <> p_test_catalog_manifest_id THEN
    RAISE EXCEPTION 'M1 phase-exit run does not belong to the catalog';
  END IF;

  SELECT count(*), array_agg(m.test_definition_version_id ORDER BY m.test_definition_version_id)
    INTO required_count, required_ids
    FROM test_catalog_definition_member m
    JOIN test_definition_version v
      ON v.test_definition_version_id = m.test_definition_version_id
   WHERE m.test_catalog_manifest_id = p_test_catalog_manifest_id
     AND m.membership = 'applicable'
     AND v.blocking = 'phase-exit';

  SELECT count(*) INTO observed_count
    FROM test_result r
   WHERE r.test_run_id = p_test_run_id
     AND r.test_definition_version_id = ANY (coalesce(required_ids, ARRAY[]::uuid[]));

  SELECT count(*) INTO missing_count
    FROM unnest(coalesce(required_ids, ARRAY[]::uuid[])) AS required(test_definition_version_id)
   WHERE NOT EXISTS (
     SELECT 1 FROM test_result r
      WHERE r.test_run_id = p_test_run_id
        AND r.test_definition_version_id = required.test_definition_version_id
   );

  SELECT count(*) INTO blocking_count
    FROM test_result r
   WHERE r.test_run_id = p_test_run_id
     AND r.test_definition_version_id = ANY (coalesce(required_ids, ARRAY[]::uuid[]))
     AND r.result <> 'pass';

  RETURN jsonb_build_object(
    'decision', CASE WHEN required_count > 0 AND missing_count = 0 AND blocking_count = 0
                    THEN 'pass' ELSE 'blocked' END,
    'targetPhase', catalog_phase::text,
    'targetGate', catalog_gate::text,
    'requiredCount', required_count,
    'observedCount', observed_count,
    'missingCount', missing_count,
    'blockingCount', blocking_count,
    'requiredDefinitionVersionIds', coalesce(to_jsonb(required_ids), '[]'::jsonb)
  );
END;
$$;

COMMIT;
