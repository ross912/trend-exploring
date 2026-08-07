# frozen_string_literal: true

require "json"

module M1
  module DataBoundary
    class Error < StandardError; end

    PRIVATE_DATA_CLASSES = %w[
      private_query_context conversation_turn memory_candidate user_memory
      correction_proposal user_principal_id personal_embedding private_attachment
    ].freeze

    GLOBAL_SERVICES = %w[global-radar-worker global-correction-reviewer global-training-runner].freeze

    module_function

    def load(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Error, "#{path}: invalid JSON: #{e.message}"
    end

    def validate!(spec)
      domains = spec.fetch("domains")
      global = domains.fetch("global")
      personal = domains.fetch("personal")
      paths = spec.fetch("paths")

      missing_global_services = GLOBAL_SERVICES - global.fetch("servicePrincipals")
      raise Error, "global domain is missing service principals: #{missing_global_services.join(',')}" unless missing_global_services.empty?

      missing_forbidden = PRIVATE_DATA_CLASSES - global.fetch("forbiddenInputs")
      raise Error, "global domain is missing forbidden inputs: #{missing_forbidden.join(',')}" unless missing_forbidden.empty?

      missing_private = PRIVATE_DATA_CLASSES - personal.fetch("privateDataClasses")
      raise Error, "personal domain is missing private data classes: #{missing_private.join(',')}" unless missing_private.empty?

      paths.each do |path|
        next unless path.fetch("allowed") && path.fetch("toDomain") == "global"

        data_classes = path.fetch("dataClasses")
        leaked = data_classes & PRIVATE_DATA_CLASSES
        if leaked.any? && path.fetch("persistence") != "ephemeral_neutralized"
          raise Error, "global path #{path.fetch('name')} persists private data: #{leaked.join(',')}"
        end
        if path.fetch("persistence") == "ephemeral_neutralized" && data_classes != ["neutral_query"]
          raise Error, "global neutralization path may carry only neutral_query"
        end
      end

      personal_to_global_long_term = paths.select do |path|
        path.fetch("allowed") && path.fetch("fromDomain") == "personal" &&
          path.fetch("toDomain") == "global" &&
          path.fetch("persistence") == "long_term"
      end
      unless personal_to_global_long_term.empty?
        names = personal_to_global_long_term.map { |path| path.fetch("name") }
        raise Error, "personal-to-global long-term paths are forbidden: #{names.join(',')}"
      end

      true
    rescue KeyError, TypeError => e
      raise Error, "data boundary contract is incomplete: #{e.message}"
    end
  end
end
