# frozen_string_literal: true

require "digest"
require "json"
require_relative "report_summary_provider"

# Builds one replaceable AI projection for an already-published local report
# edition.  The edition and archive are read-only inputs; only summary run and
# artifact rows are appended.
class ReportSummaryRunner
  class Error < StandardError; end
  MAX_PROVIDER_ITEMS = 30
  MAX_PROVIDER_CHARACTERS = 25_000

  def initialize(ledger:, provider: ReportSummaryProvider::DeepSeek.new)
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

    provider_context, citation_aliases = bounded_provider_context(context)
    raw = @provider.summarize(input: provider_context)
    raw = expand_citation_aliases(raw, citation_aliases)
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

  # The raw edition remains complete. Only the replaceable AI projection is
  # bounded: deterministic round-robin across publishers, preserving report
  # order within each publisher, then capped by an explicit character budget.
  def bounded_provider_context(context)
    placements = context.fetch("placements")
    groups = placements.group_by { |row| row.fetch("publisher", "").to_s.empty? ? row.fetch("version_id") : row.fetch("publisher") }
    ordered_groups = groups.keys.sort.map { |key| groups.fetch(key).sort_by { |row| [row.fetch("sort_order", 0).to_i, row.fetch("version_id")] } }
    selected = []
    loop do
      added = false
      ordered_groups.each do |group|
        next if group.empty? || selected.length >= MAX_PROVIDER_ITEMS
        selected << group.shift
        added = true
      end
      break unless added && selected.length < MAX_PROVIDER_ITEMS
    end
    used = 0
    bounded = selected.sort_by { |row| [row.fetch("sort_order", 0).to_i, row.fetch("version_id")] }.take_while do |row|
      used += row.fetch("title", "").to_s.length + row.fetch("summary", "").to_s.length + row.fetch("publisher", "").to_s.length + 200
      used <= MAX_PROVIDER_CHARACTERS
    end
    bounded = selected.first(1) if bounded.empty? && !selected.empty?
    aliases = {}
    provider_rows = bounded.each_with_index.map do |row, index|
      short_id = format("E%03d", index + 1)
      aliases[short_id] = row.fetch("version_id")
      row.merge("version_id" => short_id)
    end
    provider_context = context.merge("placements" => provider_rows, "projection_boundary" => {
      "raw_item_count" => placements.length, "provider_item_count" => bounded.length,
      "selection_method" => "deterministic_publisher_round_robin_v1",
      "max_provider_items" => MAX_PROVIDER_ITEMS, "max_provider_characters" => MAX_PROVIDER_CHARACTERS
    })
    [provider_context, aliases]
  end

  def expand_citation_aliases(payload, aliases)
    return payload unless payload.is_a?(Hash)
    copy = JSON.parse(JSON.generate(payload))
    units = [copy["overview"], *Array(copy["key_changes"]), *Array(copy["uncertainties"])]
    units.each do |unit|
      next unless unit.is_a?(Hash) && unit["cited_version_ids"].is_a?(Array)
      unit["cited_version_ids"] = unit["cited_version_ids"].map { |id| aliases.fetch(id.to_s, id) }
    end
    copy
  end

  def replay(run)
    if run.fetch("state") == "succeeded"
      artifact = @ledger.summary_artifact_for_run(run_id: run.fetch("run_id"))
      return { "status" => "succeeded", "run" => run, "artifact" => artifact }
    end
    { "status" => run.fetch("state"), "run" => run, "artifact" => nil }
  end

  def provider_prompt_version
    return @provider.prompt_version.to_s if @provider.respond_to?(:prompt_version)

    ReportSummaryProvider::DeepSeek::PROMPT_VERSION
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
