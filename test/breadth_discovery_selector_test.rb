# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/breadth_discovery_selector"

class BreadthDiscoverySelectorTest < Minitest::Test
  def row(version:, source:, publisher:, locale:, published:, status: "observed_domain", basis: "locale_headlines", policy: "exploration_only", query: false)
    {
      "version_id" => version, "source_id" => source, "publisher_id" => publisher,
      "publisher_identity_status" => status, "locale_tag" => locale,
      "published_at" => published, "captured_at" => published,
      "source_kind" => "discovery", "discovery_basis" => basis,
      "analysis_policy" => policy, "query_conditioned" => query
    }
  end

  def test_selector_is_order_invariant_and_applies_publisher_locale_caps
    rows = [
      row(version: "a-new", source: "s1", publisher: "p1", locale: "en-US", published: "2026-08-09T04:00:00Z"),
      row(version: "a-old", source: "s1", publisher: "p1", locale: "en-US", published: "2026-08-09T01:00:00Z"),
      row(version: "b", source: "s2", publisher: "p2", locale: "en-US", published: "2026-08-09T03:00:00Z"),
      row(version: "c", source: "s3", publisher: "p3", locale: "en-US", published: "2026-08-09T02:00:00Z"),
      row(version: "d", source: "s4", publisher: "p4", locale: "es-419", published: "2026-08-09T02:00:00Z"),
      row(version: "e", source: "s5", publisher: "p5", locale: "es-419", published: "2026-08-09T01:00:00Z"),
      row(version: "unresolved-new", source: "s6", publisher: "", locale: "en-US", published: "2026-08-09T05:00:00Z", status: "unresolved"),
      row(version: "unresolved-old", source: "s6", publisher: "", locale: "en-US", published: "2026-08-09T06:00:00Z", status: "unresolved")
    ]
    selector = BreadthDiscoverySelector.new(limit: 12)
    first = selector.select(items: rows)
    second = selector.select(items: rows.reverse)
    assert_equal first.map { |item| item.fetch("version_id") }, second.map { |item| item.fetch("version_id") }
    assert_equal "a-new", first.fetch(0).fetch("version_id")
    assert_equal 1, first.count { |item| item.fetch("publisher_id") == "p1" }
    assert_operator first.count { |item| item.fetch("locale_tag") == "en-US" }, :<=, 2
    assert_operator first.count { |item| item.fetch("locale_tag") == "es-419" }, :<=, 2
    assert_operator first.count { |item| item.fetch("source_id") == "s6" }, :<=, 1
    unresolved = selector.select(items: [rows.fetch(-2), rows.fetch(-1)])
    assert_equal ["unresolved-old"], unresolved.map { |item| item.fetch("version_id") }
  end

  def test_selector_rejects_query_conditioned_and_signal_rows
    rows = [
      row(version: "query", source: "s1", publisher: "p1", locale: "en-US", published: "2026-08-09T01:00:00Z", basis: "topic_query", policy: "signal_eligible", query: true),
      row(version: "signal", source: "s2", publisher: "p2", locale: "en-US", published: "2026-08-09T02:00:00Z", basis: "locale_headlines", policy: "signal_eligible")
    ]
    assert_empty BreadthDiscoverySelector.new.select(items: rows)
  end

  def test_selector_caps_twenty_rows_from_one_publisher_to_one
    rows = (0...20).map do |index|
      row(
        version: "same-publisher-#{index}", source: "source-#{index}", publisher: "same.example",
        locale: "locale-#{index}", published: format("2026-08-09T%02d:00:00Z", index)
      )
    end
    selected = BreadthDiscoverySelector.new(limit: 12).select(items: rows)
    assert_equal 1, selected.count { |item| item.fetch("publisher_id") == "same.example" }
    assert_equal "same-publisher-19", selected.fetch(0).fetch("version_id")
  end
end
