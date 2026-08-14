# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/report_summary_runner"

class ReportSummaryRunnerTest < Minitest::Test
  class FakeProvider
    attr_reader :calls, :last_input

    def initialize(result:, available: true)
      @result = result
      @available = available
      @calls = 0
    end

    def provider_name; "fake"; end
    def model; "fake-model"; end
    def prompt_version; "fake-v1"; end
    def available?; @available; end

    def summarize(input:)
      @calls += 1
      @last_input = input
      @result
    end
  end

  class ReceiptProvider < FakeProvider
    def initialize(result:, receipt:)
      super(result: result)
      @receipt = receipt
    end

    def last_receipt
      @receipt
    end
  end

  class FakeLedger
    attr_reader :runs

    def initialize(placements: [{ "version_id" => "version-1", "content_hash" => "hash", "title" => "Title", "summary" => "Summary", "publisher" => "Publisher", "language" => "en", "sort_order" => 0 }])
      @context = { "edition_id" => "edition-1", "boundary" => { "data_cutoff" => "2026-08-10T00:00:00Z" }, "placements" => placements }
      @runs = {}
      @artifacts = {}
    end

    def report_summary_context(edition_id:)
      raise "wrong edition" unless edition_id == "edition-1"

      @context
    end

    def append_summary_run!(edition_id:, idempotency_key:, input_hash:, provider:, model:, prompt_version:)
      @runs[idempotency_key] ||= {
        "run_id" => "run-#{idempotency_key}", "edition_id" => edition_id, "idempotency_key" => idempotency_key,
        "input_hash" => input_hash, "provider" => provider, "model" => model, "prompt_version" => prompt_version,
        "state" => "running"
      }
    end

    def finish_summary_failed!(run_id:, state:, reason:)
      run = @runs.values.find { |row| row.fetch("run_id") == run_id }
      run.merge!("state" => state, "error_reason" => reason)
    end

    def finish_summary_success!(run_id:, artifact:)
      run = @runs.values.find { |row| row.fetch("run_id") == run_id }
      stored = artifact.merge("created_at" => "2026-08-10T00:00:00Z")
      @artifacts[run_id] = stored
      run.merge!("state" => "succeeded")
      { "run" => run, "artifact" => stored }
    end

    def summary_artifact_for_run(run_id:)
      @artifacts.fetch(run_id)
    end
  end

  def unit(text: "text", citations: ["version-1"])
    { "text" => text, "cited_version_ids" => citations }
  end

  def typed_claim(text: "A typed claim")
    {
      "claim_id" => "claim-typed-1",
      "kind" => "fact",
      "text" => text,
      "epistemic_status" => "asserted",
      "evidence_scopes" => [{
        "scope_id" => "scope-typed-1", "version_id" => "version-1", "field" => "summary",
        "text" => "Summary", "relation" => "supports"
      }]
    }
  end

  def legacy_summary_payload(overview: "Legacy overview", key_changes: [], uncertainties: [])
    {
      "overview" => { "summary" => overview, "cited_version_ids" => ["version-1"] },
      "key_changes" => key_changes,
      "uncertainties" => uncertainties
    }
  end

  def test_empty_edition_blocks_without_calling_provider
    provider = FakeProvider.new(result: {})
    ledger = FakeLedger.new(placements: [])
    result = ReportSummaryRunner.new(ledger: ledger, provider: provider).run(edition_id: "edition-1", idempotency_key: "empty")
    assert_equal "blocked", result.fetch("status")
    assert_equal 0, provider.calls
  end

  def test_success_is_idempotent_and_cites_edition_version
    provider = FakeProvider.new(result: { "overview" => unit, "key_changes" => [], "uncertainties" => [] })
    ledger = FakeLedger.new
    runner = ReportSummaryRunner.new(ledger: ledger, provider: provider)
    first = runner.run(edition_id: "edition-1", idempotency_key: "same")
    replay = runner.run(edition_id: "edition-1", idempotency_key: "same")
    assert_equal "succeeded", first.fetch("status")
    assert_equal first.fetch("artifact").fetch("output_hash"), replay.fetch("artifact").fetch("output_hash")
    assert_equal 1, provider.calls
  end

  def test_unknown_citation_fails_without_artifact
    provider = FakeProvider.new(result: { "overview" => unit(citations: ["unknown"]), "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "bad")
    assert_equal "failed", result.fetch("status")
    assert_nil result.fetch("artifact")
  end

  def test_complete_claim_can_drop_the_five_echoed_edition_metadata_fields
    echoed_metadata = {
      "edition_id" => "edition-1", "nominal_window_start" => "2026-08-09T19:00:00Z",
      "nominal_window_end" => "2026-08-10T08:00:00Z", "raw_item_count" => 1,
      "provider_item_count" => 1
    }
    provider = FakeProvider.new(result: {
      "overview" => typed_claim.merge(echoed_metadata), "key_changes" => [], "uncertainties" => []
    })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "metadata")

    assert_equal "succeeded", result.fetch("status")
    refute result.dig("artifact", "overview").keys.any? { |key| echoed_metadata.key?(key) }
    assert_match(/\Aclaim-report-summary-v1-[a-f0-9]{64}\z/, result.dig("artifact", "overview", "claim_id"))
    refute_equal "claim-typed-1", result.dig("artifact", "overview", "claim_id")
  end

  def test_server_owned_claim_id_can_be_omitted_before_metadata_projection
    echoed_metadata = {
      "edition_id" => "edition-1", "nominal_window_start" => "2026-08-09T19:00:00Z",
      "nominal_window_end" => "2026-08-10T08:00:00Z", "raw_item_count" => 1,
      "provider_item_count" => 1
    }
    provider_claim = typed_claim.reject { |key, _value| key == "claim_id" }.merge(echoed_metadata)
    provider = FakeProvider.new(result: { "overview" => provider_claim, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "server-owned-claim-id")

    assert_equal "succeeded", result.fetch("status")
    assert_match(/\Aclaim-report-summary-v1-[a-f0-9]{64}\z/, result.dig("artifact", "overview", "claim_id"))
  end

  def test_provider_status_is_ignored_when_kind_and_supporting_evidence_are_complete
    provider_claim = typed_claim.merge("epistemic_status" => "attributed")
    provider = FakeProvider.new(result: { "overview" => provider_claim, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "status-invalid")

    assert_equal "succeeded", result.fetch("status")
    assert_equal "asserted", result.dig("artifact", "overview", "epistemic_status")
  end

  def test_missing_status_is_derived_and_uncertainty_maps_to_unknown
    provider_claim = typed_claim.reject { |key, _value| %w[claim_id epistemic_status].include?(key) }
                         .merge("kind" => "uncertainty")
    provider = FakeProvider.new(result: { "overview" => provider_claim, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "status-missing")

    assert_equal "succeeded", result.fetch("status")
    assert_equal "unknown", result.dig("artifact", "overview", "epistemic_status")
  end

  def test_contradictory_evidence_derives_disputed_status
    contradiction = typed_claim.merge(
      "epistemic_status" => "made-up",
      "evidence_scopes" => [
        typed_claim.fetch("evidence_scopes").first,
        typed_claim.fetch("evidence_scopes").first.merge("scope_id" => "scope-typed-2", "relation" => "contradicts")
      ]
    )
    provider = FakeProvider.new(result: { "overview" => contradiction, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "status-disputed")

    assert_equal "succeeded", result.fetch("status")
    assert_equal "disputed", result.dig("artifact", "overview", "epistemic_status")
  end

  def test_status_cannot_repair_missing_support_or_invalid_kind
    no_support = typed_claim.merge(
      "epistemic_status" => "asserted",
      "evidence_scopes" => [typed_claim.fetch("evidence_scopes").first.merge("relation" => "alternative")]
    )
    bad_kind = typed_claim.merge("kind" => "fact-ish", "epistemic_status" => "asserted")
    provider = FakeProvider.new(result: { "overview" => no_support, "key_changes" => [bad_kind], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "status-failclosed")

    assert_equal "failed", result.fetch("status")
    assert_nil result.fetch("artifact")
  end

  def test_metadata_projection_does_not_fill_missing_claim_core_fields
    echoed_metadata = {
      "edition_id" => "edition-1", "nominal_window_start" => "2026-08-09T19:00:00Z",
      "nominal_window_end" => "2026-08-10T08:00:00Z", "raw_item_count" => 1,
      "provider_item_count" => 1
    }
    incomplete = typed_claim.reject { |key, _value| key == "text" }.merge(echoed_metadata)
    provider = FakeProvider.new(result: { "overview" => incomplete, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "metadata-missing-core")

    assert_equal "failed", result.fetch("status")
    assert_match(/CLAIM_SHAPE|CLAIM_TEXT_MISSING/, result.dig("run", "error_reason"))
    assert_nil result.fetch("artifact")
  end

  def test_unrelated_unknown_claim_key_remains_rejected
    provider = FakeProvider.new(result: {
      "overview" => typed_claim.merge("edition_id" => "edition-1", "unrelated" => "not metadata"),
      "key_changes" => [], "uncertainties" => []
    })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "metadata-unknown")

    assert_equal "failed", result.fetch("status")
    assert_match(/unknown keys .*unrelated/, result.dig("run", "error_reason"))
    assert_nil result.fetch("artifact")
  end

  def test_typed_claim_summary_alias_is_normalized_to_text
    claim = typed_claim.reject { |key, _value| key == "text" }.merge("summary" => "A typed claim")
    provider = FakeProvider.new(result: { "overview" => claim, "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "summary-alias")

    assert_equal "succeeded", result.fetch("status")
    assert_equal "A typed claim", result.dig("artifact", "overview", "text")
    refute result.dig("artifact", "overview").key?("summary")
  end

  def test_equal_text_and_summary_are_accepted_but_different_values_fail
    equal_provider = FakeProvider.new(result: {
      "overview" => typed_claim.merge("summary" => "A typed claim"), "key_changes" => [], "uncertainties" => []
    })
    equal = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: equal_provider).run(edition_id: "edition-1", idempotency_key: "summary-alias-equal")
    assert_equal "succeeded", equal.fetch("status")

    conflict_provider = FakeProvider.new(result: {
      "overview" => typed_claim.merge("summary" => "different"), "key_changes" => [], "uncertainties" => []
    })
    conflict = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: conflict_provider).run(edition_id: "edition-1", idempotency_key: "summary-alias-conflict")
    assert_equal "failed", conflict.fetch("status")
    assert_match(/alias conflict/, conflict.dig("run", "error_reason"))
    assert_nil conflict.fetch("artifact")
  end

  def test_legacy_summary_shape_is_adapted_with_edition_evidence
    payload = legacy_summary_payload(
      key_changes: [{ "summary" => "Summary", "cited_version_ids" => ["version-1"] }],
      uncertainties: [{ "summary" => "Summary", "cited_version_ids" => ["version-1"] }]
    )
    provider = FakeProvider.new(result: payload)
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "legacy-summary")

    assert_equal "succeeded", result.fetch("status")
    assert_equal "legacy_unverified", result.dig("artifact", "claim_gate_status")
    assert_equal "Legacy overview", result.dig("artifact", "overview", "text")
    assert_equal "version-1", result.dig("artifact", "overview", "evidence_scopes", 0, "version_id")
  end

  def test_summary_without_citation_does_not_get_typed_claim_fields
    payload = { "overview" => { "summary" => "No citation" }, "key_changes" => [], "uncertainties" => [] }
    provider = FakeProvider.new(result: payload)
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "summary-no-citation")

    assert_equal "failed", result.fetch("status")
    assert_nil result.fetch("artifact")
  end

  def test_overview_claim_wrapper_is_allowed_only_for_one_claim
    wrapped = { "overview" => { "claim" => typed_claim.merge("summary" => "A typed claim") }, "key_changes" => [], "uncertainties" => [] }
    provider = FakeProvider.new(result: wrapped)
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "claim-wrapper")
    assert_equal "succeeded", result.fetch("status")
    assert_equal "A typed claim", result.dig("artifact", "overview", "text")

    unknown_wrapper = { "overview" => { "claim" => typed_claim, "wrapper" => "unexpected" }, "key_changes" => [], "uncertainties" => [] }
    bad_provider = FakeProvider.new(result: unknown_wrapper)
    bad = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: bad_provider).run(edition_id: "edition-1", idempotency_key: "claim-wrapper-unknown")
    assert_equal "failed", bad.fetch("status")
    assert_nil bad.fetch("artifact")
  end

  def test_provider_invalid_or_duplicate_claim_ids_are_ignored_and_canonical_ids_are_unique
    first = typed_claim.merge("claim_id" => "not-a-claim-id")
    second = typed_claim(text: "A second typed claim").merge("claim_id" => "not-a-claim-id")
    provider = FakeProvider.new(result: {
      "overview" => first, "key_changes" => [second], "uncertainties" => []
    })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: provider).run(edition_id: "edition-1", idempotency_key: "canonical-malicious-ids")

    assert_equal "succeeded", result.fetch("status")
    ids = [result.dig("artifact", "overview", "claim_id"), result.dig("artifact", "key_changes", 0, "claim_id")]
    assert_equal 2, ids.uniq.length
    ids.each { |id| assert_match(/\Aclaim-report-summary-v1-[a-f0-9]{64}\z/, id) }
  end

  def test_canonical_claim_id_is_stable_and_changes_with_edition_text_evidence_or_ordinal
    runner = ReportSummaryRunner.new(ledger: FakeLedger.new, provider: FakeProvider.new(result: {}))
    base = typed_claim
    same_provider_id = base.merge("claim_id" => "another-provider-id")
    first = runner.send(:canonicalize_claim_ids, { "overview" => base, "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    second = runner.send(:canonicalize_claim_ids, { "overview" => same_provider_id, "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    assert_equal first.dig("overview", "claim_id"), second.dig("overview", "claim_id")
    whitespace_only = runner.send(:canonicalize_claim_ids, { "overview" => base.merge("text" => "  A   typed claim  "), "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    assert_equal first.dig("overview", "claim_id"), whitespace_only.dig("overview", "claim_id")
    scope_a = base.fetch("evidence_scopes").first
    scope_b = scope_a.merge("scope_id" => "scope-typed-2", "version_id" => "version-2", "text" => "Other summary")
    ordered = runner.send(:canonicalize_claim_ids, { "overview" => base.merge("evidence_scopes" => [scope_a, scope_b]), "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    reversed = runner.send(:canonicalize_claim_ids, { "overview" => base.merge("evidence_scopes" => [scope_b, scope_a]), "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    assert_equal ordered.dig("overview", "claim_id"), reversed.dig("overview", "claim_id")

    changed_text = runner.send(:canonicalize_claim_ids, { "overview" => base.merge("text" => "changed"), "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    changed_edition = runner.send(:canonicalize_claim_ids, { "overview" => base, "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-2")
    changed_evidence = runner.send(:canonicalize_claim_ids, { "overview" => base.merge("evidence_scopes" => [base.fetch("evidence_scopes").first.merge("text" => "other")]), "key_changes" => [], "uncertainties" => [] }, edition_id: "edition-1")
    changed_ordinal = runner.send(:canonicalize_claim_ids, { "overview" => base, "key_changes" => [base], "uncertainties" => [] }, edition_id: "edition-1")
    refute_equal first.dig("overview", "claim_id"), changed_text.dig("overview", "claim_id")
    refute_equal first.dig("overview", "claim_id"), changed_edition.dig("overview", "claim_id")
    refute_equal first.dig("overview", "claim_id"), changed_evidence.dig("overview", "claim_id")
    refute_equal first.dig("overview", "claim_id"), changed_ordinal.dig("key_changes", 0, "claim_id")
  end


  def test_large_edition_keeps_raw_input_hash_but_bounds_provider_projection
    placements = 200.times.map do |index|
      { "version_id" => "version-#{index}", "content_hash" => "hash-#{index}", "title" => "Title #{index}",
        "summary" => "Summary #{index}", "publisher" => "Publisher #{index % 20}", "language" => "en", "sort_order" => index }
    end
    provider = FakeProvider.new(result: { "overview" => unit(citations: ["version-0"]), "key_changes" => [], "uncertainties" => [] })
    result = ReportSummaryRunner.new(ledger: FakeLedger.new(placements: placements), provider: provider).run(edition_id: "edition-1", idempotency_key: "bounded")
    assert_equal "succeeded", result.fetch("status")
    assert_operator provider.last_input.fetch("placements").length, :<=, ReportSummaryRunner::MAX_PROVIDER_ITEMS
    assert_match(/\AE\d{3}\z/, provider.last_input.dig("placements", 0, "version_id"))
    assert_equal 200, provider.last_input.dig("projection_boundary", "raw_item_count")
    assert_equal "deterministic_publisher_round_robin_v1", provider.last_input.dig("projection_boundary", "selection_method")
  end

  def test_provider_failure_receipt_is_appended_before_failed_run
    receipt = {
      "exchange_id" => "exchange-fail", "provider" => "fake", "model" => "fake-model", "prompt_version" => "fake-v1",
      "canonical_request_hash" => "a" * 64, "raw_response_hash" => "b" * 64,
      "captured_at" => "2026-08-10T00:00:00Z", "status" => "failed", "response_available" => true,
      "error_code" => "invalid_provider_response", "error_message" => "not an object"
    }
    provider = ReceiptProvider.new(result: { "overview" => { "bad" => true }, "key_changes" => [], "uncertainties" => [] }, receipt: receipt)
    ledger = FakeLedger.new
    # The runner's failure path is exercised with a ledger that records receipt calls.
    ledger.define_singleton_method(:append_provider_response_receipt!) do |run_id:, receipt:|
      (@receipts ||= []) << [run_id, receipt]
      "receipt-fail"
    end
    result = ReportSummaryRunner.new(ledger: ledger, provider: provider).run(edition_id: "edition-1", idempotency_key: "receipt-fail")
    assert_equal "failed", result.fetch("status")
    assert_equal "failed", ledger.instance_variable_get(:@receipts).fetch(0).fetch(1).fetch("status")
  end
end
