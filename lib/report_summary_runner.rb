# frozen_string_literal: true

require "digest"
require "json"
require_relative "report_summary_provider"

# Builds one replaceable AI projection for an already-published local report
# edition.  The edition and archive are read-only inputs; only summary run and
# artifact rows are appended.
class ReportSummaryRunner
  class Error < StandardError; end

  def initialize(ledger:, provider: ReportSummaryProvider::OpenAICompatible.new)
    @ledger = ledger
    @provider = provider
  end

  attr_reader :provider

  def run(edition_id:, idempotency_key:)
    run = nil
    context = @ledger.report_summary_context(edition_id: edition_id)
    input_hash = Digest::SHA256.hexdigest(JSON.generate(context))
    metadata = {
      "provider" => @provider.provider_name.to_s,
      "model" => @provider.model.to_s,
      "prompt_version" => provider_prompt_version
    }
    run = @ledger.append_summary_run!(edition_id: edition_id, idempotency_key: idempotency_key,
                                      input_hash: input_hash, provider: metadata.fetch("provider"),
                                      model: metadata.fetch("model"), prompt_version: metadata.fetch("prompt_version"))
    return replay(run) unless run.fetch("state") == "running"

    if context.fetch("placements").empty?
      return terminal_blocked(run, "raw edition is empty; summary not applicable")
    end
    unless @provider.available?
      return terminal_blocked(run, "summary provider credentials are not configured")
    end

    raw = @provider.summarize(input: context)
    normalized = validate_output(raw, allowed_version_ids: context.fetch("placements").map { |item| item.fetch("version_id") })
    output_hash = Digest::SHA256.hexdigest(JSON.generate(normalized))
    artifact = {
      "artifact_id" => "summary-artifact-#{run.fetch('run_id')}",
      "run_id" => run.fetch("run_id"), "edition_id" => edition_id.to_s,
      "input_hash" => input_hash, "provider" => metadata.fetch("provider"),
      "model" => metadata.fetch("model"), "prompt_version" => metadata.fetch("prompt_version"),
      "overview" => normalized.fetch("overview"), "key_changes" => normalized.fetch("key_changes"),
      "uncertainties" => normalized.fetch("uncertainties"), "output_hash" => output_hash
    }
    stored = @ledger.finish_summary_success!(run_id: run.fetch("run_id"), artifact: artifact)
    { "status" => "succeeded", "run" => stored.fetch("run"), "artifact" => stored.fetch("artifact") }
  rescue StandardError => error
    if run
      failed = @ledger.finish_summary_failed!(run_id: run.fetch("run_id"), state: "failed", reason: error.message)
      { "status" => "failed", "run" => failed, "artifact" => nil }
    else
      raise
    end
  end

  alias generate! run

  private

  def replay(run)
    if run.fetch("state") == "succeeded"
      artifact = @ledger.summary_artifact_for_run(run_id: run.fetch("run_id"))
      return { "status" => "succeeded", "run" => run, "artifact" => artifact }
    end
    { "status" => run.fetch("state"), "run" => run, "artifact" => nil }
  end

  def provider_prompt_version
    return @provider.prompt_version.to_s if @provider.respond_to?(:prompt_version)

    ReportSummaryProvider::OpenAICompatible::PROMPT_VERSION
  end

  def terminal_blocked(run, reason)
    blocked = @ledger.finish_summary_failed!(run_id: run.fetch("run_id"), state: "blocked", reason: reason)
    { "status" => "blocked", "run" => blocked, "artifact" => nil }
  end

  def validate_output(payload, allowed_version_ids:)
    raise Error, "summary provider output must be a JSON object" unless payload.is_a?(Hash)
    expected_top = %w[overview key_changes uncertainties]
    raise Error, "summary provider output has unknown or missing top-level keys" unless payload.keys.sort == expected_top.sort
    overview = validate_unit(payload.fetch("overview"), allowed_version_ids: allowed_version_ids)
    key_changes = validate_units(payload.fetch("key_changes"), allowed_version_ids: allowed_version_ids)
    uncertainties = validate_units(payload.fetch("uncertainties"), allowed_version_ids: allowed_version_ids)
    { "overview" => overview, "key_changes" => key_changes, "uncertainties" => uncertainties }
  rescue KeyError, TypeError => error
    raise Error, "invalid summary provider output: #{error.message}"
  end

  def validate_units(value, allowed_version_ids:)
    raise Error, "summary unit collection must be an array" unless value.is_a?(Array)

    value.map { |unit| validate_unit(unit, allowed_version_ids: allowed_version_ids) }
  end

  def validate_unit(unit, allowed_version_ids:)
    raise Error, "summary unit must be an object" unless unit.is_a?(Hash)
    raise Error, "summary unit has unknown or missing keys" unless unit.keys.sort == %w[cited_version_ids text]
    text = unit.fetch("text")
    citations = unit.fetch("cited_version_ids")
    raise Error, "summary unit text must be non-empty" unless text.is_a?(String) && !text.strip.empty?
    raise Error, "summary unit citations must be a non-empty array" unless citations.is_a?(Array) && !citations.empty?
    citations = citations.map do |value|
      raise Error, "summary unit citation must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?

      value
    end
    raise Error, "summary unit citations must be unique" unless citations.uniq.length == citations.length
    unknown = citations - allowed_version_ids
    raise Error, "summary unit cites unknown version_id(s): #{unknown.join(', ')}" unless unknown.empty?
    { "text" => text, "cited_version_ids" => citations }
  end
end
