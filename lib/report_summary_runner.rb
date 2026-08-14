# frozen_string_literal: true

require "digest"
require "digest/sha2"
require "json"
require "securerandom"
require_relative "local_report_ledger"
require_relative "report_summary_provider"
require_relative "report_claim_gate"

# Builds one replaceable AI projection for an already-published local report
# edition.  The edition and archive are read-only inputs; only summary run and
# artifact rows are appended.
class ReportSummaryRunner
  class Error < StandardError; end

  # Validation failures are intentionally distinct from provider/transport or
  # persistence failures.  Only this allowlist may trigger the single repair
  # exchange; everything else fails closed after the initial exchange.
  class ValidationError < Error
    attr_reader :code, :validation_message

    def initialize(message, code:, validation_message: nil)
      @code = code.to_s
      @validation_message = (validation_message || message).to_s
      super(message)
    end
  end

  MAX_PROVIDER_ITEMS = 30
  MAX_PROVIDER_CHARACTERS = 25_000
  RETRY_POLICY_VERSION = "report-summary-repair-v1"
  MAX_PROVIDER_EXCHANGES = 2
  REPAIRABLE_VALIDATION_CODES = %w[
    CLAIM_ARTIFACT_SHAPE
    CLAIM_SHAPE
    CLAIM_TEXT_ALIAS_CONFLICT
    CLAIM_TEXT_MISSING
    CLAIM_KIND_INVALID
    CLAIM_ID_INVALID
    CLAIM_ID_DUPLICATE
    CLAIM_EPISTEMIC_STATUS_INVALID
    CLAIM_EVIDENCE_MISSING
    CLAIM_SCOPE_SHAPE
    CLAIM_SCOPE_ID_INVALID
    CLAIM_SCOPE_ID_DUPLICATE
    CLAIM_SCOPE_VERSION_UNKNOWN
    CLAIM_SCOPE_FIELD_INVALID
    CLAIM_SCOPE_TEXT_MISSING
    CLAIM_SCOPE_NOT_LOCATABLE
    CLAIM_RELATION_INVALID
    CLAIM_EVIDENCE_UNKNOWN
    CLAIM_EVIDENCE_SUPPORT_MISSING
    CLAIM_CONTRADICTION_UNDECLARED
    CLAIM_ALTERNATIVE_UNSUPPORTED
    CLAIM_INFERENCE_FIELDS_FORBIDDEN
    INFERENCE_PREMISE_MISSING
    INFERENCE_SUPPORT_STATUS_INVALID
    INFERENCE_PREMISE_SCOPE_MISSING
    INFERENCE_PREMISE_NOT_SUPPORTED
    LEGACY_CITATION_MISSING
    LEGACY_TEXT_MISSING
    LEGACY_PAYLOAD_UNSUPPORTED
  ].freeze
  REPAIRABLE_ERROR_CODES = REPAIRABLE_VALIDATION_CODES
  REPAIRABLE_CLAIM_ERROR_CODES = REPAIRABLE_VALIDATION_CODES

  SECRET_KEY_PATTERN = /(api[_-]?key|authorization|secret|password|credential|access[_-]?token|refresh[_-]?token)/i
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
    lease_owner = "summary-owner-#{SecureRandom.hex(16)}"
    appended_receipt_ids = []
    initial_receipt_id = nil
    final_receipt_id = nil
    generation_attempt_count = 0
    repaired = false
    repair_from_receipt_id = nil
    context = @ledger.report_summary_context(edition_id: edition_id)
    input_hash = Digest::SHA256.hexdigest(JSON.generate(context))
    metadata = {
      "provider" => @provider.provider_name.to_s,
      "model" => @provider.model.to_s,
      "prompt_version" => provider_prompt_version,
      "retry_policy_version" => RETRY_POLICY_VERSION
    }
    run = append_summary_run(metadata: metadata, edition_id: edition_id, idempotency_key: idempotency_key,
                             input_hash: input_hash, owner_id: lease_owner)
    # LocalReportLedger returns this transient ownership marker after its
    # serializable idempotency lock.  A concurrent/replayed running row is
    # observed but never invokes the provider a second time.  Lightweight
    # fakes from older tests omit the marker and are treated as the owner.
    execution_owner = run.delete("__summary_execution_owner") if run.is_a?(Hash)
    lease_owner = run.delete("__summary_lease_owner").to_s if run.is_a?(Hash) && run["__summary_lease_owner"]
    lease_owner = nil if lease_owner.to_s.empty?
    return replay(run) unless run.fetch("state") == "running" && execution_owner != false

    if context.fetch("placements").empty?
      return terminal_blocked(run, "raw edition is empty; summary not applicable", lease_owner: lease_owner)
    end
    unless @provider.available?
      return terminal_blocked(run, "summary provider credentials are not configured", lease_owner: lease_owner)
    end

    provider_context, citation_aliases = bounded_provider_context(context)
    original_model_json = nil
    raw = begin
      heartbeat_summary_run!(run_id: run.fetch("run_id"), lease_owner: lease_owner)
      value = @provider.summarize(input: provider_context)
      heartbeat_summary_run!(run_id: run.fetch("run_id"), lease_owner: lease_owner)
      original_model_json = sanitize_repair_json(provider_content(value))
      value
    rescue StandardError => error
      receipt = provider_receipt(error)
      if receipt
        receipt = annotate_receipt(receipt, attempt_ordinal: 1, exchange_kind: "initial")
        append_receipt!(run_id: run.fetch("run_id"), receipt: receipt, appended_receipt_ids: appended_receipt_ids,
                        lease_owner: lease_owner)
      end
      raise
    end

    initial_receipt = provider_receipt
    if initial_receipt
      initial_receipt = annotate_receipt(initial_receipt, attempt_ordinal: 1, exchange_kind: "initial")
      initial_receipt_id = append_receipt!(run_id: run.fetch("run_id"), receipt: initial_receipt,
                                           appended_receipt_ids: appended_receipt_ids, lease_owner: lease_owner)
      final_receipt_id = initial_receipt_id
      if initial_receipt.fetch("status", "").to_s == "failed"
        raise Error, "initial provider exchange failed; structural repair is not permitted"
      end
    end
    generation_attempt_count = 1

    begin
      normalized, legacy = normalize_and_validate(raw, citation_aliases: citation_aliases,
                                                  context: context, edition_id: edition_id)
    rescue ValidationError => validation_error
      raise unless repairable_validation?(validation_error)
      unless provider_supports_repair?
        raise Error, "#{validation_error.validation_message}; summary provider does not support structural repair"
      end

      repaired = true
      generation_attempt_count = MAX_PROVIDER_EXCHANGES
      repair_from_receipt_id = initial_receipt_id
      heartbeat_summary_run!(run_id: run.fetch("run_id"), lease_owner: lease_owner)
      repair_result = invoke_repair(
        input: provider_context,
        original_json: original_model_json || sanitize_repair_json(provider_content(raw)),
        validation_code: validation_error.code,
        validation_message: validation_error.validation_message,
        context: context,
        citation_aliases: citation_aliases
      )
      heartbeat_summary_run!(run_id: run.fetch("run_id"), lease_owner: lease_owner)
      repair_raw = provider_content(repair_result)
      enforce_repair_no_new_facts!(original_model_json || sanitize_repair_json(provider_content(raw)), repair_raw)
      repair_receipt = provider_receipt
      if repair_receipt
        repair_receipt = annotate_receipt(repair_receipt, attempt_ordinal: 2, exchange_kind: "repair",
                                          repair_from_receipt_id: initial_receipt_id.to_s)
        final_receipt_id = append_receipt!(run_id: run.fetch("run_id"), receipt: repair_receipt,
                                           appended_receipt_ids: appended_receipt_ids, lease_owner: lease_owner)
        if repair_receipt.fetch("status", "").to_s == "failed"
          raise Error, "repair provider exchange failed; summary remains failed"
        end
      end
      # Do not recursively repair a second gate failure.  This call may raise
      # ValidationError, which is handled by the terminal failure path below.
      normalized, legacy = normalize_and_validate(repair_raw, citation_aliases: citation_aliases,
                                                  context: context, edition_id: edition_id)
    end

    output_hash = Digest::SHA256.hexdigest(JSON.generate(normalized))
    artifact = {
      "artifact_id" => "summary-artifact-#{run.fetch('run_id')}",
      "run_id" => run.fetch("run_id"), "edition_id" => edition_id.to_s,
      "input_hash" => input_hash, "provider" => metadata.fetch("provider"),
      "model" => metadata.fetch("model"), "prompt_version" => metadata.fetch("prompt_version"),
      "overview" => normalized.fetch("overview"), "key_changes" => normalized.fetch("key_changes"),
      "uncertainties" => normalized.fetch("uncertainties"), "output_hash" => output_hash,
      "claim_gate_status" => legacy ? "legacy_unverified" : "verified",
      "provider_receipt_id" => final_receipt_id,
      "generation_attempt_count" => generation_attempt_count,
      "repaired" => repaired,
      "repair_from_receipt_id" => repair_from_receipt_id
    }
    stored = finish_summary_success(run_id: run.fetch("run_id"), artifact: artifact, lease_owner: lease_owner)
    { "status" => "succeeded", "run" => stored.fetch("run"), "artifact" => stored.fetch("artifact") }
  rescue StandardError => error
    if run
      begin
        # Provider failures can happen before a normal return.  Preserve that
        # exchange receipt exactly once; validation failures already appended
        # their initial/repair receipts before reaching this branch.
        receipt = provider_receipt(error)
        if receipt && @ledger.respond_to?(:append_provider_response_receipt!)
          ordinal = appended_receipt_ids.empty? ? 1 : 2
          annotated = annotate_receipt(receipt, attempt_ordinal: ordinal,
                                        exchange_kind: ordinal == 1 ? "initial" : "repair",
                                        repair_from_receipt_id: ordinal == 2 ? initial_receipt_id.to_s : nil)
          append_receipt!(run_id: run.fetch("run_id"), receipt: annotated,
                          appended_receipt_ids: appended_receipt_ids, lease_owner: lease_owner)
        end
      rescue StandardError
        nil
      end
      begin
        failed = finish_summary_failed(run_id: run.fetch("run_id"), state: "failed", reason: error.message,
                                       lease_owner: lease_owner)
        { "status" => "failed", "run" => failed, "artifact" => nil }
      rescue StandardError => finish_error
        # Once the lease is gone this process is no longer authorized to
        # mutate the run.  Do not fabricate an interrupted terminal row (the
        # next scheduled cycle owns that CAS recovery); return the observed
        # state and leave any already-appended receipts intact.
        raise unless lease_loss_error?(finish_error)
        current = if @ledger.respond_to?(:summary_run_for_id)
                    @ledger.summary_run_for_id(run_id: run.fetch("run_id"))
                  else
                    run
                  end
        { "status" => current.fetch("state", "running"), "run" => current, "artifact" => nil,
          "error" => "summary lease lost; scheduled recovery required: #{finish_error.message}" }
      end
    else
      raise
    end
  end

  alias generate! run

  private

  def append_summary_run(metadata:, edition_id:, idempotency_key:, input_hash:, owner_id:)
    kwargs = {
      edition_id: edition_id, idempotency_key: idempotency_key, input_hash: input_hash,
      provider: metadata.fetch("provider"), model: metadata.fetch("model"),
      prompt_version: metadata.fetch("prompt_version"),
      retry_policy_version: metadata.fetch("retry_policy_version"), owner_id: owner_id
    }
    method = @ledger.method(:append_summary_run!)
    parameters = method.parameters
    accepts_retry = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :retry_policy_version } ||
                    parameters.any? { |kind, _name| kind == :keyrest }
    accepts_owner = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :owner_id } ||
                    parameters.any? { |kind, _name| kind == :keyrest }
    kwargs.delete(:retry_policy_version) unless accepts_retry
    kwargs.delete(:owner_id) unless accepts_owner
    @ledger.append_summary_run!(**kwargs)
  rescue ArgumentError => error
    # Older in-memory ledgers may not expose the new retry-policy keyword. A
    # TypeError here is not a provider retry; fall back only when the method
    # explicitly rejected that one optional keyword.
    if accepts_owner && error.message.match?(/owner_id|keyword/i)
      kwargs.delete(:owner_id)
      @ledger.append_summary_run!(**kwargs)
    elsif accepts_retry && error.message.match?(/retry_policy_version|keyword/i)
      kwargs.delete(:retry_policy_version)
      @ledger.append_summary_run!(**kwargs)
    else
      raise
    end
  end

  def provider_content(value)
    return value unless value.is_a?(Hash) && value.key?("content")

    value.fetch("content")
  end

  def provider_supports_repair?
    return false unless @provider.respond_to?(:repair)
    return @provider.supports_repair? if @provider.respond_to?(:supports_repair?)

    true
  rescue StandardError
    false
  end

  def invoke_repair(input:, original_json:, validation_code:, validation_message:, context:, citation_aliases:)
    arguments = {
      input: input,
      original_json: sanitize_repair_json(original_json),
      original_model_json: sanitize_repair_json(original_json),
      validation_code: validation_code.to_s,
      validation_message: validation_message.to_s,
      validation_error: { "code" => validation_code.to_s, "message" => validation_message.to_s },
      schema: frozen_output_schema,
      allowed_evidence: allowed_evidence(context, citation_aliases),
      minimum_example: minimum_valid_example(context, citation_aliases)
    }
    method = @provider.method(:repair)
    parameters = method.parameters
    if parameters.any? { |kind, _name| kind == :keyrest }
      return provider_content(@provider.repair(**arguments))
    end
    positional_names = parameters.select { |kind, _name| %i[req opt].include?(kind) }.map(&:last)
    if positional_names.length >= 2
      positional = positional_names.map do |name|
        if arguments.key?(name)
          arguments.fetch(name)
        elsif %i[original_output model_output output_json].include?(name)
          arguments.fetch(:original_json)
        elsif name == :validation_error
          arguments.fetch(:validation_error)
        else
          arguments.fetch(name, nil)
        end
      end
      return provider_content(@provider.repair(*positional))
    end
    keyword_names = parameters.select { |kind, _name| %i[key keyreq].include?(kind) }.map(&:last)
    if keyword_names.any?
      aliases = {
        original_output: :original_json,
        model_json: :original_json,
        output_json: :original_json,
        original_model_output: :original_json,
        model_output: :original_json,
        original_model_json: :original_model_json,
        validation_error_code: :validation_code,
        validation_error_message: :validation_message,
        evidence: :allowed_evidence,
        allowed_evidence_scope: :allowed_evidence,
        example: :minimum_example
      }
      selected = keyword_names.each_with_object({}) do |name, result|
        source = arguments.key?(name) ? name : aliases.fetch(name, nil)
        result[name] = arguments.fetch(source) if source && arguments.key?(source)
      end
      return provider_content(@provider.repair(**selected))
    end
    # Positional hash is accepted for tiny test doubles and keeps the
    # capability explicit; a provider without repair is rejected above.
    provider_content(@provider.repair(arguments))
  end

  def heartbeat_summary_run!(run_id:, lease_owner:)
    return if lease_owner.to_s.empty? || !@ledger.respond_to?(:heartbeat_summary_run!)

    parameters = @ledger.method(:heartbeat_summary_run!).parameters
    kwargs = { run_id: run_id, lease_owner: lease_owner }
    accepts_seconds = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :lease_seconds } ||
                      parameters.any? { |kind, _name| kind == :keyrest }
    kwargs[:lease_seconds] = LocalReportLedger::SUMMARY_LEASE_SECONDS if accepts_seconds
    @ledger.heartbeat_summary_run!(**kwargs)
  end

  def append_receipt!(run_id:, receipt:, appended_receipt_ids:, lease_owner: nil)
    return nil unless receipt.is_a?(Hash)
    unless @ledger.respond_to?(:append_provider_response_receipt!)
      raise Error, "provider response receipt store is unavailable"
    end
    receipt_id = receipt.fetch("receipt_id", "").to_s
    receipt_key = receipt_id.empty? ? receipt.fetch("exchange_id", "").to_s : receipt_id
    if !receipt_key.empty? && appended_receipt_ids.include?(receipt_key)
      return receipt_id.empty? ? nil : receipt_id
    end
    kwargs = { run_id: run_id, receipt: receipt }
    parameters = @ledger.method(:append_provider_response_receipt!).parameters
    accepts_owner = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :lease_owner } ||
                    parameters.any? { |kind, _name| kind == :keyrest }
    kwargs[:lease_owner] = lease_owner if accepts_owner && !lease_owner.to_s.empty?
    stored_id = @ledger.append_provider_response_receipt!(**kwargs)
    appended_receipt_ids << receipt_key unless receipt_key.empty?
    appended_receipt_ids << stored_id.to_s unless stored_id.to_s.empty?
    stored_id
  end

  def finish_summary_success(run_id:, artifact:, lease_owner: nil)
    kwargs = { run_id: run_id, artifact: artifact }
    parameters = @ledger.method(:finish_summary_success!).parameters
    accepts_owner = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :lease_owner } ||
                    parameters.any? { |kind, _name| kind == :keyrest }
    kwargs[:lease_owner] = lease_owner if accepts_owner && !lease_owner.to_s.empty?
    @ledger.finish_summary_success!(**kwargs)
  end

  def finish_summary_failed(run_id:, state:, reason:, lease_owner: nil)
    kwargs = { run_id: run_id, state: state, reason: reason }
    parameters = @ledger.method(:finish_summary_failed!).parameters
    accepts_owner = parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :lease_owner } ||
                    parameters.any? { |kind, _name| kind == :keyrest }
    kwargs[:lease_owner] = lease_owner if accepts_owner && !lease_owner.to_s.empty?
    @ledger.finish_summary_failed!(**kwargs)
  end

  def lease_loss_error?(error)
    error.message.to_s.match?(/lease|owner|not running/i)
  end

  def annotate_receipt(receipt, attempt_ordinal:, exchange_kind:, repair_from_receipt_id: nil)
    return receipt unless receipt.is_a?(Hash)

    receipt.merge(
      "prompt_version" => provider_prompt_version,
      "attempt_ordinal" => attempt_ordinal.to_i,
      "exchange_kind" => exchange_kind.to_s,
      "repair_from_receipt_id" => repair_from_receipt_id.to_s
    ).tap do |annotated|
      annotated.delete("repair_from_receipt_id") if repair_from_receipt_id.nil?
    end
  end

  def normalize_and_validate(value, citation_aliases:, context:, edition_id:)
    raw = normalize_provider_claim_shape(provider_content(value))
    raw = expand_citation_aliases(raw, citation_aliases)
    raw = project_provider_metadata(raw)
    legacy = ReportClaimGate.legacy_payload?(raw)
    raw = ReportClaimGate.adapt_legacy_payload(payload: raw, placements: context.fetch("placements")) if legacy
    raw = canonicalize_claim_ids(raw, edition_id: edition_id)
    raw = canonicalize_scope_ids(raw, edition_id: edition_id)
    raw = canonicalize_claim_statuses(raw)
    [validate_output(raw, placements: context.fetch("placements")), legacy]
  rescue ValidationError
    raise
  rescue ReportClaimGate::Error => error
    raise validation_error_from(error)
  rescue Error => error
    raise error
  end

  def repairable_validation?(error)
    error.is_a?(ValidationError) && REPAIRABLE_VALIDATION_CODES.include?(error.code.to_s)
  end

  def validation_error_from(error)
    message = error.message.to_s
    code = error.respond_to?(:code) && !error.code.to_s.empty? ? error.code.to_s : message[/\A([A-Z][A-Z0-9_]+)/, 1].to_s
    code = "CLAIM_ARTIFACT_SHAPE" if code.empty?
    ValidationError.new("claim gate blocked summary: #{message}", code: code, validation_message: message)
  end

  def sanitize_repair_json(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), result|
        key_string = key.to_s
        result[key_string] = SECRET_KEY_PATTERN.match?(key_string) ? "[REDACTED]" : sanitize_repair_json(child)
      end
    when Array
      value.map { |child| sanitize_repair_json(child) }
    else
      value
    end
  end

  # The repair exchange is a structural/reference correction only.  Every
  # repaired claim text must already occur in the initial model JSON (under
  # either the canonical text field or its explicitly supported summary alias)
  # so a repair cannot smuggle in a new assertion while fixing a shape error.
  def enforce_repair_no_new_facts!(original_json, repaired_json)
    original_texts = claim_text_values(original_json).map { |value| normalize_claim_text_for_id(value) }.uniq
    repaired_texts = claim_text_values(repaired_json).map { |value| normalize_claim_text_for_id(value) }.uniq
    added = repaired_texts - original_texts
    return if added.empty?

    raise Error, "summary repair attempted to add a new claim fact"
  end

  def claim_text_values(value)
    case value
    when Hash
      value.each_with_object([]) do |(key, child), result|
        if %w[text summary].include?(key.to_s) && child.is_a?(String)
          result << child
        else
          result.concat(claim_text_values(child))
        end
      end
    when Array
      value.flat_map { |child| claim_text_values(child) }
    else
      []
    end
  end

  def allowed_evidence(context, citation_aliases)
    placements = context.fetch("placements")
    rows = placements.map do |placement|
      {
        "version_id" => placement.fetch("version_id").to_s,
        "title" => placement.fetch("title", "").to_s,
        "summary" => placement.fetch("summary", "").to_s
      }
    end
    {
      "aliases" => citation_aliases.sort.to_h,
      "version_ids" => rows.map { |row| row.fetch("version_id") },
      "placements" => rows
    }
  end

  def frozen_output_schema
    {
      "type" => "object",
      "required" => %w[overview key_changes uncertainties],
      "additionalProperties" => false,
      "properties" => {
        "overview" => { "type" => "claim" },
        "key_changes" => { "type" => "array", "items" => { "type" => "claim" }, "maxItems" => 8 },
        "uncertainties" => { "type" => "array", "items" => { "type" => "claim" }, "maxItems" => 5 }
      },
      "claim" => {
        "type" => "object", "required" => %w[kind text evidence_scopes], "additionalProperties" => false,
        "properties" => {
          "kind" => { "enum" => ReportClaimGate::KINDS },
          "text" => { "type" => "string" },
          "evidence_scopes" => { "type" => "array", "items" => { "type" => "evidence_scope" }, "minItems" => 1 },
          "premise_scope_ids" => { "type" => "array", "items" => { "type" => "string" } },
          "inference_support_status" => { "const" => "supported" }
        }
      },
      "evidence_scope" => {
        "type" => "object", "required" => %w[version_id field text relation], "additionalProperties" => false,
        "properties" => {
          "version_id" => { "type" => "string" },
          "field" => { "enum" => ReportClaimGate::SCOPE_FIELDS }, "text" => { "type" => "string" },
          "relation" => { "enum" => ReportClaimGate::RELATIONS - ["unknown"] }
        }
      }
    }
  end

  def minimum_valid_example(context, citation_aliases)
    placement = context.fetch("placements").first
    return { "overview" => {}, "key_changes" => [], "uncertainties" => [] } unless placement

    version_id = placement.fetch("version_id").to_s
    excerpt = placement.fetch("summary", "").to_s
    field = "summary"
    if excerpt.empty?
      field = "title"
      excerpt = placement.fetch("title", "").to_s
    end
    alias_id = citation_aliases.key(version_id) || version_id
    {
      "overview" => {
        "kind" => "fact", "text" => "仅保留原始证据支持的陈述",
        "evidence_scopes" => [{ "version_id" => alias_id, "field" => field, "text" => excerpt, "relation" => "supports" }]
      },
      "key_changes" => [], "uncertainties" => []
    }
  end

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
        raise ValidationError.new("claim text alias conflict: text and summary differ",
                                  code: "CLAIM_TEXT_ALIAS_CONFLICT")
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

  # Provider scope IDs are untrusted labels.  They are deliberately ignored
  # for identity and replaced after the server-owned claim_id is available.
  # The canonical scope identity binds the immutable edition, claim, ordinal,
  # referenced version/field, normalized excerpt (the locatable span), and
  # relation.  Thus malformed, duplicate, missing, or adversarial provider
  # IDs cannot alter identity, while a forged version/excerpt still reaches
  # ReportClaimGate's edition-placement and locatability checks.
  def canonicalize_scope_ids(payload, edition_id:)
    return payload unless payload.is_a?(Hash)

    copy = JSON.parse(JSON.generate(payload))
    copy["overview"] = canonicalize_scope_ids_for_claim(copy["overview"], edition_id: edition_id) if copy.key?("overview")
    %w[key_changes uncertainties].each do |section|
      next unless copy[section].is_a?(Array)

      copy[section] = copy[section].map do |claim|
        canonicalize_scope_ids_for_claim(claim, edition_id: edition_id)
      end
    end
    copy
  rescue JSON::GeneratorError, JSON::ParserError, TypeError
    payload
  end

  def canonicalize_scope_ids_for_claim(unit, edition_id:)
    return unit unless unit.is_a?(Hash)

    normalized_claim = unit.transform_keys(&:to_s)
    claim_id = normalized_claim["claim_id"].to_s
    scopes = normalized_claim["evidence_scopes"]
    return normalized_claim unless scopes.is_a?(Array)

    original_scope_ids = Hash.new { |hash, key| hash[key] = [] }
    canonical_scope_ids = []
    normalized_scopes = scopes.each_with_index.map do |scope, ordinal|
      unless scope.is_a?(Hash)
        canonical_scope_ids << nil
        next scope
      end

      scope = scope.transform_keys(&:to_s)
      provider_scope_id = scope["scope_id"].to_s
      original_scope_ids[provider_scope_id] << ordinal unless provider_scope_id.empty?
      canonical_id = canonical_scope_id(scope, edition_id: edition_id, claim_id: claim_id, ordinal: ordinal)
      canonical_scope_ids << canonical_id
      scope.merge("scope_id" => canonical_id)
    end
    normalized_claim["evidence_scopes"] = normalized_scopes

    # AI-inference premises historically referenced provider scope IDs. Map a
    # provider ID only when it identifies exactly one scope; duplicate or
    # missing labels remain unresolved and are rejected by the gate rather than
    # being guessed. Canonical IDs are accepted for already-canonical callers.
    if normalized_claim["premise_scope_ids"].is_a?(Array)
      normalized_claim["premise_scope_ids"] = normalized_claim["premise_scope_ids"].map do |premise_id|
        value = premise_id.to_s
        if canonical_scope_ids.include?(value)
          value
        elsif original_scope_ids.fetch(value, []).length == 1
          canonical_scope_ids.fetch(original_scope_ids.fetch(value).first)
        else
          value
        end
      end
    end
    normalized_claim
  end

  def canonical_scope_id(scope, edition_id:, claim_id:, ordinal:)
    canonical_input = {
      "namespace" => "report-summary-scope",
      "version" => "v1",
      "edition_id" => edition_id.to_s,
      "claim_id" => claim_id.to_s,
      "scope_ordinal" => ordinal.to_i,
      "version_id" => scope["version_id"].to_s,
      "field" => scope["field"].to_s,
      "excerpt" => normalize_claim_text_for_id(scope["text"]),
      "relation" => scope["relation"].to_s
    }
    "scope-report-summary-v1-#{Digest::SHA256.hexdigest(JSON.generate(canonical_input))}"
  end

  def canonical_claim_id(claim, edition_id:, section:, ordinal:)
    evidence = Array(claim["evidence_scopes"]).map do |scope|
      identity = if scope.is_a?(Hash)
                   # scope_id is server-owned and is intentionally excluded
                   # from claim identity; provider labels must not affect the
                   # canonical claim_id.
                   scope.transform_keys(&:to_s).reject { |key, _value| key == "scope_id" }.sort.to_h
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

  # The provider does not own epistemic status.  Derive only an allowed status
  # from a legal kind and a complete set of legal evidence relations; malformed
  # kinds/scopes are left untouched so ReportClaimGate fails closed.  This
  # never upgrades a claim to fact or fabricates evidence.
  def canonicalize_claim_statuses(payload)
    return payload unless payload.is_a?(Hash)

    copy = JSON.parse(JSON.generate(payload))
    copy["overview"] = canonicalize_claim_status(copy["overview"]) if copy.key?("overview")
    %w[key_changes uncertainties].each do |section|
      next unless copy[section].is_a?(Array)

      copy[section] = copy[section].map { |unit| canonicalize_claim_status(unit) }
    end
    copy
  rescue JSON::GeneratorError, JSON::ParserError, TypeError
    payload
  end

  def canonicalize_claim_status(unit)
    return unit unless unit.is_a?(Hash)

    normalized = unit.transform_keys(&:to_s)
    kind = normalized["kind"].to_s
    return normalized unless ReportClaimGate::KINDS.include?(kind)

    scopes = normalized["evidence_scopes"]
    return normalized unless scopes.is_a?(Array) && !scopes.empty? && scopes.all? { |scope| scope.is_a?(Hash) }

    relations = scopes.map { |scope| scope.transform_keys(&:to_s).fetch("relation", "").to_s }
    return normalized unless relations.all? { |relation| ReportClaimGate::RELATIONS.include?(relation) }
    return normalized unless relations.include?("supports")

    normalized["epistemic_status"] = if kind == "uncertainty"
                                       "unknown"
                                     elsif relations.include?("contradicts")
                                       "disputed"
                                     else
                                       "asserted"
                                     end
    normalized
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

  def terminal_blocked(run, reason, lease_owner: nil)
    blocked = finish_summary_failed(run_id: run.fetch("run_id"), state: "blocked", reason: reason,
                                    lease_owner: lease_owner)
    { "status" => "blocked", "run" => blocked, "artifact" => nil }
  end

  def validate_output(payload, placements:)
    ReportClaimGate.validate_artifact!(payload: payload, placements: placements)
  rescue ReportClaimGate::Error => error
    raise validation_error_from(error)
  end

  def provider_receipt(error = nil)
    receipt = @provider.respond_to?(:last_receipt) ? @provider.last_receipt : nil
    return receipt if receipt.is_a?(Hash)
    if error && error.respond_to?(:receipt) && error.receipt.is_a?(Hash)
      return error.receipt
    end
    return nil unless @provider.respond_to?(:provider_name) && @provider.provider_name.to_s == "deepseek"

    raise Error, "provider response receipt missing"
  end
end
