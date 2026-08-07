# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/test_catalog_generator"

class TestCatalogGeneratorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PLAN = File.join(ROOT, "docs/04-acceptance-test-plan.md")

  def rows
    @rows ||= M1::TestCatalogGenerator.load_acceptance_plan(PLAN)
  end

  def test_catalog_is_deterministic_and_phase_bounded
    first = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
    second = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")

    assert_equal first, second
    assert_equal "m1.test-catalog.v1", first.fetch("schemaVersion")
    assert_equal "unsigned", first.fetch("signatureStatus")
    assert_nil first.fetch("manifestSignature")
    assert first.fetch("definitions").length < rows.length
    assert first.fetch("definitions").all? do |definition|
      M1::TestCatalogGenerator::PHASES.index(definition.fetch("introducedPhase")) <= 1
    end
  end

  def test_p0_floor_and_member_hash_are_machine_visible
    catalog = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
    p0_definitions = catalog.fetch("definitions").select { |definition| definition.fetch("severity") == "P0" }

    refute_empty p0_definitions
    assert p0_definitions.all? { |definition| definition.fetch("applicabilityPredicate") == "always" }
    assert p0_definitions.none? { |definition| definition.fetch("waiverAllowed") }

    expected = M1::TestCatalogGenerator.digest_members(catalog.fetch("members"))
    assert_equal expected, catalog.fetch("definitionsUniverseHash")
    assert_equal catalog.fetch("definitions").map { |definition| definition.fetch("testDefinitionVersionId") }.sort,
                 catalog.fetch("members").map { |member| member.fetch("testDefinitionVersionId") }.sort
  end

  def test_uuid_and_hash_outputs_are_valid_and_parse_errors_fail_closed
    catalog = M1::TestCatalogGenerator.build(rows, target_phase: "M0", target_gate: "phase-exit")
    catalog.fetch("definitions").each do |definition|
      assert_match(/\A[0-9a-f-]{36}\z/, definition.fetch("testId"))
      assert_match(/\A[0-9a-f-]{36}\z/, definition.fetch("testDefinitionVersionId"))
      assert_match(/\A[0-9a-f]{64}\z/, definition.fetch("definitionHash"))
    end

    assert_raises(M1::TestCatalogGenerator::Error) do
      M1::TestCatalogGenerator.parse("| BAD | M9 | P0 | none | fixture | oracle |\n")
    end
  end
end
