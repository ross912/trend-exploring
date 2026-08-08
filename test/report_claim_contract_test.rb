# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/report_claim_contract"

class ReportClaimContractTest < Minitest::Test
  def test_factual_claim_requires_entailed_evidence
    assert M2::ReportClaimContract.validate!(
      claim_type: "external_world_state", entailment_result: "entailed",
      evidence_scope_ids: ["evidence-a"], item_version_id: "item-1",
      evidence_scopes: [{ "evidence_scope_id" => "evidence-a", "item_version_id" => "item-1" }]
    )
    assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "external_world_state", entailment_result: "not_entailed", evidence_scope_ids: ["evidence-a"],
        item_version_id: "item-1", evidence_scopes: [{ "evidence_scope_id" => "evidence-a", "item_version_id" => "item-1" }]
      )
    end
  end

  def test_evidence_scope_must_belong_to_claim_item_version
    assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "source_claim", entailment_result: "entailed", evidence_scope_ids: ["evidence-a"],
        item_version_id: "item-1", evidence_scopes: [{ "evidence_scope_id" => "evidence-a", "item_version_id" => "item-2" }]
      )
    end
  end

  def test_factual_claim_without_structured_evidence_is_rejected
    error = assert_raises(M2::ReportClaimContract::Error) do
      M2::ReportClaimContract.validate!(
        claim_type: "external_world_state", entailment_result: "entailed", evidence_scope_ids: ["evidence-a"]
      )
    end
    assert_match(/CLAIM_ITEM_VERSION_MISSING/, error.message)
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
