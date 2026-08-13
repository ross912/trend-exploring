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

  def test_seeded_manifest_is_order_invariant_and_materializes_every_terminal
    rows = [
      row(version: "seed-a", source: "s-a", publisher: "p-a", locale: "en-US", published: "2026-08-09T01:00:00Z"),
      row(version: "seed-b", source: "s-b", publisher: "p-b", locale: "en-US", published: "2026-08-09T02:00:00Z"),
      row(version: "seed-c", source: "s-c", publisher: "p-c", locale: "es-419", published: "2026-08-09T03:00:00Z"),
      row(version: "seed-d", source: "s-d", publisher: "p-d", locale: "ja-JP", published: "2026-08-09T04:00:00Z", policy: "signal_eligible"),
      row(version: "seed-e", source: "s-e", publisher: "p-e", locale: "de-DE", published: "2026-08-09T05:00:00Z", basis: "topic_query")
    ]
    selector = BreadthDiscoverySelector.new(limit: 2, locale_limit: 1, seed: "fixture-seed")
    detector_results = { "seed-a" => "no-candidate", "seed-b" => "no-candidate", "seed-c" => "candidate" }
    first = selector.selection_manifest(items: rows, scope_id: "fixture-scope", detector_results: detector_results)
    second = selector.selection_manifest(items: rows.reverse, scope_id: "fixture-scope", detector_results: { "seed-a" => "candidate" })

    assert_equal first.fetch("manifest_id"), second.fetch("manifest_id")
    assert_equal first.fetch("selected_version_ids"), second.fetch("selected_version_ids")
    assert_equal rows.length, first.fetch("eligibility_count")
    assert_equal rows.length, first.fetch("eligibility_decisions").length
    assert first.fetch("eligibility_decisions").all? { |decision| decision.fetch("terminal") }
    assert_equal first.fetch("eligible_count") + first.fetch("ineligible_count"), first.fetch("eligibility_count")
    assert_equal first.fetch("eligible_count"), first.fetch("exploration_decisions").length
    assert first.fetch("exploration_decisions").all? { |decision| decision.fetch("terminal") && decision.fetch("not_a_signal") && decision.fetch("delivery_status") == "unmeasured" }
  end

  def test_seeded_manifest_selects_no_candidate_items_without_personalization
    rows = (0...4).map do |index|
      row(version: "no-candidate-#{index}", source: "source-#{index}", publisher: "publisher-#{index}", locale: index.even? ? "en-US" : "es-419", published: format("2026-08-09T%02d:00:00Z", index))
    end
    selector = BreadthDiscoverySelector.new(limit: 3, locale_limit: 2, seed: "stable-seed")
    manifest = selector.selection_manifest(items: rows, detector_results: rows.to_h { |item| [item.fetch("version_id"), "no-candidate"] })
    assert_equal 4, manifest.fetch("eligible_count")
    assert_equal 3, manifest.fetch("selected_count")
    assert manifest.fetch("exploration_decisions").select { |decision| decision.fetch("outcome") == "selected" }.all? { |decision| decision.fetch("not_a_signal") }
    assert manifest.fetch("selected_items").all? { |item| item.fetch("detector_outcome") == "no-candidate" && item.fetch("allocation_lane") == "random_exploration" && item.fetch("delivery_status") == "unmeasured" }
    assert_equal "none", manifest.fetch("personalization")
  end

  def test_seeded_manifest_keeps_duplicate_and_invalid_rows_in_eligibility_denominator
    valid = row(version: "duplicate", source: "s1", publisher: "p1", locale: "en-US", published: "2026-08-09T01:00:00Z")
    manifest = BreadthDiscoverySelector.new(seed: "duplicate-seed").selection_manifest(items: [valid, valid.dup, { "version_id" => "broken" }])
    assert_equal 3, manifest.fetch("eligibility_count")
    assert_equal 2, manifest.fetch("ineligible_count")
    assert_equal 1, manifest.fetch("exploration_decisions").length
    assert_includes manifest.fetch("eligibility_decisions").map { |decision| decision.fetch("reason_code") }, "duplicate_version_id"
  end
end
