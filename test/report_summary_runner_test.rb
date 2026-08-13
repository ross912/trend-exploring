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
end
