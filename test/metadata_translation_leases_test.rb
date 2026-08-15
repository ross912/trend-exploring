# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require "tempfile"
require_relative "../lib/local_radar_store"

class MetadataTranslationLeasesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "metadata_translation_leases_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql 024_metadata_translation_leases.sql].each do |file|
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = LocalRadarStore.new(psql: bin("psql"), host: host, port: port, user: user, database: @database)
    seed_source
  end

  def teardown
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, @database]) if @database
  end

  def test_mismatched_artifact_rolls_back_without_terminalizing_run
    candidate, job_id = claim_candidate
    artifact = artifact_for(candidate).merge("source_version_id" => "not-the-claimed-version")
    result = { "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1 } }

    assert_raises(LocalRadarStore::Error) do
      @store.commit_metadata_translation_success!(run_id: candidate.fetch("translation_run_id"), result: result, artifact: artifact, owner: "lease-owner", job_id: job_id)
    end
    assert_equal "running", scalar_text("SELECT state FROM local_metadata_translation_run")
    assert_equal 0, scalar("SELECT COUNT(*) FROM local_translation_artifact")

    @store.commit_metadata_translation_success!(run_id: candidate.fetch("translation_run_id"), result: result, artifact: artifact_for(candidate), owner: "lease-owner", job_id: job_id)
    assert_equal "succeeded", scalar_text("SELECT state FROM local_metadata_translation_run")
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_translation_artifact")
  end

  def test_024_migration_is_idempotent
    run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/024_metadata_translation_leases.sql")])
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_translation_lease_schema_meta WHERE schema_version = '024_metadata_translation_leases_v1'")
    assert_equal 1, scalar("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_translation_artifact'::regclass AND conname = 'local_translation_artifact_lineage_unique'")
  end

  def test_024_upgrade_preserves_existing_append_only_artifact_and_assigns_legacy_prompt
    database = disposable_database("legacy_artifact")
    begin
      run_migrations(database, %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql])
      store = store_for(database)
      seed_source(store: store)
      version = store.source_item_versions(item_key: "item").fetch(0)
      store.save_translation_artifact!(artifact: artifact_for_version(version))
      before_hash = artifact_payload_hash(database)

      assert_equal 0, scalar_on(database, "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_translation_artifact' AND column_name = 'prompt_version'")
      run_migration(database, "024_metadata_translation_leases.sql")

      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal "metadata-translation-v1", scalar_text_on(database, "SELECT prompt_version FROM local_translation_artifact")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_translation_artifact'::regclass AND conname = 'local_translation_artifact_lineage_unique'")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM pg_trigger WHERE tgrelid = 'local_translation_artifact'::regclass AND tgname = 'local_translation_artifact_immutable_trigger' AND NOT tgenabled = 'D'")
      assert_raises(RuntimeError) { sql_on(database, "UPDATE local_translation_artifact SET translated_title = 'tampered'") }

      run_migration(database, "024_metadata_translation_leases.sql")
      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal "metadata-translation-v1", scalar_text_on(database, "SELECT prompt_version FROM local_translation_artifact")
    ensure
      drop_disposable_database(database)
    end
  end

  def test_024_refuses_nullable_prompt_nulls_without_rewriting_append_only_rows
    database = disposable_database("partial_prompt")
    begin
      run_migrations(database, %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql])
      store = store_for(database)
      seed_source(store: store)
      version = store.source_item_versions(item_key: "item").fetch(0)
      sql_on(database, "ALTER TABLE local_translation_artifact ADD COLUMN prompt_version text")
      sql_on(database, <<~SQL)
        INSERT INTO local_translation_artifact
          (artifact_id, source_version_id, item_key, source_language, target_language,
           original_content_hash, provider, model, translated_title, translated_summary,
           validation_status, status, error_reason)
        VALUES ('partial-artifact', '#{version.fetch("version_id")}', '#{version.fetch("item_key")}',
                '#{version.fetch("language")}', 'zh-CN', '#{version.fetch("content_hash")}',
                'deepseek', 'deepseek-v4-pro', '标题', '摘要', 'mechanical_pass', 'translated', '')
      SQL
      before_hash = artifact_payload_hash(database)

      error = assert_raises(RuntimeError) { run_migration(database, "024_metadata_translation_leases.sql") }
      assert_match(/prompt_version contains NULL/i, error.message)
      assert_match(/restore the pre-024 backup/i, error.message)
      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM local_translation_artifact WHERE prompt_version IS NULL")
      assert_equal 0, scalar_on(database, "SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_translation_artifact'::regclass AND conname = 'local_translation_artifact_lineage_unique'")
    ensure
      drop_disposable_database(database)
    end
  end

  def test_024_promotes_existing_nonnull_prompt_column_to_not_null
    database = disposable_database("nonnull_prompt")
    begin
      run_migrations(database, %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql])
      store = store_for(database)
      seed_source(store: store)
      version = store.source_item_versions(item_key: "item").fetch(0)
      sql_on(database, "ALTER TABLE local_translation_artifact ADD COLUMN prompt_version text")
      sql_on(database, <<~SQL)
        INSERT INTO local_translation_artifact
          (artifact_id, source_version_id, item_key, source_language, target_language,
           original_content_hash, provider, model, prompt_version, translated_title,
           translated_summary, validation_status, status, error_reason)
        VALUES ('nonnull-artifact', '#{version.fetch("version_id")}', '#{version.fetch("item_key")}',
                '#{version.fetch("language")}', 'zh-CN', '#{version.fetch("content_hash")}',
                'deepseek', 'deepseek-v4-pro', 'legacy-prompt-v7', '标题', '摘要',
                'mechanical_pass', 'translated', '')
      SQL
      before_hash = artifact_payload_hash(database)

      run_migration(database, "024_metadata_translation_leases.sql")
      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal "legacy-prompt-v7", scalar_text_on(database, "SELECT prompt_version FROM local_translation_artifact")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM pg_attribute WHERE attrelid = 'local_translation_artifact'::regclass AND attname = 'prompt_version' AND attnotnull")
    ensure
      drop_disposable_database(database)
    end
  end

  def test_024_upgrades_historical_marker_shape_without_preflight_shortcut
    database = disposable_database("historical_marker")
    personal_database = disposable_database("historical_personal")
    begin
      run_migrations(database, %w[
        011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql
        014_local_report_summary.sql 015_local_weak_signal.sql 016_local_fulltext_translation.sql
        017_raw_archive_immutability.sql 018_multilingual_concepts.sql 019_world_change_candidates.sql
        020_signal_lifecycle.sql 021_report_claim_gate.sql 022_report_summary_repair.sql 023_summary_run_leases.sql
      ])
      run_migrations(personal_database, %w[personal/001_personal_memory.sql personal/002_conversation_ledger.sql])
      store = store_for(database)
      seed_source(store: store)
      version = store.source_item_versions(item_key: "item").fetch(0)
      store.save_translation_artifact!(artifact: artifact_for_version(version))
      before_hash = artifact_payload_hash(database)

      run_git_migration(database, "f122fdf", "schema/postgres/024_metadata_translation_leases.sql")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM local_translation_lease_schema_meta WHERE schema_version = '024_metadata_translation_leases_v1'")
      assert_equal 0, scalar_on(database, "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_translation_artifact' AND column_name = 'prompt_version'")

      success, output = verify_backup_stats(database, personal_database)
      refute success
      assert_match(/partial 024 schema/i, output)

      run_migration(database, "024_metadata_translation_leases.sql")
      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal "metadata-translation-v1", scalar_text_on(database, "SELECT prompt_version FROM local_translation_artifact")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_translation_artifact'::regclass AND conname = 'local_translation_artifact_lineage_unique'")
      assert_equal 1, scalar_on(database, "SELECT COUNT(*) FROM pg_trigger WHERE tgrelid = 'local_translation_artifact'::regclass AND tgname = 'local_translation_artifact_immutable_trigger' AND NOT tgenabled = 'D'")
      success, output = verify_backup_stats(database, personal_database)
      assert success
      assert_match(/post_024/, output)

      run_migration(database, "024_metadata_translation_leases.sql")
      assert_equal before_hash, artifact_payload_hash(database)
      assert_equal "metadata-translation-v1", scalar_text_on(database, "SELECT prompt_version FROM local_translation_artifact")
    ensure
      drop_disposable_database(database)
      drop_disposable_database(personal_database)
    end
  end

  def test_024_refuses_an_early_schema_without_016
    database = disposable_database("early_schema")
    begin
      run_migrations(database, %w[011_local_radar.sql 012_breadth_discovery.sql])
      error = assert_raises(RuntimeError) { run_migration(database, "024_metadata_translation_leases.sql") }
      assert_match(/requires 016_local_fulltext_translation/i, error.message)
      assert_equal 0, scalar_on(database, "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'local_translation_lease_schema_meta'")
    ensure
      drop_disposable_database(database)
    end
  end

  def test_expired_running_row_is_reconciled_as_interrupted
    candidate, = claim_candidate
    sql!("UPDATE local_metadata_translation_run SET lease_expires_at = now() - interval '1 second' WHERE run_id = '#{candidate.fetch('translation_run_id')}'")

    assert_equal [candidate.fetch("translation_run_id")], @store.recover_stale_metadata_translation_runs!(owner: "crash-recovery")
    assert_equal "interrupted", scalar_text("SELECT state FROM local_metadata_translation_run")
    assert_equal 0, scalar("SELECT COUNT(*) FROM local_translation_artifact")
  end

  def test_batch_attempt_and_terminal_job_history_cannot_be_mutated
    candidate, job_id = claim_candidate
    @store.send(:record_translation_batch_attempt!, job_id: job_id, run_id: candidate.fetch("translation_run_id"), owner_id: "lease-owner", event: "heartbeat")
    assert_raises(RuntimeError) { sql!("UPDATE local_translation_batch_attempt SET error_reason = 'tampered'") }
    assert_raises(RuntimeError) { sql!("DELETE FROM local_translation_batch_attempt") }
    assert_raises(RuntimeError) { sql!("TRUNCATE local_translation_batch_attempt") }

    @store.finish_translation_batch_job!(job_id: job_id, owner: "lease-owner", state: "succeeded", counters: { "queued_count" => 1, "examined_count" => 0 })
    assert_raises(RuntimeError) { sql!("UPDATE local_translation_batch_job SET heartbeat_at = now() WHERE job_id = '#{job_id}'") }
    assert_raises(RuntimeError) { sql!("DELETE FROM local_translation_batch_job WHERE job_id = '#{job_id}'") }
  end

  private

  def claim_candidate
    @store.ensure_metadata_translation_runs!
    candidate = @store.metadata_translation_candidates(limit: 1, daily_character_limit: 10_000).fetch(0)
    job_id = @store.start_translation_batch_job!(limit: 1, daily_character_limit: 10_000, owner: "lease-owner")
    @store.start_metadata_translation!(run_id: candidate.fetch("translation_run_id"), owner: "lease-owner", job_id: job_id)
    [candidate, job_id]
  end

  def artifact_for(candidate)
    {
      "artifact_id" => "artifact-#{candidate.fetch('translation_run_id')}",
      "source_version_id" => candidate.fetch("version_id"),
      "item_key" => candidate.fetch("item_key"),
      "source_language" => candidate.fetch("language"),
      "target_language" => "zh-CN",
      "original_content_hash" => candidate.fetch("content_hash"),
      "provider" => "deepseek",
      "model" => "deepseek-v4-pro",
      "prompt_version" => candidate.fetch("prompt_version"),
      "translated_title" => "标题 2026",
      "translated_summary" => "摘要",
      "validation_status" => "mechanical_pass",
      "status" => "translated",
      "error_reason" => ""
    }
  end

  def seed_source(store: @store)
    source = { "id" => "source", "name" => "source", "url" => "https://example.test/feed", "language" => "en", "region" => "global", "publisher_id" => "publisher", "publisher_name" => "Publisher", "publisher_url" => "https://example.test", "rights_scope" => "excerpt_only" }
    store.register_sources!(sources: [source])
    store.register_archive_policies!(sources: [source])
    store.ingest_source_items!(items: [{ "item_key" => "item", "source_id" => "source", "source_name" => "source", "language" => "en", "region" => "global", "publisher_id" => "publisher", "publisher_name" => "Publisher", "publisher_url" => "https://example.test", "publisher_identity_status" => "configured", "source_kind" => "configured", "title" => "Title 2026", "summary" => "Summary", "source_url" => "https://example.test/item", "published_at" => "2026-08-15T00:00:00Z", "fetched_at" => "2026-08-15T00:01:00Z", "capture_id" => "capture", "capture_captured_at" => "2026-08-15T00:01:00Z", "capture_body_hash" => "feed-hash", "rights_scope" => "excerpt_only" }])
  end

  def store_for(database)
    LocalRadarStore.new(psql: bin("psql"), host: host, port: port, user: user, database: database)
  end

  def disposable_database(label)
    database = "#{PREFIX}#{label}_#{SecureRandom.hex(5)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, database])
    database
  end

  def drop_disposable_database(database)
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, database]) if database
  rescue StandardError
    nil
  end

  def run_migrations(database, files)
    files.each { |file| run_migration(database, file) }
  end

  def run_migration(database, file)
    run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(ROOT, "schema/postgres", file)])
  end

  def run_git_migration(database, revision, file)
    sql, stderr, status = Open3.capture3("git", "show", "#{revision}:#{file}", chdir: ROOT)
    raise stderr unless status.success?
    Tempfile.create(["metadata-translation-", ".sql"]) do |migration|
      migration.write(sql)
      migration.flush
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", migration.path])
    end
  end

  def verify_backup_stats(database, personal_database)
    Tempfile.create(["verify-backup-", ".json"]) do |stats|
      args = ["ruby", File.join(ROOT, "scripts/local/verify_backup.rb"), "--write-stats", stats.path,
              "--psql", bin("psql"), "--global-database", database, "--personal-database", personal_database,
              "--host", host, "--port", port, "--user", user]
      stdout, stderr, status = Open3.capture3(*args)
      [status.success?, "#{stderr}\n#{stdout}"]
    end
  end

  def artifact_for_version(version)
    {
      "artifact_id" => "legacy-artifact",
      "source_version_id" => version.fetch("version_id"),
      "item_key" => version.fetch("item_key"),
      "source_language" => version.fetch("language"),
      "target_language" => "zh-CN",
      "original_content_hash" => version.fetch("content_hash"),
      "provider" => "deepseek",
      "model" => "deepseek-v4-pro",
      "translated_title" => "标题 2026",
      "translated_summary" => "摘要",
      "validation_status" => "mechanical_pass",
      "status" => "translated",
      "error_reason" => ""
    }
  end

  def host; ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket"); end
  def port; ENV.fetch("LOCAL_PGPORT", "55433"); end
  def user; ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")); end
  def bin(name); File.join(ENV.fetch("PG_BIN", "/private/tmp/trend-exploring-postgres15-runtime/bin"), name); end
  def run!(args); stdout, stderr, status = Open3.capture3(*args); raise "#{stderr}\n#{stdout}" unless status.success?; stdout; end
  def sql!(sql); run!([bin("psql"), "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-c", sql]); end
  def sql_on(database, sql); run!([bin("psql"), "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-c", sql]); end
  def scalar(sql); sql!(sql).strip.to_i; end
  def scalar_text(sql); sql!(sql).strip; end
  def scalar_on(database, sql); sql_on(database, sql).strip.to_i; end
  def scalar_text_on(database, sql); sql_on(database, sql).strip; end
  def artifact_payload_hash(database)
    scalar_text_on(database, <<~SQL)
      SELECT md5(row_to_json(legacy)::text)
        FROM (
          SELECT artifact_id, source_version_id, item_key, source_language, target_language,
                 original_content_hash, provider, model, translated_title, translated_summary,
                 validation_status, status, error_reason, created_at::text
            FROM local_translation_artifact
           ORDER BY artifact_id
        ) legacy
    SQL
  end
end
