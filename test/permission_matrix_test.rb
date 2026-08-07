# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/permission_matrix"

class PermissionMatrixTest < Minitest::Test
  def matrix
    @matrix ||= M1::PermissionMatrix.build
  end

  def test_matrix_is_deterministic_and_all_purposes_fail_closed
    assert_equal matrix, M1::PermissionMatrix.build
    assert_equal 8, matrix.fetch("purposes").length
    assert matrix.fetch("purposes").all? { |purpose| purpose.fetch("defaultDecision") == "deny" }
    assert_equal "unsigned", matrix.fetch("signatureStatus")
  end

  def test_provider_inference_never_implies_training
    provider = M1::PermissionMatrix.expand("O_model:{provider_id}", provider_id: "provider-a")
    training = M1::PermissionMatrix.expand("O_train:{model_id,purpose}", model_id: "model-a", training_purpose: "forecast")
    assert_equal "O_model:provider-a", provider
    assert_equal "O_train:model-a,forecast", training
    assert_equal "allow", M1::PermissionMatrix.authorize(
      purpose: provider,
      context: { "authorization_decision" => "allow", "rights_grant" => true,
                 "authorized_scope" => true, "purpose_authorization" => true,
                 "provider_identity" => true }
    ).fetch("decision")
    assert_equal "deny", M1::PermissionMatrix.authorize(
      purpose: training,
      context: { "rights_grant" => true, "authorized_scope" => true, "purpose_authorization" => true,
                 "model_identity" => true }
    ).fetch("decision")
    assert_equal "PURPOSE_TRAIN_DENIED", M1::PermissionMatrix.authorize(purpose: training).fetch("reasonCode")
  end

  def test_malformed_matrix_is_rejected
    malformed = matrix.fetch("purposes").map(&:dup)
    malformed.first["defaultDecision"] = "allow"
    assert_raises(M1::PermissionMatrix::Error) { M1::PermissionMatrix.validate!(malformed) }
  end
end
