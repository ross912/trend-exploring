# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/signal_lifecycle_store"

class SignalLifecycleReplayTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "signal_lifecycle_replay_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(4)}"
    run!([pgbin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    2.times do
      run!([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/020_signal_lifecycle.sql")])
    end
    @store = build_store
  end

  def teardown
    run!([pgbin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_as_known_replay_excludes_late_evidence_until_system_available
    detected = @store.record_detection!(family: family, signal: { "signal_key" => "water-stress" }, as_of: "2026-02-01T00:00:00Z", input_manifest_id: "operational-1", method_version: "detector-1", capability_version: "cap-1")
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    @store.append_evidence_link!(link: evidence(signal_id, family_id, "late-contradiction", "contradictory", as_of: "2026-02-02T00:00:00Z", system_available_at: "2026-02-05T00:00:00Z"))

    before_availability = @store.replay(signal_id: signal_id, as_of: "2026-02-03T00:00:00Z", system_available_at: "2026-02-04T23:59:59Z")
    after_availability = @store.replay(signal_id: signal_id, as_of: "2026-02-03T00:00:00Z", system_available_at: "2026-02-05T00:00:00Z")
    assert_empty before_availability.fetch("evidence_links")
    assert_equal ["late-contradiction"], after_availability.fetch("evidence_links").map { |row| row.fetch("evidence_key") }
    assert_equal Time.parse(detected.fetch("signal").fetch("first_detected_as_of")).utc, Time.parse(after_availability.fetch("first_detected_as_of")).utc
    assert_equal "operational_detection", after_availability.fetch("first_detection_mode")
  end

  def test_retrospective_review_is_visible_as_late_mode_not_as_initial_detection
    detected = @store.record_detection!(family: family, signal: { "signal_key" => "grid-risk" }, as_of: "2026-02-01T00:00:00Z", input_manifest_id: "operational-1", method_version: "detector-1", capability_version: "cap-1")
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    review = @store.append_trigger_event!(event: {
      "event_key" => "review-grid-risk", "signal_id" => signal_id, "proposition_family_id" => family_id,
      "trigger_kind" => "retrospective_review", "run_mode" => "retrospective_reanalysis",
      "as_of" => "2026-02-02T00:00:00Z", "system_available_at" => "2026-02-10T00:00:00Z",
      "input_manifest_id" => "review-1", "method_version" => "reanalysis-1", "capability_version" => "cap-2",
      "evidence_role" => "unknown", "payload" => { "reviewed_after" => "2026-02-09T00:00:00Z" }
    })
    assert_equal "retrospective_reanalysis", review.fetch("run_mode")
    replay = @store.replay(signal_id: signal_id, as_of: "2026-02-02T00:00:00Z", system_available_at: "2026-02-10T00:00:00Z", run_mode: "retrospective_reanalysis")
    assert_equal 1, replay.fetch("retrospective_event_count")
    assert_equal ["review-grid-risk"], replay.fetch("trigger_events").map { |row| row.fetch("event_key") }
    assert_equal "2026-02-01 08:00:00+08", replay.fetch("first_detected_as_of")
    assert_equal "operational_detection", replay.fetch("first_detection_mode")
    assert_empty @store.replay(signal_id: signal_id, as_of: "2026-02-02T00:00:00Z", system_available_at: "2026-02-10T00:00:00Z", run_mode: "retrospective_reanalysis").fetch("state_events")
  end

  def test_concurrent_same_state_event_has_one_terminal_row
    detected = @store.record_detection!(family: family, signal: { "signal_key" => "concurrency" }, as_of: "2026-02-01T00:00:00Z", input_manifest_id: "operational-1", method_version: "detector-1", capability_version: "cap-1")
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    event = {
      "event_key" => "concurrent-watching", "signal_id" => signal_id, "proposition_family_id" => family_id,
      "to_state" => "watching", "reason_code" => "concurrent_fixture", "as_of" => "2026-02-02T00:00:00Z",
      "input_manifest_id" => "operational-2", "method_version" => "detector-1", "capability_version" => "cap-1"
    }
    results = [build_store, build_store].map do |store|
      Thread.new do
        begin
          store.append_state_event!(event: event)
        rescue SignalLifecycleStore::Error => error
          error
        end
      end
    end.map(&:value)
    successful = results.select { |result| result.is_a?(Hash) }
    assert_equal 2, results.length
    assert_operator successful.length, :>=, 1
    assert_equal 1, @store.history(signal_id: signal_id).fetch("state_events").count { |row| row.fetch("event_key") == "concurrent-watching" }
  end

  private

  def family
    { "family_key" => "replay-family", "proposition_text" => "Replay fixture proposition", "input_manifest_id" => "operational-1", "method_version" => "detector-1", "capability_version" => "cap-1" }
  end

  def evidence(signal_id, family_id, key, role, as_of:, system_available_at:)
    { "evidence_key" => key, "signal_id" => signal_id, "proposition_family_id" => family_id, "evidence_role" => role, "as_of" => as_of, "system_available_at" => system_available_at, "input_manifest_id" => "evidence-1", "method_version" => "detector-1", "capability_version" => "cap-1", "evidence_payload" => { "fixture" => key } }
  end

  def build_store
    SignalLifecycleStore.new(psql: pgbin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user)
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
