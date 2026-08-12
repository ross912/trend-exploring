# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/weak_signal_detector"

class WeakSignalDetectorTest < Minitest::Test
  AS_OF = Time.parse("2026-08-13T00:00:00Z")

  def item(id, publisher, title, created_at, language: "en", locale_tag: "", query: false,
           policy: "signal_eligible", status: "configured", discovery_basis: "editorial_feed")
    {
      "version_id" => id, "item_key" => id, "source_id" => "source-#{id}",
      "publisher_id" => publisher, "publisher_identity_status" => status,
      "analysis_policy" => policy, "registry_enabled" => true,
      "discovery_basis" => discovery_basis, "query_conditioned" => query,
      "language" => language, "locale_tag" => locale_tag, "title" => title,
      "summary" => "", "created_at" => created_at
    }
  end

  def evaluated(items)
    WeakSignalDetector.new.analyze(items: items, as_of: AS_OF)
  end

  def test_newly_repeated_requires_three_publishers_and_ignores_single_publisher_replays
    rows = []
    %w[p1 p2 p3].each_with_index do |publisher, index|
      rows << item("recent-#{index}", publisher, "AI model breakthrough", "2026-08-12T0#{index + 1}:00:00Z")
    end
    20.times do |index|
      rows << item("replay-#{index}", "only", "single publisher replay", "2026-08-12T#{index % 2 + 1}:#{index % 60}:00Z")
    end
    rows << item("history", "old", "AI model breakthrough", "2026-08-09T01:00:00Z")
    candidate = evaluated(rows).fetch("candidates").find { |row| row.fetch("phrase") == "ai model" }
    refute_nil candidate
    assert_includes candidate.fetch("reason_codes"), "NEWLY_REPEATED"
    refute evaluated(rows).fetch("candidates").any? { |row| row.fetch("phrase") == "single publisher" }
  end

  def test_warming_up_and_future_and_exploration_rows_are_not_candidates
    rows = [
      item("future", "p1", "AI model breakthrough", "2026-08-14T00:00:00Z"),
      item("explore", "p2", "AI model breakthrough", "2026-08-12T00:00:00Z", policy: "exploration_only"),
      item("now", "p3", "AI model breakthrough", "2026-08-12T01:00:00Z")
    ]
    result = evaluated(rows)
    assert_equal "warming_up", result.fetch("status")
    assert_empty result.fetch("candidates")
  end

  def test_source_expansion_new_language_and_decline_rules
    rows = []
    4.times do |day|
      4.times do |index|
        rows << item("old-#{day}-#{index}", "old-#{index}", "housing market shift", (AS_OF - ((day + 2) * 86_400) - index).iso8601)
      end
    end
    rows << item("recent-a", "new-a", "housing market shift", "2026-08-12T01:00:00Z", language: "en")
    rows << item("recent-b", "new-b", "housing market shift", "2026-08-12T02:00:00Z", language: "fr", locale_tag: "fr-FR")
    rows << item("recent-c", "new-c", "housing market shift", "2026-08-12T03:00:00Z", language: "de", locale_tag: "de-DE")
    rows << item("recent-d", "new-d", "housing market shift", "2026-08-12T04:00:00Z", language: "es", locale_tag: "es-ES")
    rows << item("recent-e", "new-e", "housing market shift", "2026-08-12T05:00:00Z", language: "it", locale_tag: "it-IT")
    rows << item("recent-f", "new-f", "housing market shift", "2026-08-12T06:00:00Z", language: "pt", locale_tag: "pt-BR")
    candidate = evaluated(rows).fetch("candidates").find { |row| row.fetch("phrase") == "housing market" }
    refute_nil candidate
    assert_includes candidate.fetch("reason_codes"), "SOURCE_EXPANSION"
    assert_includes candidate.fetch("reason_codes"), "NEW_LANGUAGE_OR_LOCALE_PARTICIPATION"

    decline_rows = rows.reject { |row| row.fetch("version_id").start_with?("recent-") }
    decline_rows << item("decline-recent", "old-0", "housing market shift", "2026-08-12T03:00:00Z")
    decline = evaluated(decline_rows).fetch("candidates").find { |row| row.fetch("phrase") == "housing market" }
    assert_includes decline.fetch("reason_codes"), "DISCUSSION_DECLINE"
  end

  def test_unresolved_and_query_rows_are_support_only_and_evidence_is_capped
    rows = []
    25.times do |index|
      rows << item("query-#{index}", "query-publisher", "AI model breakthrough", "2026-08-12T#{index % 24}:00:00Z", query: true)
    end
    3.times do |index|
      rows << item("recent-#{index}", "pub-#{index}", "AI model breakthrough", "2026-08-12T0#{index + 1}:00:00Z")
    end
    rows << item("unresolved", "", "AI model breakthrough", "2026-08-12T04:00:00Z", status: "unresolved")
    rows << item("old", "old", "AI model breakthrough", "2026-08-09T01:00:00Z")
    candidate = evaluated(rows).fetch("candidates").find { |row| row.fetch("phrase") == "ai model" }
    refute_nil candidate
    assert_equal 3, candidate.fetch("recent_publisher_count")
    assert_operator candidate.fetch("query_evidence_count"), :>, 0
    assert_operator candidate.fetch("unresolved_evidence_count"), :>, 0
    assert_operator candidate.fetch("recent_evidence_version_ids").length, :<=, 20
  end

  def test_query_only_or_unresolved_only_new_language_locale_cannot_trigger_participation
    rows = [
      item("old", "old", "robot policy change", "2026-08-09T01:00:00Z", language: "en", locale_tag: "en-US"),
      item("q1", "query-1", "robot policy change", "2026-08-12T01:00:00Z", language: "fr", locale_tag: "fr-FR", query: true),
      item("q2", "query-2", "robot policy change", "2026-08-12T02:00:00Z", language: "de", locale_tag: "de-DE", query: true),
      item("q3", "query-3", "robot policy change", "2026-08-12T03:00:00Z", language: "es", locale_tag: "es-ES", query: true)
    ]
    result = evaluated(rows)
    candidate = result.fetch("phrase_stats").find { |row| row.fetch("phrase") == "robot policy" }
    refute_nil candidate
    refute_includes candidate.fetch("reason_codes"), "NEW_LANGUAGE_OR_LOCALE_PARTICIPATION"

    unresolved = rows.reject { |row| row.fetch("version_id").start_with?("q") }.map(&:dup)
    %w[u1 u2 u3].each_with_index do |id, index|
      unresolved << item(id, "", "robot policy change", "2026-08-12T0#{index + 1}:00:00Z", language: %w[fr de es][index], locale_tag: %w[fr-FR de-DE es-ES][index], status: "unresolved")
    end
    unresolved_result = evaluated(unresolved)
    unresolved_candidate = unresolved_result.fetch("phrase_stats").find { |row| row.fetch("phrase") == "robot policy" }
    refute_includes unresolved_candidate.fetch("reason_codes"), "NEW_LANGUAGE_OR_LOCALE_PARTICIPATION"
  end

  def test_editorial_observation_wins_same_publisher_window_dedup_over_query_row
    rows = [
      item("old", "old", "space launch plan", "2026-08-09T01:00:00Z"),
      item("query-first", "same", "space launch plan", "2026-08-12T01:00:00Z", query: true),
      item("editorial", "same", "space launch plan", "2026-08-12T01:01:00Z")
    ]
    candidate = evaluated(rows).fetch("phrase_stats").find { |row| row.fetch("phrase") == "space launch" }
    refute_nil candidate
    assert_equal 1, candidate.fetch("recent_publisher_count")
    assert_equal 1, candidate.fetch("recent_qualifying_observation_count")
  end

  def test_order_reversal_is_deterministic
    rows = [
      item("a", "p-a", "quantum compute shift", "2026-08-12T01:00:00Z"),
      item("b", "p-b", "quantum compute shift", "2026-08-12T02:00:00Z"),
      item("c", "p-c", "quantum compute shift", "2026-08-12T03:00:00Z"),
      item("old", "old", "quantum compute shift", "2026-08-09T01:00:00Z")
    ]
    assert_equal evaluated(rows), evaluated(rows.reverse)
  end
end
