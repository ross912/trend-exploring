# frozen_string_literal: true

require "digest"
require "json"
require_relative "deepseek_client"

# Provider boundary for multilingual concept mapping.
#
# Translation is deliberately an input to this provider, never a decision. A
# provider must return an explicit relation and canonical label; the runner
# records the provider/model/prompt/input/output hashes as immutable mapping
# evidence. No provider is invoked by the default CLI mode.
module ConceptMappingProvider
  RELATIONS = %w[exact_alias translation_equivalent related_not_equivalent unknown].freeze
  ACCEPTED_RELATIONS = %w[exact_alias translation_equivalent].freeze
  PROMPT_VERSION = "concept-mapping-v1"

  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "concept_mapping_error")
      @code = code
      super(message)
    end
  end

  class MissingCredentials < Error
    def initialize
      super("concept mapping API credentials are not configured", code: "missing_credentials")
    end
  end

  # DeepSeek is an optional production provider. It is never selected by the
  # CLI unless the caller explicitly chooses production mode and enables paid
  # calls. The prompt treats the translation as auxiliary evidence and forbids
  # event/claim identity decisions.
  class DeepSeek
    attr_reader :client, :prompt_version

    def initialize(client: nil, api_key: nil,
                   endpoint: ENV.fetch("DEEPSEEK_BASE_URL", DeepSeekClient::DEFAULT_BASE_URL),
                   model: ENV.fetch("DEEPSEEK_MODEL", DeepSeekClient::DEFAULT_MODEL),
                   prompt_version: PROMPT_VERSION)
      @client = client || DeepSeekClient.new(api_key: api_key, base_url: endpoint, model: model)
      @prompt_version = prompt_version.to_s
      raise Error.new("concept mapping prompt version is required", code: "invalid_configuration") if @prompt_version.empty?
    end

    def available?
      client.available?
    end

    def provider_name
      client.provider_name
    end

    def model
      client.model
    end

    def map(source_text:, translated_text:, source_language:, target_language:, source_version_id:,
            translation_artifact_id:)
      raise MissingCredentials unless available?

      input = {
        "source_version_id" => source_version_id.to_s,
        "translation_artifact_id" => translation_artifact_id.to_s,
        "source_language" => source_language.to_s,
        "target_language" => target_language.to_s,
        "source_text" => source_text.to_s,
        "translated_text" => translated_text.to_s
      }
      response = client.chat_json(
        thinking: false,
        max_tokens: Integer(ENV.fetch("DEEPSEEK_CONCEPT_MAPPING_MAX_OUTPUT_TOKENS", "2048")),
        system: <<~PROMPT.strip,
          你是严格的多语言概念映射审阅器。原文与译文只是同一来源版本的输入，
          译文不能单独证明事件、主张、时间、因果或实体身份。只返回 JSON 对象，
          且只能包含 canonical_label、canonical_concept_key、relation。
          relation 必须是 exact_alias、translation_equivalent、related_not_equivalent、unknown 之一。
          只有在两个语言表达明确指向同一稳定概念时才使用前两个关系；不确定时使用 unknown。
          related_not_equivalent 表示相关但不等价。不要把事件或主张合并。
        PROMPT
        user: JSON.generate(input)
      )
      result = response.fetch("content")
      validate_result(result)
      output = {
        "canonical_label" => result.fetch("canonical_label").to_s.strip,
        "canonical_concept_key" => canonical_key(result, target_language: target_language),
        "relation" => result.fetch("relation").to_s
      }
      {
        "provider" => provider_name,
        "model" => response.fetch("model").to_s.empty? ? model : response.fetch("model").to_s,
        "prompt_version" => prompt_version,
        "prompt_hash" => Digest::SHA256.hexdigest(prompt_version),
        "input_hash" => Digest::SHA256.hexdigest(JSON.generate(input)),
        "output_hash" => Digest::SHA256.hexdigest(JSON.generate(output)),
        "target_language" => target_language.to_s,
        "target_canonical_label" => output.fetch("canonical_label"),
        "canonical_concept_key" => output.fetch("canonical_concept_key"),
        "relation" => output.fetch("relation"),
        "usage" => response.fetch("usage", {})
      }
    rescue DeepSeekClient::Error => error
      raise MissingCredentials if error.code == "missing_credentials"
      raise Error.new(error.message, code: error.code)
    rescue KeyError, TypeError => error
      raise Error.new("concept mapping provider response is invalid: #{error.message}", code: "invalid_provider_response")
    end

    private

    def validate_result(result)
      raise Error.new("concept mapping response must be an object", code: "invalid_provider_response") unless result.is_a?(Hash)
      keys = result.keys.map(&:to_s).sort
      allowed = %w[canonical_concept_key canonical_label relation]
      raise Error.new("concept mapping provider returned unknown or missing keys", code: "invalid_provider_response") unless keys.all? { |key| allowed.include?(key) } && keys.include?("canonical_label") && keys.include?("relation")
      label = result.fetch("canonical_label").to_s.strip
      relation = result.fetch("relation").to_s
      raise Error.new("concept mapping canonical label is empty", code: "invalid_provider_response") if label.empty?
      raise Error.new("concept mapping relation is invalid", code: "invalid_provider_response") unless RELATIONS.include?(relation)
    end

    def canonical_key(result, target_language:)
      value = result.fetch("canonical_concept_key", "").to_s.strip
      return value unless value.empty?

      "concept:#{target_language}:#{normalize_label(result.fetch('canonical_label'))}"
    end

    def normalize_label(value)
      value.to_s.strip.downcase.gsub(/\s+/, " ")
    end
  end

  # Deterministic test-only provider. It requires an explicit caller-supplied
  # result and never infers a relation from translated text. The runner rejects
  # this provider in production mode, so fixture evidence cannot masquerade as
  # a real provider result.
  class Fixture
    attr_reader :provider_name, :model, :prompt_version

    def initialize(mappings: nil, mapping: nil, provider: "fixture", model: "fixture-concept-v1",
                   prompt_version: "concept-map-fixture-v1")
      @mappings = (mappings || mapping || {}).to_h.transform_keys(&:to_s)
      @provider_name = provider.to_s
      @model = model.to_s
      @prompt_version = prompt_version.to_s
      if [@provider_name, @model, @prompt_version].any?(&:empty?)
        raise ArgumentError, "provider/model/prompt_version are required"
      end
    end

    def available?
      true
    end

    def map(source_text:, translated_text:, source_language:, target_language:, source_version_id:,
            translation_artifact_id:)
      raw = @mappings.fetch(source_version_id.to_s) do
        @mappings.fetch(translation_artifact_id.to_s) do
          raise Error.new("fixture mapping is missing for source version", code: "fixture_mapping_missing")
        end
      end
      value = raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
      relation = value.fetch("relation", "").to_s
      label = value.fetch("target_canonical_label", value.fetch("canonical_label", "")).to_s.strip
      raise Error.new("fixture mapping must provide canonical label and relation", code: "invalid_fixture_mapping") if label.empty? || relation.empty?
      raise Error.new("fixture mapping relation is invalid", code: "invalid_fixture_mapping") unless RELATIONS.include?(relation)
      canonical_key = value.fetch("canonical_concept_key", "").to_s.strip
      canonical_key = "concept:#{target_language}:#{label.downcase.gsub(/\s+/, ' ')}" if canonical_key.empty?
      input = {
        "source_version_id" => source_version_id.to_s,
        "translation_artifact_id" => translation_artifact_id.to_s,
        "source_language" => source_language.to_s,
        "target_language" => target_language.to_s,
        "source_text" => source_text.to_s,
        "translated_text" => translated_text.to_s
      }
      output = { "canonical_label" => label, "canonical_concept_key" => canonical_key, "relation" => relation }
      {
        "provider" => provider_name,
        "model" => model,
        "prompt_version" => prompt_version,
        "prompt_hash" => Digest::SHA256.hexdigest(prompt_version),
        "input_hash" => Digest::SHA256.hexdigest(JSON.generate(input)),
        "output_hash" => Digest::SHA256.hexdigest(JSON.generate(output)),
        "target_language" => target_language.to_s,
        "target_canonical_label" => label,
        "canonical_concept_key" => canonical_key,
        "relation" => relation,
        "usage" => { "prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0 }
      }
    end
  end
end
