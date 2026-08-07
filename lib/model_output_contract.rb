# frozen_string_literal: true

require_relative "model_invocation_contract"

module M1
  module ModelOutputContract
    class Error < StandardError; end
    FORBIDDEN_GLOBAL_SINKS = %w[global_long_term_log global_cache global_embedding global_training].freeze

    module_function

    def authorize_persistence(purpose:, context:, dependency_snapshot:, domains:, epochs:, sink:, output_dependency_hash:)
      invocation = ModelInvocationContract.authorize(
        purpose: purpose, context: context, dependency_snapshot: dependency_snapshot,
        domains: domains, epochs: epochs
      )
      return invocation unless invocation.fetch("decision") == "allow"

      if sink.to_s.empty? || (purpose.start_with?("O_model") && FORBIDDEN_GLOBAL_SINKS.include?(sink))
        return deny("OUTPUT_SINK_DENIED")
      end
      if output_dependency_hash.to_s != invocation.fetch("revocationDependencySetHash")
        return deny("OUTPUT_REVOCATION_DEPENDENCY_MISMATCH")
      end

      invocation.merge("decision" => "allow", "sink" => sink)
    rescue KeyError, TypeError => error
      raise Error, "model output contract is incomplete: #{error.message}"
    end

    def deny(reason_code)
      { "decision" => "deny", "reasonCode" => reason_code, "missingClaims" => [] }
    end
    private_class_method :deny
  end
end
