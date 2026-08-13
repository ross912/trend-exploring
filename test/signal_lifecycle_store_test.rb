# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/signal_lifecycle_store"

class SignalLifecycleStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "signal_lifecycle_store_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(4)}"
    run!([pgbin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    run!([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/020_signal_lifecycle.sql")])
    @store = SignalLifecycleStore.new(psql: pgbin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user)
  end

  def teardown
    run!([pgbin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_first_detection_is_stable_and_idempotent
    first = @store.record_detection!(family: family, signal: { "signal_key" => "climate-risk" }, as_of: "2026-01-01T00:00:00Z", input_manifest_id: "manifest-1", method_version: "method-1", capability_version: "cap-1")
    second = @store.record_detection!(family: family, signal: { "signal_key" => "climate-risk" }, as_of: "2026-01-01T00:00:00Z", input_manifest_id: "manifest-1", method_version: "method-1", capability_version: "cap-1")

    assert_equal first.fetch("signal").fetch("signal_id"), second.fetch("signal").fetch("signal_id")
    assert_equal first.fetch("signal").fetch("proposition_family_id"), second.fetch("signal").fetch("proposition_family_id")
    assert_equal first.fetch("trigger").fetch("trigger_event_id"), second.fetch("trigger").fetch("trigger_event_id")
    assert_equal first.fetch("state").fetch("state_event_id"), second.fetch("state").fetch("state_event_id")
    assert_equal 1, @store.replay(signal_id: first.fetch("signal").fetch("signal_id"), as_of: "2026-01-01T00:00:00Z").fetch("state_events").length
    assert_equal "candidate", @store.history(signal_id: first.fetch("signal").fetch("signal_id")).fetch("current_state")
  end

  def test_lifecycle_transitions_are_append_only_and_expected_head_is_checked
    detected = detect
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    previous = detected.fetch("state").fetch("state_event_id")
    %w[watching strengthening weakening invalidated dormant].each_with_index do |state, index|
      event = @store.append_state_event!(event: {
        "event_key" => "state-#{state}", "signal_id" => signal_id, "proposition_family_id" => family_id,
        "to_state" => state, "reason_code" => "fixture_#{state}", "run_mode" => "operational_detection",
        "as_of" => format("2026-01-0#{index + 2}T00:00:00Z"), "input_manifest_id" => "manifest-#{index + 2}",
        "method_version" => "method-1", "capability_version" => "cap-1",
        "expected_predecessor_state_event_id" => previous
      })
      previous = event.fetch("state_event_id")
      assert_equal state, event.fetch("to_state")
      assert_equal index + 2, event.fetch("state_revision")
    end
    assert_raises(SignalLifecycleStore::Error) do
      @store.append_state_event!(event: {
        "event_key" => "stale-head", "signal_id" => signal_id, "proposition_family_id" => family_id,
        "to_state" => "watching", "reason_code" => "stale", "as_of" => "2026-01-10T00:00:00Z",
        "input_manifest_id" => "manifest-stale", "method_version" => "method-1", "capability_version" => "cap-1",
        "expected_predecessor_state_event_id" => "not-the-head"
      })
    end
    assert_equal %w[candidate watching strengthening weakening invalidated dormant], @store.history(signal_id: signal_id).fetch("state_events").map { |event| event.fetch("to_state") }
  end

  def test_evidence_roles_and_late_evidence_do_not_change_first_detection
    detected = detect
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    support = @store.append_evidence_link!(link: evidence(signal_id: signal_id, family_id: family_id, evidence_key: "support-1", evidence_role: "support", as_of: "2026-01-02T00:00:00Z", system_available_at: "2026-01-02T00:00:00Z"))
    contradictory = @store.append_evidence_link!(link: evidence(signal_id: signal_id, family_id: family_id, evidence_key: "contradiction-1", evidence_role: "contradictory", as_of: "2026-01-02T00:00:00Z", system_available_at: "2026-01-04T00:00:00Z"))
    unknown = @store.append_evidence_link!(link: evidence(signal_id: signal_id, family_id: family_id, evidence_key: "unknown-1", evidence_role: "unknown", as_of: "2026-01-03T00:00:00Z", system_available_at: "2026-01-03T00:00:00Z"))

    assert_equal "support", support.fetch("evidence_role")
    assert_equal "contradictory", contradictory.fetch("evidence_role")
    assert_equal "unknown", unknown.fetch("evidence_role")
    assert_equal true, contradictory.fetch("late_evidence")
    before_late = @store.replay(signal_id: signal_id, as_of: "2026-01-03T00:00:00Z", system_available_at: "2026-01-03T23:59:59Z")
    after_late = @store.replay(signal_id: signal_id, as_of: "2026-01-03T00:00:00Z", system_available_at: "2026-01-04T00:00:00Z")
    assert_equal ["support-1", "unknown-1"], before_late.fetch("evidence_links").map { |link| link.fetch("evidence_key") }
    assert_equal %w[contradiction-1 support-1 unknown-1], after_late.fetch("evidence_links").map { |link| link.fetch("evidence_key") }.sort
    assert_equal "2026-01-01 08:00:00+08", after_late.fetch("first_detected_as_of")
  end

  def test_invalid_transition_and_update_are_rejected
    detected = detect
    signal_id = detected.fetch("signal").fetch("signal_id")
    family_id = detected.fetch("signal").fetch("proposition_family_id")
    invalidated = @store.append_state_event!(event: {
      "event_key" => "invalidated", "signal_id" => signal_id, "proposition_family_id" => family_id,
      "to_state" => "invalidated", "reason_code" => "false", "as_of" => "2026-01-02T00:00:00Z",
      "input_manifest_id" => "manifest-2", "method_version" => "method-1", "capability_version" => "cap-1"
    })
    assert_raises(SignalLifecycleStore::Error) do
      @store.append_state_event!(event: {
        "event_key" => "bad-revive", "signal_id" => signal_id, "proposition_family_id" => family_id,
        "to_state" => "strengthening", "reason_code" => "bad", "as_of" => "2026-01-03T00:00:00Z",
        "input_manifest_id" => "manifest-3", "method_version" => "method-1", "capability_version" => "cap-1"
      })
    end
    assert_raises(SignalLifecycleStore::Error) do
      @store.send(:execute, "UPDATE signal_state_event SET reason_code = 'mutated' WHERE state_event_id = '#{invalidated.fetch("state_event_id")}'")
    end
  end

  def test_retroactive_relation_preserves_forward_denominator
    first = detect(signal_key: "root-signal")
    second = detect(family_key: "related-family", signal_key: "related-signal", manifest: "manifest-2")
    relation = @store.append_relation_event!(event: {
      "event_key" => "merge-after-review", "relation_kind" => "merge",
      "source_signal_id" => first.fetch("signal").fetch("signal_id"), "source_proposition_family_id" => first.fetch("signal").fetch("proposition_family_id"),
      "target_signal_id" => second.fetch("signal").fetch("signal_id"), "target_proposition_family_id" => second.fetch("signal").fetch("proposition_family_id"),
      "as_of" => "2026-02-01T00:00:00Z", "system_available_at" => "2026-02-02T00:00:00Z",
      "input_manifest_id" => "retrospective-1", "method_version" => "reanalysis-1", "capability_version" => "cap-1",
      "reason_code" => "same_proposition_review", "payload" => { "original_denominator" => first.fetch("signal").fetch("forward_denominator_key") }
    })
    assert_equal "retrospective_reanalysis", relation.fetch("run_mode")
    replay = @store.replay(signal_id: first.fetch("signal").fetch("signal_id"), as_of: "2026-02-01T00:00:00Z", system_available_at: "2026-02-02T00:00:00Z")
    assert_equal 1, replay.fetch("relation_events").length
    assert_equal "root-signal", first.fetch("signal").fetch("forward_denominator_key")
    refute_equal first.fetch("signal").fetch("signal_id"), second.fetch("signal").fetch("signal_id")
  end

  private

  def detect(family_key: "climate-family", signal_key: "climate-risk", manifest: "manifest-1")
    @store.record_detection!(family: family.merge("family_key" => family_key, "input_manifest_id" => manifest), signal: { "signal_key" => signal_key }, as_of: "2026-01-01T00:00:00Z", input_manifest_id: manifest, method_version: "method-1", capability_version: "cap-1")
  end

  def family
    { "family_key" => "climate-family", "proposition_text" => "Climate risk grows", "input_manifest_id" => "manifest-1", "method_version" => "method-1", "capability_version" => "cap-1" }
  end

  def evidence(signal_id:, family_id:, evidence_key:, evidence_role:, as_of:, system_available_at:)
    { "evidence_key" => evidence_key, "signal_id" => signal_id, "proposition_family_id" => family_id, "evidence_role" => evidence_role, "as_of" => as_of, "system_available_at" => system_available_at, "input_manifest_id" => "evidence-manifest", "method_version" => "method-1", "capability_version" => "cap-1", "evidence_payload" => { "fixture" => evidence_key } }
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
