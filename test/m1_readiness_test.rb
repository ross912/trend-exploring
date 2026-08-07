# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/m1_readiness"

class M1ReadinessTest < Minitest::Test
  def plan
    <<~MARKDOWN
      | ID | phase | severity | blocking | fixture | oracle |
      |---|---|---|---|---|---|
      | CTR-001 | M0 | P0 | phase-exit | fixture | oracle |
      | COV-002 | M1 | P0 | phase-exit | fixture | oracle |
      | COV-003 | M1 | P0 | release | fixture | oracle |
    MARKDOWN
  end

  def test_partial_entry_blocks_readiness
    coverage = {
      "entries" => [
        { "testCode" => "CTR-001", "status" => "fixture_passed", "evidence" => "fixture.sql" },
        { "testCode" => "COV-002", "status" => "partial", "evidence" => "partial.sql" }
      ]
    }
    report = M1::M1Readiness.evaluate(acceptance_plan: plan, coverage: coverage)
    assert_equal "blocked", report.fetch("decision")
    assert_equal ["COV-002"], report.fetch("blockedTestCodes")
  end

  def test_missing_and_extra_entries_are_visible
    report = M1::M1Readiness.evaluate(
      acceptance_plan: plan,
      coverage: { "entries" => [{ "testCode" => "CTR-001", "status" => "fixture_passed", "evidence" => "fixture.sql" }, { "testCode" => "EXTRA-001", "status" => "fixture_passed", "evidence" => "x" }] }
    )
    assert_equal ["COV-002"], report.fetch("missingTestCodes")
    assert_equal ["EXTRA-001"], report.fetch("extraTestCodes")
  end

  def test_current_coverage_is_explicitly_blocked
    root = File.expand_path("..", __dir__)
    report = M1::M1Readiness.evaluate(
      acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
      coverage: JSON.parse(File.read(File.join(root, "schema/m1-phase-exit-coverage.json")))
    )
    assert_equal "blocked", report.fetch("decision")
    assert_operator report.fetch("blockedTestCodes").length, :>, 0
  end
end
