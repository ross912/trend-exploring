# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
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

  def seed_source
    source = { "id" => "source", "name" => "source", "url" => "https://example.test/feed", "language" => "en", "region" => "global", "publisher_id" => "publisher", "publisher_name" => "Publisher", "publisher_url" => "https://example.test", "rights_scope" => "excerpt_only" }
    @store.register_sources!(sources: [source])
    @store.register_archive_policies!(sources: [source])
    @store.ingest_source_items!(items: [{ "item_key" => "item", "source_id" => "source", "source_name" => "source", "language" => "en", "region" => "global", "publisher_id" => "publisher", "publisher_name" => "Publisher", "publisher_url" => "https://example.test", "publisher_identity_status" => "configured", "source_kind" => "configured", "title" => "Title 2026", "summary" => "Summary", "source_url" => "https://example.test/item", "published_at" => "2026-08-15T00:00:00Z", "fetched_at" => "2026-08-15T00:01:00Z", "capture_id" => "capture", "capture_captured_at" => "2026-08-15T00:01:00Z", "capture_body_hash" => "feed-hash", "rights_scope" => "excerpt_only" }])
  end

  def host; ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket"); end
  def port; ENV.fetch("LOCAL_PGPORT", "55433"); end
  def user; ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")); end
  def bin(name); File.join(ENV.fetch("PG_BIN", "/private/tmp/trend-exploring-postgres15-runtime/bin"), name); end
  def run!(args); stdout, stderr, status = Open3.capture3(*args); raise "#{stderr}\n#{stdout}" unless status.success?; stdout; end
  def sql!(sql); run!([bin("psql"), "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-c", sql]); end
  def scalar(sql); sql!(sql).strip.to_i; end
  def scalar_text(sql); sql!(sql).strip; end
end
