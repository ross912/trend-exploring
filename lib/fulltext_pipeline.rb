# frozen_string_literal: true

require_relative "article_archive"
require_relative "translation_provider"

class FulltextPipeline
  PROMPT_VERSION = "full-article-translation-v1"

  def initialize(store:, archive_fetcher: ArticleArchive::Fetcher.new,
                 translation_provider: TranslationProvider::DeepSeek.new)
    @store, @archive_fetcher, @translation_provider = store, archive_fetcher, translation_provider
  end

  def archive(limit: 20)
    counts = Hash.new(0)
    @store.article_archive_candidates(limit: limit).each do |item|
      result = @archive_fetcher.fetch(item)
      @store.save_article_archive_result!(attempt: result.fetch("attempt"), archive: result["archive"])
      counts[result.fetch("attempt").fetch("outcome")] += 1
    end
    { "status" => "passed", "examined_count" => counts.values.sum, "outcomes" => counts.sort.to_h }
  end

  def translate(limit: 5, daily_character_limit: 200_000)
    @store.ensure_article_translation_runs!(provider: "deepseek", model: "deepseek-v4-pro", prompt_version: PROMPT_VERSION)
    candidates = @store.article_translation_candidates(limit: limit, daily_character_limit: daily_character_limit)
    unless @translation_provider.available?
      candidates.each do |item|
        @store.block_article_translation_for_credentials!(run_id: item.fetch("run_id"), reason: "DeepSeek API credentials are not configured")
      end
      return { "status" => "external_blocked", "translated_count" => 0, "blocked_count" => candidates.length }
    end
    translated = failed = 0
    candidates.each do |item|
      @store.start_article_translation!(run_id: item.fetch("run_id"))
      begin
        result = @translation_provider.translate(
          title: item.fetch("title"), summary: item.fetch("summary"), body: item.fetch("body_text"),
          image_captions: item.fetch("image_captions"), source_language: item.fetch("source_language")
        )
        validation = mechanically_valid?(item, result) ? "mechanical_pass" : "needs_review"
        @store.finish_article_translation!(run_id: item.fetch("run_id"), result: result, validation_status: validation)
        translated += 1
      rescue TranslationProvider::MissingCredentials => error
        @store.fail_article_translation!(run_id: item.fetch("run_id"), state: "credential_blocked", reason: error.message)
      rescue TranslationProvider::Error, LocalRadarStore::Error => error
        @store.fail_article_translation!(run_id: item.fetch("run_id"), state: "failed", reason: error.message)
        failed += 1
      end
    end
    { "status" => failed.zero? ? "passed" : "degraded", "translated_count" => translated,
      "failed_count" => failed, "examined_count" => candidates.length,
      "provider" => @translation_provider.provider_name, "model" => @translation_provider.model }
  end

  private

  def mechanically_valid?(item, result)
    source = [item.fetch("title"), item.fetch("summary"), item.fetch("body_text")].join(" ")
    translated = [result.fetch("translated_title"), result.fetch("translated_summary"), result.fetch("translated_body")].join(" ")
    numbers = source.scan(/\d+(?:[.,]\d+)?/).uniq.first(200)
    numbers.all? { |number| translated.include?(number) } &&
      result.fetch("translated_image_captions").length == item.fetch("image_captions").length
  end
end
