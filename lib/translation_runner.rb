# frozen_string_literal: true

require "digest"
require_relative "translation_provider"

class TranslationRunner
  def initialize(store:, provider:, target_language: "zh-CN")
    @store = store
    @provider = provider
    @target_language = target_language
  end

  def run(limit: 20, daily_character_limit: 200_000)
    queued = @store.respond_to?(:ensure_metadata_translation_runs!)
    @store.ensure_metadata_translation_runs! if queued
    candidates = queued ? @store.metadata_translation_candidates(limit: limit, daily_character_limit: daily_character_limit) : @store.translation_candidates(limit: limit)
    return summary("not_needed", candidates.length, 0, 0, 0) if candidates.empty?
    unless @provider.available?
      candidates.each { |item| @store.block_metadata_translation_for_credentials!(run_id: item.fetch("translation_run_id"), reason: "DeepSeek API credentials are not configured") } if queued
      return summary("external_blocked", 0, 0, candidates.length, candidates.length)
    end

    translated = 0
    failed = 0
    candidates.each do |item|
      begin
        @store.start_metadata_translation!(run_id: item.fetch("translation_run_id")) if queued
        result = @provider.translate(title: item.fetch("title"), summary: item.fetch("summary"), body: "", image_captions: [], source_language: item.fetch("language"), target_language: @target_language)
        artifact = {
          "artifact_id" => artifact_id(item, result),
          "source_version_id" => item.fetch("version_id"), "item_key" => item.fetch("item_key"),
          "source_language" => item.fetch("language"),
          "target_language" => @target_language,
          "original_content_hash" => item.fetch("content_hash"),
          "provider" => result.fetch("provider"),
          "model" => result.fetch("model"),
          "translated_title" => result.fetch("translated_title"),
          "translated_summary" => result.fetch("translated_summary"),
          "validation_status" => mechanical_validation(item, result) ? "mechanical_pass" : "needs_review",
          "status" => "translated",
          "error_reason" => ""
        }
        @store.save_translation_artifact!(artifact: artifact)
        @store.finish_metadata_translation!(run_id: item.fetch("translation_run_id"), result: result) if queued
        translated += 1
      rescue TranslationProvider::Error, LocalRadarStore::Error => error
        @store.fail_metadata_translation!(run_id: item.fetch("translation_run_id"), reason: error.message) if queued
        failed += 1
        warn "translation failed #{item.fetch('item_key')}: #{error.message}"
      end
    end
    summary(failed.zero? ? "passed" : "degraded", translated, failed, 0, candidates.length)
  end

  private

  def artifact_id(item, result)
    Digest::SHA256.hexdigest([item.fetch("item_key"), item.fetch("content_hash"), @target_language, result.fetch("provider"), result.fetch("model")].join("\u0000"))
  end

  def mechanical_validation(item, result)
    source = [item.fetch("title"), item.fetch("summary")].join(" ")
    translated = [result.fetch("translated_title"), result.fetch("translated_summary")].join(" ")
    numbers = source.scan(/\d+(?:[.,]\d+)?/)
    numbers.all? { |number| translated.include?(number) }
  end

  def summary(status, translated, failed, blocked, examined)
    { "status" => status, "translated_count" => translated, "failed_count" => failed,
      "blocked_count" => blocked, "examined_count" => examined,
      "provider" => @provider.provider_name, "model" => @provider.model, "target_language" => @target_language }
  end
end
