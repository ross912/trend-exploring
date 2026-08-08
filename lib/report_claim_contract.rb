# frozen_string_literal: true

module M2
  module ReportClaimContract
    class Error < StandardError; end
    EVIDENCE_REQUIRED_TYPES = %w[external_world_state source_claim].freeze
    INFERENCE_TYPES = %w[ai_inference].freeze

    module_function

    def validate!(claim_type:, entailment_result:, evidence_scope_ids:, premise_scope_ids: [], inference_support_status: nil,
                  item_version_id: nil, evidence_scopes: nil)
      evidence_scope_ids = Array(evidence_scope_ids)
      premise_scope_ids = Array(premise_scope_ids)
      if EVIDENCE_REQUIRED_TYPES.include?(claim_type)
        raise Error, "CLAIM_ITEM_VERSION_MISSING: factual/source claim requires item_version_id" if item_version_id.to_s.empty?
        raise Error, "CLAIM_EVIDENCE_MISSING: factual/source claim requires evidence scope" if evidence_scope_ids.empty?
        raise Error, "EVIDENCE_NOT_ENTAILED: factual/source claim requires entailed evidence" unless entailment_result == "entailed"
        raise Error, "factual/source claim cannot carry inference premises" unless premise_scope_ids.empty?
        validate_evidence_scopes!(item_version_id: item_version_id, evidence_scope_ids: evidence_scope_ids,
                                 evidence_scopes: evidence_scopes)
      elsif INFERENCE_TYPES.include?(claim_type)
        raise Error, "AI inference must use not_applicable entailment" unless entailment_result == "not_applicable"
        raise Error, "AI inference requires premise scopes" if premise_scope_ids.empty?
        unless %w[supported unsupported].include?(inference_support_status)
          raise Error, "AI inference requires explicit support status"
        end
      else
        raise Error, "unsupported report claim type: #{claim_type}"
      end
      true
    end

    def validate_evidence_scopes!(item_version_id:, evidence_scope_ids:, evidence_scopes:)
      scopes = Array(evidence_scopes)
      raise Error, "CLAIM_EVIDENCE_MISSING: evidence scope records are required" if scopes.empty?

      records = scopes.map do |scope|
        raise Error, "CLAIM_EVIDENCE_MISSING: evidence scope record must be an object" unless scope.is_a?(Hash)

        {
          "evidence_scope_id" => read_scope_value(scope, "evidence_scope_id", "evidenceScopeId"),
          "item_version_id" => read_scope_value(scope, "item_version_id", "itemVersionId")
        }
      end
      record_ids = records.map { |record| record.fetch("evidence_scope_id") }
      raise Error, "CLAIM_SCOPE_MISMATCH: evidence scope IDs do not match claim" unless
        record_ids.sort == evidence_scope_ids.map(&:to_s).sort
      if records.any? { |record| record.fetch("item_version_id").to_s != item_version_id.to_s }
        raise Error, "CLAIM_SCOPE_MISMATCH: evidence scope belongs to a different item version"
      end
      true
    end

    def read_scope_value(scope, snake_key, camel_key)
      value = scope.key?(snake_key) ? scope[snake_key] : scope[camel_key]
      raise Error, "CLAIM_EVIDENCE_MISSING: evidence scope field #{snake_key} is required" if value.to_s.empty?

      value
    end
    private_class_method :validate_evidence_scopes!, :read_scope_value
  end
end
