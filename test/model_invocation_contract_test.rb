# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/model_invocation_contract"

class ModelInvocationContractTest < Minitest::Test
  DOMAINS = { "rights" => { "epoch" => 11 }, "global" => { "epoch" => 3 }, "personal" => { "epoch" => 7 } }.freeze
  EPOCHS = { "rights" => 11, "global" => 3, "personal" => 7 }.freeze

  def snapshot
    M1::RevocationDependency.snapshot(domains: DOMAINS, epochs: EPOCHS)
  end

  def provider_context
    { "authorization_decision" => "allow", "rights_grant" => true,
      "authorized_scope" => true, "purpose_authorization" => true,
      "provider_identity" => true }
  end

  def test_provider_invocation_requires_matching_dependency_snapshot
    result = M1::ModelInvocationContract.authorize(
      purpose: "O_model:provider-a", context: provider_context,
      dependency_snapshot: snapshot, domains: DOMAINS, epochs: EPOCHS
    )
    assert_equal "allow", result.fetch("decision")
    assert_equal snapshot.fetch("setHash"), result.fetch("revocationDependencySetHash")

    stale = EPOCHS.merge("rights" => 12)
    result = M1::ModelInvocationContract.authorize(
      purpose: "O_model:provider-a", context: provider_context,
      dependency_snapshot: snapshot, domains: DOMAINS, epochs: stale
    )
    assert_equal "REVOCATION_DEPENDENCY_MISMATCH", result.fetch("reasonCode")
  end

  def test_provider_authorization_does_not_imply_training
    result = M1::ModelInvocationContract.authorize(
      purpose: "O_train:model-a,forecast", context: provider_context,
      dependency_snapshot: snapshot, domains: DOMAINS, epochs: EPOCHS
    )
    assert_equal "PURPOSE_TRAIN_DENIED", result.fetch("reasonCode")
  end
end
