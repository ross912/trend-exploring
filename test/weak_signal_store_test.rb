# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/weak_signal_store"

class WeakSignalStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "weak_signal_store_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(4)}"
    run!([pgbin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 015_local_weak_signal.sql].each do |file|
      run!([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = WeakSignalStore.new(psql: pgbin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user)
  end

  def teardown
    run!([pgbin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_publish_idempotency_different_payload_rejection_and_latest_evaluated
    run = base_run.merge("run_id" => "run-1", "status" => "evaluated")
    candidate = { "phrase" => "ai model", "language" => "en", "reason_codes" => ["NEWLY_REPEATED"],
                  "recent_publisher_count" => 3, "prior_publisher_count" => 1,
                  "recent_observation_count" => 3, "prior_observation_count" => 1,
                  "prior_bucket_counts" => [0, 0, 0, 1, 0, 0],
                  "recent_evidence_version_ids" => %w[v1 v2 v3], "prior_evidence_version_ids" => ["v0"],
                  "explanation" => "deterministic fixture", "sort_order" => 0 }
    first = @store.publish!(run: run, candidates: [candidate])
    second = @store.publish!(run: run, candidates: [candidate])
    assert_equal first, second
    assert_raises(WeakSignalStore::Error) { @store.publish!(run: run.merge("input_hash" => "different"), candidates: [candidate]) }
    assert_equal "run-1", @store.latest_evaluated.fetch("run_id")
    assert_equal 1, @store.latest_evaluated.fetch("candidates").length
  end

  def test_invalid_candidate_rolls_back_run_and_warming_up_has_no_candidates
    run = base_run.merge("run_id" => "invalid", "status" => "evaluated")
    invalid = { "phrase" => "", "language" => "en", "reason_codes" => [] }
    assert_raises(WeakSignalStore::Error) { @store.publish!(run: run, candidates: [invalid]) }
    assert_nil @store.latest_run(run_id: "invalid")
    warming = base_run.merge("run_id" => "warming", "status" => "warming_up")
    assert_equal "warming", @store.publish!(run: warming, candidates: []).fetch("run_id")
    assert_equal "warming_up", @store.latest_run(run_id: "warming").fetch("status")
  end

  private

  def base_run
    { "as_of" => "2026-08-13T00:00:00Z", "input_cutoff" => "2026-08-13T00:00:00Z",
      "input_hash" => "fixture-input", "detector_version" => "weak_signal_detector_v1",
      "recent_window_hours" => 24, "prior_window_days" => 7, "prior_bucket_count" => 6 }
  end

  def pgbin(name)
    "/private/tmp/trend-exploring-postgres15-runtime/bin/#{name}"
  end

  def pg_host
    "/private/tmp/trend-exploring-pg-socket"
  end

  def pg_port
    "55433"
  end

  def pg_user
    ENV.fetch("USER", "postgres")
  end

  def run!(args)
    stdout, stderr, status = Open3.capture3(*args)
    raise stderr unless status.success?
    stdout
  end
end
