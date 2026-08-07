# frozen_string_literal: true

module M1
  module M1GateEvaluator
    class Error < StandardError; end
    TERMINAL_RESULTS = %w[pass fail blocked not_applicable].freeze

    module_function

    def required_definitions(catalog)
      definitions = catalog.fetch("definitions").each_with_object({}) do |definition, memo|
        memo.fetch(definition.fetch("testDefinitionVersionId")) { memo[definition.fetch("testDefinitionVersionId")] = definition }
      end
      catalog.fetch("members").each_with_object([]) do |member, required|
        next unless member.fetch("membership") == "applicable"

        definition = definitions.fetch(member.fetch("testDefinitionVersionId"))
        next unless definition.fetch("blocking") == "phase-exit"

        required << definition
      end.sort_by { |definition| definition.fetch("testDefinitionVersionId") }
    rescue KeyError => e
      raise Error, "catalog is malformed: #{e.message}"
    end

    def evaluate(catalog:, results: {})
      required = required_definitions(catalog)
      required_ids = required.map { |definition| definition.fetch("testDefinitionVersionId") }
      unless catalog.fetch("signatureStatus") == "signed" && catalog.fetch("manifestSignature").to_s != ""
        return blocked_report(catalog, required_ids, [], ["CATALOG_SIGNATURE_UNVERIFIED"])
      end

      unknown_result_ids = results.keys - required_ids
      missing_ids = required_ids - results.keys
      invalid_ids = results.each_with_object([]) do |(definition_id, result), memo|
        memo << definition_id unless TERMINAL_RESULTS.include?(result.to_s)
      end
      failed_ids = required_ids.select { |definition_id| %w[fail blocked].include?(results[definition_id].to_s) }
      not_applicable_ids = required_ids.select { |definition_id| results[definition_id].to_s == "not_applicable" }
      reason_codes = []
      reason_codes << "CATALOG_INCOMPLETE" unless missing_ids.empty?
      reason_codes << "RESULT_ID_OUT_OF_SCOPE" unless unknown_result_ids.empty?
      reason_codes << "RESULT_STATUS_INVALID" unless invalid_ids.empty?
      reason_codes << "PHASE_EXIT_BLOCKED" unless failed_ids.empty? && not_applicable_ids.empty?
      reason_codes << "PHASE_EXIT_PASSED" if reason_codes.empty?

      {
        "decision" => reason_codes == ["PHASE_EXIT_PASSED"] ? "pass" : "blocked",
        "targetPhase" => catalog.fetch("targetPhase"),
        "targetGate" => catalog.fetch("targetGate"),
        "requiredCount" => required_ids.length,
        "observedCount" => results.length,
        "missingDefinitionVersionIds" => missing_ids,
        "failedDefinitionVersionIds" => failed_ids,
        "notApplicableDefinitionVersionIds" => not_applicable_ids,
        "unknownResultDefinitionVersionIds" => unknown_result_ids,
        "invalidResultDefinitionVersionIds" => invalid_ids,
        "reasonCodes" => reason_codes
      }
    rescue KeyError => e
      raise Error, "catalog is malformed: #{e.message}"
    end

    def blocked_report(catalog, missing_ids, failed_ids, reason_codes)
      {
        "decision" => "blocked",
        "targetPhase" => catalog.fetch("targetPhase", "M1"),
        "targetGate" => catalog.fetch("targetGate", "phase-exit"),
        "requiredCount" => missing_ids.length + failed_ids.length,
        "observedCount" => 0,
        "missingDefinitionVersionIds" => missing_ids,
        "failedDefinitionVersionIds" => failed_ids,
        "notApplicableDefinitionVersionIds" => [],
        "unknownResultDefinitionVersionIds" => [],
        "invalidResultDefinitionVersionIds" => [],
        "reasonCodes" => reason_codes
      }
    end
  end
end
