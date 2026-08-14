# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"

class ReportClaimGateSchemaTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "report_claim_gate_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(6)}"
    run!([pg_bin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql 014_local_report_summary.sql 021_report_claim_gate.sql].each do |file|
      run!([pg_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
            "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
  end

  def teardown
    return unless @database

    raise "refusing to drop database outside test prefix" unless @database.start_with?(PREFIX)
    run!([pg_bin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
  end

  def test_verified_artifact_rejects_failed_unavailable_provider_receipt
    result = sql_raw(<<~SQL)
      BEGIN;
      SET CONSTRAINTS ALL DEFERRED;
      INSERT INTO local_report_schedule_slot
        (slot_id, kind, timezone, window_start, window_end, scheduled_at, configured_data_cutoff, config_hash, state, failure_reason)
      VALUES ('slot', 'morning', 'Asia/Shanghai', '2026-08-10 00:00Z', '2026-08-10 01:00Z', '2026-08-10 01:00Z', '2026-08-10 00:00Z', 'h', 'scheduled', '');
      INSERT INTO local_report_publication_attempt
        (attempt_id, slot_id, idempotency_key, payload_hash, state)
      VALUES ('attempt', 'slot', 'attempt-key', 'h', 'running');
      INSERT INTO local_report_edition
        (edition_id, slot_id, attempt_id, nominal_window_start, nominal_window_end, configured_data_cutoff,
         processing_frontier, selection_completeness_frontier, data_cutoff, comparison_watermark,
         edition_status, reason_codes, payload_hash, item_count)
      VALUES ('edition', 'slot', 'attempt', '2026-08-10 00:00Z', '2026-08-10 01:00Z', '2026-08-10 00:00Z',
              '2026-08-10 00:00Z', '2026-08-10 00:00Z', '2026-08-10 00:00Z', '2026-08-10 00:00Z',
              'normal', '[]', 'h', 0);
      UPDATE local_report_publication_attempt SET state = 'published', finished_at = now() WHERE attempt_id = 'attempt';
      UPDATE local_report_schedule_slot SET state = 'published' WHERE slot_id = 'slot';
      INSERT INTO local_report_summary_run
        (run_id, edition_id, idempotency_key, input_hash, provider, model, prompt_version, state)
      VALUES ('run', 'edition', 'summary-key', 'input', 'p', 'm', 'v', 'running');
      INSERT INTO provider_response_receipt
        (receipt_id, run_id, provider, model, prompt_version, exchange_id, canonical_request_hash, raw_response_hash,
         captured_at, status, response_available, error_code, error_message)
      VALUES ('receipt', 'run', 'p', 'm', 'v', 'exchange', repeat('a', 64), repeat('b', 64), now(), 'failed', false, 'HTTP_500', 'failed');
      INSERT INTO local_report_summary_artifact
        (artifact_id, run_id, edition_id, input_hash, provider, model, prompt_version, overview, key_changes,
         uncertainties, output_hash, claim_gate_status, provider_receipt_id)
      VALUES ('artifact', 'run', 'edition', 'input', 'p', 'm', 'v',
              jsonb_build_object('claim_id', 'claim-1', 'kind', 'fact', 'text', 'A', 'epistemic_status', 'asserted',
                'evidence_scopes', jsonb_build_array(jsonb_build_object('scope_id', 'scope-1', 'version_id', 'missing',
                  'field', 'summary', 'text', 'missing', 'relation', 'supports'))), '[]', '[]', repeat('c', 64), 'verified', 'receipt');
      COMMIT;
    SQL

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "succeeded provider receipt"
    assert_equal "0", psql!("SELECT COUNT(*) FROM local_report_summary_artifact").lines.grep(/\A\s*0\s*\z/).first.to_s.strip
  end

  private

  def sql_raw(sql)
    stdout, stderr, status = Open3.capture3(pg_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
                                            "-U", pg_user, "-d", @database, "-c", sql)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def psql!(sql)
    result = sql_raw(sql)
    raise result.fetch(:stderr) unless result.fetch(:status).success?
    result.fetch(:stdout)
  end

  def run!(args)
    stdout, stderr, status = Open3.capture3(*args)
    raise "command failed: #{stderr}" unless status.success?
    stdout
  end

  def pg_bin(name)
    File.join(ENV.fetch("LOCAL_PSQL", "/private/tmp/trend-exploring-postgres15-runtime/bin/psql").sub(/\/psql\z/, ""), name)
  end

  def pg_host; ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket"); end
  def pg_port; ENV.fetch("LOCAL_PGPORT", "55433"); end
  def pg_user; ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")); end
end
