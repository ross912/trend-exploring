# frozen_string_literal: true

require "json"

module M1
  module PermissionMatrix
    class Error < StandardError; end

    PURPOSES = [
      {
        "purpose" => "O_acquire",
        "resourceUnit" => "collection_opportunity",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization]
      },
      {
        "purpose" => "O_extract",
        "resourceUnit" => "artifact_or_version",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization]
      },
      {
        "purpose" => "O_model:local",
        "resourceUnit" => "artifact_or_version",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization local_processor]
      },
      {
        "purpose" => "O_model:{provider_id}",
        "resourceUnit" => "artifact_or_version",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization provider_identity]
      },
      {
        "purpose" => "O_train:{model_id,purpose}",
        "resourceUnit" => "training_member",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization training_authorization deletion_contract model_identity]
      },
      {
        "purpose" => "O_signal",
        "resourceUnit" => "version_or_projection",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant purpose_authorization signal_processor]
      },
      {
        "purpose" => "O_display",
        "resourceUnit" => "display_projection",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[rights_grant authorized_scope purpose_authorization display_scope transform_allowlist revocation_epoch]
      },
      {
        "purpose" => "O_prevalence",
        "resourceUnit" => "observation_denominator",
        "defaultDecision" => "deny",
        "requiredClaims" => %w[coverage_policy denominator_eligibility]
      }
    ].freeze

    module_function

    def build(matrix_version: "m1.permission-matrix.v1")
      matrix = {
        "schemaVersion" => matrix_version,
        "signatureStatus" => "unsigned",
        "manifestSignature" => nil,
        "purposes" => PURPOSES.map(&:dup),
        "separationRules" => [
          {
            "left" => "O_model:{provider_id}",
            "right" => "O_train:{model_id,purpose}",
            "rule" => "provider_inference_does_not_imply_training"
          },
          {
            "left" => "O_acquire",
            "right" => "O_display",
            "rule" => "acquisition_does_not_imply_display"
          },
          {
            "left" => "O_extract",
            "right" => "O_prevalence",
            "rule" => "extraction_does_not_imply_prevalence"
          }
        ],
        "governance" => {
          "signatureRequiredBeforeActivation" => true,
          "defaultDecision" => "deny",
          "reason" => "deterministic matrix output is not a governance signature"
        }
      }
      validate!(matrix.fetch("purposes"))
      matrix
    end

    def expand(purpose, provider_id: nil, model_id: nil, training_purpose: nil)
      expanded = purpose.dup
      expanded = expanded.sub("{provider_id}", provider_id.to_s) if provider_id
      if model_id && training_purpose
        expanded = expanded.sub("{model_id,purpose}", "#{model_id},#{training_purpose}")
      end
      raise Error, "dynamic purpose is not fully specified: #{purpose}" if expanded.include?("{")

      expanded
    end

    def authorize(purpose:, context: {})
      definition = PURPOSES.find { |candidate| candidate.fetch("purpose") == purpose || purpose_matches?(candidate.fetch("purpose"), purpose) }
      raise Error, "unknown purpose: #{purpose}" unless definition

      missing = definition.fetch("requiredClaims").reject { |claim| context.fetch(claim, false) == true }
      if context.fetch("authorization_decision", "deny") != "allow" || missing.any?
        {
          "decision" => "deny",
          "purpose" => purpose,
          "reasonCode" => purpose.start_with?("O_train") ? "PURPOSE_TRAIN_DENIED" : "PURPOSE_#{purpose.split(':', 2).first.delete('O_').upcase}_DENIED",
          "missingClaims" => missing
        }
      else
        { "decision" => "allow", "purpose" => purpose, "missingClaims" => [] }
      end
    end

    def validate!(purposes)
      names = purposes.map { |purpose| purpose.fetch("purpose") }
      raise Error, "duplicate purpose" unless names.uniq == names

      purposes.each do |purpose|
        raise Error, "purpose defaults to allow: #{purpose.fetch('purpose')}" unless purpose.fetch("defaultDecision") == "deny"
        claims = purpose.fetch("requiredClaims")
        raise Error, "purpose has no required claims: #{purpose.fetch('purpose')}" if claims.empty?
        if purpose.fetch("purpose").start_with?("O_train") && !claims.include?("training_authorization")
          raise Error, "training purpose lacks explicit training_authorization"
        end
        if purpose.fetch("purpose").start_with?("O_model:{provider_id}") && !claims.include?("provider_identity")
          raise Error, "provider purpose lacks provider_identity"
        end
      end
      true
    end

    def purpose_matches?(pattern, purpose)
      Regexp.new("\\A" + Regexp.escape(pattern).gsub("\\{provider_id\\}", "[^:]+")
        .gsub("\\{model_id,purpose\\}", "[^,]+,[^:]+") + "\\z").match?(purpose)
    end
  end
end
