# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/concept_mapping_provider"
require_relative "../lib/concept_mapping_runner"

class ConceptMappingProviderTest < Minitest::Test
  class FakeStore
    attr_reader :linkages

    def initialize(inputs)
      @inputs = inputs
      @linkages = []
    end

    def translation_mapping_inputs(limit:)
      @inputs.first(limit)
    end

    def save_linkage!(linkage:)
      @linkages << linkage
      linkage.fetch("participation_candidates")
    end
  end

  def input(version_id, language, publisher, artifact_id)
    {
      "artifact_id" => artifact_id, "source_version_id" => version_id, "item_key" => "item-#{version_id}",
      "source_language" => language, "target_language" => "zh-CN", "original_content_hash" => "hash-#{version_id}",
      "content_hash" => "hash-#{version_id}", "provider" => "deepseek", "model" => "deepseek-v4-pro",
      "prompt_version" => "metadata-translation-v1", "translated_title" => "台风", "translated_summary" => "同一概念",
      "publisher_id" => publisher, "publisher_identity_status" => "configured", "query_conditioned" => false,
      "analysis_policy" => "signal_eligible", "title" => "Typhoon", "summary" => "A typhoon", "source_url" => "https://example.test/#{version_id}"
    }
  end

  def test_fixture_provider_requires_explicit_mapping_and_runner_persists_only_cross_language_candidate
    inputs = [input("v-en", "en", "pub-en", "tr-en"), input("v-zh", "zh-CN", "pub-zh", "tr-zh")]
    provider = ConceptMappingProvider::Fixture.new(mappings: {
      "v-en" => { "canonical_concept_key" => "concept:typhoon", "target_canonical_label" => "台风", "relation" => "translation_equivalent" },
      "v-zh" => { "canonical_concept_key" => "concept:typhoon", "target_canonical_label" => "台风", "relation" => "translation_equivalent" }
    })
    store = FakeStore.new(inputs)
    result = ConceptMappingRunner.new(store: store, provider: provider).run(mode: "fixture", persist: true, limit: 2)
    assert_equal "passed", result.fetch("status")
    assert_equal 1, result.fetch("candidate_count")
    linkage = store.linkages.fetch(0)
    assert_equal false, linkage.fetch("participation_candidates").fetch(0).fetch("event_merge_allowed")
    assert_equal %w[tr-en tr-zh], linkage.fetch("mappings").map { |mapping| mapping.fetch("translation_artifact_id") }.sort
    assert linkage.fetch("mappings").all? { |mapping| mapping.fetch("relation") == "translation_equivalent" }
  end

  def test_dry_run_and_paid_production_are_explicitly_non_mutating
    store = FakeStore.new([input("v-en", "en", "pub-en", "tr-en")])
    dry = ConceptMappingRunner.new(store: store).run(mode: "dry_run", limit: 1)
    assert_equal "not_run", dry.fetch("status")
    assert_empty store.linkages
    production = ConceptMappingRunner.new(store: store, provider: ConceptMappingProvider::DeepSeek.new(api_key: "")).run(mode: "production", limit: 1)
    assert_equal "blocked", production.fetch("status")
    assert_equal "paid_calls_disabled", production.fetch("reason")
    assert_empty store.linkages
  end

  def test_related_and_unknown_do_not_form_candidate
    inputs = [input("v-en", "en", "pub-en", "tr-en"), input("v-zh", "zh-CN", "pub-zh", "tr-zh")]
    provider = ConceptMappingProvider::Fixture.new(mappings: {
      "v-en" => { "canonical_concept_key" => "concept:typhoon", "target_canonical_label" => "台风", "relation" => "related_not_equivalent" },
      "v-zh" => { "canonical_concept_key" => "concept:typhoon", "target_canonical_label" => "台风", "relation" => "unknown" }
    })
    result = ConceptMappingRunner.new(store: FakeStore.new(inputs), provider: provider).run(mode: "fixture", limit: 2)
    assert_equal 0, result.fetch("candidate_count")
  end
end
