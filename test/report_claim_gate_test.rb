# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/report_claim_gate"

class ReportClaimGateTest < Minitest::Test
  PLACEMENTS = [{ "version_id" => "v1", "title" => "A title", "summary" => "A summary with exact evidence" }].freeze

  def scope(relation: "supports", text: "A summary with exact evidence", id: "scope-1")
    { "scope_id" => id, "version_id" => "v1", "field" => "summary", "text" => text, "relation" => relation }
  end

  def claim(kind: "fact", scopes: [scope], **extra)
    { "claim_id" => "claim-1", "kind" => kind, "text" => "A claim", "epistemic_status" => "asserted", "evidence_scopes" => scopes }.merge(extra)
  end

  def artifact(claims: [claim])
    { "overview" => claims.fetch(0), "key_changes" => [], "uncertainties" => [] }
  end

  def test_typed_fact_requires_locatable_support_scope
    normalized = ReportClaimGate.validate_artifact!(payload: artifact, placements: PLACEMENTS)
    assert_equal "fact", normalized.dig("overview", "kind")
    assert_equal "supports", normalized.dig("overview", "evidence_scopes", 0, "relation")
  end

  def test_unknown_relation_is_blocked
    error = assert_raises(ReportClaimGate::Error) do
      ReportClaimGate.validate_artifact!(payload: artifact(claims: [claim(scopes: [scope(relation: "unknown")])]), placements: PLACEMENTS)
    end
    assert_match(/UNKNOWN|unknown|relation/, error.message)
  end

  def test_edition_metadata_is_not_a_claim_gate_field
    payload = artifact(claims: [claim.merge(
      "edition_id" => "edition-1", "nominal_window_start" => "2026-08-09T19:00:00Z",
      "nominal_window_end" => "2026-08-10T08:00:00Z", "raw_item_count" => 1,
      "provider_item_count" => 1
    )])
    error = assert_raises(ReportClaimGate::Error) do
      ReportClaimGate.validate_artifact!(payload: payload, placements: PLACEMENTS)
    end
    assert_match(/unknown keys .*edition_id/, error.message)
  end

  def test_unrelated_scope_text_is_blocked
    error = assert_raises(ReportClaimGate::Error) do
      ReportClaimGate.validate_artifact!(payload: artifact(claims: [claim(scopes: [scope(text: "not in archive")])]), placements: PLACEMENTS)
    end
    assert_match(/LOCATABLE|locatable/, error.message)
  end

  def test_source_claim_cannot_be_written_as_inference_or_fact_without_typed_kind
    source = claim(kind: "source_claim", text: "The source claims A")
    assert_equal "source_claim", ReportClaimGate.validate_artifact!(payload: artifact(claims: [source]), placements: PLACEMENTS).dig("overview", "kind")
  end

  def test_ai_inference_requires_supported_premise_scope
    inference = claim(kind: "ai_inference", premise_scope_ids: ["scope-1"], inference_support_status: "supported")
    assert_equal "ai_inference", ReportClaimGate.validate_artifact!(payload: artifact(claims: [inference]), placements: PLACEMENTS).dig("overview", "kind")
    unsupported = inference.merge("inference_support_status" => "unsupported")
    assert_raises(ReportClaimGate::Error) { ReportClaimGate.validate_artifact!(payload: artifact(claims: [unsupported]), placements: PLACEMENTS) }
  end

  def test_legacy_payload_is_adapted_but_marked_by_runner
    payload = { "overview" => { "text" => "legacy", "cited_version_ids" => ["v1"] }, "key_changes" => [], "uncertainties" => [] }
    assert ReportClaimGate.legacy_payload?(payload)
    adapted = ReportClaimGate.adapt_legacy_payload(payload: payload, placements: PLACEMENTS)
    assert_equal "claim-legacy-", adapted.fetch("overview").fetch("claim_id")[0, 13]
    assert_equal "fact", adapted.dig("overview", "kind")
  end

  def test_legacy_summary_alias_is_adapted_from_edition_placement
    payload = { "overview" => { "summary" => "legacy", "cited_version_ids" => ["v1"] }, "key_changes" => [], "uncertainties" => [] }
    assert ReportClaimGate.legacy_payload?(payload)
    adapted = ReportClaimGate.adapt_legacy_payload(payload: payload, placements: PLACEMENTS)
    assert_equal "legacy", adapted.dig("overview", "text")
    assert_equal "v1", adapted.dig("overview", "evidence_scopes", 0, "version_id")
  end

  def test_legacy_adapter_rejects_missing_citation_and_unknown_unit_keys
    no_citation = { "overview" => { "summary" => "legacy", "cited_version_ids" => [] }, "key_changes" => [], "uncertainties" => [] }
    assert ReportClaimGate.legacy_payload?(no_citation)
    assert_raises(ReportClaimGate::Error) do
      ReportClaimGate.adapt_legacy_payload(payload: no_citation, placements: PLACEMENTS)
    end

    unknown = { "overview" => { "summary" => "legacy", "cited_version_ids" => ["v1"], "wrapper" => true }, "key_changes" => [], "uncertainties" => [] }
    refute ReportClaimGate.legacy_payload?(unknown)
  end
end
