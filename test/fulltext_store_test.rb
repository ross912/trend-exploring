# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/local_radar_store"

class FulltextStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "trend_exploring_fulltext_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql 016_local_fulltext_translation.sql].each do |file|
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = LocalRadarStore.new(psql: bin("psql"), host: host, port: port, database: @database, user: user)
  end

  def teardown
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, @database]) if @database
  end

  def test_policy_is_append_only_and_excerpt_attempt_does_not_create_body
    source = { "id" => "source", "name" => "source", "url" => "https://example.test/feed", "language" => "en", "region" => "global", "publisher_id" => "example", "publisher_name" => "Example", "publisher_url" => "https://example.test/", "rights_scope" => "excerpt_only" }
    @store.register_sources!(sources: [source])
    @store.register_archive_policies!(sources: [source])
    item = { "item_key" => "item", "source_id" => "source", "source_name" => "source", "language" => "en", "region" => "global", "publisher_id" => "example", "publisher_name" => "Example", "publisher_url" => "https://example.test/", "publisher_identity_status" => "configured", "source_kind" => "configured", "title" => "Title 2026", "summary" => "Summary", "source_url" => "https://example.test/article", "published_at" => "2026-08-13T00:00:00Z", "fetched_at" => "2026-08-13T00:01:00Z", "capture_id" => "capture", "capture_captured_at" => "2026-08-13T00:01:00Z", "capture_body_hash" => "feed-hash", "rights_scope" => "excerpt_only" }
    @store.ingest_source_items!(items: [item])
    version = @store.source_item_versions(item_key: "item").fetch(0)
    attempt = { "attempt_id" => "attempt", "source_version_id" => version.fetch("version_id"), "rights_scope" => "excerpt_only", "outcome" => "not_permitted", "http_status" => nil, "fetched_at" => "2026-08-13T00:02:00Z", "final_url" => "", "content_type" => "", "response_bytes" => 0, "error_reason" => "not permitted" }
    @store.save_article_archive_result!(attempt: attempt)
    assert_equal 0, scalar("SELECT COUNT(*) FROM local_article_archive")
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_article_archive_attempt")
    assert_raises(RuntimeError) { sql!("DELETE FROM local_source_archive_policy") }
  end

  def test_metadata_queue_is_version_bound_and_credential_block_does_not_consume_attempt
    test_policy_is_append_only_and_excerpt_attempt_does_not_create_body
    assert_equal 1, @store.ensure_metadata_translation_runs!
    candidate = @store.metadata_translation_candidates(limit: 10, daily_character_limit: 10_000).fetch(0)
    assert_equal candidate.fetch("version_id"), scalar_text("SELECT source_version_id FROM local_metadata_translation_run")
    @store.block_metadata_translation_for_credentials!(run_id: candidate.fetch("translation_run_id"), reason: "missing")
    assert_equal "credential_blocked|0", row("SELECT state,attempt_count FROM local_metadata_translation_run")
    assert_equal 0, @store.ensure_metadata_translation_runs!
  end

  def test_raw_capture_and_version_history_reject_direct_mutation_and_projection_delete
    test_policy_is_append_only_and_excerpt_attempt_does_not_create_body
    version = @store.source_item_versions(item_key: "item").fetch(0)

    # The current item projection is intentionally refreshable by ingest; the
    # immutable capture/version records must not change with it.
    sql!("UPDATE local_source_item SET title = 'Projection refresh' WHERE item_key = 'item'")
    assert_equal "Projection refresh", scalar_text("SELECT title FROM local_source_item WHERE item_key = 'item'")
    assert_equal "Title 2026", scalar_text("SELECT title FROM local_source_item_version WHERE version_id = '#{version.fetch('version_id')}'")

    assert_raises(RuntimeError) do
      sql!("UPDATE local_source_capture SET body_hash = 'changed' WHERE capture_id = 'capture'")
    end
    assert_raises(RuntimeError) do
      sql!("UPDATE local_source_item_version SET title = 'changed' WHERE version_id = '#{version.fetch('version_id')}'")
    end
    assert_raises(RuntimeError) do
      sql!("DELETE FROM local_source_item_version WHERE version_id = '#{version.fetch('version_id')}'")
    end
    assert_raises(RuntimeError) do
      sql!("DELETE FROM local_source_capture WHERE capture_id = 'capture'")
    end

    # Deleting the mutable projection must not cascade into retained history.
    # The trigger blocks the delete, and the FK is also restrictive as a
    # second database-side defense.
    assert_raises(RuntimeError) { sql!("DELETE FROM local_source_item WHERE item_key = 'item'") }
    assert_equal "r", scalar_text(<<~SQL)
      SELECT confdeltype
        FROM pg_constraint
       WHERE conrelid = 'local_source_item_version'::regclass
         AND confrelid = 'local_source_item'::regclass
         AND contype = 'f'
         AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'local_source_item_version'::regclass AND attname = 'item_key' AND NOT attisdropped)]::smallint[]
         AND confkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'local_source_item'::regclass AND attname = 'item_key' AND NOT attisdropped)]::smallint[]
    SQL
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_source_item_version WHERE version_id = '#{version.fetch('version_id')}'")
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_source_capture WHERE capture_id = 'capture'")
  end

  def test_late_translation_projects_over_immutable_snapshot_without_republishing
    source = { "id" => "projection-source", "name" => "projection", "url" => "https://example.test/feed", "language" => "en", "region" => "global", "publisher_id" => "example", "publisher_name" => "Example", "publisher_url" => "https://example.test/", "rights_scope" => "excerpt_only" }
    @store.register_sources!(sources: [source])
    @store.register_archive_policies!(sources: [source])
    @store.ingest_source_items!(items: [{ "item_key" => "projection-item", "source_id" => source.fetch("id"), "source_name" => source.fetch("name"), "language" => "en", "region" => "global", "publisher_id" => "example", "publisher_name" => "Example", "publisher_url" => "https://example.test/", "publisher_identity_status" => "configured", "source_kind" => "configured", "title" => "Original title 2026", "summary" => "Original summary", "source_url" => "https://example.test/article", "published_at" => "2026-08-13T00:00:00Z", "fetched_at" => "2026-08-13T00:01:00Z", "capture_id" => "projection-capture", "capture_captured_at" => "2026-08-13T00:01:00Z", "capture_body_hash" => "projection-feed-hash", "rights_scope" => "excerpt_only" }])
    version = @store.source_item_versions(item_key: "projection-item").fetch(0)
    @store.publish_snapshot!(snapshot: { "snapshot_id" => "projection-snapshot", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-13T00:01:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection" }, cards: [{ "card_id" => "projection-card", "signal_type" => "news", "title" => version.fetch("title"), "summary" => version.fetch("summary"), "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown", "action_stage" => "review", "evidence_label" => "fixture", "source_name" => "Example", "source_url" => version.fetch("source_url"), "source_language" => "en", "original_title" => version.fetch("title"), "original_summary" => version.fetch("summary"), "translation_status" => "untranslated", "source_item_key" => version.fetch("item_key"), "source_version_id" => version.fetch("version_id"), "source_content_hash" => version.fetch("content_hash"), "sort_order" => 0 }])
    assert_equal "Original title 2026", @store.current_radar.dig("cards", 0, "title")
    @store.save_translation_artifact!(artifact: { "artifact_id" => "projection-translation", "source_version_id" => version.fetch("version_id"), "item_key" => version.fetch("item_key"), "source_language" => "en", "target_language" => "zh-CN", "original_content_hash" => version.fetch("content_hash"), "provider" => "deepseek", "model" => "deepseek-v4-pro", "translated_title" => "原始标题 2026", "translated_summary" => "原始摘要", "validation_status" => "mechanical_pass", "status" => "translated", "error_reason" => "" })
    radar = @store.current_radar
    assert_equal "projection-snapshot", radar.dig("snapshot", "snapshot_id")
    assert_equal "原始标题 2026", radar.dig("cards", 0, "title")
    assert_equal "Original title 2026", radar.dig("cards", 0, "original_title")
    assert_equal "translated", radar.dig("cards", 0, "translation_status")
    assert_equal 0, radar.dig("archive", "full_archive_source_count")
    assert_equal "excerpt_only", radar.dig("archive", "source_policies", 0, "rights_scope")
  end

  private

  def host; ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket"); end
  def port; ENV.fetch("LOCAL_PGPORT", "55433"); end
  def user; ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")); end
  def bin(name); File.join(ENV.fetch("PG_BIN", "/private/tmp/trend-exploring-postgres15-runtime/bin"), name); end
  def run!(args); out, err, status = Open3.capture3(*args); raise "#{err}\n#{out}" unless status.success?; out; end
  def row(sql); run!([bin("psql"), "-XAtq", "-F", "|", "-h", host, "-p", port, "-U", user, "-d", @database, "-c", sql]).strip; end
  def scalar(sql); row(sql).to_i; end
  def scalar_text(sql); row(sql); end
  def sql!(sql); run!([bin("psql"), "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-c", sql]); end
end
