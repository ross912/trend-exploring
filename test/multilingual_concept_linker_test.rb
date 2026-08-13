# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/multilingual_concept_linker"

class MultilingualConceptLinkerTest < Minitest::Test
  def setup
    @linker = MultilingualConceptLinker.new
  end

  def test_requires_two_languages_and_two_publishers_and_keeps_qualification_lanes
    result = @linker.link(
      source_items: [
        source("v-en", "en", "pub-en", analysis_policy: "signal_eligible"),
        source("v-zh", "zh-CN", "pub-zh", query_conditioned: true, analysis_policy: "signal_eligible"),
        source("v-es", "es", "pub-es", analysis_policy: "exploration_only")
      ],
      mappings: [mapping("m-en", "v-en", "en", "pub-en"), mapping("m-zh", "v-zh", "zh-CN", "pub-zh"), mapping("m-es", "v-es", "es", "pub-es")]
    )
    candidate = result.fetch("participation_candidates").fetch(0)
    assert_equal ["en", "es", "zh-CN"], candidate.fetch("languages")
    assert_equal ["pub-en", "pub-es", "pub-zh"], candidate.fetch("publishers")
    assert_equal ["v-zh"], candidate.fetch("query_conditioned_version_ids")
    assert_equal ["v-es"], candidate.fetch("exploration_only_version_ids")
    assert_equal ["v-en", "v-zh"], candidate.fetch("signal_eligible_version_ids")
    assert_equal false, candidate.fetch("event_merge_allowed")
    assert_equal false, candidate.fetch("claim_merge_allowed")
    assert_equal "participation_only", candidate.fetch("merge_policy")
  end

  def test_translation_and_mapping_are_derived_but_original_version_hash_is_checked
    translation = {
      "artifact_id" => "tr-en",
      "source_version_id" => "v-en",
      "source_content_hash" => "hash-v-en",
      "source_language" => "en",
      "target_language" => "zh-CN",
      "provider" => "fixture",
      "model" => "concept-v1",
      "prompt_version" => "prompt-v1",
      "input_hash" => "input-hash",
      "output_hash" => "output-hash",
      "translated_text" => "原文派生译文"
    }
    result = @linker.link(
      source_items: [source("v-en", "en", "pub-en")],
      translations: [translation],
      mappings: [mapping("m-en", "v-en", "en", "pub-en", translation_artifact_id: "tr-en")]
    )
    assert_equal true, result.fetch("translation_inputs").fetch(0).fetch("derived_from_original")
    assert_equal "tr-en", result.fetch("mappings").fetch(0).fetch("translation_artifact_id")
    assert_raises(MultilingualConceptLinker::Error) do
      @linker.link(source_items: [source("v-en", "en", "pub-en")], mappings: [mapping("bad", "v-en", "en", "pub-en").merge("source_content_hash" => "rewritten")])
    end
  end

  def test_unknown_and_related_not_equivalent_never_form_candidate
    mappings = [
      mapping("m-en", "v-en", "en", "pub-en", relation: "unknown"),
      mapping("m-zh", "v-zh", "zh-CN", "pub-zh", relation: "related_not_equivalent")
    ]
    assert_empty @linker.link(source_items: [source("v-en", "en", "pub-en"), source("v-zh", "zh-CN", "pub-zh")], mappings: mappings).fetch("participation_candidates")
  end

  def test_one_language_or_one_publisher_is_not_cross_language_participation
    same_publisher = [
      mapping("m-en", "v-en", "en", "shared-pub"),
      mapping("m-zh", "v-zh", "zh-CN", "shared-pub")
    ]
    assert_empty @linker.link(source_items: [source("v-en", "en", "shared-pub"), source("v-zh", "zh-CN", "shared-pub")], mappings: same_publisher).fetch("participation_candidates")
    one_language = [
      mapping("m-en-1", "v-en", "en", "pub-en"),
      mapping("m-en-2", "v-en-2", "en", "pub-en-2")
    ]
    assert_empty @linker.link(source_items: [source("v-en", "en", "pub-en"), source("v-en-2", "en", "pub-en-2")], mappings: one_language).fetch("participation_candidates")
  end

  private

  def source(version_id, language, publisher_id, query_conditioned: false, analysis_policy: "signal_eligible")
    {
      "version_id" => version_id,
      "item_key" => "item-#{version_id}",
      "content_hash" => "hash-#{version_id}",
      "language" => language,
      "publisher_id" => publisher_id,
      "query_conditioned" => query_conditioned,
      "analysis_policy" => analysis_policy,
      "title" => "Source #{version_id}",
      "summary" => "Fixture"
    }
  end

  def mapping(mapping_id, version_id, language, _publisher_id, relation: "translation_equivalent", translation_artifact_id: nil)
    {
      "mapping_id" => mapping_id,
      "source_version_id" => version_id,
      "source_content_hash" => "hash-#{version_id}",
      "source_language" => language,
      "target_language" => "zh-CN",
      "target_canonical_label" => "台风",
      "relation" => relation,
      "translation_artifact_id" => translation_artifact_id,
      "provider" => "fixture",
      "model" => "concept-v1",
      "prompt_version" => "prompt-v1",
      "input_hash" => "input-#{mapping_id}",
      "output_hash" => "output-#{mapping_id}"
    }
  end
end
