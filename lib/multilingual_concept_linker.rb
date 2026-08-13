# frozen_string_literal: true

require "digest"
require "json"
require "time"

# Deterministic, provenance-first concept linkage for material published in
# more than one language.
#
# This class intentionally does not identify events or merge claims.  A
# translation (or a model saying that two labels are equivalent) is only
# evidence for a concept participation candidate.  Every source version and
# every qualification lane remains visible in the returned value.
class MultilingualConceptLinker
  class Error < StandardError; end

  RELATIONS = %w[exact_alias translation_equivalent related_not_equivalent unknown].freeze
  ACCEPTED_RELATIONS = %w[exact_alias translation_equivalent].freeze
  ANALYSIS_POLICIES = %w[signal_eligible exploration_only].freeze
  DEFAULT_TARGET_LANGUAGE = "zh-CN"
  LINKER_VERSION = "multilingual_concept_linker_v1"

  attr_reader :default_target_language

  def initialize(default_target_language: DEFAULT_TARGET_LANGUAGE)
    @default_target_language = default_target_language.to_s.strip
    raise Error, "target language is required" if @default_target_language.empty?
  end

  # Link explicit provider mappings to immutable source versions and return
  # participation candidates. The +mappings+ argument is deliberately
  # provider-shaped data; no mapping is inferred from translated text.
  def link(source_items:, mappings:, translations: [])
    sources = normalize_sources(source_items)
    source_by_version = sources.to_h { |source| [source.fetch("version_id"), source] }
    translation_records = normalize_translations(translations, source_by_version)
    translation_by_id = translation_records.to_h { |translation| [translation.fetch("artifact_id"), translation] }
    mapping_records = normalize_mappings(mappings, source_by_version, translation_by_id)
    {
      "linker_version" => LINKER_VERSION,
      "source_versions" => sources,
      "translation_inputs" => translation_records,
      "mappings" => mapping_records,
      "participation_candidates" => participation_candidates(
        sources: sources,
        mappings: mapping_records
      )
    }
  end

  alias link_concepts link
  alias build link

  # Build candidates from already-normalized records. This is public so a
  # store can validate a manifest before persisting it.
  def participation_candidates(sources:, mappings:)
    source_by_version = Array(sources).to_h { |source| [source.fetch("version_id"), source] }
    accepted = Array(mappings).select do |mapping|
      ACCEPTED_RELATIONS.include?(mapping.fetch("relation"))
    end
    groups = accepted.group_by { |mapping| mapping.fetch("canonical_concept_key") }
    groups.keys.sort.each_with_object([]) do |concept_key, output|
      group = groups.fetch(concept_key).sort_by { |mapping| [mapping.fetch("source_version_id"), mapping.fetch("mapping_id")] }
      evidence = group.map do |mapping|
        source = source_by_version.fetch(mapping.fetch("source_version_id"))
        {
          "mapping_id" => mapping.fetch("mapping_id"),
          "source_version_id" => source.fetch("version_id"),
          "item_key" => source.fetch("item_key"),
          "source_content_hash" => source.fetch("content_hash"),
          "source_language" => source.fetch("language"),
          "publisher_id" => source.fetch("publisher_id"),
          "query_conditioned" => source.fetch("query_conditioned"),
          "analysis_policy" => source.fetch("analysis_policy"),
          "relation" => mapping.fetch("relation"),
          "target_canonical_label" => mapping.fetch("target_canonical_label"),
          "translation_artifact_id" => mapping.fetch("translation_artifact_id"),
          "provider" => mapping.fetch("provider"),
          "model" => mapping.fetch("model"),
          "prompt_version" => mapping.fetch("prompt_version"),
          "input_hash" => mapping.fetch("input_hash"),
          "output_hash" => mapping.fetch("output_hash")
        }
      end
      languages = evidence.map { |entry| entry.fetch("source_language") }.uniq.sort
      publishers = evidence.map { |entry| entry.fetch("publisher_id") }.uniq.sort
      # A candidate is intentionally stricter than a within-language topic:
      # at least two languages and two independently identified publishers.
      next if languages.length < 2 || publishers.length < 2

      query_evidence = evidence.select { |entry| entry.fetch("query_conditioned") }
      exploration_evidence = evidence.select { |entry| entry.fetch("analysis_policy") == "exploration_only" }
      signal_evidence = evidence.select { |entry| entry.fetch("analysis_policy") == "signal_eligible" }
      label = group.map { |mapping| mapping.fetch("target_canonical_label") }.uniq.sort.first
      version_ids = evidence.map { |entry| entry.fetch("source_version_id") }.uniq.sort
      candidate_id = stable_id("participation", concept_key, version_ids)
      output << {
        "candidate_id" => candidate_id,
        "candidate_status" => "cross_language_participation",
        "candidate_kind" => "concept_participation",
        "canonical_concept_key" => concept_key,
        "target_canonical_label" => label,
        "target_language" => group.map { |mapping| mapping.fetch("target_language") }.uniq.sort.first,
        "relation_set" => group.map { |mapping| mapping.fetch("relation") }.uniq.sort,
        "member_mapping_ids" => evidence.map { |entry| entry.fetch("mapping_id") },
        "member_version_ids" => version_ids,
        "languages" => languages,
        "publishers" => publishers,
        "source_language_count" => languages.length,
        "publisher_count" => publishers.length,
        "member_count" => evidence.length,
        "query_conditioned_version_ids" => query_evidence.map { |entry| entry.fetch("source_version_id") }.sort,
        "exploration_only_version_ids" => exploration_evidence.map { |entry| entry.fetch("source_version_id") }.sort,
        "signal_eligible_version_ids" => signal_evidence.map { |entry| entry.fetch("source_version_id") }.sort,
        "query_conditioned_count" => query_evidence.length,
        "exploration_only_count" => exploration_evidence.length,
        "signal_eligible_count" => signal_evidence.length,
        "evidence" => evidence,
        # Concept participation is not an event/claim identity.
        "merge_policy" => "participation_only",
        "event_merge_allowed" => false,
        "claim_merge_allowed" => false
      }
    end
  end

  # A deterministic fixture provider. It requires a caller-supplied canonical
  # label and relation, making it impossible for translated text alone to
  # silently become an event or claim merge.
  class FixtureProvider
    attr_reader :provider_name, :model, :prompt_version

    def initialize(provider: "fixture", model: "fixture-concept-v1", prompt_version: "concept-map-v1")
      @provider_name = provider.to_s
      @model = model.to_s
      @prompt_version = prompt_version.to_s
      raise ArgumentError, "provider/model/prompt_version are required" if [@provider_name, @model, @prompt_version].any?(&:empty?)
    end

    def map(source_text:, source_language:, target_language: MultilingualConceptLinker::DEFAULT_TARGET_LANGUAGE,
            canonical_label:, relation:, translation_artifact_id: nil)
      input = {
        "source_text" => source_text.to_s,
        "source_language" => source_language.to_s,
        "target_language" => target_language.to_s,
        "canonical_label" => canonical_label.to_s,
        "relation" => relation.to_s,
        "translation_artifact_id" => translation_artifact_id
      }
      output = { "canonical_label" => canonical_label.to_s, "relation" => relation.to_s }
      {
        "provider" => provider_name,
        "model" => model,
        "prompt_version" => prompt_version,
        "input_hash" => Digest::SHA256.hexdigest(JSON.generate(input)),
        "output_hash" => Digest::SHA256.hexdigest(JSON.generate(output)),
        "target_language" => target_language.to_s,
        "target_canonical_label" => canonical_label.to_s,
        "relation" => relation.to_s,
        "translation_artifact_id" => translation_artifact_id
      }
    end
  end

  private

  def normalize_sources(items)
    seen = {}
    Array(items).map do |raw|
      value = stringify(raw)
      required = %w[version_id item_key content_hash language publisher_id]
      missing = required.select { |key| value.fetch(key, "").to_s.strip.empty? }
      raise Error, "source version is missing #{missing.join(', ')}" unless missing.empty?
      version_id = value.fetch("version_id").to_s
      raise Error, "duplicate source version_id #{version_id}" if seen.key?(version_id)

      policy = value.fetch("analysis_policy", "signal_eligible").to_s
      raise Error, "invalid analysis_policy #{policy}" unless ANALYSIS_POLICIES.include?(policy)
      source = {
        "version_id" => version_id,
        "item_key" => value.fetch("item_key").to_s,
        "content_hash" => value.fetch("content_hash").to_s,
        "language" => value.fetch("language").to_s.strip,
        "publisher_id" => value.fetch("publisher_id").to_s.strip,
        "query_conditioned" => truthy?(value.fetch("query_conditioned", false)),
        "analysis_policy" => policy,
        "title" => value.fetch("title", "").to_s,
        "summary" => value.fetch("summary", "").to_s,
        "source_url" => value.fetch("source_url", "").to_s,
        "claim_key" => value.fetch("claim_key", "").to_s,
        "event_key" => value.fetch("event_key", "").to_s
      }
      seen[version_id] = true
      source
    end.sort_by { |source| source.fetch("version_id") }
  end

  def normalize_translations(inputs, source_by_version)
    seen = {}
    Array(inputs).map do |raw|
      value = stringify(raw)
      required = %w[artifact_id source_version_id source_content_hash source_language target_language provider model prompt_version input_hash output_hash]
      missing = required.select { |key| value.fetch(key, "").to_s.strip.empty? }
      raise Error, "translation input is missing #{missing.join(', ')}" unless missing.empty?
      artifact_id = value.fetch("artifact_id").to_s
      raise Error, "duplicate translation artifact_id #{artifact_id}" if seen.key?(artifact_id)
      source = source_by_version.fetch(value.fetch("source_version_id").to_s) { raise Error, "translation source version is unknown" }
      raise Error, "translation source content hash does not match immutable version" unless value.fetch("source_content_hash").to_s == source.fetch("content_hash")
      raise Error, "translation source language does not match immutable version" unless value.fetch("source_language").to_s == source.fetch("language")
      record = {
        "artifact_id" => artifact_id,
        "source_version_id" => source.fetch("version_id"),
        "item_key" => source.fetch("item_key"),
        "source_content_hash" => source.fetch("content_hash"),
        "source_language" => source.fetch("language"),
        "target_language" => value.fetch("target_language").to_s,
        "provider" => value.fetch("provider").to_s,
        "model" => value.fetch("model").to_s,
        "prompt_version" => value.fetch("prompt_version").to_s,
        "input_hash" => value.fetch("input_hash").to_s,
        "output_hash" => value.fetch("output_hash").to_s,
        "translated_text" => value.fetch("translated_text", value.fetch("translated_body", value.fetch("translated_summary", ""))).to_s,
        "derived_from_original" => true
      }
      seen[artifact_id] = true
      record
    end.sort_by { |translation| translation.fetch("artifact_id") }
  end

  def normalize_mappings(mappings, source_by_version, translation_by_id)
    seen = {}
    Array(mappings).map do |raw|
      value = stringify(raw)
      required = %w[mapping_id source_version_id source_content_hash source_language target_language target_canonical_label relation provider model prompt_version input_hash output_hash]
      missing = required.select { |key| value.fetch(key, "").to_s.strip.empty? }
      raise Error, "concept mapping is missing #{missing.join(', ')}" unless missing.empty?
      mapping_id = value.fetch("mapping_id").to_s
      raise Error, "duplicate mapping_id #{mapping_id}" if seen.key?(mapping_id)
      relation = value.fetch("relation").to_s
      raise Error, "invalid concept relation #{relation}" unless RELATIONS.include?(relation)
      source = source_by_version.fetch(value.fetch("source_version_id").to_s) { raise Error, "mapping source version is unknown" }
      raise Error, "mapping source content hash does not match immutable version" unless value.fetch("source_content_hash").to_s == source.fetch("content_hash")
      raise Error, "mapping source language does not match immutable version" unless value.fetch("source_language").to_s == source.fetch("language")
      artifact_id = value.fetch("translation_artifact_id", "").to_s
      unless artifact_id.empty?
        translation = translation_by_id.fetch(artifact_id) { raise Error, "mapping translation artifact is unknown" }
        unless translation.fetch("source_version_id") == source.fetch("version_id") && translation.fetch("source_content_hash") == source.fetch("content_hash")
          raise Error, "translation artifact lineage does not match mapping source version"
        end
      end
      label = value.fetch("target_canonical_label").to_s.strip
      target_language = value.fetch("target_language").to_s.strip
      canonical_key = value.fetch("canonical_concept_key", "").to_s.strip
      canonical_key = stable_id("concept", target_language, normalize_label(label)) if canonical_key.empty?
      record = {
        "mapping_id" => mapping_id,
        "source_version_id" => source.fetch("version_id"),
        "item_key" => source.fetch("item_key"),
        "source_content_hash" => source.fetch("content_hash"),
        "source_language" => source.fetch("language"),
        "target_language" => target_language,
        "target_canonical_label" => label,
        "canonical_concept_key" => canonical_key,
        "relation" => relation,
        "translation_artifact_id" => artifact_id.empty? ? nil : artifact_id,
        "provider" => value.fetch("provider").to_s,
        "model" => value.fetch("model").to_s,
        "prompt_version" => value.fetch("prompt_version").to_s,
        "prompt_hash" => value.fetch("prompt_hash", Digest::SHA256.hexdigest(value.fetch("prompt_version").to_s)).to_s,
        "input_hash" => value.fetch("input_hash").to_s,
        "output_hash" => value.fetch("output_hash").to_s,
        "derived_from_translation" => !artifact_id.empty?,
        "claim_key" => source.fetch("claim_key"),
        "event_key" => source.fetch("event_key")
      }
      seen[mapping_id] = true
      record
    end.sort_by { |mapping| mapping.fetch("mapping_id") }
  end

  def stringify(value)
    raise Error, "record must be an object" unless value.respond_to?(:to_h)
    value.to_h.transform_keys(&:to_s)
  end

  def normalize_label(label)
    label.to_s.strip.downcase.gsub(/\s+/, " ")
  end

  def stable_id(*parts)
    "mc-#{Digest::SHA256.hexdigest(parts.flatten.map(&:to_s).join("\u0000"))}"
  end

  def truthy?(value)
    %w[t true 1 yes y].include?(value.to_s.downcase)
  end
end
