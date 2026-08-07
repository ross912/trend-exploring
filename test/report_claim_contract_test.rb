# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/report_claim_contract"

class ReportClaimContractTest < Minitest::Test
  def test_factual_claim_requires_entailed_evidence
    assert M2::ReportClaimContract.validate!(
      claim_type: "external_world_state", entailment_result: "entailed",
      evidence_scope_ids: ["evidence-a"]
    )
    assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "external_world_state", entailment_result: "not_entailed", evidence_scope_ids: ["evidence-a"]
      )
    end
  end

  def test_inference_requires_separate_premises_and_support_status
    assert M2::ReportClaimContract.validate!(
      claim_type: "ai_inference", entailment_result: "not_applicable",
      evidence_scope_ids: [], premise_scope_ids: ["premise-a"], inference_support_status: "supported"
    )
    assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "ai_inference", entailment_result: "entailed",
        evidence_scope_ids: ["evidence-a"], premise_scope_ids: ["premise-a"], inference_support_status: "supported"
      )
    end
  end

  def test_unknown_claim_type_fails_closed
    assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "external_world_state_or_ai", entailment_result: "entailed", evidence_scope_ids: ["x"]
      )
    end
  end
end
