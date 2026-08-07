# frozen_string_literal: true

module M2
  module ReportClaimContract
    class Error < StandardError; end
    EVIDENCE_REQUIRED_TYPES = %w[external_world_state source_claim].freeze
    INFERENCE_TYPES = %w[ai_inference].freeze

    module_function

    def validate!(claim_type:, entailment_result:, evidence_scope_ids:, premise_scope_ids: [], inference_support_status: nil)
      evidence_scope_ids = Array(evidence_scope_ids)
      premise_scope_ids = Array(premise_scope_ids)
      if EVIDENCE_REQUIRED_TYPES.include?(claim_type)
        raise Error, "factual/source claim requires evidence scope" if evidence_scope_ids.empty?
        raise Error, "factual/source claim requires entailed evidence" unless entailment_result == "entailed"
        raise Error, "factual/source claim cannot carry inference premises" unless premise_scope_ids.empty?
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
  end
end
