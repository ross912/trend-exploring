-- Deterministic local weak-signal v1.  This migration is additive and
-- content-addressed: a run and its candidates are immutable once committed.
BEGIN;

-- If an early draft relation already contains rows but is missing the frozen
-- run/candidate shape, fail before CREATE/ALTER can reinterpret those rows.
-- Empty clean installs (and a complete 015 rerun) pass this guard.
DO $$
DECLARE
  rel regclass;
  row_count bigint;
  required_ok boolean;
  structural_ok boolean;
BEGIN
  FOREACH rel IN ARRAY ARRAY[to_regclass('weak_signal_run'), to_regclass('weak_signal_candidate')] LOOP
    CONTINUE WHEN rel IS NULL;
    EXECUTE format('SELECT COUNT(*) FROM %s', rel) INTO row_count;
    IF rel::text = 'weak_signal_run' THEN
      SELECT COUNT(*) = 11 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['run_id','as_of','recent_window_hours','prior_window_days','prior_bucket_count','input_cutoff','input_hash','detector_version','status','payload_hash','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'weak_signal_run_pkey') INTO structural_ok;
    ELSE
      SELECT COUNT(*) = 19 INTO required_ok
        FROM pg_attribute WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
          AND attname = ANY (ARRAY['run_id','phrase','language','reason_codes','counts','recent_publisher_count','prior_publisher_count','recent_observation_count','prior_observation_count','prior_bucket_counts','recent_evidence_version_ids','prior_evidence_version_ids','evidence','publishers','languages','locales','explanation','sort_order','created_at']);
      SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = rel AND conname = 'weak_signal_candidate_pkey') INTO structural_ok;
    END IF;
    IF row_count > 0 AND (NOT required_ok OR NOT structural_ok) THEN
      RAISE EXCEPTION 'unsupported early-draft data in %; refusing weak-signal migration', rel;
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS weak_signal_run (
  run_id text PRIMARY KEY,
  as_of timestamptz NOT NULL,
  recent_window_hours integer NOT NULL CHECK (recent_window_hours > 0),
  prior_window_days integer NOT NULL CHECK (prior_window_days > 0),
  prior_bucket_count integer NOT NULL CHECK (prior_bucket_count > 0),
  input_cutoff timestamptz NOT NULL,
  input_hash text NOT NULL CHECK (btrim(input_hash) <> ''),
  payload_hash text NOT NULL CHECK (btrim(payload_hash) <> ''),
  detector_version text NOT NULL CHECK (btrim(detector_version) <> ''),
  status text NOT NULL CHECK (status IN ('warming_up', 'evaluated')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (run_id, input_hash)
);

CREATE TABLE IF NOT EXISTS weak_signal_candidate (
  run_id text NOT NULL REFERENCES weak_signal_run(run_id) ON DELETE CASCADE,
  phrase text NOT NULL CHECK (btrim(phrase) <> ''),
  language text NOT NULL CHECK (btrim(language) <> ''),
  reason_codes jsonb NOT NULL,
  counts JSONB NOT NULL DEFAULT '{}'::jsonb,
  recent_publisher_count integer NOT NULL CHECK (recent_publisher_count >= 0),
  prior_publisher_count integer NOT NULL CHECK (prior_publisher_count >= 0),
  recent_observation_count integer NOT NULL CHECK (recent_observation_count >= 0),
  prior_observation_count integer NOT NULL CHECK (prior_observation_count >= 0),
  prior_bucket_counts jsonb NOT NULL,
  recent_evidence_version_ids jsonb NOT NULL,
  prior_evidence_version_ids jsonb NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  publishers JSONB NOT NULL DEFAULT '{}'::jsonb,
  languages JSONB NOT NULL DEFAULT '{}'::jsonb,
  locales JSONB NOT NULL DEFAULT '{}'::jsonb,
  explanation text NOT NULL,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, phrase, language),
  UNIQUE (run_id, sort_order),
  CHECK (jsonb_typeof(reason_codes) = 'array'),
  CHECK (jsonb_typeof(counts) = 'object'),
  CHECK (jsonb_typeof(prior_bucket_counts) = 'array'),
  CHECK (jsonb_typeof(recent_evidence_version_ids) = 'array'),
  CHECK (jsonb_typeof(prior_evidence_version_ids) = 'array'),
  CHECK (jsonb_typeof(evidence) = 'object'),
  CHECK (jsonb_typeof(publishers) = 'object'),
  CHECK (jsonb_typeof(languages) = 'object'),
  CHECK (jsonb_typeof(locales) = 'object'),
  CHECK (jsonb_array_length(recent_evidence_version_ids) <= 20),
  CHECK (jsonb_array_length(prior_evidence_version_ids) <= 20)
);

CREATE INDEX IF NOT EXISTS weak_signal_run_latest_idx
  ON weak_signal_run (status, as_of DESC, created_at DESC, run_id ASC);

CREATE INDEX IF NOT EXISTS weak_signal_candidate_run_order_idx
  ON weak_signal_candidate (run_id, sort_order ASC);

COMMIT;
