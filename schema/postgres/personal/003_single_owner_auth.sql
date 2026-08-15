-- Single-owner authentication domain.  This migration is intentionally
-- scoped to the personal database: no credential, session, recovery, or
-- client identity material belongs in the global radar database.
BEGIN;

CREATE TABLE IF NOT EXISTS cloud_owner_account (
  account_id text PRIMARY KEY,
  username text NOT NULL UNIQUE CHECK (btrim(username) <> ''),
  password_digest text NOT NULL CHECK (btrim(password_digest) <> ''),
  recovery_code_digest text NOT NULL CHECK (btrim(recovery_code_digest) <> ''),
  recovery_used_at timestamptz,
  failed_login_count integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
  login_locked_until timestamptz,
  password_changed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  disabled_at timestamptz,
  CONSTRAINT cloud_owner_account_single_owner_id CHECK (account_id = 'owner')
);

-- A session stores only SHA-256 digests.  The raw 256-bit values exist only
-- in the browser cookie and request process memory.
CREATE TABLE IF NOT EXISTS cloud_auth_session (
  session_hash text PRIMARY KEY CHECK (session_hash ~ '^[a-f0-9]{64}$'),
  account_id text NOT NULL REFERENCES cloud_owner_account(account_id),
  csrf_hash text NOT NULL CHECK (csrf_hash ~ '^[a-f0-9]{64}$'),
  issued_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  idle_expires_at timestamptz NOT NULL,
  absolute_expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CONSTRAINT cloud_auth_session_expiry_order CHECK (idle_expires_at >= last_seen_at),
  CONSTRAINT cloud_auth_session_absolute_order CHECK (absolute_expires_at >= issued_at)
);

CREATE INDEX IF NOT EXISTS cloud_auth_session_account_idx
  ON cloud_auth_session(account_id, revoked_at, absolute_expires_at);
CREATE INDEX IF NOT EXISTS cloud_auth_session_idle_idx
  ON cloud_auth_session(idle_expires_at) WHERE revoked_at IS NULL;

-- Security events intentionally contain only an IP digest and coarse outcome;
-- the source IP is never retained.
CREATE TABLE IF NOT EXISTS cloud_auth_event (
  event_id text PRIMARY KEY,
  account_id text REFERENCES cloud_owner_account(account_id),
  event_type text NOT NULL CHECK (event_type IN ('login_success', 'login_failure', 'logout', 'recovery_success', 'recovery_failure', 'revoke_all')),
  ip_hash text CHECK (ip_hash IS NULL OR ip_hash ~ '^[a-f0-9]{64}$'),
  request_id text CHECK (request_id IS NULL OR request_id ~ '^[A-Za-z0-9._-]{1,96}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cloud_auth_event_created_idx
  ON cloud_auth_event(created_at DESC, event_type);

-- Refuse to silently continue against a partial or incompatible historical
-- table.  Existing rows are preserved, but all required columns/keys must be
-- present before this migration advertises readiness.
DO $$
DECLARE
  missing text;
BEGIN
  SELECT string_agg(required.column_name, ', ' ORDER BY required.column_name)
    INTO missing
    FROM (VALUES
      ('account_id'), ('username'), ('password_digest'), ('recovery_code_digest'),
      ('recovery_used_at'), ('failed_login_count'), ('login_locked_until'),
      ('password_changed_at'), ('created_at'), ('updated_at'), ('disabled_at')
    ) AS required(column_name)
   WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
       WHERE c.table_schema = current_schema()
         AND c.table_name = 'cloud_owner_account'
         AND c.column_name = required.column_name
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'cloud_owner_account shape is incomplete: %', missing;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = 'cloud_owner_account'::regclass AND c.contype = 'p'
  ) THEN
    RAISE EXCEPTION 'cloud_owner_account primary key is required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = 'cloud_auth_session'::regclass AND c.contype = 'p'
  ) THEN
    RAISE EXCEPTION 'cloud_auth_session primary key is required';
  END IF;
  SELECT string_agg(required.column_name, ', ' ORDER BY required.column_name)
    INTO missing
    FROM (VALUES
      ('session_hash'), ('account_id'), ('csrf_hash'), ('issued_at'), ('last_seen_at'),
      ('idle_expires_at'), ('absolute_expires_at'), ('revoked_at')
    ) AS required(column_name)
   WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
       WHERE c.table_schema = current_schema()
         AND c.table_name = 'cloud_auth_session'
         AND c.column_name = required.column_name
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'cloud_auth_session shape is incomplete: %', missing;
  END IF;
  SELECT string_agg(required.column_name, ', ' ORDER BY required.column_name)
    INTO missing
    FROM (VALUES
      ('event_id'), ('account_id'), ('event_type'), ('ip_hash'), ('request_id'), ('created_at')
    ) AS required(column_name)
   WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
       WHERE c.table_schema = current_schema()
         AND c.table_name = 'cloud_auth_event'
         AND c.column_name = required.column_name
   );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'cloud_auth_event shape is incomplete: %', missing;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS cloud_auth_schema_meta (
  schema_version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM cloud_auth_schema_meta
     WHERE schema_version <> '003_single_owner_auth_v1'
  ) THEN
    RAISE EXCEPTION 'cloud auth schema marker is incompatible';
  END IF;
END $$;
INSERT INTO cloud_auth_schema_meta(schema_version)
VALUES ('003_single_owner_auth_v1')
ON CONFLICT (schema_version) DO NOTHING;

CREATE OR REPLACE FUNCTION cloud_auth_event_append_only_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'cloud_auth_event is append-only; updates, deletes and truncates are forbidden';
END;
$$;

DROP TRIGGER IF EXISTS cloud_auth_event_immutable_trigger ON cloud_auth_event;
CREATE TRIGGER cloud_auth_event_immutable_trigger
BEFORE UPDATE OR DELETE ON cloud_auth_event
FOR EACH ROW EXECUTE FUNCTION cloud_auth_event_append_only_guard();

DROP TRIGGER IF EXISTS cloud_auth_event_truncate_trigger ON cloud_auth_event;
CREATE TRIGGER cloud_auth_event_truncate_trigger
BEFORE TRUNCATE ON cloud_auth_event
FOR EACH STATEMENT EXECUTE FUNCTION cloud_auth_event_append_only_guard();

COMMIT;
