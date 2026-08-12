# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/translation_provider"
require_relative "../lib/translation_runner"

class TranslationProviderTest < Minitest::Test
  class FakeStore
    attr_reader :artifacts

    def initialize(items)
      @items = items
      @artifacts = []
    end

    def translation_candidates(limit:)
      @items.first(limit)
    end

    def save_translation_artifact!(artifact:)
      @artifacts << artifact
    end
  end

  class FakeProvider
    attr_reader :model

    def initialize
      @model = "fixture-model"
    end

    def available?
      true
    end

    def provider_name
      "fixture-provider"
    end

    def translate(**_arguments)
      { "translated_title" => "卫星发射成功", "translated_summary" => "任务在 2026 年完成。", "provider" => provider_name, "model" => model }
    end
  end

  def item
    { "item_key" => "item-1", "language" => "en", "title" => "Satellite launch succeeds", "summary" => "Mission completed in 2026.", "content_hash" => "hash-1" }
  end

  def test_missing_credentials_are_explicitly_blocked
    provider = TranslationProvider::OpenAICompatible.new(api_key: "")
    refute provider.available?
    error = assert_raises(TranslationProvider::MissingCredentials) do
      provider.translate(title: "A", summary: "B", source_language: "en")
    end
    assert_equal "missing_credentials", error.code
  end

  def test_runner_keeps_original_input_and_writes_a_mechanically_valid_artifact
    store = FakeStore.new([item])
    result = TranslationRunner.new(store: store, provider: FakeProvider.new).run(limit: 1)
    assert_equal "passed", result.fetch("status")
    artifact = store.artifacts.fetch(0)
    assert_equal "item-1", artifact.fetch("item_key")
    assert_equal "mechanical_pass", artifact.fetch("validation_status")
    assert_equal "Satellite launch succeeds", item.fetch("title")
  end

  def test_runner_does_not_claim_translation_without_credentials
    store = FakeStore.new([item])
    result = TranslationRunner.new(store: store, provider: TranslationProvider::OpenAICompatible.new(api_key: "")).run(limit: 1)
    assert_equal "external_blocked", result.fetch("status")
    assert_equal 1, result.fetch("blocked_count")
    assert_empty store.artifacts
  end
end
