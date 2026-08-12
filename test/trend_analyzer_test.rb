# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/trend_analyzer"

class TrendAnalyzerTest < Minitest::Test
  NOW = Time.parse("2026-08-08T12:00:00Z")

  def item(source_id, title, published_at, language: "zh-CN", region: "全球")
    {
      "item_key" => "#{source_id}-#{published_at}",
      "source_id" => source_id,
      "source_name" => source_id,
      "language" => language,
      "region" => region,
      "title" => title,
      "summary" => "",
      "source_url" => "https://example.test/#{source_id}/#{published_at}",
      "published_at" => published_at,
      "fetched_at" => published_at
    }
  end

  def test_requires_independent_sources_and_reports_growth_windows
    trends = TrendAnalyzer.new.analyze(items: [
      item("source-a", "量子计算取得进展", "2026-08-07T08:00:00Z", region: "亚洲"),
      item("source-a", "量子计算进入产业应用", "2026-08-08T02:00:00Z", region: "亚洲"),
      item("source-b", "量子计算获得新投资", "2026-08-08T04:00:00Z", region: "欧洲"),
      item("source-c", "量子计算发布新计划", "2026-08-08T05:00:00Z", region: "北美")
    ], now: NOW)

    trend = trends.find { |candidate| candidate.fetch("topic") == "量子计算" }
    refute_nil trend
    assert_equal "rising", trend.fetch("signal_state")
    assert_equal 4, trend.fetch("mention_count")
    assert_equal 3, trend.fetch("recent_mention_count")
    assert_equal 1, trend.fetch("prior_mention_count")
    assert_equal 3, trend.fetch("source_count")
    assert_equal 200.0, trend.fetch("growth_rate")
    assert_equal 3, trend.fetch("region_count")
    assert_includes %w[deterministic_episode contextual_term], trend.fetch("semantic_status")
    assert_includes trend.fetch("summary"), "去重来源标识"
    assert_includes trend.fetch("summary"), "词频线索"
    assert_includes trend.fetch("topic_explanation"), "去重来源标识"
  end

  def test_repeated_articles_from_one_source_are_not_a_trend
    trends = TrendAnalyzer.new.analyze(items: [
      item("only-source", "机器人进入家庭", "2026-08-08T02:00:00Z"),
      item("only-source", "机器人进入医院", "2026-08-08T03:00:00Z"),
      item("only-source", "机器人进入工厂", "2026-08-08T04:00:00Z")
    ], now: NOW)

    assert_empty trends
  end

  def test_same_term_without_shared_event_context_is_not_promoted
    trends = TrendAnalyzer.new.analyze(items: [
      item("source-a", "无人机扑灭森林火灾", "2026-08-08T02:00:00Z"),
      item("source-b", "无人机参与边境巡逻", "2026-08-08T03:00:00Z", region: "欧洲"),
      item("source-c", "无人机用于农田测绘", "2026-08-08T04:00:00Z", region: "北美")
    ], now: NOW)

    refute trends.any? { |trend| trend.fetch("topic") == "无人机" }
  end

  def test_english_and_chinese_topics_do_not_claim_cross_language_semantics
    trends = TrendAnalyzer.new.analyze(items: [
      item("zh-a", "能源转型获得关注", "2026-08-08T03:00:00Z", region: "亚洲"),
      item("zh-b", "能源转型带来投资", "2026-08-08T04:00:00Z", region: "欧洲"),
      item("en-a", "Energy transition attracts investment", "2026-08-08T05:00:00Z", language: "en", region: "北美"),
      item("en-b", "Energy transition changes policy", "2026-08-08T06:00:00Z", language: "en", region: "欧洲")
    ], now: NOW)

    assert trends.any? { |trend| trend.fetch("topic") == "能源转型" && trend.fetch("topic_language") == "zh-CN" }
    assert trends.any? { |trend| trend.fetch("topic") == "energy transition" && trend.fetch("topic_language") == "en" }
  end
end
