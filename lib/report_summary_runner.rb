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
  # These are fields that can appear in the provider input as edition or
  # projection-boundary metadata.  They are never claim fields and are never
  # accepted by ReportClaimGate.  A provider may accidentally echo them next
  # to an otherwise complete claim; the projection below removes only this
  # closed set after checking the claim's declared core shape.  Any other
  # unknown key remains visible to the gate and therefore fails closed.
  CLAIM_METADATA_KEYS = %w[
    edition_id nominal_window_start nominal_window_end raw_item_count provider_item_count
  ].freeze
  CLAIM_DECLARED_KEYS = %w[
    claim_id kind text epistemic_status evidence_scopes premise_scope_ids inference_support_status
  ].freeze
  # claim_id is server-owned and is assigned after all provider compatibility
  # normalization.  It is intentionally not part of the provider core shape.
  CLAIM_CORE_KEYS = %w[kind text epistemic_status evidence_scopes].freeze
  CLAIM_WRAPPER_KEYS = %w[claim].freeze
  CLAIM_ID_NAMESPACE = "report-summary"
  CLAIM_ID_VERSION = "v1"

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
    raw = normalize_provider_claim_shape(raw)
    raw = expand_citation_aliases(raw, citation_aliases)
    raw = project_provider_metadata(raw)
    legacy = ReportClaimGate.legacy_payload?(raw)
    raw = ReportClaimGate.adapt_legacy_payload(payload: raw, placements: context.fetch("placements")) if legacy
    raw = canonicalize_claim_ids(raw, edition_id: edition_id)
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

  # A provider may use the input/archive vocabulary (summary) for the claim
  # text or wrap one overview claim in a `claim` object.  Normalize only those
  # two explicitly registered compatibility shapes.  The gate remains the
  # authority for all required fields and evidence; this method never creates
  # a kind, epistemic status, citation, or evidence scope.
  def normalize_provider_claim_shape(payload)
    return payload unless payload.is_a?(Hash)

    copy = JSON.parse(JSON.generate(payload))
    if copy.key?("overview")
      overview = copy["overview"]
      overview = unwrap_overview_claim(overview)
      copy["overview"] = normalize_claim_text_alias(overview)
    end
    %w[key_changes uncertainties].each do |section|
      next unless copy[section].is_a?(Array)

      copy[section] = copy[section].map { |unit| normalize_claim_text_alias(unit) }
    end
    copy
  rescue JSON::GeneratorError, JSON::ParserError, TypeError
    payload
  end

  def unwrap_overview_claim(unit)
    return unit unless unit.is_a?(Hash)

    normalized = unit.transform_keys(&:to_s)
    return normalized unless normalized.key?("claim")
    return unit unless normalized.keys.sort == CLAIM_WRAPPER_KEYS.sort
    return unit unless normalized.fetch("claim").is_a?(Hash)

    normalized.fetch("claim")
  end

  def normalize_claim_text_alias(unit)
    return unit unless unit.is_a?(Hash)

    normalized = unit.transform_keys(&:to_s)
    return normalized unless normalized.key?("summary")

    if normalized.key?("text")
      unless normalized.fetch("text") == normalized.fetch("summary")
        raise Error, "claim text alias conflict: text and summary differ"
      end
      normalized.delete("summary")
    else
      normalized["text"] = normalized.delete("summary")
    end
    normalized
  end

  # Providers sometimes echo the edition/projection boundary alongside a
  # claim.  Keep the claim gate strict: only a closed, explicitly-known set of
  # input metadata keys may be removed, and only when the remaining claim has
  # its complete declared core shape.  Unknown keys are intentionally left in
  # place so ReportClaimGate rejects them.  In particular, this method never
  # projects nested evidence scopes or treats metadata as evidence.
  def project_provider_metadata(payload)
    return payload unless payload.is_a?(Hash)

    copy = JSON.parse(JSON.generate(payload))
    copy["overview"] = project_claim_metadata!(copy["overview"]) if copy.key?("overview")
    if copy.key?("key_changes") && copy["key_changes"].is_a?(Array)
      copy["key_changes"] = copy["key_changes"].map { |unit| project_claim_metadata!(unit) }
    end
    if copy.key?("uncertainties") && copy["uncertainties"].is_a?(Array)
      copy["uncertainties"] = copy["uncertainties"].map { |unit| project_claim_metadata!(unit) }
    end
    copy
  rescue JSON::GeneratorError, JSON::ParserError, TypeError
    payload
  end

  def project_claim_metadata!(unit)
    return unit unless unit.is_a?(Hash)

    normalized = unit.transform_keys(&:to_s)
    metadata_keys = normalized.keys & CLAIM_METADATA_KEYS
    return unit if metadata_keys.empty?

    # Do not strip metadata from malformed claims.  This leaves the original
    # object for the claim gate, which reports the missing/unknown shape and
    # prevents a partial projection from being accepted.
    return unit unless CLAIM_CORE_KEYS.all? { |key| normalized.key?(key) }

    # An ai_inference has two additional core fields.  Checking them here is
    # what prevents a metadata-only cleanup from making an incomplete
    # inference look valid; the gate still validates their values and scopes.
    if normalized["kind"].to_s == "ai_inference" &&
       !%w[premise_scope_ids inference_support_status].all? { |key| normalized.key?(key) }
      return unit
    end

    # Only the closed metadata set can be projected.  Any unrelated unknown
    # key remains in the object and is rejected by ReportClaimGate.
    non_metadata_keys = normalized.keys - metadata_keys
    return unit unless (non_metadata_keys - CLAIM_DECLARED_KEYS).empty?

    # Evidence scopes are deliberately not projected or rewritten.  If the
    # provider placed metadata (or any other unknown key) inside a scope, the
    # gate must see it and fail closed.
    normalized.select { |key, _value| CLAIM_DECLARED_KEYS.include?(key) }
  end

  # Provider-supplied claim IDs are never identity.  The immutable edition,
  # section/ordinal, normalized claim text, and a sorted, field-level evidence
  # identity form one canonical input to a versioned, namespaced SHA-256 ID.
  # This runs immediately before the gate so malformed claims still fail at
  # the gate, while arbitrary/duplicate provider IDs cannot replace or merge
  # an artifact claim.
  def canonicalize_claim_ids(payload, edition_id:)
    return payload unless payload.is_a?(Hash)

    copy = JSON.parse(JSON.generate(payload))
    copy["overview"] = canonicalize_claim_unit(copy["overview"], edition_id: edition_id, section: "overview", ordinal: 0) if copy.key?("overview")
    if copy["key_changes"].is_a?(Array)
      copy["key_changes"] = copy["key_changes"].each_with_index.map do |unit, index|
        canonicalize_claim_unit(unit, edition_id: edition_id, section: "key_changes", ordinal: index)
      end
    end
    if copy["uncertainties"].is_a?(Array)
      copy["uncertainties"] = copy["uncertainties"].each_with_index.map do |unit, index|
        canonicalize_claim_unit(unit, edition_id: edition_id, section: "uncertainties", ordinal: index)
      end
    end
    copy
  rescue JSON::GeneratorError, JSON::ParserError, TypeError
    payload
  end

  def canonicalize_claim_unit(unit, edition_id:, section:, ordinal:)
    return unit unless unit.is_a?(Hash)

    normalized = unit.transform_keys(&:to_s)
    normalized["claim_id"] = canonical_claim_id(normalized, edition_id: edition_id, section: section, ordinal: ordinal)
    normalized
  end

  def canonical_claim_id(claim, edition_id:, section:, ordinal:)
    evidence = Array(claim["evidence_scopes"]).map do |scope|
      identity = if scope.is_a?(Hash)
                   scope.transform_keys(&:to_s).sort.to_h
                 else
                   { "invalid_scope" => scope.to_s }
                 end
      [JSON.generate(identity), identity]
    end.sort_by(&:first).map(&:last)
    text = claim["text"]
    normalized_text = normalize_claim_text_for_id(text)
    canonical_input = {
      "namespace" => CLAIM_ID_NAMESPACE,
      "version" => CLAIM_ID_VERSION,
      "edition_id" => edition_id.to_s,
      "section" => section.to_s,
      "ordinal" => ordinal.to_i,
      "text" => normalized_text,
      "evidence_scopes" => evidence
    }
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical_input))
    "claim-#{CLAIM_ID_NAMESPACE}-#{CLAIM_ID_VERSION}-#{digest}"
  end

  def normalize_claim_text_for_id(value)
    return value unless value.is_a?(String)

    normalized = value.respond_to?(:unicode_normalize) ? value.unicode_normalize(:nfkc) : value
    normalized.gsub(/\s+/, " ").strip
  rescue ArgumentError
    value
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
