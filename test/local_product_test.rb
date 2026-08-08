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
    assert_includes radar.fetch("cards").first.fetch("title"), "小语种"
    assert_includes radar.fetch("cards").first.fetch("summary"), "独立证据"
  end

  def test_frontend_is_present_and_contains_evidence_boundary_copy
    html = File.read(File.join(ROOT, "app/public/index.html"))
    css = File.read(File.join(ROOT, "app/public/styles.css"))
    js = File.read(File.join(ROOT, "app/public/app.js"))
    assert_includes html, "证据优先"
    assert_includes css, ".signal-card"
    assert_includes js, "/api/radar"
  end

  def test_staging_publish_is_atomic_and_moves_the_read_head
    result = @store.publish_snapshot!(
      snapshot: { "snapshot_id" => "staging-snapshot-002", "surface_id" => "public-radar", "revision" => 2,
                  "comparison_watermark" => "2026-08-08T08:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                  "render_plan_hash" => "render-staging-002" },
      cards: [{ "card_id" => "card-004", "signal_type" => "emergence", "title" => "Next line", "summary" => "A staging card.",
                 "metric_label" => "change", "metric_value" => "+1", "source_count" => 1, "stance" => "unknown",
                 "action_stage" => "discussion", "evidence_label" => "fixture", "sort_order" => 0 }]
    )
    assert_equal "staging-snapshot-002", result.dig("snapshot", "snapshot_id")
    assert_equal 1, result.fetch("cards").length
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "broken", "surface_id" => "public-radar" }, cards: [])
    end
  end
end
