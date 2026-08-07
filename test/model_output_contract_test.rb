# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/model_output_contract"

class ModelOutputContractTest < Minitest::Test
  DOMAINS = { "rights" => { "epoch" => 11 }, "global" => { "epoch" => 3 }, "personal" => { "epoch" => 7 } }.freeze
  EPOCHS = { "rights" => 11, "global" => 3, "personal" => 7 }.freeze

  def setup
    @snapshot = M1::RevocationDependency.snapshot(domains: DOMAINS, epochs: EPOCHS)
    @context = { "authorization_decision" => "allow", "rights_grant" => true,
                 "authorized_scope" => true, "purpose_authorization" => true,
                 "provider_identity" => true }
  end

  def test_output_requires_same_dependency_hash
    result = M1::ModelOutputContract.authorize_persistence(
      purpose: "O_model:provider-a", context: @context, dependency_snapshot: @snapshot,
      domains: DOMAINS, epochs: EPOCHS, sink: "provider_response_store",
      output_dependency_hash: @snapshot.fetch("setHash")
    )
    assert_equal "allow", result.fetch("decision")

    result = M1::ModelOutputContract.authorize_persistence(
      purpose: "O_model:provider-a", context: @context, dependency_snapshot: @snapshot,
      domains: DOMAINS, epochs: EPOCHS, sink: "provider_response_store", output_dependency_hash: "stale"
    )
    assert_equal "OUTPUT_REVOCATION_DEPENDENCY_MISMATCH", result.fetch("reasonCode")
  end

  def test_global_forbidden_sink_is_denied
    result = M1::ModelOutputContract.authorize_persistence(
      purpose: "O_model:provider-a", context: @context, dependency_snapshot: @snapshot,
      domains: DOMAINS, epochs: EPOCHS, sink: "global_training",
      output_dependency_hash: @snapshot.fetch("setHash")
    )
    assert_equal "OUTPUT_SINK_DENIED", result.fetch("reasonCode")
  end
end
