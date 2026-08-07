# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/provider_response_contract"

class ProviderResponseContractTest < Minitest::Test
  def callback_proof
    { "provider_signature" => "sig", "nonce" => "nonce", "provider_job_id" => "job",
      "captured_exchange_id" => "exchange", "authenticated_peer" => "mtls-peer" }
  end

  def test_callback_requires_signed_nonce_and_exchange_proof
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "callback", proof: callback_proof, response_set_closed: true,
      output_dependency_hash: "hash", invocation_dependency_hash: "hash"
    )
    assert_equal "allow", result.fetch("decision")
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "callback", proof: callback_proof.merge("nonce" => nil), response_set_closed: true,
      output_dependency_hash: "hash", invocation_dependency_hash: "hash"
    )
    assert_equal "CALLBACK_PROOF_INCOMPLETE", result.fetch("reasonCode")
  end

  def test_non_callback_requires_exchange_and_rejects_callback_only_proof
    proof = { "captured_exchange_id" => "exchange", "authenticated_peer" => "peer", "raw_response_hash" => "a" * 64 }
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "poll", proof: proof, response_set_closed: true,
      output_dependency_hash: "hash", invocation_dependency_hash: "hash"
    )
    assert_equal "allow", result.fetch("decision")
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "poll", proof: proof.merge("nonce" => "replay"), response_set_closed: true,
      output_dependency_hash: "hash", invocation_dependency_hash: "hash"
    )
    assert_equal "NON_CALLBACK_HAS_CALLBACK_PROOF", result.fetch("reasonCode")
  end

  def test_closed_set_and_dependency_are_fail_closed
    proof = { "captured_exchange_id" => "exchange", "authenticated_peer" => "peer", "raw_response_hash" => "a" * 64 }
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "sync", proof: proof, response_set_closed: false,
      output_dependency_hash: "hash", invocation_dependency_hash: "hash"
    )
    assert_equal "RESPONSE_SET_NOT_CLOSED", result.fetch("reasonCode")
    result = M1::ProviderResponseContract.authorize_receipt(
      mode: "sync", proof: proof, response_set_closed: true,
      output_dependency_hash: "old", invocation_dependency_hash: "new"
    )
    assert_equal "RESPONSE_DEPENDENCY_MISMATCH", result.fetch("reasonCode")
  end
end
