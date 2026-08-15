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
    owner = ENV.fetch("LOCAL_TRANSLATION_OWNER", "translation-runner-#{Process.pid}")
    job_id = ENV["LOCAL_TRANSLATION_JOB_ID"].to_s.empty? ? nil : ENV["LOCAL_TRANSLATION_JOB_ID"]
    claimed_job = !job_id.nil?
    if queued && @store.respond_to?(:start_translation_batch_job!) && !claimed_job
      begin
        job_id = @store.start_translation_batch_job!(limit: limit, daily_character_limit: daily_character_limit, owner: owner)
      rescue LocalRadarStore::Error => error
        return summary("active", 0, 0, 0, 0).merge("error" => "translation batch job is already active") if error.message.include?("already active")
        raise
      end
    end

    begin
      @store.ensure_metadata_translation_runs! if queued
      candidates = queued ? @store.metadata_translation_candidates(limit: limit, daily_character_limit: daily_character_limit) : @store.translation_candidates(limit: limit)
      if candidates.empty?
        @store.finish_translation_batch_job!(job_id: job_id, owner: owner, state: "succeeded", counters: { "queued_count" => 0, "examined_count" => 0 }) if job_id
        return summary("not_needed", 0, 0, 0, 0).merge("job_id" => job_id)
      end
      @store.update_translation_batch_job!(job_id: job_id, owner: owner, counters: { "queued_count" => candidates.length, "examined_count" => 0 }) if job_id
      unless @provider.available?
        candidates.each do |item|
          if queued
            block_metadata_translation!(item.fetch("translation_run_id"), "DeepSeek API credentials are not configured", owner: owner, job_id: job_id)
          end
        end
        @store.finish_translation_batch_job!(job_id: job_id, owner: owner, state: "blocked", counters: { "queued_count" => candidates.length, "examined_count" => candidates.length, "blocked_count" => candidates.length }, error_reason: "DeepSeek API credentials are not configured") if job_id
        return summary("external_blocked", 0, 0, candidates.length, candidates.length).merge("job_id" => job_id)
      end

      translated = 0
      failed = 0
      candidates.each do |item|
        begin
          @store.heartbeat_translation_batch_job!(job_id: job_id, owner: owner) if job_id
          start_metadata_translation!(item.fetch("translation_run_id"), owner: owner, job_id: job_id) if queued
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
          if queued && accepts_artifact_finish?
            @store.finish_metadata_translation!(run_id: item.fetch("translation_run_id"), result: result, artifact: artifact, owner: owner, job_id: job_id)
          else
            @store.save_translation_artifact!(artifact: artifact)
            @store.finish_metadata_translation!(run_id: item.fetch("translation_run_id"), result: result) if queued
          end
          translated += 1
          @store.update_translation_batch_job!(job_id: job_id, owner: owner, counters: { "examined_count" => translated + failed, "translated_count" => translated, "failed_count" => failed, "input_chars" => candidates.first(translated + failed).sum { |entry| entry.fetch("input_chars", 0).to_i } }) if job_id
        rescue TranslationProvider::Error, LocalRadarStore::Error => error
          fail_metadata_translation!(item.fetch("translation_run_id"), error.message, owner: owner, job_id: job_id) if queued
          failed += 1
          @store.update_translation_batch_job!(job_id: job_id, owner: owner, counters: { "examined_count" => translated + failed, "translated_count" => translated, "failed_count" => failed, "input_chars" => candidates.first(translated + failed).sum { |entry| entry.fetch("input_chars", 0).to_i } }) if job_id
          warn "translation failed #{item.fetch('item_key')}: #{error.message}"
        end
      end
      state = failed.zero? ? "succeeded" : "failed"
      @store.finish_translation_batch_job!(job_id: job_id, owner: owner, state: state, counters: { "queued_count" => candidates.length, "examined_count" => candidates.length, "translated_count" => translated, "failed_count" => failed, "input_chars" => candidates.sum { |item| item.fetch("input_chars", 0).to_i } }, error_reason: failed.zero? ? "" : "one or more metadata translations failed") if job_id
      summary(failed.zero? ? "passed" : "degraded", translated, failed, 0, candidates.length).merge("job_id" => job_id)
    rescue StandardError => error
      if job_id
        begin
          @store.finish_translation_batch_job!(job_id: job_id, owner: owner, state: "failed", error_reason: error.message)
        rescue StandardError
          nil
        end
      end
      raise
    end
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

  def accepts_artifact_finish?
    @store.method(:finish_metadata_translation!).parameters.any? { |kind, name| kind == :key && name == :artifact }
  rescue NameError
    false
  end

  def start_metadata_translation!(run_id, owner:, job_id:)
    method = @store.method(:start_metadata_translation!)
    if method.parameters.any? { |kind, name| kind == :key && name == :owner }
      @store.start_metadata_translation!(run_id: run_id, owner: owner, job_id: job_id)
    else
      @store.start_metadata_translation!(run_id: run_id)
    end
  end

  def block_metadata_translation!(run_id, reason, owner:, job_id:)
    method = @store.method(:block_metadata_translation_for_credentials!)
    if method.parameters.any? { |kind, name| kind == :key && name == :owner }
      @store.block_metadata_translation_for_credentials!(run_id: run_id, reason: reason, owner: owner, job_id: job_id)
    else
      @store.block_metadata_translation_for_credentials!(run_id: run_id, reason: reason)
    end
  end

  def fail_metadata_translation!(run_id, reason, owner:, job_id:)
    method = @store.method(:fail_metadata_translation!)
    if method.parameters.any? { |kind, name| kind == :key && name == :owner }
      @store.fail_metadata_translation!(run_id: run_id, reason: reason, owner: owner, job_id: job_id)
    else
      @store.fail_metadata_translation!(run_id: run_id, reason: reason)
    end
  end
end
