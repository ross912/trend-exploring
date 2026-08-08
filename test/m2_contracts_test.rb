# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m2_contracts"

class M2ContractsTest < Minitest::Test
  def test_coverage_quota_preserves_prevalence_and_blocks_missing_stratum
    allowed = M2::CoverageContract.allocate(
      prevalence_lens: { "us" => 95, "other" => 5 },
      candidates: [{ "candidate_id" => "a", "stratum" => "other" }],
      required_strata: ["us", "other"], quota: 2
    )
    assert_equal "QUOTA_INFEASIBLE", allowed.fetch("reasonCode")
    blocked = M2::CoverageContract.allocate(
      prevalence_lens: { "us" => 95, "other" => 5 },
      candidates: [{ "candidate_id" => "a", "stratum" => "us" }, { "candidate_id" => "b", "stratum" => "other" }],
      required_strata: ["us", "other"], quota: 2
    )
    assert_equal "allow", blocked.fetch("decision")
    assert_equal({ "us" => 95, "other" => 5 }, blocked.fetch("prevalenceLens"))
  end

  def test_hidden_stratum_comparison_reports_shift_and_overlap
    result = M2::CoverageContract.compare_strata(
      fixed_ranking: %w[a b c d], current_ranking: %w[b a d c], top_k: 2, tolerance: 0.1
    )
    assert_includes result.fetch("reasonCodes"), "COVERAGE_SHIFT"
    assert_equal 1.0, result.fetch("topKOverlap")
  end

  def test_processing_delay_is_stratified_and_reasoned
    result = M2::CoverageContract.processing_delays(records: [{
      "language" => "ar", "published_at" => "2026-08-08T07:00:00Z", "discovered_at" => "2026-08-08T08:00:00Z",
      "version_available_at" => "2026-08-08T07:30:00Z", "processed_at" => "2026-08-08T09:00:00Z",
      "nominal_window_end" => "2026-08-08T08:00:00Z"
    }])
    assert_includes result.fetch("ar").fetch("reasonCodes"), "DISCOVERY_DELAY"
    assert_includes result.fetch("ar").fetch("reasonCodes"), "PROCESSING_BACKFILL"
  end

  def test_confidence_and_unknown_candidate_do_not_rewrite_prevalence
    confidence = M2::CoverageContract.confidence_preserves_allocation(
      observation_confidence: "C1", evidence_confidence: "C3", prevalence_magnitude: 0.8,
      allocation: { "lane" => "coverage_floor" }
    )
    assert_equal 0.8, confidence.fetch("prevalenceMagnitude")
    unknown = M2::CoverageContract.unknown_open_world(candidate: { "domain" => "unknown", "publisher_role" => "unknown", "candidate_id" => "u" })
    assert_equal "random_exploration", unknown.fetch("allocation_lane")
    assert_equal true, unknown.fetch("open_world_unknown")
  end

  def test_coverage_debt_age_is_query_derived_and_checksum_stable
    record = M2::CoverageContract.coverage_debt(
      opened_at: "2026-08-01T00:00:00Z", as_of: "2026-08-11T00:00:00Z", coverage_debt_id: "debt-1",
      reason_code: "STRATUM_WATERMARK_LAG", next_rotation_at: "2026-08-12T00:00:00Z"
    )
    assert_equal 864_000, record.dig("query_projection", "age_seconds")
    refute record.key?("age")
    refute record.key?("age_seconds")
    later = M2::CoverageContract.coverage_debt(
      opened_at: "2026-08-01T00:00:00Z", as_of: "2026-08-12T00:00:00Z", coverage_debt_id: "debt-1",
      reason_code: "STRATUM_WATERMARK_LAG", next_rotation_at: "2026-08-12T00:00:00Z"
    )
    assert_equal record.fetch("checksum"), later.fetch("checksum")
    assert_equal "COVERAGE_DEBT_STATE", record.dig("state_event", "type")
  end

  def test_language_evaluation_blocks_false_support_below_threshold
    result = M2::LanguageEvaluationContract.evaluate(
      rows: [
        { "language" => "zh", "assertion_type" => "table_number", "false_support" => true, "abstained" => false },
        { "language" => "zh", "assertion_type" => "table_number", "false_support" => false, "abstained" => false }
      ], false_support_threshold: 0.1, minimum_coverage: 0.5
    )
    assert_equal "blocked", result.fetch("decision")
    assert_equal 0.5, result.dig("strata", "zh/table_number", "falseSupportRate")
  end

  def test_report_publication_requires_contiguous_windows_and_one_first_placement
    arrivals = [{ "arrival_id" => "arrival-1", "reportable" => true }, { "arrival_id" => "metadata-1", "reportable" => false }]
    placements = [{ "arrival_id" => "arrival-1", "is_first_publication" => true, "publication_event_id" => "event-1" }]
    assert M2::ReportPublicationContract.validate!(
      windows: [{ id: "morning", start: "2026-08-08T07:00:00Z", end: "2026-08-08T12:00:00Z" },
                { id: "evening", start: "2026-08-08T12:00:00Z", end: "2026-08-08T19:00:00Z" }],
      arrivals: arrivals, placements: placements
    )
    assert_raises(M2::ReportPublicationContract::Error) do
      M2::ReportPublicationContract.validate!(
        windows: [{ id: "morning", start: "2026-08-08T07:00:00Z", end: "2026-08-08T12:00:00Z" },
                  { id: "evening", start: "2026-08-08T13:00:00Z", end: "2026-08-08T19:00:00Z" }],
        arrivals: arrivals, placements: placements
      )
    end
  end

  def test_presentation_contracts_preserve_raw_evidence_and_reasoned_selection
    raw = %w[title source published_at license_scope evidence coverage_boundary].each_with_object({}) { |key, result| result[key] = key }
    assert_nil M2::PresentationContract.ai_judgment_disabled(raw).fetch("ai_judgment")
    assert_equal "signal-a via random_exploration", M2::PresentationContract.selection_reason(
      candidate: { "signal_types" => ["signal-a"], "allocation_lane" => "random_exploration", "surface_sections" => ["explore"], "reason_codes" => ["COVERAGE_FLOOR"] }
    ).fetch("human_readable_reason")
  end

  def test_presentation_capacity_blind_review_and_attention_budget_fail_closed
    assert_equal "blocked", M2::PresentationContract.blind_review(samples: [{ "major_omission" => false }], rubric: "").fetch("result")
    assert_raises(M2::PresentationContract::Error) do
      M2::PresentationContract.capacity_rotation(selected: [{ "quality" => 0.2, "stratum" => "ar" }], capacity: 1, quality_floor: 0.5)
    end
    assert_raises(M2::PresentationContract::Error) do
      M2::PresentationContract.attention_budget(
        placements: [{ "content_id" => "x", "surface" => "daily", "allocation_lane" => "random_exploration", "fold" => "below_fold", "delivered" => false, "minutes" => 1 }],
        budget: { "k" => 10, "minutes" => 2 }, no_click_input: true
      )
    end
  end
end
