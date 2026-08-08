# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/m2_contracts"
require_relative "../lib/m2_readiness"

class M2ArchitectureSelfCheckTest < Minitest::Test
  def test_m2_contracts_do_not_cross_contaminate_prevalence_or_private_input
    allocation = M2::CoverageContract.allocate(
      prevalence_lens: { "technology" => 0.95 },
      candidates: [{ "candidate_id" => "u", "stratum" => "unknown" }],
      required_strata: ["unknown"], quota: 1
    )
    assert_equal({ "technology" => 0.95 }, allocation.fetch("prevalenceLens"))
    unknown = M2::CoverageContract.unknown_open_world(candidate: { "domain" => "unknown", "publisher_role" => "unknown" })
    assert_equal "random_exploration", unknown.fetch("allocation_lane")
    assert_raises(M2::PresentationContract::Error) do
      M2::PresentationContract.attention_budget(
        placements: [{ "content_id" => "a", "surface" => "daily", "allocation_lane" => "coverage_floor", "fold" => "first", "delivered" => true, "minutes" => 1 }],
        budget: { "k" => 1, "minutes" => 2 }, no_click_input: false
      )
    end
  end

  def test_m2_publication_is_closed_over_windows_and_first_placements
    assert M2::ReportPublicationContract.validate!(
      windows: [{ "id" => "a", "start" => "2026-08-08T00:00:00Z", "end" => "2026-08-08T01:00:00Z" },
                { "id" => "b", "start" => "2026-08-08T01:00:00Z", "end" => "2026-08-08T02:00:00Z" }],
      arrivals: [{ "arrival_id" => "arrival", "reportable" => true }],
      placements: [{ "arrival_id" => "arrival", "is_first_publication" => true, "publication_event_id" => "event" }]
    )
  end

  def test_m2_readiness_plan_and_coverage_universe_match
    root = File.expand_path("..", __dir__)
    report = M2::M2Readiness.evaluate(
      acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
      coverage: JSON.parse(File.read(File.join(root, "schema/m2-phase-exit-coverage.json"))),
      root: root
    )
    assert_equal "ready", report.fetch("decision")
    assert_equal 14, report.fetch("requiredCount")
    assert_equal 14, report.dig("summary", "fixture_passed")
    assert_empty report.fetch("missingTestCodes")
    assert_empty report.fetch("extraTestCodes")
  end
end
