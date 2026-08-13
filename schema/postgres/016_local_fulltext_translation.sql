-- Rights-aware article text archive and version-bound Chinese translation.
-- Original text and translations are append-only. A source_version may have
-- at most one successful artifact per provider/model/prompt combination.
BEGIN;

ALTER TABLE local_translation_artifact ADD COLUMN IF NOT EXISTS source_version_id text;
UPDATE local_translation_artifact t
   SET source_version_id = (
     SELECT v.version_id FROM local_source_item_version v
      WHERE v.item_key = t.item_key AND v.content_hash = t.original_content_hash
      ORDER BY v.created_at ASC, v.version_id ASC LIMIT 1
   )
 WHERE t.source_version_id IS NULL;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM local_translation_artifact WHERE source_version_id IS NULL) THEN
    RAISE EXCEPTION 'translation artifact cannot be bound to immutable source version';
  END IF;
END $$;
ALTER TABLE local_translation_artifact ALTER COLUMN source_version_id SET NOT NULL;
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_item_key text;
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_version_id text;
ALTER TABLE local_radar_card ADD COLUMN IF NOT EXISTS source_content_hash text NOT NULL DEFAULT '';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='local_translation_artifact'::regclass AND conname='local_translation_artifact_source_version_fkey') THEN
    ALTER TABLE local_translation_artifact ADD CONSTRAINT local_translation_artifact_source_version_fkey FOREIGN KEY (source_version_id) REFERENCES local_source_item_version(version_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='local_radar_card'::regclass AND conname='local_radar_card_source_version_fkey') THEN
    ALTER TABLE local_radar_card ADD CONSTRAINT local_radar_card_source_version_fkey FOREIGN KEY (source_version_id) REFERENCES local_source_item_version(version_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='local_radar_card'::regclass AND conname='local_radar_card_source_item_fkey') THEN
    ALTER TABLE local_radar_card ADD CONSTRAINT local_radar_card_source_item_fkey FOREIGN KEY (source_item_key) REFERENCES local_source_item(item_key);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS local_metadata_translation_run (
  run_id text PRIMARY KEY,
  source_version_id text NOT NULL REFERENCES local_source_item_version(version_id),
  item_key text NOT NULL REFERENCES local_source_item(item_key),
  source_content_hash text NOT NULL,
  target_language text NOT NULL CHECK (target_language = 'zh-CN'),
  provider text NOT NULL CHECK (provider = 'deepseek'),
  model text NOT NULL CHECK (model = 'deepseek-v4-pro'),
  prompt_version text NOT NULL,
  state text NOT NULL CHECK (state IN ('pending','running','succeeded','failed','budget_blocked','credential_blocked')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  input_chars integer NOT NULL CHECK (input_chars >= 0),
  prompt_tokens integer NOT NULL DEFAULT 0 CHECK (prompt_tokens >= 0),
  completion_tokens integer NOT NULL DEFAULT 0 CHECK (completion_tokens >= 0),
  error_reason text NOT NULL DEFAULT '',
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_key, source_content_hash, target_language, provider, model, prompt_version),
  CHECK ((state IN ('pending','running') AND finished_at IS NULL) OR (state NOT IN ('pending','running') AND finished_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS local_metadata_translation_run_queue_idx
  ON local_metadata_translation_run(state, created_at, run_id);

CREATE TABLE IF NOT EXISTS local_article_archive_attempt (
  attempt_id text PRIMARY KEY,
  source_version_id text NOT NULL REFERENCES local_source_item_version(version_id),
  rights_scope text NOT NULL CHECK (rights_scope IN ('full_archive', 'excerpt_only', 'link_only')),
  outcome text NOT NULL CHECK (outcome IN ('archived', 'not_permitted', 'fetch_failed', 'parse_failed', 'empty_body', 'too_large')),
  http_status integer CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  fetched_at timestamptz NOT NULL,
  final_url text NOT NULL DEFAULT '',
  content_type text NOT NULL DEFAULT '',
  response_bytes bigint NOT NULL DEFAULT 0 CHECK (response_bytes >= 0),
  error_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_version_id, rights_scope),
  CHECK ((outcome = 'archived' AND btrim(error_reason) = '') OR (outcome <> 'archived' AND btrim(error_reason) <> ''))
);

CREATE TABLE IF NOT EXISTS local_source_archive_policy (
  policy_id text PRIMARY KEY,
  source_id text NOT NULL,
  rights_scope text NOT NULL CHECK (rights_scope IN ('full_archive', 'excerpt_only', 'link_only')),
  permission_basis text NOT NULL,
  permission_verified_at timestamptz,
  source_config_hash text NOT NULL,
  effective_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, source_config_hash),
  CHECK ((rights_scope = 'full_archive' AND permission_basis IN ('publisher_permission','open_license','public_domain','robots_and_terms_reviewed') AND permission_verified_at IS NOT NULL)
      OR (rights_scope <> 'full_archive' AND permission_basis = '' AND permission_verified_at IS NULL))
);

CREATE TABLE IF NOT EXISTS local_article_archive (
  archive_id text PRIMARY KEY,
  attempt_id text NOT NULL UNIQUE REFERENCES local_article_archive_attempt(attempt_id),
  source_version_id text NOT NULL UNIQUE REFERENCES local_source_item_version(version_id),
  source_url text NOT NULL,
  final_url text NOT NULL,
  source_language text NOT NULL,
  title text NOT NULL,
  body_text text NOT NULL CHECK (btrim(body_text) <> ''),
  image_captions jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(image_captions) = 'array'),
  extraction_method text NOT NULL,
  extractor_version text NOT NULL,
  body_hash text NOT NULL CHECK (btrim(body_hash) <> ''),
  body_chars integer NOT NULL CHECK (body_chars > 0),
  archived_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (body_chars = char_length(body_text))
);

CREATE TABLE IF NOT EXISTS local_article_translation_run (
  run_id text PRIMARY KEY,
  archive_id text NOT NULL REFERENCES local_article_archive(archive_id),
  target_language text NOT NULL CHECK (target_language = 'zh-CN'),
  provider text NOT NULL CHECK (provider = 'deepseek'),
  model text NOT NULL CHECK (model = 'deepseek-v4-pro'),
  prompt_version text NOT NULL,
  source_body_hash text NOT NULL,
  state text NOT NULL CHECK (state IN ('pending', 'running', 'succeeded', 'failed', 'budget_blocked', 'credential_blocked')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  input_chars integer NOT NULL CHECK (input_chars >= 0),
  prompt_tokens integer NOT NULL DEFAULT 0 CHECK (prompt_tokens >= 0),
  completion_tokens integer NOT NULL DEFAULT 0 CHECK (completion_tokens >= 0),
  error_reason text NOT NULL DEFAULT '',
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (archive_id, target_language, provider, model, prompt_version, source_body_hash),
  CHECK ((state IN ('pending', 'running') AND finished_at IS NULL) OR (state NOT IN ('pending', 'running') AND finished_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS local_article_translation_artifact (
  artifact_id text PRIMARY KEY,
  run_id text NOT NULL UNIQUE REFERENCES local_article_translation_run(run_id),
  archive_id text NOT NULL REFERENCES local_article_archive(archive_id),
  source_body_hash text NOT NULL,
  target_language text NOT NULL CHECK (target_language = 'zh-CN'),
  provider text NOT NULL CHECK (provider = 'deepseek'),
  model text NOT NULL CHECK (model = 'deepseek-v4-pro'),
  prompt_version text NOT NULL,
  translated_title text NOT NULL CHECK (btrim(translated_title) <> ''),
  translated_summary text NOT NULL CHECK (btrim(translated_summary) <> ''),
  translated_body text NOT NULL CHECK (btrim(translated_body) <> ''),
  translated_image_captions jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(translated_image_captions) = 'array'),
  output_hash text NOT NULL,
  validation_status text NOT NULL CHECK (validation_status IN ('mechanical_pass', 'needs_review')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (archive_id, target_language, provider, model, prompt_version, source_body_hash)
);

CREATE INDEX IF NOT EXISTS local_article_translation_run_queue_idx
  ON local_article_translation_run (state, created_at, run_id);

CREATE OR REPLACE FUNCTION local_article_immutable_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;

DROP TRIGGER IF EXISTS local_article_archive_attempt_immutable_trigger ON local_article_archive_attempt;
CREATE TRIGGER local_article_archive_attempt_immutable_trigger BEFORE UPDATE OR DELETE ON local_article_archive_attempt
FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();
DROP TRIGGER IF EXISTS local_source_archive_policy_immutable_trigger ON local_source_archive_policy;
CREATE TRIGGER local_source_archive_policy_immutable_trigger BEFORE UPDATE OR DELETE ON local_source_archive_policy
FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();
DROP TRIGGER IF EXISTS local_article_archive_immutable_trigger ON local_article_archive;
CREATE TRIGGER local_article_archive_immutable_trigger BEFORE UPDATE OR DELETE ON local_article_archive
FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();
DROP TRIGGER IF EXISTS local_article_translation_artifact_immutable_trigger ON local_article_translation_artifact;
CREATE TRIGGER local_article_translation_artifact_immutable_trigger BEFORE UPDATE OR DELETE ON local_article_translation_artifact
FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();
DROP TRIGGER IF EXISTS local_translation_artifact_immutable_trigger ON local_translation_artifact;
CREATE TRIGGER local_translation_artifact_immutable_trigger BEFORE UPDATE OR DELETE ON local_translation_artifact
FOR EACH ROW EXECUTE FUNCTION local_article_immutable_guard();

CREATE TABLE IF NOT EXISTS local_fulltext_schema_meta (
  schema_version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO local_fulltext_schema_meta(schema_version)
VALUES ('016_local_fulltext_translation_v1') ON CONFLICT DO NOTHING;

COMMIT;
