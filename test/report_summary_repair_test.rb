# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require "thread"
require_relative "../lib/report_summary_runner"
require_relative "../lib/local_report_ledger"

class ReportSummaryRepairTest < Minitest::Test
  class Ledger
    attr_reader :receipts, :artifacts, :runs

    def initialize
      @context = {
        "edition_id" => "edition-1",
        "boundary" => { "data_cutoff" => "2026-08-10T00:00:00Z" },
        "placements" => [{ "version_id" => "version-1", "title" => "Title", "summary" => "Summary",
                            "publisher" => "Publisher", "language" => "en", "sort_order" => 0 }]
      }
      @runs = {}
      @receipts = []
      @artifacts = {}
      @lock = Mutex.new
    end

    def report_summary_context(edition_id:)
      raise "wrong edition" unless edition_id.to_s == "edition-1"

      Marshal.load(Marshal.dump(@context))
    end

    def append_summary_run!(edition_id:, idempotency_key:, input_hash:, provider:, model:, prompt_version:, retry_policy_version:)
      @lock.synchronize do
        row = @runs[idempotency_key]
        if row
          raise "idempotency payload differs" unless row.values_at("edition_id", "input_hash", "provider", "model", "prompt_version", "retry_policy_version") ==
                                                     [edition_id, input_hash, provider, model, prompt_version, retry_policy_version]
          return row.merge("__summary_execution_owner" => false)
        end
        @runs[idempotency_key] = {
          "run_id" => "run-#{idempotency_key}", "edition_id" => edition_id, "idempotency_key" => idempotency_key,
          "input_hash" => input_hash, "provider" => provider, "model" => model,
          "prompt_version" => prompt_version, "retry_policy_version" => retry_policy_version, "state" => "running"
        }
        @runs[idempotency_key].merge("__summary_execution_owner" => true)
      end
    end

    def append_provider_response_receipt!(run_id:, receipt:)
      @lock.synchronize do
        receipt_id = "receipt-#{@receipts.length + 1}"
        @receipts << receipt.merge("receipt_id" => receipt_id, "run_id" => run_id)
        receipt_id
      end
    end

    def finish_summary_success!(run_id:, artifact:)
      @lock.synchronize do
        run = @runs.values.find { |row| row.fetch("run_id") == run_id }
        run["state"] = "succeeded"
        @artifacts[run_id] = Marshal.load(Marshal.dump(artifact))
        { "run" => run.dup, "artifact" => @artifacts.fetch(run_id) }
      end
    end

    def finish_summary_failed!(run_id:, state:, reason:)
      @lock.synchronize do
        run = @runs.values.find { |row| row.fetch("run_id") == run_id }
        run["state"] = state
        run["error_reason"] = reason
        run.dup
      end
    end

    def summary_artifact_for_run(run_id:)
      @artifacts[run_id]
    end
  end

  class Provider
    attr_reader :calls, :repair_calls, :repair_args, :last_receipt

    def initialize(initial:, repaired: nil)
      @initial = initial
      @repaired = repaired
      @calls = 0
      @repair_calls = 0
    end

    def provider_name; "fake"; end
    def model; "fake-model"; end
    def prompt_version; "local-report-summary-fake-v9"; end
    def available?; true; end
    def supports_repair?; !@repaired.nil?; end

    def summarize(input:)
      @calls += 1
      @last_receipt = receipt("initial", 1)
      @initial
    end

    def repair(**kwargs)
      @repair_calls += 1
      @repair_args = kwargs
      @last_receipt = receipt("repair", 2)
      @repaired
    end

    private

    def receipt(exchange, ordinal)
      {
        "exchange_id" => "exchange-#{exchange}", "provider" => provider_name, "model" => model,
        "prompt_version" => prompt_version, "canonical_request_hash" => ("a".ord + ordinal).to_s(16).rjust(64, "0"),
        "raw_response_hash" => ("b".ord + ordinal).to_s(16).rjust(64, "0"),
        "captured_at" => "2026-08-10T00:00:00Z", "status" => "succeeded", "response_available" => true
      }
    end
  end

  class HttpFailureProvider < Provider
    def initialize
      super(initial: {})
    end

    def summarize(input:)
      @calls += 1
      @last_receipt = receipt_for_http
      raise ReportSummaryProvider::Error.new("HTTP 503", code: "provider_http_503", receipt: @last_receipt)
    end

    def supports_repair?; true; end

    private

    def receipt_for_http
      {
        "exchange_id" => "exchange-http", "provider" => provider_name, "model" => model,
        "prompt_version" => prompt_version, "canonical_request_hash" => "a" * 64,
        "raw_response_hash" => "b" * 64, "captured_at" => "2026-08-10T00:00:00Z",
        "status" => "failed", "response_available" => false, "http_status" => 503,
        "error_code" => "provider_http_503", "error_message" => "HTTP 503"
      }
    end
  end

  def typed_claim(text: "Summary", **extra)
    {
      "kind" => "fact", "text" => text,
      "evidence_scopes" => [{ "scope_id" => "scope-1", "version_id" => "E001", "field" => "summary",
                               "text" => "Summary", "relation" => "supports" }]
    }.merge(extra)
  end

  def payload(claim)
    { "overview" => claim, "key_changes" => [], "uncertainties" => [] }
  end

  def execute(provider, ledger: Ledger.new, key: "summary-key")
    [ReportSummaryRunner.new(ledger: ledger, provider: provider).run(edition_id: "edition-1", idempotency_key: key), ledger]
  end

  def test_first_pass_uses_one_provider_call_and_one_receipt
    provider = Provider.new(initial: payload(typed_claim))
    result, ledger = execute(provider)
    assert_equal "succeeded", result.fetch("status")
    assert_equal 1, provider.calls
    assert_equal 0, provider.repair_calls
    assert_equal 1, result.dig("artifact", "generation_attempt_count")
    assert_equal false, result.dig("artifact", "repaired")
    assert_equal 1, ledger.receipts.length
  end

  def test_shape_failure_repairs_once_with_two_calls_and_receipt_lineage
    malformed = payload(typed_claim.merge("unknown" => "shape"))
    provider = Provider.new(initial: malformed, repaired: payload(typed_claim))
    result, ledger = execute(provider, key: "shape-repair")
    assert_equal "succeeded", result.fetch("status")
    assert_equal 1, provider.calls
    assert_equal 1, provider.repair_calls
    assert_equal 2, ledger.receipts.length
    assert_equal 2, result.dig("artifact", "generation_attempt_count")
    assert_equal true, result.dig("artifact", "repaired")
    assert_equal "receipt-1", result.dig("artifact", "repair_from_receipt_id")
    assert_equal "receipt-2", result.dig("artifact", "provider_receipt_id")
    assert_equal "CLAIM_SHAPE", provider.repair_args.fetch(:validation_code)
    assert_equal malformed.dig("overview", "text"), provider.repair_args.dig(:original_json, "overview", "text")
  end

  def test_repair_with_invalid_duplicate_and_missing_scope_ids_uses_server_ids
    malformed = payload(typed_claim.merge("unknown" => "shape"))
    repaired = payload(typed_claim.merge("evidence_scopes" => [
      typed_claim.fetch("evidence_scopes").first.merge("scope_id" => "../../forged"),
      typed_claim.fetch("evidence_scopes").first.merge("scope_id" => "../../forged", "relation" => "alternative"),
      typed_claim.fetch("evidence_scopes").first.reject { |key, _| key == "scope_id" }
    ]))
    provider = Provider.new(initial: malformed, repaired: repaired)
    result, = execute(provider, key: "scope-id-repair")
    assert_equal "succeeded", result.fetch("status")
    ids = result.dig("artifact", "overview", "evidence_scopes").map { |scope| scope.fetch("scope_id") }
    assert_equal 3, ids.uniq.length
    ids.each { |id| assert_match(/\Ascope-report-summary-v1-[a-f0-9]{64}\z/, id) }
  end

  def test_second_gate_failure_keeps_two_receipts_but_no_artifact
    malformed = payload(typed_claim.merge("unknown" => "shape"))
    still_bad = payload(typed_claim.merge("evidence_scopes" => [typed_claim.fetch("evidence_scopes").first.merge("version_id" => "unknown")]))
    provider = Provider.new(initial: malformed, repaired: still_bad)
    result, ledger = execute(provider, key: "repair-fail")
    assert_equal "failed", result.fetch("status")
    assert_nil result.fetch("artifact")
    assert_equal 1, provider.calls
    assert_equal 1, provider.repair_calls
    assert_equal 2, ledger.receipts.length
  end

  def test_http_failure_does_not_trigger_repair
    provider = HttpFailureProvider.new
    result, ledger = execute(provider, key: "http-fail")
    assert_equal "failed", result.fetch("status")
    assert_equal 1, provider.calls
    assert_equal 0, provider.repair_calls
    assert_equal 1, ledger.receipts.length
  end

  def test_unknown_evidence_after_repair_is_still_rejected
    malformed = payload(typed_claim.merge("unknown" => "shape"))
    unknown = payload(typed_claim.merge("evidence_scopes" => [typed_claim.fetch("evidence_scopes").first.merge("version_id" => "E999")]))
    provider = Provider.new(initial: malformed, repaired: unknown)
    result, = execute(provider, key: "unknown-evidence")
    assert_equal "failed", result.fetch("status")
    assert_match(/CLAIM_SCOPE_VERSION_UNKNOWN/, result.dig("run", "error_reason"))
  end

  def test_scope_id_identity_ignores_provider_id_but_binds_claim_and_evidence_fields
    runner = ReportSummaryRunner.new(ledger: Ledger.new, provider: Provider.new(initial: payload(typed_claim)))
    base = payload(typed_claim)
    canonical = runner.send(:canonicalize_scope_ids,
                             runner.send(:canonicalize_claim_ids, base, edition_id: "edition-1"), edition_id: "edition-1")
    provider_id_changed = base.merge("overview" => base.fetch("overview").merge("evidence_scopes" => [
      base.dig("overview", "evidence_scopes", 0).merge("scope_id" => "another-provider-id")
    ]))
    changed_provider_id = runner.send(:canonicalize_scope_ids,
                                       runner.send(:canonicalize_claim_ids, provider_id_changed, edition_id: "edition-1"), edition_id: "edition-1")
    assert_equal canonical.dig("overview", "claim_id"), changed_provider_id.dig("overview", "claim_id")
    assert_equal canonical.dig("overview", "evidence_scopes", 0, "scope_id"), changed_provider_id.dig("overview", "evidence_scopes", 0, "scope_id")
    changed_excerpt = base.merge("overview" => base.fetch("overview").merge("evidence_scopes" => [
      base.dig("overview", "evidence_scopes", 0).merge("text" => "Title")
    ]))
    changed = runner.send(:canonicalize_scope_ids,
                           runner.send(:canonicalize_claim_ids, changed_excerpt, edition_id: "edition-1"), edition_id: "edition-1")
    refute_equal canonical.dig("overview", "evidence_scopes", 0, "scope_id"), changed.dig("overview", "evidence_scopes", 0, "scope_id")
  end

  def test_same_key_replay_does_not_call_provider_again
    provider = Provider.new(initial: payload(typed_claim))
    ledger = Ledger.new
    first, = execute(provider, ledger: ledger, key: "replay")
    second, = execute(provider, ledger: ledger, key: "replay")
    assert_equal "succeeded", first.fetch("status")
    assert_equal "succeeded", second.fetch("status")
    assert_equal 1, provider.calls
  end

  def test_concurrent_owner_allows_only_one_provider_group
    provider = Provider.new(initial: payload(typed_claim))
    ledger = Ledger.new
    threads = 2.times.map { Thread.new { execute(provider, ledger: ledger, key: "concurrent") } }
    results = threads.map(&:value)
    assert_equal 1, provider.calls
    assert results.all? { |result, _| %w[succeeded running].include?(result.fetch("status")) }
    assert_operator results.count { |result, _| result.fetch("status") == "succeeded" }, :>=, 1
    assert_equal 1, ledger.receipts.length
  end

  def test_022_schema_guards_failed_parent_and_final_receipt_lineage
    sql = File.read(File.expand_path("../schema/postgres/022_report_summary_repair.sql", __dir__))
    assert_includes sql, "provider_response_receipt_repair_parent_fkey"
    assert_includes sql, "summary artifact requires final succeeded provider receipt"
    assert_includes sql, "summary artifact repair lineage must reference available succeeded initial receipt"
    assert_includes sql, "provider_response_receipt_attempt_check"
  end

  # Exercise the actual PostgreSQL trigger, including the failed-parent
  # lineage case that a static SQL assertion cannot catch.
  def test_022_database_rejects_failed_parent_and_nonfinal_receipt
    database = "report_summary_repair_test_#{Process.pid}_#{SecureRandom.hex(4)}"
    psql = ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql"))
    pg_dir = File.dirname(psql)
    host = ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket")
    port = ENV.fetch("LOCAL_PGPORT", "55433")
    user = ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
    skip "local PostgreSQL runtime is unavailable" unless File.executable?(File.join(pg_dir, "createdb"))
    run_cmd!([File.join(pg_dir, "createdb"), "-h", host, "-p", port, "-U", user, database])
    begin
      root = File.expand_path("..", __dir__)
      %w[011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql 014_local_report_summary.sql 021_report_claim_gate.sql 022_report_summary_repair.sql].each do |file|
        run_cmd!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database,
                  "-f", File.join(root, "schema/postgres", file)])
      end
      ledger = LocalReportLedger.new(psql: psql, host: host, port: port, database: database, user: user)
      slot = ledger.generate_slots!(date: "2026-08-10", kinds: ["morning"]).fetch(0)
      insert_fixture_version(psql: psql, host: host, port: port, user: user, database: database)
      edition = ledger.publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: "repair-db-publish",
                                     processing_frontier: slot.fetch("scheduled_at"),
                                     selection_completeness_frontier: slot.fetch("scheduled_at"),
                                     comparison_watermark: slot.fetch("scheduled_at"))
      context = ledger.report_summary_context(edition_id: edition.fetch("edition_id"))
      input_hash = Digest::SHA256.hexdigest(JSON.generate(context))
      failed_parent_run = ledger.append_summary_run!(edition_id: edition.fetch("edition_id"), idempotency_key: "failed-parent",
                                                      input_hash: input_hash, provider: "fake", model: "fake-model",
                                                      prompt_version: "v9", retry_policy_version: ReportSummaryRunner::RETRY_POLICY_VERSION)
      failed_parent = ledger.append_provider_response_receipt!(run_id: failed_parent_run.fetch("run_id"), receipt: receipt_fixture(status: "failed", ordinal: 1, kind: "initial"))
      final = ledger.append_provider_response_receipt!(run_id: failed_parent_run.fetch("run_id"), receipt: receipt_fixture(status: "succeeded", ordinal: 2, kind: "repair", parent: failed_parent))
      assert_raises(LocalReportLedger::Error) do
        ledger.finish_summary_success!(run_id: failed_parent_run.fetch("run_id"), artifact: artifact_fixture(run: failed_parent_run, edition: edition, input_hash: input_hash, final_receipt: final, parent_receipt: failed_parent))
      end
      assert_equal 0, scalar_psql(psql, host, port, user, database, "SELECT COUNT(*) FROM local_report_summary_artifact")

      bad_final_run = ledger.append_summary_run!(edition_id: edition.fetch("edition_id"), idempotency_key: "bad-final",
                                                 input_hash: input_hash, provider: "fake", model: "fake-model",
                                                 prompt_version: "v9", retry_policy_version: ReportSummaryRunner::RETRY_POLICY_VERSION)
      bad_final = ledger.append_provider_response_receipt!(run_id: bad_final_run.fetch("run_id"), receipt: receipt_fixture(status: "failed", ordinal: 1, kind: "initial"))
      assert_raises(LocalReportLedger::Error) do
        ledger.finish_summary_success!(run_id: bad_final_run.fetch("run_id"), artifact: artifact_fixture(run: bad_final_run, edition: edition, input_hash: input_hash, final_receipt: bad_final))
      end
      assert_equal 0, scalar_psql(psql, host, port, user, database, "SELECT COUNT(*) FROM local_report_summary_artifact")
    ensure
      run_cmd!([File.join(pg_dir, "dropdb"), "-h", host, "-p", port, "-U", user, database])
    end
  end

  private

  def run_cmd!(args)
    _stdout, stderr, status = Open3.capture3(*args)
    raise stderr unless status.success?
  end

  def scalar_psql(psql, host, port, user, database, sql)
    stdout, stderr, status = Open3.capture3(psql, "-XAt", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port,
                                            "-U", user, "-d", database, "-c", sql)
    raise stderr unless status.success?
    stdout.strip.to_i
  end

  def insert_fixture_version(psql:, host:, port:, user:, database:)
    sql = <<~SQL
      INSERT INTO local_source_capture
        (capture_id, source_id, source_url, source_kind, rights_scope, captured_at, http_status,
         content_type, content_bytes, body_hash, storage_status, storage_uri)
      VALUES ('repair-capture', 'source-fixture', 'https://fixture.test/item', 'configured', 'excerpt_only',
              '2026-08-09 23:40Z', 200, 'application/rss+xml', 10, 'repair-body', 'metadata_only', '');
      INSERT INTO local_source_item
        (item_key, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id,
         publisher_identity_status, source_kind, capture_id, title, summary, source_url,
         fetched_at, captured_at, content_hash)
      VALUES ('repair-item', 'source-fixture', 'Fixture source', 'en', 'fixture', 'Fixture publisher',
              'https://fixture.test/publisher', 'fixture.test', 'configured', 'configured', 'repair-capture',
              'Fixture title', 'Fixture summary', 'https://fixture.test/item', '2026-08-09 23:40Z',
              '2026-08-09 23:40Z', 'repair-hash');
      INSERT INTO local_source_item_version
        (version_id, item_key, capture_id, source_id, source_name, language, region, publisher_name,
         publisher_url, publisher_id, publisher_identity_status, source_kind, query_conditioned,
         lineage_metadata_basis, title, summary, source_url, fetched_at, captured_at, content_hash,
         created_at, discovery_basis, analysis_policy, aggregator_id, locale_tag, market_label,
         market_label_basis, query_topics)
      VALUES ('repair-version', 'repair-item', 'repair-capture', 'source-fixture', 'Fixture source', 'en', 'fixture',
              'Fixture publisher', 'https://fixture.test/publisher', 'fixture.test', 'configured', 'configured', false,
              'capture_time', 'Fixture title', 'Fixture summary', 'https://fixture.test/item', '2026-08-09 23:40Z',
              '2026-08-09 23:40Z', 'repair-hash', '2026-08-09 23:40Z', 'editorial_feed', 'signal_eligible', '', '', '',
              'editorial_scope_label', '[]'::jsonb);
    SQL
    run_cmd!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-c", sql])
  end

  def receipt_fixture(status:, ordinal:, kind:, parent: nil)
    {
      "exchange_id" => "db-#{ordinal}-#{kind}-#{status}", "provider" => "fake", "model" => "fake-model", "prompt_version" => "v9",
      "canonical_request_hash" => ("a".ord + ordinal).to_s(16).rjust(64, "0"),
      "raw_response_hash" => ("b".ord + ordinal).to_s(16).rjust(64, "0"), "captured_at" => "2026-08-10T00:00:00Z",
      "status" => status, "response_available" => status == "succeeded", "attempt_ordinal" => ordinal,
      "exchange_kind" => kind, "repair_from_receipt_id" => parent
    }
  end

  def artifact_fixture(run:, edition:, input_hash:, final_receipt:, parent_receipt: nil)
    {
      "artifact_id" => "artifact-#{run.fetch('run_id')}", "run_id" => run.fetch("run_id"), "edition_id" => edition.fetch("edition_id"),
      "input_hash" => input_hash, "provider" => "fake", "model" => "fake-model", "prompt_version" => "v9",
      "overview" => { "claim_id" => "claim-test", "kind" => "fact", "text" => "Fixture summary",
                       "epistemic_status" => "asserted", "evidence_scopes" => [{ "scope_id" => "scope-test",
                         "version_id" => "repair-version", "field" => "summary", "text" => "Fixture summary", "relation" => "supports" }] },
      "key_changes" => [], "uncertainties" => [], "output_hash" => "c" * 64, "claim_gate_status" => "verified",
      "provider_receipt_id" => final_receipt, "generation_attempt_count" => parent_receipt ? 2 : 1,
      "repaired" => !parent_receipt.nil?, "repair_from_receipt_id" => parent_receipt
    }
  end
end
