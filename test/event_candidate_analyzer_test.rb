# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/event_candidate_analyzer"

class EventCandidateAnalyzerTest < Minitest::Test
  NOW = Time.parse("2026-08-08T12:00:00Z").freeze

  def setup
    @analyzer = EventCandidateAnalyzer.new
  end

  def test_english_earthquake_titles_form_one_deterministic_candidate
    items = [
      item("en-a", "publisher-a", "Japan 7.1 earthquake triggers tsunami warning"),
      item("en-b", "publisher-b", "Japan 7.1 earthquake prompts tsunami warning"),
      item("en-c", "publisher-c", "Japan 7.1 earthquake and tsunami warning")
    ]
    candidates = @analyzer.analyze(items: items, now: NOW)
    assert_equal 1, candidates.length
    candidate = candidates.fetch(0)
    assert_equal "event_candidate", candidate.fetch("candidate_status")
    assert_equal "en", candidate.fetch("language")
    assert_equal 3, candidate.fetch("qualifying_source_count")
    assert_equal 0, candidate.fetch("query_conditioned_evidence_count")
    assert_includes candidate.fetch("explanation"), "3 个非 query"
    assert_includes candidate.fetch("explanation"), "0 条 query-conditioned 证据不计资格"
    assert_includes candidate.fetch("explanation"), "7.1"
    assert_equal "deterministic_anchor_similarity_v1", candidate.fetch("matching_method")
    assert candidate.fetch("shared_anchors").any? { |anchor| anchor.fetch("kind") == "trigram" }
    assert candidate.fetch("shared_anchors").any? { |anchor| anchor.fetch("kind") == "number" }
    assert_equal items.map { |row| row.fetch("item_key") }.sort, candidate.fetch("qualifying_item_keys").sort
  end

  def test_chinese_earthquake_is_partitioned_from_english_and_has_long_anchor
    items = [
      item("zh-a", "publisher-a", "北海道7.1级地震引发海啸警报", language: "zh-CN"),
      item("zh-b", "publisher-b", "北海道发生7.1级地震并发布海啸警报", language: "zh-CN"),
      item("en-a", "publisher-c", "Hokkaido 7.1 earthquake tsunami warning", language: "en")
    ]
    candidates = @analyzer.analyze(items: items, now: NOW)
    assert_equal 1, candidates.length
    candidate = candidates.fetch(0)
    assert_equal "zh-CN", candidate.fetch("language")
    assert candidate.fetch("shared_anchors").any? { |anchor| anchor.fetch("kind") == "long_shingle" }
    refute_includes candidate.fetch("qualifying_item_keys"), "en-a"
  end

  def test_query_evidence_can_attach_after_two_non_query_publishers
    items = [
      item("base-a", "publisher-a", "Japan 7.1 earthquake triggers tsunami warning"),
      item("base-b", "publisher-b", "Japan 7.1 earthquake prompts tsunami warning"),
      item("query-a", "publisher-c", "Japan 7.1 earthquake tsunami warning", query_conditioned: true)
    ]
    candidate = @analyzer.analyze(items: items, now: NOW).fetch(0)
    assert_equal 2, candidate.fetch("qualifying_source_count")
    assert_equal 1, candidate.fetch("query_conditioned_evidence_count")
    assert_equal 3, candidate.fetch("member_count")
    query_evidence = candidate.fetch("evidence_items").find { |entry| entry.fetch("item_key") == "query-a" }
    assert_equal "query_conditioned_support", query_evidence.fetch("lineage_role")
    refute_includes candidate.fetch("candidate_key"), "query-a"
  end

  def test_query_time_does_not_change_core_candidate_span
    items = [
      item("core-a", "publisher-a", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-08T07:00:00Z"),
      item("core-b", "publisher-b", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-08T08:00:00Z"),
      item("late-query", "publisher-q", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-09T14:00:00Z", query_conditioned: true)
    ]
    candidate = @analyzer.analyze(items: items, now: Time.parse("2026-08-09T14:00:00Z")).fetch(0)
    assert_equal "2026-08-08T07:00:00Z", candidate.fetch("first_published_at")
    assert_equal "2026-08-08T08:00:00Z", candidate.fetch("last_published_at")
    assert_equal 1.0, candidate.fetch("time_span_hours")
    assert_equal 1, candidate.fetch("query_conditioned_evidence_count")
  end

  def test_query_only_and_unresolved_items_never_form_candidate
    items = [
      item("query-a", "publisher-a", "Japan 7.1 earthquake tsunami warning", query_conditioned: true),
      item("query-b", "publisher-b", "Japan 7.1 earthquake tsunami warning", query_conditioned: true),
      item("unresolved", "", "Japan 7.1 earthquake tsunami warning", publisher_identity_status: "unresolved")
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_false_positive_templates_and_incompatible_numbers_are_rejected
    items = [
      item("drone-a", "publisher-a", "无人机灭火行动持续" , language: "zh-CN"),
      item("border-a", "publisher-b", "边境局势出现变化", language: "zh-CN"),
      item("farm-a", "publisher-c", "农田灌溉计划调整", language: "zh-CN"),
      item("num-a", "publisher-d", "Japan 7.1 earthquake tsunami warning"),
      item("num-b", "publisher-e", "Japan 5.1 earthquake tsunami warning")
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_drc_flood_and_republic_congo_election_stay_as_two_candidates
    items = [
      item("drc-a", "publisher-a", "DRC Kinshasa flood emergency"),
      item("drc-b", "publisher-b", "DRC Kinshasa flood worsens"),
      item("congo-a", "publisher-c", "Republic Congo Brazzaville election results"),
      item("congo-b", "publisher-d", "Republic Congo Brazzaville election held")
    ]
    candidates = @analyzer.analyze(items: items, now: NOW)
    assert_equal 2, candidates.length
    labels = candidates.map { |candidate| candidate.fetch("label") }.join(" ")
    assert_includes labels, "DRC Kinshasa"
    assert_includes labels, "Republic Congo"
  end

  def test_complete_link_does_not_bridge_an_incompatible_third_item
    items = [
      item("a", "publisher-a", "Alpha 7.1 earthquake tsunami warning"),
      item("b", "publisher-b", "Alpha 7.1 earthquake coastal alert"),
      item("c", "publisher-c", "Alpha 5.1 earthquake coastal alert")
    ]
    candidates = @analyzer.analyze(items: items, now: NOW)
    refute candidates.any? { |candidate| candidate.fetch("qualifying_item_keys").sort == %w[a b c] }
  end

  def test_same_publisher_two_feeds_are_one_member_and_do_not_reach_two_publishers
    items = [
      item("same-a", "publisher-a", "Japan 7.1 earthquake tsunami warning"),
      item("same-b", "publisher-a", "Japan 7.1 earthquake tsunami warning update"),
      item("same-c", "publisher-b", "Japan 7.1 earthquake tsunami warning")
    ]
    candidate = @analyzer.analyze(items: items, now: NOW).fetch(0)
    assert_equal 2, candidate.fetch("qualifying_source_count")
    assert_equal 2, candidate.fetch("dedup_source_count")
    assert_equal 1, candidate.fetch("qualifying_item_keys").count { |key| key.start_with?("same-") && key != "same-c" }
  end

  def test_single_common_bigram_and_three_character_chinese_shingle_do_not_pass
    english = [
      item("bigram-a", "publisher-a", "border tension rises"),
      item("bigram-b", "publisher-b", "border tension persists")
    ]
    chinese = [
      item("shingle-a", "publisher-c", "北海道", language: "zh-CN"),
      item("shingle-b", "publisher-d", "北海道", language: "zh-CN")
    ]
    assert_empty @analyzer.analyze(items: english + chinese, now: NOW)
  end

  def test_one_shared_trigram_or_name_with_components_is_not_two_independent_anchors
    trigram_only = [
      item("trigram-a", "publisher-a", "Alpha beta gamma delta"),
      item("trigram-b", "publisher-b", "Alpha beta gamma epsilon")
    ]
    name_only = [
      item("name-a", "publisher-c", "Republic Congo flood"),
      item("name-b", "publisher-d", "Republic Congo election")
    ]
    assert_empty @analyzer.analyze(items: trigram_only + name_only, now: NOW)
  end

  def test_shared_anchors_only_report_values_supported_by_every_qualifying_source
    items = [
      item("quake-1", "publisher-a", "Quake alpha 1 2 Japan alert"),
      item("quake-2", "publisher-b", "Quake alpha 1 3 Japan alert"),
      item("quake-3", "publisher-c", "Quake alpha 2 3 Japan alert")
    ]
    candidate = @analyzer.analyze(items: items, now: NOW).fetch(0)
    assert_equal 3, candidate.fetch("qualifying_source_count")
    refute_includes candidate.fetch("shared_anchors").map { |anchor| anchor.fetch("value") }, "1"
    refute_includes candidate.fetch("shared_anchors").map { |anchor| anchor.fetch("value") }, "2"
    refute_includes candidate.fetch("shared_anchors").map { |anchor| anchor.fetch("value") }, "3"
    candidate.fetch("shared_anchors").each do |anchor|
      assert_equal 3, anchor.fetch("supporting_qualifying_source_count")
    end
    assert_includes candidate.fetch("explanation"), "每一对均通过门槛"
  end

  def test_common_raw_anchor_survives_a_private_longer_shingle
    items = [
      item("raw-a", "publisher-a", "Japan 7.1 earthquake warning tsunami response"),
      item("raw-b", "publisher-b", "Japan 7.1 earthquake warning"),
      item("raw-c", "publisher-c", "Japan 7.1 earthquake warning confirmed")
    ]
    candidate = @analyzer.analyze(items: items, now: NOW).fetch(0)
    shared = candidate.fetch("shared_anchors")
    assert_includes shared.map { |anchor| anchor.fetch("value") }, "7.1 earthquake warning"
    assert shared.all? { |anchor| anchor.fetch("supporting_qualifying_source_count") == 3 }
  end

  def test_query_outside_core_span_keeps_key_and_core_times_unchanged
    core = [
      item("span-a", "publisher-a", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-08T07:00:00Z"),
      item("span-b", "publisher-b", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-08T08:00:00Z")
    ]
    with_query = core + [item("span-q", "publisher-q", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-09T00:00:00Z", query_conditioned: true)]
    without_query = @analyzer.analyze(items: core, now: NOW).fetch(0)
    with_query_candidate = @analyzer.analyze(items: with_query, now: Time.parse("2026-08-09T01:00:00Z")).fetch(0)
    assert_equal without_query.fetch("candidate_key"), with_query_candidate.fetch("candidate_key")
    assert_equal without_query.fetch("first_published_at"), with_query_candidate.fetch("first_published_at")
    assert_equal without_query.fetch("last_published_at"), with_query_candidate.fetch("last_published_at")
    assert_equal without_query.fetch("time_span_hours"), with_query_candidate.fetch("time_span_hours")
    assert_equal 1, with_query_candidate.fetch("query_conditioned_evidence_count")
  end

  def test_same_chinese_title_does_not_become_many_overlapping_components
    items = [
      item("same-zh-a", "publisher-a", "北海道发生地震", language: "zh-CN"),
      item("same-zh-b", "publisher-b", "北海道发生地震", language: "zh-CN")
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_ten_query_conditioned_publishers_do_not_create_query_only_candidate
    items = (1..10).map do |index|
      item("query-#{index}", "query-publisher-#{index}", "Japan 7.1 earthquake tsunami warning", query_conditioned: true)
    end
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_two_same_publisher_feeds_without_second_publisher_are_empty
    items = [
      item("same-only-a", "publisher-a", "Japan 7.1 earthquake tsunami warning"),
      item("same-only-b", "publisher-a", "Japan 7.1 earthquake tsunami warning update")
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_pair_over_thirty_six_hours_is_not_compatible
    items = [
      item("old-a", "publisher-a", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-06T23:00:00Z"),
      item("old-b", "publisher-b", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-08T11:00:01Z")
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)
  end

  def test_time_language_registry_and_html_boundaries_are_deterministic
    items = [
      item("html-a", "publisher-a", "<b>Japan&nbsp;7.1</b> earthquake &amp; tsunami warning"),
      item("html-b", "publisher-b", "Japan 7.1 earthquake tsunami warning", published_at: "2026-08-09T13:01:00Z"),
      item("html-c", "publisher-c", "Japan 7.1 earthquake tsunami warning", language: "zh-CN"),
      item("disabled", "publisher-d", "Japan 7.1 earthquake tsunami warning", registry_enabled: false),
      item("missing-time", "publisher-e", "Japan 7.1 earthquake tsunami warning", published_at: nil)
    ]
    assert_empty @analyzer.analyze(items: items, now: NOW)

    same_time = items.fetch(0).merge("item_key" => "html-b", "publisher_id" => "publisher-b", "published_at" => "2026-08-08T11:30:00Z")
    candidate = @analyzer.analyze(items: [items.fetch(0), same_time], now: NOW).fetch(0)
    assert_equal 2, candidate.fetch("qualifying_source_count")
    assert_equal items.fetch(0).fetch("title"), candidate.fetch("label")
  end

  def test_input_order_does_not_change_key_members_label_or_explanation
    items = [
      item("order-a", "publisher-a", "Japan 7.1 earthquake triggers tsunami warning"),
      item("order-b", "publisher-b", "Japan 7.1 earthquake prompts tsunami warning"),
      item("order-c", "publisher-c", "Japan 7.1 earthquake and tsunami warning")
    ]
    forward = @analyzer.analyze(items: items, now: NOW)
    reverse = @analyzer.analyze(items: items.reverse, now: NOW)
    assert_equal forward, reverse
  end

  private

  def item(item_key, publisher_id, title, language: "en", published_at: "2026-08-08T11:00:00Z", query_conditioned: false, publisher_identity_status: "configured", registry_enabled: true)
    {
      "item_key" => item_key,
      "source_id" => "source-#{item_key}",
      "publisher_id" => publisher_id,
      "publisher_identity_status" => publisher_identity_status,
      "publisher_name" => publisher_id,
      "language" => language,
      "title" => title,
      "summary" => "短摘要",
      "source_url" => "https://example.test/#{item_key}",
      "published_at" => published_at,
      "query_conditioned" => query_conditioned,
      "registry_enabled" => registry_enabled
    }
  end
end
