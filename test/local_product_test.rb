# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "open3"
require "securerandom"
require_relative "../lib/local_radar_store"

class LocalProductTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  TEST_DATABASE_PREFIX = "trend_exploring_test_#{Process.pid}_"

  def setup
    @database = "#{TEST_DATABASE_PREFIX}#{SecureRandom.hex(6)}"
    create_test_database!
    @store = LocalRadarStore.new(psql: test_psql, host: test_host, port: test_port, database: @database, user: test_user)
    assert_equal @database, @store.health.fetch("database")
    @store.seed_demo!
  end

  def teardown
    drop_test_database! if @database
  end

  def test_local_database_is_postgresql_15_and_seeded_radar_is_readable
    health = @store.health
    assert_equal @database, health.fetch("database")
    assert_match(/\A15\./, health.fetch("server_version"))
    radar = @store.current_radar
    assert_equal "staging-snapshot-001", radar.dig("snapshot", "snapshot_id")
    assert_equal 3, radar.fetch("cards").length
    assert_empty radar.fetch("trends")
    assert_empty radar.fetch("event_candidates")
    assert radar.key?("sources")
    assert_equal({ "latest_batch" => nil, "items" => [], "boundary" => radar.fetch("exploration").fetch("boundary") }, radar.fetch("exploration"))
    assert_includes radar.fetch("cards").first.fetch("title"), "小语种"
    assert_includes radar.fetch("cards").first.fetch("summary"), "独立证据"
  end

  def test_frontend_is_present_and_contains_evidence_boundary_copy
    html = File.read(File.join(ROOT, "app/public/index.html"))
    css = File.read(File.join(ROOT, "app/public/styles.css"))
    js = File.read(File.join(ROOT, "app/public/app.js"))
    readme_top = File.readlines(File.join(ROOT, "README.md"), chomp: true).first(4).join("\n")
    assert_includes html, "证据优先"
    assert_includes html, "来源矩阵"
    assert_includes html, "多来源信息台"
    assert_includes html, "当前来源雷达"
    refute_includes html, "实时来源雷达"
    assert_includes html, "哪些词在重复出现"
    assert_includes html, "词频线索"
    assert_includes html, "事件候选"
    assert_includes html, "确定性文本锚门槛"
    assert_includes html, "世界变化候选"
    assert_includes html, "多语言概念候选"
    assert_includes html, "五通道证据"
    assert_includes html, "非预测"
    assert_includes css, ".signal-card"
    assert_includes css, ".card-meta"
    assert_includes css, ".translation-badge"
    assert_includes js, "card-time"
    assert_includes js, "translationStatusLabels"
    assert_includes js, "coverage"
    assert_includes js, "/api/radar"
    assert_includes js, "配置出版方"
    assert_includes js, "观察出版方域名"
    assert_includes js, "尚无观察到的内容语言"
    assert_includes js, "当前仅一种内容语言"
    assert_includes js, "当前仅两种内容语言"
    assert_includes js, "event_candidates"
    assert_includes js, "query evidence"
    assert_includes js, "/api/world-changes"
    assert_includes js, "evidence_boundary"
    assert_includes js, "公开 refs 上限"
    assert_includes js, "/api/signals/lifecycle"
    assert_includes js, "/api/multilingual-concepts"
    assert_includes js, "contradicting_evidence"
    assert_includes js, "missing_channels"
    assert_includes js, "alternative_explanations"
    assert_includes js, "next_verification"
    assert_includes js, "AI 摘要未通过生成或证据门禁，raw 已保留；观察台与 raw 日报更新正常"
    assert_includes readme_top, "单用户本地产品"
    %w[全球变化台 多地区 可验证趋势 可解释趋势 什么正在变化 条趋势 独立来源 独立出版方 事件短语 已翻译 覆盖地区].each do |forbidden|
      refute_includes html, forbidden
      refute_includes js, forbidden
    end
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
    assert_empty result.fetch("event_candidates")
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "broken", "surface_id" => "public-radar" }, cards: [])
    end
  end

  def test_event_candidate_snapshot_is_readable_and_invalid_candidate_rolls_back
    candidate = {
      "candidate_id" => "event-candidate-fixture",
      "candidate_key" => "event-candidate-82c91998744cbcce1fe4",
      "candidate_status" => "event_candidate",
      "label" => "Japan 7.1 earthquake",
      "language" => "en",
      "matching_method" => "deterministic_anchor_similarity_v1",
      "explanation" => "2 个非 query 去重出版方在 1 小时内通过门槛；每一对均通过门槛，全体共同锚 7.1, japan 7.1 earthquake；附加 1 条 query-conditioned 证据不计资格。仅作确定性文本相似候选，未确认事件、影响或重要性。",
      "member_count" => 3,
      "dedup_source_count" => 3,
      "qualifying_source_count" => 2,
      "query_conditioned_evidence_count" => 1,
      "first_published_at" => "2026-08-08T07:00:00Z",
      "last_published_at" => "2026-08-08T08:00:00Z",
      "time_span_hours" => 1.0,
      "shared_anchors" => [
        { "kind" => "number", "value" => "7.1", "strength" => "strong", "supporting_qualifying_source_count" => 2 },
        { "kind" => "trigram", "value" => "japan 7.1 earthquake", "strength" => "strong", "supporting_qualifying_source_count" => 2 }
      ],
      "shared_phrases" => ["japan 7.1 earthquake"],
      "evidence_items" => [
        { "item_key" => "a", "source_id" => "source-a", "source_name" => "publisher-a", "region" => "fixture", "publisher_id" => "publisher-a", "publisher_name" => "publisher-a", "publisher_url" => "https://example.test/publisher-a/", "source_kind" => "configured", "publisher_identity_status" => "configured", "source_url" => "https://example.test/a", "language" => "en", "title" => "Japan 7.1 earthquake", "summary" => "fixture", "published_at" => "2026-08-08T07:00:00Z", "query_conditioned" => false, "lineage_role" => "qualifying_non_query" },
        { "item_key" => "b", "source_id" => "source-b", "source_name" => "publisher-b", "region" => "fixture", "publisher_id" => "publisher-b", "publisher_name" => "publisher-b", "publisher_url" => "https://example.test/publisher-b/", "source_kind" => "configured", "publisher_identity_status" => "configured", "source_url" => "https://example.test/b", "language" => "en", "title" => "Japan 7.1 earthquake", "summary" => "fixture", "published_at" => "2026-08-08T08:00:00Z", "query_conditioned" => false, "lineage_role" => "qualifying_non_query" },
        { "item_key" => "q", "source_id" => "source-q", "source_name" => "publisher-q", "region" => "fixture", "publisher_id" => "publisher-q", "publisher_name" => "publisher-q", "publisher_url" => "https://example.test/publisher-q/", "source_kind" => "discovery", "publisher_identity_status" => "configured", "source_url" => "https://example.test/q", "language" => "en", "title" => "Japan 7.1 earthquake", "summary" => "fixture", "published_at" => "2026-08-08T08:00:00Z", "query_conditioned" => true, "lineage_role" => "query_conditioned_support" }
      ],
      "member_item_keys" => ["a", "b", "q"],
      "qualifying_item_keys" => ["a", "b"],
      "query_item_keys" => ["q"],
      "sort_order" => 0
    }
    @store.register_sources!(sources: [
      { "id" => "source-a", "name" => "publisher-a", "url" => "https://example.test/feed-a", "language" => "en", "region" => "fixture", "publisher_id" => "publisher-a", "query_conditioned" => false, "enabled" => true },
      { "id" => "source-b", "name" => "publisher-b", "url" => "https://example.test/feed-b", "language" => "en", "region" => "fixture", "publisher_id" => "publisher-b", "query_conditioned" => false, "enabled" => true },
      { "id" => "source-q", "name" => "publisher-q", "url" => "https://example.test/feed-q", "language" => "en", "region" => "fixture", "publisher_id" => "publisher-q", "query_conditioned" => true, "enabled" => true }
    ])
    candidate.fetch("evidence_items").each_with_index do |entry, index|
      capture_at = "2026-08-08T0#{6 + index}:30:00Z"
      @store.ingest_source_items!(items: [{
        "item_key" => entry.fetch("item_key"), "source_id" => entry.fetch("source_id"), "source_name" => entry.fetch("publisher_name"),
        "language" => entry.fetch("language"), "region" => "fixture", "title" => entry.fetch("title"), "summary" => entry.fetch("summary"),
        "source_url" => entry.fetch("source_url"), "published_at" => entry.fetch("published_at"), "fetched_at" => capture_at,
        "capture_captured_at" => capture_at, "capture_id" => "capture-#{entry.fetch("item_key")}", "capture_http_status" => 200,
        "capture_content_type" => "application/rss+xml", "capture_content_bytes" => 100, "capture_body_hash" => "body-#{entry.fetch("item_key")}",
        "capture_storage_status" => "metadata_only", "capture_source_url" => "https://example.test/feed.xml",
        "publisher_id" => entry.fetch("publisher_id"), "publisher_name" => entry.fetch("publisher_name"), "publisher_url" => entry.fetch("publisher_url"),
        "publisher_identity_status" => "configured", "source_kind" => entry.fetch("source_kind"), "query_conditioned" => entry.fetch("query_conditioned")
      }])
      version = @store.source_item_versions(item_key: entry.fetch("item_key")).fetch(0)
      entry["version_id"] = version.fetch("version_id")
      entry["capture_id"] = version.fetch("capture_id")
      entry["content_hash"] = version.fetch("content_hash")
    end
    result = @store.publish_snapshot!(
      snapshot: { "snapshot_id" => "staging-snapshot-event", "surface_id" => "public-radar", "revision" => 2,
                  "comparison_watermark" => "2026-08-08T08:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                  "render_plan_hash" => "render-event" },
      cards: [{ "card_id" => "event-card", "signal_type" => "news", "title" => "event", "summary" => "fixture",
                 "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown",
                 "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
      event_candidates: [candidate]
    )
    assert_equal 1, result.fetch("event_candidates").length
    assert_equal "event-candidate-82c91998744cbcce1fe4", result.fetch("event_candidates").first.fetch("candidate_key")
    assert_equal "event_candidate", result.fetch("event_candidates").first.fetch("candidate_status")
    assert_equal 2, result.fetch("event_candidates").first.fetch("qualifying_source_count")
    assert_equal 1, result.fetch("event_candidates").first.fetch("query_conditioned_evidence_count")
    assert_equal "query_conditioned_support", result.fetch("event_candidates").first.fetch("evidence_items").last.fetch("lineage_role")

    broken = candidate.merge("candidate_id" => "event-candidate-broken", "candidate_key" => "broken-key", "qualifying_source_count" => 1)
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "staging-snapshot-event-broken", "surface_id" => "public-radar", "revision" => 3,
                    "comparison_watermark" => "2026-08-08T09:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                    "render_plan_hash" => "render-event-broken" },
        cards: [{ "card_id" => "event-card-broken", "signal_type" => "news", "title" => "broken", "summary" => "fixture",
                   "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown",
                   "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
        event_candidates: [broken]
      )
    end
    assert_equal "staging-snapshot-event", @store.current_radar.dig("snapshot", "snapshot_id")
    assert_empty @store.current_radar.fetch("event_candidates").select { |row| row.fetch("candidate_key") == "broken-key" }

    invalid_variants = [
      candidate.merge("candidate_id" => "event-candidate-bad-member", "candidate_key" => "bad-member", "member_count" => 999),
      candidate.merge("candidate_id" => "event-candidate-bad-publisher-count", "candidate_key" => "bad-publisher-count", "dedup_source_count" => 99),
      candidate.merge("candidate_id" => "event-candidate-bad-evidence", "candidate_key" => "bad-evidence", "evidence_items" => candidate.fetch("evidence_items").first(2)),
      candidate.merge("candidate_id" => "event-candidate-bad-role", "candidate_key" => "bad-role", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.merge("lineage_role" => "query_conditioned_support") }),
      candidate.merge("candidate_id" => "event-candidate-bad-language", "candidate_key" => "bad-language", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.merge("language" => "zh-CN") }),
      candidate.merge("candidate_id" => "event-candidate-bad-time", "candidate_key" => "bad-time", "last_published_at" => "2026-08-08T06:00:00Z"),
      candidate.merge("candidate_id" => "event-candidate-bad-anchor", "candidate_key" => "bad-anchor", "shared_anchors" => [{ "kind" => "number", "value" => "7.1", "strength" => "strong", "supporting_qualifying_source_count" => 1 }]),
      candidate.merge("candidate_id" => "event-candidate-bad-semantic", "label" => "Unrelated invented headline"),
      candidate.merge("candidate_id" => "event-candidate-bad-title", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "a" ? entry.merge("title" => "100h unrelated invented title") : entry }),
      candidate.merge("candidate_id" => "event-candidate-bad-summary", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "b" ? entry.merge("summary" => "unrelated fabricated summary") : entry }),
      candidate.merge("candidate_id" => "event-candidate-bad-method", "matching_method" => "invented_method_v99"),
      candidate.merge("candidate_id" => "event-candidate-bad-key", "candidate_key" => "invented-key"),
      candidate.merge("candidate_id" => "event-candidate-bad-publisher", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "a" ? entry.merge("publisher_id" => "fake-publisher") : entry }),
      candidate.merge("candidate_id" => "event-candidate-bad-query", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "q" ? entry.merge("query_conditioned" => false) : entry }),
      candidate.merge("candidate_id" => "event-candidate-bad-version", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "a" ? entry.merge("version_id" => "orphan-version") : entry }),
      candidate.merge("candidate_id" => "event-candidate-bad-content-hash", "evidence_items" => candidate.fetch("evidence_items").map { |entry| entry.fetch("item_key") == "b" ? entry.merge("content_hash" => "wrong-hash") : entry })
    ]
    invalid_variants.each_with_index do |invalid, index|
      assert_raises(LocalRadarStore::Error) do
        @store.publish_snapshot!(
          snapshot: { "snapshot_id" => "staging-snapshot-event-invalid-#{index}", "surface_id" => "public-radar", "revision" => 10 + index,
                      "comparison_watermark" => "2026-08-08T09:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                      "render_plan_hash" => "render-event-invalid-#{index}" },
          cards: [{ "card_id" => "event-card-invalid-#{index}", "signal_type" => "news", "title" => "broken", "summary" => "fixture",
                     "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown",
                     "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
          event_candidates: [invalid]
        )
      end
    end
    assert_equal "staging-snapshot-event", @store.current_radar.dig("snapshot", "snapshot_id")
    @store.send(:execute, "UPDATE local_source_registry SET enabled = FALSE WHERE source_id = 'source-a'")
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "staging-snapshot-event-disabled", "surface_id" => "public-radar", "revision" => 30,
                    "comparison_watermark" => "2026-08-08T09:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                    "render_plan_hash" => "render-event-disabled" },
        cards: [{ "card_id" => "event-card-disabled", "signal_type" => "news", "title" => "broken", "summary" => "fixture",
                   "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown",
                   "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
        event_candidates: [candidate]
      )
    end
  end

  def test_event_candidate_store_accepts_case_normalized_en_language_partition
    items = [
      { "item_key" => "case-a", "source_id" => "case-source-a", "source_name" => "case-publisher-a", "region" => "fixture", "publisher_id" => "case-publisher-a", "publisher_name" => "case-publisher-a", "publisher_url" => "https://example.test/case-publisher-a/", "publisher_identity_status" => "configured", "source_kind" => "configured", "language" => "en", "title" => "Japan 7.1 earthquake tsunami warning", "summary" => "fixture", "source_url" => "https://example.test/case-a", "published_at" => "2026-08-08T07:00:00Z", "query_conditioned" => false },
      { "item_key" => "case-b", "source_id" => "case-source-b", "source_name" => "case-publisher-b", "region" => "fixture", "publisher_id" => "case-publisher-b", "publisher_name" => "case-publisher-b", "publisher_url" => "https://example.test/case-publisher-b/", "publisher_identity_status" => "configured", "source_kind" => "configured", "language" => "EN", "title" => "Japan 7.1 earthquake tsunami warning", "summary" => "fixture", "source_url" => "https://example.test/case-b", "published_at" => "2026-08-08T08:00:00Z", "query_conditioned" => false }
    ]
    @store.register_sources!(sources: [
      { "id" => "case-source-a", "name" => "case-publisher-a", "url" => "https://example.test/case-feed-a", "language" => "en", "region" => "fixture", "publisher_id" => "case-publisher-a", "query_conditioned" => false, "enabled" => true },
      { "id" => "case-source-b", "name" => "case-publisher-b", "url" => "https://example.test/case-feed-b", "language" => "EN", "region" => "fixture", "publisher_id" => "case-publisher-b", "query_conditioned" => false, "enabled" => true }
    ])
    candidate = EventCandidateAnalyzer.new.analyze(items: items, now: Time.parse("2026-08-08T08:00:00Z")).fetch(0).merge("candidate_id" => "case-event-candidate", "sort_order" => 0)
    candidate.fetch("evidence_items").each_with_index do |entry, index|
      capture_at = "2026-08-08T0#{6 + index}:30:00Z"
      @store.ingest_source_items!(items: [items.fetch(index).merge(
        "source_name" => entry.fetch("publisher_name"), "region" => "fixture", "fetched_at" => capture_at,
        "capture_captured_at" => capture_at, "capture_id" => "case-capture-#{entry.fetch("item_key")}",
        "capture_http_status" => 200, "capture_content_type" => "application/rss+xml", "capture_content_bytes" => 100,
        "capture_body_hash" => "case-body-#{entry.fetch("item_key")}", "capture_storage_status" => "metadata_only",
        "capture_source_url" => "https://example.test/case-feed.xml", "publisher_identity_status" => "configured"
      )])
      version = @store.source_item_versions(item_key: entry.fetch("item_key")).fetch(0)
      entry["version_id"] = version.fetch("version_id")
      entry["capture_id"] = version.fetch("capture_id")
      entry["content_hash"] = version.fetch("content_hash")
    end
    result = @store.publish_snapshot!(
      snapshot: { "snapshot_id" => "staging-snapshot-case", "surface_id" => "public-radar", "revision" => 2,
                  "comparison_watermark" => "2026-08-08T08:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                  "render_plan_hash" => "render-case" },
      cards: [{ "card_id" => "case-card", "signal_type" => "news", "title" => "case", "summary" => "fixture",
                 "metric_label" => "time", "metric_value" => "now", "source_count" => 1, "stance" => "unknown",
                 "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
      event_candidates: [candidate]
    )
    assert_equal "en", result.fetch("event_candidates").first.fetch("language")
    assert_equal 2, result.fetch("event_candidates").first.fetch("qualifying_source_count")
  end

  def test_self_consistent_100_hour_candidate_is_rejected_by_canonical_pair_gate
    suffix = "#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    sources = 2.times.map do |index|
      number = index + 1
      {
        "id" => "event-100h-source-#{suffix}-#{number}", "name" => "event-100h-source-#{number}",
        "url" => "https://event-100h.example/feed-#{number}", "language" => "en", "region" => "fixture",
        "publisher_id" => "event-100h-publisher-#{number}", "enabled" => true
      }
    end
    @store.register_sources!(sources: sources)
    item_keys = ["event-100h-item-#{suffix}-a", "event-100h-item-#{suffix}-b"]
    published = ["2026-08-01T00:00:00Z", "2026-08-05T04:00:00Z"]
    item_keys.each_with_index do |item_key, index|
      source = sources.fetch(index)
      captured_at = format("2026-08-01T0%d:30:00Z", index + 1)
      @store.ingest_source_items!(items: [{
        "item_key" => item_key, "source_id" => source.fetch("id"), "source_name" => source.fetch("name"),
        "language" => "en", "region" => "fixture", "publisher_id" => source.fetch("publisher_id"),
        "publisher_name" => source.fetch("publisher_id"), "publisher_url" => "https://#{source.fetch("publisher_id")}.example/",
        "publisher_identity_status" => "configured", "source_kind" => "configured", "query_conditioned" => false,
        "title" => "Japan 7.1 earthquake tsunami warning", "summary" => "fixture", "source_url" => "https://event-100h.example/item-#{index + 1}",
        "published_at" => published.fetch(index), "fetched_at" => captured_at, "capture_captured_at" => captured_at,
        "capture_id" => "event-100h-capture-#{suffix}-#{index + 1}", "capture_http_status" => 200,
        "capture_content_type" => "application/rss+xml", "capture_content_bytes" => 100,
        "capture_body_hash" => "event-100h-body-#{suffix}-#{index + 1}", "capture_storage_status" => "metadata_only",
        "capture_source_url" => "https://event-100h.example/feed.xml"
      }])
    end
    evidence = item_keys.each_with_index.map do |item_key, index|
      version = @store.source_item_versions(item_key: item_key).fetch(0)
      {
        "item_key" => item_key, "source_id" => version.fetch("source_id"), "source_name" => version.fetch("source_name"),
        "region" => version.fetch("region"), "publisher_id" => version.fetch("publisher_id"),
        "publisher_name" => version.fetch("publisher_name"), "publisher_url" => version.fetch("publisher_url"),
        "publisher_identity_status" => version.fetch("publisher_identity_status"), "source_kind" => version.fetch("source_kind"),
        "lineage_metadata_basis" => version.fetch("lineage_metadata_basis"), "language" => version.fetch("language"),
        "source_url" => version.fetch("source_url"), "title" => version.fetch("title"), "summary" => version.fetch("summary"),
        "published_at" => version.fetch("published_at"), "query_conditioned" => false, "lineage_role" => "qualifying_non_query",
        "version_id" => version.fetch("version_id"), "capture_id" => version.fetch("capture_id"), "content_hash" => version.fetch("content_hash")
      }
    end
    candidate = {
      "candidate_id" => "event-100h-candidate-#{suffix}", "candidate_key" => "event-candidate-100h-#{suffix}",
      "candidate_status" => "event_candidate", "label" => "Japan 7.1 earthquake tsunami warning", "language" => "en",
      "matching_method" => "deterministic_anchor_similarity_v1", "explanation" => "self-consistent but intentionally overlong fixture",
      "member_count" => 2, "dedup_source_count" => 2, "qualifying_source_count" => 2,
      "query_conditioned_evidence_count" => 0, "first_published_at" => published.fetch(0),
      "last_published_at" => published.fetch(1), "time_span_hours" => 100.0,
      "shared_anchors" => [
        { "kind" => "number", "value" => "7.1", "strength" => "strong", "supporting_qualifying_source_count" => 2 },
        { "kind" => "trigram", "value" => "japan 7.1 earthquake", "strength" => "strong", "supporting_qualifying_source_count" => 2 }
      ], "shared_phrases" => ["japan 7.1 earthquake"], "evidence_items" => evidence,
      "member_item_keys" => item_keys, "qualifying_item_keys" => item_keys, "query_item_keys" => [], "sort_order" => 0
    }
    assert_empty EventCandidateAnalyzer.new.analyze(items: @store.event_analysis_items(limit: 20), now: Time.parse("2026-08-05T05:00:00Z"))
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "event-100h-snapshot-#{suffix}", "surface_id" => "public-radar", "revision" => 2,
                    "comparison_watermark" => "2026-08-05T05:00:00Z", "method_epoch" => "method-v1", "rights_epoch" => 1,
                    "render_plan_hash" => "event-100h-render-#{suffix}" },
        cards: [{ "card_id" => "event-100h-card-#{suffix}", "signal_type" => "news", "title" => "fixture", "summary" => "fixture",
                   "metric_label" => "sources", "metric_value" => "2", "source_count" => 2, "stance" => "unknown",
                   "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }],
        event_candidates: [candidate]
      )
    end
    assert_equal "staging-snapshot-001", @store.current_radar.dig("snapshot", "snapshot_id")
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
    assert_equal item.fetch("item_key"), @store.latest_source_items(limit: 1000).find { |row| row.fetch("item_key") == item.fetch("item_key") }.fetch("item_key")
  end

  def test_capture_versions_are_append_only_and_late_observations_do_not_rewind_current
    key = "archive-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    first = archive_item(key: key, capture_id: "capture-#{key}-t1", captured_at: "2026-08-08T08:00:00Z", title: "同一内容")
    second = archive_item(key: key, capture_id: "capture-#{key}-t2", captured_at: "2026-08-08T09:00:00Z", title: "同一内容")
    late = archive_item(key: key, capture_id: "capture-#{key}-t0", captured_at: "2026-08-08T07:00:00Z", title: "迟到修订")

    @store.ingest_source_items!(items: [first])
    @store.ingest_source_items!(items: [second])
    @store.ingest_source_items!(items: [late])
    @store.ingest_source_items!(items: [second])

    current = @store.latest_source_items(limit: 1000).find { |row| row.fetch("item_key") == key }
    assert_equal "同一内容", current.fetch("title")
    assert_equal second.fetch("capture_id"), current.fetch("capture_id")
    versions = @store.source_item_versions(item_key: key)
    assert_equal 3, versions.length
    assert_equal [second.fetch("capture_id"), first.fetch("capture_id"), late.fetch("capture_id")], versions.map { |version| version.fetch("capture_id") }
    assert_equal versions.length, versions.map { |version| [version.fetch("item_key"), version.fetch("capture_id")] }.uniq.length
    assert versions.all? { |version| version.fetch("capture_storage_status") == "metadata_only" }
  end

  def test_event_analysis_uses_only_the_current_projection_capture_version
    source_id = "event-current-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "Event current source", "url" => "https://example.test/event-current.xml",
      "language" => "en", "region" => "fixture", "publisher_id" => "event-current-publisher", "enabled" => true
    }])
    key = "event-current-item-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    base = archive_item(key: key, capture_id: "event-current-old-#{key}", captured_at: "2026-08-08T07:00:00Z", title: "Old immutable title").merge(
      "source_id" => source_id, "source_name" => "Event current source", "publisher_id" => "event-current-publisher",
      "publisher_name" => "Event current publisher", "publisher_url" => "https://example.test/event-current-publisher",
      "publisher_identity_status" => "configured", "source_kind" => "configured"
    )
    current = base.merge("capture_id" => "event-current-new-#{key}", "capture_captured_at" => "2026-08-08T08:00:00Z", "fetched_at" => "2026-08-08T08:00:00Z", "title" => "Current immutable title")
    @store.ingest_source_items!(items: [base])
    @store.ingest_source_items!(items: [current])
    rows = @store.event_analysis_items(limit: 20).select { |row| row.fetch("item_key") == key }
    assert_equal 1, rows.length
    assert_equal "Current immutable title", rows.fetch(0).fetch("title")
    assert_equal current.fetch("capture_id"), rows.fetch(0).fetch("capture_id")
    assert_equal @store.source_item_versions(item_key: key).find { |row| row.fetch("capture_id") == current.fetch("capture_id") }.fetch("version_id"), rows.fetch(0).fetch("version_id")
  end

  def test_persisted_hash_is_recomputable_and_ingest_rolls_back_on_failure
    key = "archive-hash-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    summary = "摘要" + ("尾部" * 300)
    item = archive_item(key: key, capture_id: "capture-#{key}", captured_at: "2026-08-08T10:00:00Z", summary: summary)
    @store.ingest_source_items!(items: [item])
    current = @store.latest_source_items(limit: 1000).find { |row| row.fetch("item_key") == key }
    expected = Digest::SHA256.hexdigest([current.fetch("title"), current.fetch("summary"), current.fetch("source_url")].join("\u0000"))
    assert_equal expected, current.fetch("content_hash")
    version = @store.source_item_versions(item_key: key).fetch(0)
    assert_equal expected, version.fetch("content_hash")

    staged_key = "archive-staged-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    broken_key = "archive-broken-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    staged = archive_item(key: staged_key, capture_id: "capture-#{staged_key}", captured_at: "2026-08-08T11:00:00Z")
    broken = archive_item(key: broken_key, capture_id: "capture-#{broken_key}", captured_at: "2026-08-08T11:00:00Z").merge("capture_storage_status" => "invalid")
    before = @store.archive_summary
    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [staged, broken]) }
    assert_empty @store.source_item_versions(item_key: staged_key)
    assert_empty @store.source_item_versions(item_key: broken_key)
    assert_equal before, @store.archive_summary
  end

  def test_capture_tie_break_is_stable_in_both_input_orders_and_conflicts_fail
    first_key = "archive-order-a-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    second_key = "archive-order-b-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    first_low = archive_item(key: first_key, capture_id: "capture-#{first_key}-a", captured_at: "2026-08-08T12:00:00.123456Z", title: "低").merge("capture_body_hash" => "same-body")
    first_high = archive_item(key: first_key, capture_id: "capture-#{first_key}-z", captured_at: "2026-08-08T12:00:00.123456Z", title: "高").merge("capture_body_hash" => "same-body")
    second_low = archive_item(key: second_key, capture_id: "capture-#{second_key}-a", captured_at: "2026-08-08T12:00:00.123456Z", title: "低").merge("capture_body_hash" => "same-body")
    second_high = archive_item(key: second_key, capture_id: "capture-#{second_key}-z", captured_at: "2026-08-08T12:00:00.123456Z", title: "高").merge("capture_body_hash" => "same-body")
    @store.ingest_source_items!(items: [first_low, first_high])
    @store.ingest_source_items!(items: [second_high, second_low])
    assert_equal first_high.fetch("capture_id"), @store.latest_source_items(limit: 1000).find { |row| row.fetch("item_key") == first_key }.fetch("capture_id")
    assert_equal second_high.fetch("capture_id"), @store.latest_source_items(limit: 1000).find { |row| row.fetch("item_key") == second_key }.fetch("capture_id")
    assert_equal 2, @store.source_item_versions(item_key: first_key).length
    assert_equal 2, @store.source_item_versions(item_key: second_key).length

    conflict_capture = first_high.merge("capture_body_hash" => "changed-body")
    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [conflict_capture]) }
    conflict_version = first_high.merge("title" => "改写")
    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [conflict_version]) }
    wrong_source = archive_item(key: first_key, capture_id: "capture-wrong-source", captured_at: "2026-08-08T13:00:00Z", title: "错绑").merge("source_id" => "wrong-source")
    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [wrong_source]) }
  end

  def test_coverage_separates_editorial_query_and_observed_domain_facts
    suffix = "#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    editorial_a = "coverage-editorial-a-#{suffix}"
    editorial_b = "coverage-editorial-b-#{suffix}"
    query_id = "coverage-query-#{suffix}"
    disabled_id = "coverage-disabled-#{suffix}"
    observed_domain = "guardian-#{suffix}.example"
    before = @store.coverage
    @store.register_sources!(sources: [
      { "id" => editorial_a, "name" => "BBC feed A", "url" => "https://bbc.example/a.xml", "language" => "en", "region" => "全球", "publisher_id" => "bbc-#{suffix}", "region_basis" => "editorial_scope_label", "query_conditioned" => false, "enabled" => true },
      { "id" => editorial_b, "name" => "BBC feed B", "url" => "https://bbc.example/b.xml", "language" => "en", "region" => "全球", "publisher_id" => "bbc-#{suffix}", "region_basis" => "editorial_scope_label", "query_conditioned" => false, "enabled" => true },
      { "id" => query_id, "name" => "非洲/拉美主题查询", "url" => "https://news.google.com/rss/search?q=africa", "language" => "en", "region" => "非洲/拉美", "source_kind" => "discovery", "publisher_id" => "", "region_basis" => "query_target_label", "query_conditioned" => true, "enabled" => true },
      { "id" => disabled_id, "name" => "disabled", "url" => "https://disabled.example/feed", "language" => "en", "region" => "北美", "publisher_id" => "disabled", "region_basis" => "editorial_scope_label", "query_conditioned" => false, "enabled" => false }
    ])
    query_items = (1..24).map do |index|
      archive_item(key: "coverage-item-#{suffix}-#{index}", capture_id: "coverage-capture-#{suffix}-#{index}", captured_at: "2026-08-08T14:#{format('%02d', index)}:00Z", title: "查询条目 #{index}").merge(
        "source_id" => query_id, "source_name" => "非洲/拉美主题查询", "language" => index == 1 ? "zh-CN" : "en", "source_url" => "https://query.example/items/#{index}",
        "capture_source_url" => "https://news.google.com/rss/search?q=africa", "publisher_id" => observed_domain,
        "publisher_name" => observed_domain, "publisher_url" => "https://#{observed_domain}/", "publisher_identity_status" => "observed_domain",
        "source_kind" => "discovery", "capture_body_hash" => "same-query-body"
      )
    end
    unresolved = archive_item(key: "coverage-unresolved-#{suffix}", capture_id: "coverage-unresolved-capture-#{suffix}", captured_at: "2026-08-08T15:00:00Z").merge(
      "source_id" => query_id, "source_name" => "非洲/拉美主题查询", "source_url" => "https://query.example/unresolved",
      "capture_source_url" => "https://news.google.com/rss/search?q=africa", "publisher_id" => "", "publisher_name" => "",
      "publisher_url" => "", "publisher_identity_status" => "unresolved", "source_kind" => "discovery"
    )
    @store.ingest_source_items!(items: query_items + [unresolved])
    after = @store.coverage
    assert_equal 1, after.fetch("configured_publisher_count") - before.fetch("configured_publisher_count")
    assert_equal 1, after.fetch("query_feed_count") - before.fetch("query_feed_count")
    assert_operator after.fetch("observed_publisher_domain_count"), :>=, before.fetch("observed_publisher_domain_count") + 1
    assert_equal 1, after.fetch("unresolved_publisher_item_count") - before.fetch("unresolved_publisher_item_count")
    assert_equal "unverified", after.fetch("event_geography_status")
    assert after.fetch("query_conditioned")
    assert_includes after.fetch("debts"), "event_geography_unverified"
    assert_includes after.fetch("debts"), "only_two_content_languages"
    assert_includes after.fetch("debts"), "discovery_is_topic_conditioned"
    assert_includes after.fetch("debts"), "discovery_publisher_origin_unknown"
    domains = @store.discovered_publishers.select { |publisher| publisher.fetch("publisher_id") == observed_domain }
    assert_equal 1, domains.length
    assert_equal observed_domain, domains.fetch(0).fetch("publisher_name")
    radar = @store.current_radar
    assert radar.key?("coverage")
    assert radar.key?("sources")
    assert radar.key?("cards")
  end

  def test_coverage_language_debts_and_configured_unresolved_are_separate
    empty = @store.coverage
    assert_empty empty.fetch("observed_languages")
    assert_includes empty.fetch("debts"), "no_observed_content_language"

    source_id = "coverage-configured-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "configured", "url" => "https://configured.example/feed",
      "language" => "en", "region" => "编辑范围", "publisher_id" => "configured-publisher",
      "region_basis" => "editorial_scope_label", "query_conditioned" => false, "enabled" => true
    }])
    item = archive_item(key: "coverage-configured-item-#{source_id}", capture_id: "coverage-configured-capture-#{source_id}", captured_at: "2026-08-08T16:00:00Z").merge(
      "source_id" => source_id, "source_name" => "configured", "source_kind" => "configured",
      "source_url" => "https://configured.example/item", "publisher_id" => "", "publisher_name" => "",
      "publisher_url" => "", "publisher_identity_status" => "unresolved"
    )
    @store.ingest_source_items!(items: [item])
    one_language = @store.coverage
    assert_equal ["en"], one_language.fetch("observed_languages")
    assert_includes one_language.fetch("debts"), "single_content_language"
    refute_includes one_language.fetch("debts"), "discovery_publisher_origin_unknown"
    assert_equal 1, one_language.fetch("unresolved_publisher_item_count")
    assert_equal 0, one_language.fetch("discovery_unresolved_publisher_item_count")
  end

  def test_disabled_query_history_does_not_create_active_query_conditioned_coverage
    source_id = "coverage-disabled-query-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "disabled query", "url" => "https://news.google.com/rss/search?q=old",
      "language" => "en", "region" => "旧查询目标", "source_kind" => "discovery", "region_basis" => "query_target_label",
      "query_conditioned" => true, "enabled" => false
    }])
    item = archive_item(key: "coverage-disabled-item-#{source_id}", capture_id: "coverage-disabled-capture-#{source_id}", captured_at: "2026-08-08T16:00:00Z").merge(
      "source_id" => source_id, "source_name" => "disabled query", "source_kind" => "discovery",
      "source_url" => "https://query.example/old", "publisher_id" => "old.example",
      "publisher_name" => "old.example", "publisher_url" => "https://old.example/", "publisher_identity_status" => "observed_domain"
    )
    @store.ingest_source_items!(items: [item])
    coverage = @store.coverage
    assert_equal 0, coverage.fetch("query_feed_count")
    assert coverage.fetch("query_conditioned")
    assert_operator coverage.fetch("observed_publisher_domain_count"), :>=, 1
    assert_includes coverage.fetch("debts"), "discovery_is_topic_conditioned"
    assert_includes coverage.fetch("debts"), "discovery_publisher_origin_unknown"
  end

  def test_disabled_query_without_history_is_not_query_conditioned
    source_id = "coverage-disabled-query-empty-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "disabled empty query", "url" => "https://news.google.com/rss/search?q=empty",
      "language" => "en", "region" => "空查询", "source_kind" => "discovery", "region_basis" => "query_target_label",
      "query_conditioned" => true, "enabled" => false
    }])
    coverage = @store.coverage
    assert_equal 0, coverage.fetch("query_feed_count")
    refute coverage.fetch("query_conditioned")
    refute_includes coverage.fetch("debts"), "discovery_is_topic_conditioned"
    refute_includes coverage.fetch("debts"), "discovery_publisher_origin_unknown"
  end

  def test_non_query_discovery_history_does_not_trigger_query_conditioned_debt
    source_id = "coverage-discovery-non-query-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "ordinary discovery", "url" => "https://discovery.example/feed",
      "language" => "en", "region" => "编辑发现", "source_kind" => "discovery", "region_basis" => "editorial_scope_label",
      "query_conditioned" => false, "enabled" => true
    }])
    item = archive_item(key: "coverage-discovery-non-query-item-#{source_id}", capture_id: "coverage-discovery-non-query-capture-#{source_id}", captured_at: "2026-08-08T16:00:00Z").merge(
      "source_id" => source_id, "source_name" => "ordinary discovery", "source_kind" => "discovery",
      "source_url" => "https://discovery.example/item", "publisher_id" => "ordinary.example",
      "publisher_name" => "ordinary.example", "publisher_url" => "https://ordinary.example/", "publisher_identity_status" => "observed_domain"
    )
    @store.ingest_source_items!(items: [item])
    coverage = @store.coverage
    assert_equal 0, coverage.fetch("query_feed_count")
    refute coverage.fetch("query_conditioned")
    assert_equal 0, coverage.fetch("observed_publisher_domain_count")
    assert_equal 0, coverage.fetch("discovery_unresolved_publisher_item_count")
    refute_includes coverage.fetch("debts"), "discovery_is_topic_conditioned"
    refute_includes coverage.fetch("debts"), "discovery_publisher_origin_unknown"
  end

  def test_enabled_query_without_items_is_not_reported_as_observed_publisher_origin
    source_id = "coverage-failed-query-#{Process.pid}-#{object_id}-#{rand(1_000_000)}"
    @store.register_sources!(sources: [{
      "id" => source_id, "name" => "failed query", "url" => "https://news.google.com/rss/search?q=failed",
      "language" => "en", "region" => "查询目标", "source_kind" => "discovery", "region_basis" => "query_target_label",
      "query_conditioned" => true, "enabled" => true
    }])
    coverage = @store.coverage
    assert_equal 1, coverage.fetch("query_feed_count")
    assert coverage.fetch("query_conditioned")
    assert_equal 0, coverage.fetch("observed_publisher_domain_count")
    assert_equal 0, coverage.fetch("discovery_unresolved_publisher_item_count")
    assert_includes coverage.fetch("debts"), "discovery_is_topic_conditioned"
    refute_includes coverage.fetch("debts"), "discovery_publisher_origin_unknown"
  end

  private

  def test_psql
    ENV.fetch("LOCAL_PSQL", "/private/tmp/trend-exploring-postgres15-runtime/bin/psql")
  end

  def test_createdb
    ENV.fetch("LOCAL_CREATEDB", File.join(File.dirname(test_psql), "createdb"))
  end

  def test_dropdb
    ENV.fetch("LOCAL_DROPDB", File.join(File.dirname(test_psql), "dropdb"))
  end

  def test_host
    ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket")
  end

  def test_port
    ENV.fetch("LOCAL_PGPORT", "55433")
  end

  def test_user
    ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
  end

  def run_test_command!(args)
    _stdout, stderr, status = Open3.capture3(*args)
    raise "local product test command failed: #{stderr.strip}" unless status.success?
  end

  def create_test_database!
    run_test_command!([test_createdb, "-h", test_host, "-p", test_port, "-U", test_user, @database])
    @database_created = true
    run_test_command!([test_psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", test_host, "-p", test_port, "-U", test_user,
                       "-d", @database, "-f", File.join(ROOT, "schema/postgres/011_local_radar.sql")])
  rescue StandardError
    drop_test_database! if @database_created
    raise
  end

  def drop_test_database!
    return unless @database_created
    expected = /\A#{Regexp.escape(TEST_DATABASE_PREFIX)}[0-9a-f]{12}\z/
    raise "refusing to drop unexpected test database #{@database}" unless @database.match?(expected)

    run_test_command!([test_dropdb, "-h", test_host, "-p", test_port, "-U", test_user, @database])
    @database_created = false
  end

  def archive_item(key:, capture_id:, captured_at:, title: "归档条目", summary: "短摘要")
    {
      "item_key" => key,
      "source_id" => "archive-source-#{key}",
      "source_name" => "归档测试来源",
      "language" => "en",
      "region" => "全球",
      "title" => title,
      "summary" => summary,
      "source_url" => "https://example.test/archive/#{key}",
      "published_at" => "2026-08-08T07:00:00Z",
      "fetched_at" => captured_at,
      "capture_captured_at" => captured_at,
      "capture_id" => capture_id,
      "capture_http_status" => 200,
      "capture_content_type" => "application/rss+xml",
      "capture_content_bytes" => 123,
      "capture_body_hash" => "body-#{capture_id}",
      "capture_storage_status" => "metadata_only",
      "capture_source_url" => "https://example.test/feed.xml",
      "rights_scope" => "excerpt_only"
    }
  end
end
