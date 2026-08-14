# frozen_string_literal: true

require "digest"
require "json"

# Fail-closed validation for the replaceable report-summary projection.
#
# The raw report edition remains an immutable archive.  This gate only accepts
# atomic claims that retain a stable identity, a typed epistemic kind, and a
# locatable field-level scope into that edition.  It intentionally does not
# attempt to prove a claim by language understanding; it verifies the
# provider's declared scope and relation contract and rejects anything that
# cannot be replayed against the archived title/summary fields.
class ReportClaimGate
  class Error < StandardError; end

  KINDS = %w[fact source_claim ai_inference uncertainty].freeze
  EPISTEMIC_STATUSES = %w[asserted disputed retracted unknown].freeze
  RELATIONS = %w[supports contradicts alternative unknown].freeze
  SCOPE_FIELDS = %w[title summary].freeze
  INFERENCE_SUPPORT_STATUSES = %w[supported unsupported uncertain].freeze
  LEGACY_UNIT_KEYS = [
    %w[cited_version_ids text].freeze,
    %w[cited_version_ids summary].freeze
  ].freeze

  class << self

  def validate_artifact!(payload:, placements:)
    raise Error, "CLAIM_ARTIFACT_SHAPE: payload must be an object" unless payload.is_a?(Hash)

    expected = %w[overview key_changes uncertainties]
    raise Error, "CLAIM_ARTIFACT_SHAPE: unknown or missing top-level keys" unless payload.keys.map(&:to_s).sort == expected.sort
    raise Error, "CLAIM_ARTIFACT_SHAPE: key_changes and uncertainties must be arrays" unless payload.fetch("key_changes").is_a?(Array) && payload.fetch("uncertainties").is_a?(Array)

    rows = []
    rows << validate_claim(payload.fetch("overview"), placements: placements, location: "overview")
    Array(payload.fetch("key_changes")).each_with_index do |claim, index|
      rows << validate_claim(claim, placements: placements, location: "key_changes[#{index}]")
    end
    Array(payload.fetch("uncertainties")).each_with_index do |claim, index|
      rows << validate_claim(claim, placements: placements, location: "uncertainties[#{index}]")
    end
    ids = rows.map { |claim| claim.fetch("claim_id") }
    raise Error, "CLAIM_ID_DUPLICATE: claim_id must be unique" unless ids.uniq.length == ids.length
    {
      "overview" => rows.fetch(0),
      "key_changes" => rows.select.with_index { |_claim, index| index.positive? && index <= Array(payload.fetch("key_changes")).length },
      "uncertainties" => rows.last(Array(payload.fetch("uncertainties")).length)
    }.tap do |normalized|
      # The select/last expressions above keep the original section boundary
      # without retaining provider-owned hashes or unknown keys.
      normalized["key_changes"] = Array(payload.fetch("key_changes")).each_with_index.map do |claim, index|
        rows.fetch(1 + index)
      end
      offset = 1 + Array(payload.fetch("key_changes")).length
      normalized["uncertainties"] = Array(payload.fetch("uncertainties")).each_index.map do |index|
        rows.fetch(offset + index)
      end
    end
  rescue KeyError, TypeError => error
    raise Error, "CLAIM_ARTIFACT_SHAPE: #{error.message}"
  end

  def validate_claim(claim, placements:, location: "claim")
    raise Error, "CLAIM_SHAPE: #{location} must be an object" unless claim.is_a?(Hash)
    claim = claim.transform_keys(&:to_s)
    allowed = %w[claim_id kind text epistemic_status evidence_scopes premise_scope_ids inference_support_status]
    unknown = claim.keys.map(&:to_s) - allowed
    missing = %w[claim_id kind text epistemic_status evidence_scopes].reject { |key| claim.key?(key) }
    raise Error, "CLAIM_SHAPE: #{location} unknown keys #{unknown.join(', ')}" unless unknown.empty?
    raise Error, "CLAIM_SHAPE: #{location} missing #{missing.join(', ')}" unless missing.empty?

    claim_id = claim.fetch("claim_id").to_s
    raise Error, "CLAIM_ID_INVALID: #{location}" unless claim_id.match?(/\Aclaim-[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
    kind = claim.fetch("kind").to_s
    raise Error, "CLAIM_KIND_INVALID: #{location}" unless KINDS.include?(kind)
    text = claim.fetch("text")
    raise Error, "CLAIM_TEXT_MISSING: #{location}" unless text.is_a?(String) && !text.strip.empty?
    epistemic_status = claim.fetch("epistemic_status").to_s
    raise Error, "CLAIM_EPISTEMIC_STATUS_INVALID: #{location}" unless EPISTEMIC_STATUSES.include?(epistemic_status)

    placement_by_id = Array(placements).to_h { |row| [row.fetch("version_id").to_s, row] }
    scopes = Array(claim.fetch("evidence_scopes"))
    raise Error, "CLAIM_EVIDENCE_MISSING: #{location}" if scopes.empty?
    normalized_scopes = scopes.each_with_index.map do |scope, index|
      validate_scope(scope, placement_by_id: placement_by_id, location: "#{location}.evidence_scopes[#{index}]")
    end
    scope_ids = normalized_scopes.map { |scope| scope.fetch("scope_id") }
    raise Error, "CLAIM_SCOPE_ID_DUPLICATE: #{location}" unless scope_ids.uniq.length == scope_ids.length
    relations = normalized_scopes.map { |scope| scope.fetch("relation") }
    raise Error, "CLAIM_EVIDENCE_UNKNOWN: #{location}" if relations.include?("unknown")
    raise Error, "CLAIM_EVIDENCE_SUPPORT_MISSING: #{location}" unless relations.include?("supports")
    if relations.include?("contradicts") && !%w[disputed unknown retracted].include?(epistemic_status)
      raise Error, "CLAIM_CONTRADICTION_UNDECLARED: #{location}"
    end
    if relations.include?("alternative") && !relations.include?("supports")
      raise Error, "CLAIM_ALTERNATIVE_UNSUPPORTED: #{location}"
    end

    premise_ids = Array(claim.fetch("premise_scope_ids", [])).map(&:to_s)
    support_status = claim["inference_support_status"]&.to_s
    if kind == "ai_inference"
      raise Error, "INFERENCE_PREMISE_MISSING: #{location}" if premise_ids.empty?
      raise Error, "INFERENCE_SUPPORT_STATUS_INVALID: #{location}" unless support_status == "supported"
      missing_premises = premise_ids - scope_ids
      raise Error, "INFERENCE_PREMISE_SCOPE_MISSING: #{location}" unless missing_premises.empty?
      premise_scopes = normalized_scopes.select { |scope| premise_ids.include?(scope.fetch("scope_id")) }
      unless premise_scopes.all? { |scope| scope.fetch("relation") == "supports" }
        raise Error, "INFERENCE_PREMISE_NOT_SUPPORTED: #{location}"
      end
    elsif !premise_ids.empty? || !support_status.to_s.empty?
      raise Error, "CLAIM_INFERENCE_FIELDS_FORBIDDEN: #{location}"
    end

    {
      "claim_id" => claim_id,
      "kind" => kind,
      "text" => text,
      "epistemic_status" => epistemic_status,
      "evidence_scopes" => normalized_scopes,
      "premise_scope_ids" => premise_ids,
      "inference_support_status" => support_status
    }.tap do |normalized|
      normalized.delete("premise_scope_ids") if premise_ids.empty?
      normalized.delete("inference_support_status") if support_status.to_s.empty?
    end
  rescue KeyError, TypeError => error
    raise Error, "CLAIM_SHAPE: #{location} #{error.message}"
  end

  def validate_scope(scope, placement_by_id:, location:)
    raise Error, "CLAIM_SCOPE_SHAPE: #{location} must be an object" unless scope.is_a?(Hash)
    scope = scope.transform_keys(&:to_s)
    allowed = %w[scope_id version_id field text relation]
    unknown = scope.keys.map(&:to_s) - allowed
    missing = allowed.reject { |key| scope.key?(key) }
    raise Error, "CLAIM_SCOPE_SHAPE: #{location} unknown keys #{unknown.join(', ')}" unless unknown.empty?
    raise Error, "CLAIM_SCOPE_SHAPE: #{location} missing #{missing.join(', ')}" unless missing.empty?

    scope_id = scope.fetch("scope_id").to_s
    raise Error, "CLAIM_SCOPE_ID_INVALID: #{location}" unless scope_id.match?(/\Ascope-[A-Za-z0-9][A-Za-z0-9_.:-]{0,160}\z/)
    version_id = scope.fetch("version_id").to_s
    placement = placement_by_id[version_id]
    raise Error, "CLAIM_SCOPE_VERSION_UNKNOWN: #{location}" unless placement
    field = scope.fetch("field").to_s
    raise Error, "CLAIM_SCOPE_FIELD_INVALID: #{location}" unless SCOPE_FIELDS.include?(field)
    relation = scope.fetch("relation").to_s
    raise Error, "CLAIM_RELATION_INVALID: #{location}" unless RELATIONS.include?(relation)
    excerpt = scope.fetch("text")
    raise Error, "CLAIM_SCOPE_TEXT_MISSING: #{location}" unless excerpt.is_a?(String) && !excerpt.strip.empty?
    source_text = placement.fetch(field, "").to_s
    raise Error, "CLAIM_SCOPE_NOT_LOCATABLE: #{location}" unless source_text.include?(excerpt)
    {
      "scope_id" => scope_id,
      "version_id" => version_id,
      "field" => field,
      "text" => excerpt,
      "relation" => relation
    }
  end

  def legacy_payload?(payload)
    return false unless payload.is_a?(Hash)
    normalized = payload.transform_keys(&:to_s)
    return false unless normalized.keys.sort == %w[overview key_changes uncertainties].sort
    return false unless legacy_unit?(normalized["overview"])
    %w[key_changes uncertainties].all? do |section|
      normalized[section].is_a?(Array) && normalized[section].all? { |unit| legacy_unit?(unit) }
    end
  end

  def adapt_legacy_payload(payload:, placements:)
    raise Error, "LEGACY_PAYLOAD_UNSUPPORTED" unless legacy_payload?(payload)
    placement_by_id = Array(placements).to_h { |row| [row.fetch("version_id").to_s, row] }
    convert = lambda do |unit, section, index|
      unit = unit.transform_keys(&:to_s)
      citations = unit.fetch("cited_version_ids")
      raise Error, "LEGACY_CITATION_MISSING: #{section}[#{index}]" unless citations.is_a?(Array) && !citations.empty?
      citations = citations.map(&:to_s)
      raise Error, "LEGACY_CITATION_MISSING: #{section}[#{index}]" if citations.any?(&:empty?)
      text = if unit.key?("text")
               unit.fetch("text")
             else
               unit.fetch("summary")
             end
      raise Error, "LEGACY_TEXT_MISSING: #{section}[#{index}]" unless text.is_a?(String) && !text.strip.empty?
      scopes = citations.each_with_index.map do |version_id, scope_index|
        placement = placement_by_id.fetch(version_id) { raise Error, "CLAIM_SCOPE_VERSION_UNKNOWN: #{version_id}" }
        field = placement.fetch("summary", "").to_s.empty? ? "title" : "summary"
        excerpt = placement.fetch(field).to_s
        {
          "scope_id" => "scope-legacy-#{Digest::SHA256.hexdigest([section, index, scope_index, version_id].join("\u0000"))[0, 24]}",
          "version_id" => version_id, "field" => field, "text" => excerpt, "relation" => "supports"
        }
      end
      {
        "claim_id" => "claim-legacy-#{Digest::SHA256.hexdigest([section, index, text].join("\u0000"))[0, 24]}",
        "kind" => section == "uncertainties" ? "uncertainty" : "fact",
        "text" => text,
        "epistemic_status" => section == "uncertainties" ? "unknown" : "asserted",
        "evidence_scopes" => scopes
      }
    end
    {
      "overview" => convert.call(payload.fetch("overview"), "overview", 0),
      "key_changes" => Array(payload.fetch("key_changes")).each_with_index.map { |unit, index| convert.call(unit, "key_changes", index) },
      "uncertainties" => Array(payload.fetch("uncertainties")).each_with_index.map { |unit, index| convert.call(unit, "uncertainties", index) }
    }
  end

  def legacy_unit?(unit)
    return false unless unit.is_a?(Hash)

    LEGACY_UNIT_KEYS.include?(unit.keys.map(&:to_s).sort)
  end
  end
end
