# frozen_string_literal: true

require "digest"
require "json"
require_relative "report_summary_provider"
require_relative "report_claim_gate"

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
    receipt = nil
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
    receipt = provider_receipt
    receipt_id = if receipt
                   unless @ledger.respond_to?(:append_provider_response_receipt!)
                     raise Error, "provider response receipt store is unavailable"
                   end
                   @ledger.append_provider_response_receipt!(run_id: run.fetch("run_id"), receipt: receipt)
                 end
    raw = expand_citation_aliases(raw, citation_aliases)
    legacy = ReportClaimGate.legacy_payload?(raw)
    raw = ReportClaimGate.adapt_legacy_payload(payload: raw, placements: context.fetch("placements")) if legacy
    normalized = validate_output(raw, placements: context.fetch("placements"))
    output_hash = Digest::SHA256.hexdigest(JSON.generate(normalized))
    artifact = {
      "artifact_id" => "summary-artifact-#{run.fetch('run_id')}",
      "run_id" => run.fetch("run_id"), "edition_id" => edition_id.to_s,
      "input_hash" => input_hash, "provider" => metadata.fetch("provider"),
      "model" => metadata.fetch("model"), "prompt_version" => metadata.fetch("prompt_version"),
      "overview" => normalized.fetch("overview"), "key_changes" => normalized.fetch("key_changes"),
      "uncertainties" => normalized.fetch("uncertainties"), "output_hash" => output_hash,
      "claim_gate_status" => legacy ? "legacy_unverified" : "verified",
      "provider_receipt_id" => receipt_id
    }
    stored = @ledger.finish_summary_success!(run_id: run.fetch("run_id"), artifact: artifact)
    { "status" => "succeeded", "run" => stored.fetch("run"), "artifact" => stored.fetch("artifact") }
  rescue StandardError => error
    if run
      begin
        if receipt.nil? && error.respond_to?(:receipt)
          receipt = error.receipt
        end
        if receipt && @ledger.respond_to?(:append_provider_response_receipt!)
          @ledger.append_provider_response_receipt!(run_id: run.fetch("run_id"), receipt: receipt)
        end
      rescue StandardError
        nil
      end
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
      next unless unit.is_a?(Hash)
      if unit["cited_version_ids"].is_a?(Array)
        unit["cited_version_ids"] = unit["cited_version_ids"].map { |id| aliases.fetch(id.to_s, id) }
      end
      Array(unit["evidence_scopes"]).each do |scope|
        next unless scope.is_a?(Hash)
        scope["version_id"] = aliases.fetch(scope["version_id"].to_s, scope["version_id"]) if scope.key?("version_id")
      end
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

  def validate_output(payload, placements:)
    ReportClaimGate.validate_artifact!(payload: payload, placements: placements)
  rescue ReportClaimGate::Error => error
    raise Error, "claim gate blocked summary: #{error.message}"
  end

  def provider_receipt
    receipt = @provider.respond_to?(:last_receipt) ? @provider.last_receipt : nil
    return receipt if receipt.is_a?(Hash)
    return nil unless @provider.respond_to?(:provider_name) && @provider.provider_name.to_s == "deepseek"

    raise Error, "provider response receipt missing"
  end
end
