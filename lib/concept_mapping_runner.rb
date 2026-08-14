# frozen_string_literal: true

require "digest"
require "json"
require_relative "concept_mapping_provider"
require_relative "multilingual_concept_linker"

# Bounded production bridge from successful translation artifacts to 018
# provider-backed concept mappings. Translation text is carried as evidence
# input only; the mapping provider must independently return the relation.
class ConceptMappingRunner
  MODES = %w[dry_run fixture production].freeze

  def initialize(store:, provider: nil, linker: MultilingualConceptLinker.new, target_language: "zh-CN")
    @store = store
    @provider = provider
    @linker = linker
    @target_language = target_language.to_s
    raise ArgumentError, "target language is required" if @target_language.empty?
  end

  def run(limit: 20, mode: "dry_run", persist: false, allow_paid: false)
    mode = mode.to_s
    raise ArgumentError, "unsupported concept mapping mode #{mode}" unless MODES.include?(mode)
    inputs = @store.translation_mapping_inputs(limit: Integer(limit))
    return summary("not_run", inputs.length, 0, 0, 0, mode: mode, persisted: false,
                   reason: "no_eligible_translation_inputs") if inputs.empty?

    if mode == "dry_run"
      return summary("not_run", inputs.length, 0, 0, 0, mode: mode, persisted: false,
                     reason: "dry_run_default_no_provider")
    end
    if mode == "production" && !allow_paid
      return summary("blocked", inputs.length, 0, 0, inputs.length, mode: mode, persisted: false,
                     reason: "paid_calls_disabled")
    end
    if @provider.nil?
      return summary("not_run", inputs.length, 0, 0, inputs.length, mode: mode, persisted: false,
                     reason: "provider_not_configured")
    end
    if mode == "production" && (@provider.is_a?(ConceptMappingProvider::Fixture) || @provider.provider_name.to_s == "fixture")
      return summary("blocked", inputs.length, 0, 0, inputs.length, mode: mode, persisted: false,
                     reason: "fixture_provider_not_allowed")
    end
    unless @provider.respond_to?(:available?) && @provider.available?
      return summary("blocked", inputs.length, 0, 0, inputs.length, mode: mode, persisted: false,
                     reason: "provider_credentials_unavailable")
    end

    source_items = inputs.map { |input| source_item(input) }
    translations = inputs.map { |input| translation_input(input) }
    mappings = []
    failed = 0
    errors = []
    inputs.each do |input|
      begin
        result = @provider.map(
          source_text: [input.fetch("title"), input.fetch("summary")].reject(&:empty?).join(" "),
          translated_text: [input.fetch("translated_title"), input.fetch("translated_summary")].reject(&:empty?).join(" "),
          source_language: input.fetch("source_language"), target_language: input.fetch("target_language"),
          source_version_id: input.fetch("source_version_id"), translation_artifact_id: input.fetch("artifact_id")
        )
        validate_provider_hashes!(input, result)
        mappings << mapping_record(input, result)
      rescue ConceptMappingProvider::Error, MultilingualConceptLinker::Error, KeyError, TypeError => error
        failed += 1
        errors << { "source_version_id" => input.fetch("source_version_id"), "error" => error.message }
      end
    end
    return summary("degraded", inputs.length, mappings.length, 0, inputs.length, mode: mode, persisted: false, errors: errors) if mappings.empty?

    linkage = @linker.link(source_items: source_items, translations: translations, mappings: mappings)
    persisted = false
    stored_candidates = []
    if persist
      stored_candidates = @store.save_linkage!(linkage: linkage)
      persisted = true
    end
    status = failed.zero? ? "passed" : "degraded"
    {
      "status" => status,
      "mode" => mode,
      "persisted" => persisted,
      "examined_count" => inputs.length,
      "mapped_count" => mappings.length,
      "failed_count" => failed,
      "candidate_count" => linkage.fetch("participation_candidates").length,
      "stored_candidate_count" => stored_candidates.length,
      "provider" => @provider.provider_name,
      "model" => @provider.model,
      "target_language" => @target_language,
      "errors" => errors,
      "linkage" => linkage
    }
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  class Error < StandardError; end

  private

  def source_item(input)
    {
      "version_id" => input.fetch("source_version_id"),
      "item_key" => input.fetch("item_key"),
      "content_hash" => input.fetch("content_hash"),
      "language" => input.fetch("source_language"),
      "publisher_id" => input.fetch("publisher_id"),
      "query_conditioned" => input.fetch("query_conditioned"),
      "analysis_policy" => input.fetch("analysis_policy"),
      "title" => input.fetch("title"),
      "summary" => input.fetch("summary"),
      "source_url" => input.fetch("source_url")
    }
  end

  def translation_input(input)
    source_payload = {
      "source_version_id" => input.fetch("source_version_id"),
      "source_content_hash" => input.fetch("content_hash"),
      "source_language" => input.fetch("source_language"),
      "target_language" => input.fetch("target_language"),
      "title" => input.fetch("title"),
      "summary" => input.fetch("summary")
    }
    translated_text = [input.fetch("translated_title"), input.fetch("translated_summary")].reject(&:empty?).join("\n")
    output_payload = { "translated_title" => input.fetch("translated_title"), "translated_summary" => input.fetch("translated_summary") }
    {
      "artifact_id" => input.fetch("artifact_id"),
      "source_version_id" => input.fetch("source_version_id"),
      "item_key" => input.fetch("item_key"),
      "source_content_hash" => input.fetch("content_hash"),
      "source_language" => input.fetch("source_language"),
      "target_language" => input.fetch("target_language"),
      "provider" => input.fetch("provider"),
      "model" => input.fetch("model"),
      "prompt_version" => input.fetch("prompt_version"),
      "input_hash" => Digest::SHA256.hexdigest(JSON.generate(source_payload)),
      "output_hash" => Digest::SHA256.hexdigest(JSON.generate(output_payload)),
      "translated_text" => translated_text
    }
  end

  def mapping_record(input, result)
    value = result.to_h.transform_keys(&:to_s)
    required = %w[provider model prompt_version prompt_hash input_hash output_hash target_language target_canonical_label canonical_concept_key relation]
    missing = required.select { |key| value.fetch(key, "").to_s.strip.empty? }
    raise MultilingualConceptLinker::Error, "concept mapping provider result is missing #{missing.join(', ')}" unless missing.empty?
    raise MultilingualConceptLinker::Error, "concept mapping target language differs from translation input" unless value.fetch("target_language").to_s == input.fetch("target_language").to_s
    mapping_id = Digest::SHA256.hexdigest([
      input.fetch("source_version_id"), input.fetch("artifact_id"), value.fetch("provider"), value.fetch("model"),
      value.fetch("prompt_version"), value.fetch("input_hash"), value.fetch("output_hash")
    ].join("\u0000"))
    {
      "mapping_id" => "cmap-#{mapping_id}",
      "source_version_id" => input.fetch("source_version_id"),
      "source_content_hash" => input.fetch("content_hash"),
      "source_language" => input.fetch("source_language"),
      "target_language" => value.fetch("target_language"),
      "target_canonical_label" => value.fetch("target_canonical_label"),
      "canonical_concept_key" => value.fetch("canonical_concept_key"),
      "relation" => value.fetch("relation"),
      "translation_artifact_id" => input.fetch("artifact_id"),
      "provider" => value.fetch("provider"),
      "model" => value.fetch("model"),
      "prompt_version" => value.fetch("prompt_version"),
      "prompt_hash" => value.fetch("prompt_hash"),
      "input_hash" => value.fetch("input_hash"),
      "output_hash" => value.fetch("output_hash")
    }
  end

  def validate_provider_hashes!(input, result)
    value = result.to_h.transform_keys(&:to_s)
    mapping_input = {
      "source_version_id" => input.fetch("source_version_id"),
      "translation_artifact_id" => input.fetch("artifact_id"),
      "source_language" => input.fetch("source_language"),
      "target_language" => input.fetch("target_language"),
      "source_text" => [input.fetch("title"), input.fetch("summary")].reject(&:empty?).join(" "),
      "translated_text" => [input.fetch("translated_title"), input.fetch("translated_summary")].reject(&:empty?).join(" ")
    }
    expected_input_hash = Digest::SHA256.hexdigest(JSON.generate(mapping_input))
    raise MultilingualConceptLinker::Error, "concept mapping input hash does not match frozen input" unless value.fetch("input_hash").to_s == expected_input_hash
    output = {
      "canonical_label" => value.fetch("target_canonical_label").to_s,
      "canonical_concept_key" => value.fetch("canonical_concept_key").to_s,
      "relation" => value.fetch("relation").to_s
    }
    expected_output_hash = Digest::SHA256.hexdigest(JSON.generate(output))
    raise MultilingualConceptLinker::Error, "concept mapping output hash does not match frozen output" unless value.fetch("output_hash").to_s == expected_output_hash
    expected_prompt_hash = Digest::SHA256.hexdigest(value.fetch("prompt_version").to_s)
    raise MultilingualConceptLinker::Error, "concept mapping prompt hash does not match frozen prompt" unless value.fetch("prompt_hash").to_s == expected_prompt_hash
  end

  def summary(status, examined, mapped, failed, blocked, mode:, persisted:, reason: nil, errors: [])
    {
      "status" => status, "mode" => mode, "persisted" => persisted,
      "examined_count" => examined, "mapped_count" => mapped, "failed_count" => failed,
      "blocked_count" => blocked, "candidate_count" => 0,
      "provider" => @provider&.provider_name, "model" => @provider&.model,
      "target_language" => @target_language, "errors" => errors
    }.tap { |value| value["reason"] = reason if reason }
  end
end
