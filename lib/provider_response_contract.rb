# frozen_string_literal: true

module M1
  module ProviderResponseContract
    class Error < StandardError; end
    NON_CALLBACK_MODES = %w[sync poll download].freeze

    module_function

    def authorize_receipt(mode:, proof:, response_set_closed:, output_dependency_hash:, invocation_dependency_hash:)
      return deny("RESPONSE_SET_NOT_CLOSED") unless response_set_closed
      return deny("RESPONSE_DEPENDENCY_MISMATCH") unless output_dependency_hash == invocation_dependency_hash

      case mode
      when "callback"
        required = %w[provider_signature nonce provider_job_id captured_exchange_id authenticated_peer]
        return deny("CALLBACK_PROOF_INCOMPLETE") unless required.all? { |key| present?(proof[key]) }
      when *NON_CALLBACK_MODES
        required = %w[captured_exchange_id authenticated_peer raw_response_hash]
        return deny("RESPONSE_PROOF_INCOMPLETE") unless required.all? { |key| present?(proof[key]) }
        return deny("NON_CALLBACK_HAS_CALLBACK_PROOF") if present?(proof["provider_signature"]) || present?(proof["nonce"])
      else
        return deny("RESPONSE_MODE_UNSUPPORTED")
      end

      { "decision" => "allow", "responseMode" => mode, "missingClaims" => [] }
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
    private_class_method :present?

    def deny(reason_code)
      { "decision" => "deny", "reasonCode" => reason_code, "missingClaims" => [] }
    end
    private_class_method :deny
  end
end
