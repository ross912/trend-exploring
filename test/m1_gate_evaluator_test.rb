# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m1_gate_evaluator"

class M1GateEvaluatorTest < Minitest::Test
  def definition(id, blocking: "phase-exit")
    {
      "testDefinitionVersionId" => id,
      "introducedPhase" => "M1",
      "blocking" => blocking,
      "severity" => "P0"
    }
  end

  def catalog(signature: "signed", definitions: [definition("a")], members: nil)
    {
      "signatureStatus" => signature,
      "manifestSignature" => signature == "signed" ? "fixture-signature" : nil,
      "targetPhase" => "M1",
      "targetGate" => "phase-exit",
      "definitions" => definitions,
      "members" => members || definitions.map { |definition| { "testDefinitionVersionId" => definition.fetch("testDefinitionVersionId"), "membership" => "applicable" } }
    }
  end

  def test_missing_result_blocks_phase_exit
    report = M1::M1GateEvaluator.evaluate(catalog: catalog, results: {})
    assert_equal "blocked", report.fetch("decision")
    assert_includes report.fetch("reasonCodes"), "CATALOG_INCOMPLETE"
  end

  def test_all_required_phase_exit_results_must_pass
    definitions = [definition("a"), definition("b"), definition("c", blocking: "release")]
    report = M1::M1GateEvaluator.evaluate(
      catalog: catalog(definitions: definitions),
      results: { "a" => "pass", "b" => "pass" }
    )
    assert_equal "pass", report.fetch("decision")
    assert_equal 2, report.fetch("requiredCount")
  end

  def test_unsigned_catalog_and_not_applicable_are_fail_closed
    unsigned = M1::M1GateEvaluator.evaluate(catalog: catalog(signature: "unsigned"), results: { "a" => "pass" })
    assert_equal ["CATALOG_SIGNATURE_UNVERIFIED"], unsigned.fetch("reasonCodes")

    not_applicable = M1::M1GateEvaluator.evaluate(catalog: catalog, results: { "a" => "not_applicable" })
    assert_equal "blocked", not_applicable.fetch("decision")
    assert_includes not_applicable.fetch("reasonCodes"), "PHASE_EXIT_BLOCKED"
  end
end
