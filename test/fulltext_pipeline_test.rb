# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/article_archive"
require_relative "../lib/fulltext_pipeline"

class FulltextPipelineTest < Minitest::Test
  class FakeResponse
    attr_reader :body, :code
    def initialize(body, code: "200", content_type: "text/html"); @body, @code, @content_type = body, code, content_type; end
    def [](key); key.downcase == "content-type" ? @content_type : nil; end
  end

  class TestFetcher < ArticleArchive::Fetcher
    def extract_for_test(raw, content_type: "text/html"); send(:extract, raw, content_type: content_type); end
  end

  class FakeStore
    attr_reader :saved, :failed, :finished
    def initialize(items: [], translations: []); @items, @translations = items, translations; @saved=[]; @failed=[]; @finished=[]; end
    def article_archive_candidates(limit:); @items.first(limit); end
    def save_article_archive_result!(attempt:, archive:); @saved << [attempt, archive]; end
    def ensure_article_translation_runs!(**); 0; end
    def article_translation_candidates(limit:, daily_character_limit:); @translations.first(limit); end
    def start_article_translation!(run_id:); true; end
    def fail_article_translation!(**args); @failed << args; end
    def block_article_translation_for_credentials!(**args); @failed << args.merge(state: "credential_blocked"); end
    def finish_article_translation!(**args); @finished << args; end
  end

  class MissingProvider
    def available?; false; end
    def provider_name; "deepseek"; end
    def model; "deepseek-v4-pro"; end
  end

  def item(rights)
    { "version_id" => "v1", "language" => "en", "title" => "Title", "summary" => "Summary",
      "source_url" => "https://example.test/a", "archive_rights_scope" => rights }
  end

  def test_excerpt_only_never_touches_network_and_is_recorded
    result = ArticleArchive::Fetcher.new.fetch(item("excerpt_only"))
    assert_equal "not_permitted", result.dig("attempt", "outcome")
    assert_nil result["archive"]
  end

  def test_semantic_extractor_preserves_paragraphs_and_captions
    html = "<html><article><h1>Long article heading here</h1><p>#{'Substantive paragraph ' * 12}</p><figcaption>Photo caption text</figcaption></article></html>"
    result = TestFetcher.new.extract_for_test(html)
    assert_includes result.fetch("body_text"), "Substantive paragraph"
    assert_equal ["Photo caption text"], result.fetch("image_captions")
  end

  def test_missing_credentials_marks_existing_queue_rows_blocked
    translation = { "run_id" => "r1", "input_chars" => 500 }
    store = FakeStore.new(translations: [translation])
    result = FulltextPipeline.new(store: store, translation_provider: MissingProvider.new).translate(limit: 2, daily_character_limit: 1000)
    assert_equal "external_blocked", result.fetch("status")
    assert_equal "credential_blocked", store.failed.fetch(0).fetch(:state)
  end
end
