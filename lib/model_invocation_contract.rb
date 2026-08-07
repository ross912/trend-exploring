# frozen_string_literal: true

require_relative "permission_matrix"
require_relative "revocation_dependency"

module M1
  module ModelInvocationContract
    class Error < StandardError; end

    module_function

    def authorize(purpose:, context:, dependency_snapshot:, domains:, epochs:)
      decision = PermissionMatrix.authorize(purpose: purpose, context: context)
      return decision unless decision.fetch("decision") == "allow"

      unless RevocationDependency.matches?(dependency_snapshot, domains: domains, epochs: epochs)
        return {
          "decision" => "deny",
          "purpose" => purpose,
          "reasonCode" => "REVOCATION_DEPENDENCY_MISMATCH",
          "missingClaims" => []
        }
      end

      decision.merge("revocationDependencySetHash" => dependency_snapshot.fetch("setHash"))
    rescue KeyError, TypeError => error
      raise Error, "model invocation contract is incomplete: #{error.message}"
    end
  end
end
