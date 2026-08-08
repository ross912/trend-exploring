# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_radar_store"

class LocalProductTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @store = LocalRadarStore.new
    begin
      @store.health
    rescue LocalRadarStore::Error => error
      skip "local PostgreSQL staging is unavailable: #{error.message}"
    end
    @store.reset_demo!
    @store.seed_demo!
  end

  def test_local_database_is_postgresql_15_and_seeded_radar_is_readable
    health = @store.health
    assert_equal "trend_exploring_local", health.fetch("database")
    assert_match(/\A15\./, health.fetch("server_version"))
    radar = @store.current_radar
    assert_equal "staging-snapshot-001", radar.dig("snapshot", "snapshot_id")
    assert_equal 3, radar.fetch("cards").length
    assert_empty radar.fetch("trends")
    assert radar.key?("sources")
    assert_includes radar.fetch("cards").first.fetch("title"), "小语种"
    assert_includes radar.fetch("cards").first.fetch("summary"), "独立证据"
  end

  def test_frontend_is_present_and_contains_evidence_boundary_copy
    html = File.read(File.join(ROOT, "app/public/index.html"))
    css = File.read(File.join(ROOT, "app/public/styles.css"))
    js = File.read(File.join(ROOT, "app/public/app.js"))
    assert_includes html, "证据优先"
    assert_includes html, "来源矩阵"
    assert_includes html, "可解释趋势"
    assert_includes css, ".signal-card"
    assert_includes css, ".card-meta"
    assert_includes js, "card-time"
    assert_includes js, "/api/radar"
  end

  def test_staging_publish_is_atomic_and_moves_the_read_head
    result = @store.publish_snapshot!(
      snapshot: { "snapshot_id" => "staging-snapshot-002", "surface_id" => "public-radar", "revision" => 2,
                  "comparison_watermark" => "2026-08-08T08:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                  "render_plan_hash" => "render-staging-002" },
      cards: [{ "card_id" => "card-004", "signal_type" => "emergence", "title" => "Next line", "summary" => "A staging card.",
                 "metric_label" => "change", "metric_value" => "+1", "source_count" => 1, "stance" => "unknown",
                 "action_stage" => "discussion", "evidence_label" => "fixture", "sort_order" => 0 }],
      trends: [{ "trend_id" => "trend-004", "topic_key" => "en:quantum computing", "topic" => "quantum computing",
                 "topic_language" => "en", "signal_state" => "rising", "summary" => "Two sources moved together.",
                 "mention_count" => 3, "recent_mention_count" => 2, "prior_mention_count" => 1, "source_count" => 2,
                 "region_count" => 2, "language_count" => 1, "growth_rate" => 100.0, "window_hours" => 48,
                 "recent_window_hours" => 12, "window_start" => "2026-08-06T12:00:00Z", "window_end" => "2026-08-08T12:00:00Z",
                 "source_names" => ["A", "B"], "regions" => ["亚洲", "北美"], "languages" => ["en"],
                 "evidence_urls" => ["https://example.test/a"], "sort_order" => 0 }]
    )
    assert_equal "staging-snapshot-002", result.dig("snapshot", "snapshot_id")
    assert_equal 1, result.fetch("cards").length
    assert_equal "quantum computing", result.fetch("trends").first.fetch("topic")
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "broken", "surface_id" => "public-radar" }, cards: [])
    end
  end

  def test_source_items_are_deduplicated_in_postgresql
    item_key = "fixture-#{Time.now.to_f}"
    item = {
      "item_key" => item_key, "source_id" => "fixture-source", "source_name" => "中文来源", "language" => "zh-CN",
      "region" => "全球",
      "title" => "真实采集去重测试", "summary" => "仅用于本地 fixture", "source_url" => "https://example.test/#{item_key}",
      "published_at" => "2026-08-08T07:00:00Z", "fetched_at" => "2026-08-08T07:01:00Z", "content_hash" => "hash-fixture"
    }
    assert_equal 1, @store.ingest_source_items!(items: [item])
    assert_equal 0, @store.ingest_source_items!(items: [item])
    assert_equal item.fetch("item_key"), @store.latest_source_items(limit: 100).find { |row| row.fetch("item_key") == item.fetch("item_key") }.fetch("item_key")
  end
end
