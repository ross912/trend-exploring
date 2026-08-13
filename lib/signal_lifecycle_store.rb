# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "time"
require_relative "local_runtime"

# Append-only storage for stable proposition families, signals, evidence and
# lifecycle state.  This store deliberately does not depend on the local
# radar read model: operational detection and retrospective reanalysis remain
# distinguishable in every event and replay result.
class SignalLifecycleStore
  STATES = %w[candidate watching strengthening weakening invalidated dormant].freeze
  MODES = %w[operational_detection retrospective_reanalysis].freeze
  EVIDENCE_ROLES = %w[support contradictory unknown].freeze
  TRIGGER_KINDS = %w[initial_detection retrigger late_evidence retrospective_review manual].freeze
  RELATION_KINDS = %w[merge split].freeze

  class Error < StandardError; end

  attr_reader :psql, :host, :port, :database, :user

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user))
    @psql = psql
    @host = host
    @port = port
    @database = database
    @user = user
    @transaction_io = nil
  end

  # Stable identity is derived from a caller-owned family key.  Replaying the
  # same key never creates a second proposition family or signal.
  def proposition_family_id(family_key:)
    stable_id("proposition-family", family_key.to_s)
  end

  def signal_id(proposition_family_id:, signal_key:)
    stable_id("signal", proposition_family_id.to_s, signal_key.to_s)
  end

  def ensure_proposition_family!(family:)
    value = normalize_family(family)
    transaction do
      execute(<<~SQL)
        INSERT INTO signal_proposition_family
          (proposition_family_id, family_key, proposition_text, created_as_of,
           system_available_at, input_manifest_id, method_version, capability_version)
        VALUES (#{literal(value.fetch("proposition_family_id"))}, #{literal(value.fetch("family_key"))},
                #{literal(value.fetch("proposition_text"))}, #{literal(value.fetch("created_as_of"))},
                #{literal(value.fetch("system_available_at"))}, #{literal(value.fetch("input_manifest_id"))},
                #{literal(value.fetch("method_version"))}, #{literal(value.fetch("capability_version"))})
        ON CONFLICT (proposition_family_id) DO NOTHING
      SQL
      row = query("SELECT proposition_family_id, family_key, proposition_text, created_as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version FROM signal_proposition_family WHERE proposition_family_id = #{literal(value.fetch("proposition_family_id"))}").fetch(0)
      existing = row_to_hash(row, %w[proposition_family_id family_key proposition_text created_as_of system_available_at input_manifest_id method_version capability_version])
      immutable_match!(existing, value, "proposition family")
      existing
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "proposition family is incomplete: #{error.message}"
  end

  alias create_proposition_family! ensure_proposition_family!

  def ensure_signal!(signal:, family: nil)
    value = normalize_signal(signal, family: family)
    ensure_proposition_family!(family: family_for_signal(value, family)) if family
    transaction do
      execute(<<~SQL)
        INSERT INTO signal
          (signal_id, proposition_family_id, signal_key, first_detected_as_of,
           first_detected_system_available_at, initial_input_manifest_id,
           initial_method_version, initial_capability_version, initial_run_mode,
           forward_denominator_key)
        VALUES (#{literal(value.fetch("signal_id"))}, #{literal(value.fetch("proposition_family_id"))},
                #{literal(value.fetch("signal_key"))}, #{literal(value.fetch("first_detected_as_of"))},
                #{literal(value.fetch("first_detected_system_available_at"))},
                #{literal(value.fetch("initial_input_manifest_id"))},
                #{literal(value.fetch("initial_method_version"))},
                #{literal(value.fetch("initial_capability_version"))}, 'operational_detection',
                #{literal(value.fetch("forward_denominator_key"))})
        ON CONFLICT (signal_id) DO NOTHING
      SQL
      row = query("SELECT signal_id, proposition_family_id, signal_key, first_detected_as_of::text, first_detected_system_available_at::text, initial_input_manifest_id, initial_method_version, initial_capability_version, initial_run_mode, forward_denominator_key FROM signal WHERE signal_id = #{literal(value.fetch("signal_id"))}").fetch(0)
      existing = row_to_hash(row, %w[signal_id proposition_family_id signal_key first_detected_as_of first_detected_system_available_at initial_input_manifest_id initial_method_version initial_capability_version initial_run_mode forward_denominator_key])
      immutable_match!(existing, value, "signal")
      existing
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "signal is incomplete: #{error.message}"
  end

  alias create_signal! ensure_signal!

  # One transaction for the common first-detection path.  A later call with
  # the same event key is idempotent; a changed payload is rejected.
  def record_detection!(family:, signal:, as_of:, system_available_at: nil,
                        input_manifest_id:, method_version:, capability_version:,
                        forward_denominator_key: nil, proposition_text: nil,
                        evidence: [], reason_code: "initial_detection",
                        payload: {})
    as_of = parse_time(as_of)
    system_available_at = parse_time(system_available_at || as_of)
    family_value = normalize_family(
      (family || {}).merge(
        "proposition_text" => proposition_text || family&.fetch("proposition_text", nil),
        "created_as_of" => family&.fetch("created_as_of", as_of.iso8601(6)),
        "system_available_at" => family&.fetch("system_available_at", system_available_at.iso8601(6)),
        "input_manifest_id" => family&.fetch("input_manifest_id", input_manifest_id),
        "method_version" => family&.fetch("method_version", method_version),
        "capability_version" => family&.fetch("capability_version", capability_version)
      )
    )
    signal_value = normalize_signal(
      (signal || {}).merge(
        "proposition_family_id" => family_value.fetch("proposition_family_id"),
        "first_detected_as_of" => signal&.fetch("first_detected_as_of", as_of.iso8601(6)),
        "first_detected_system_available_at" => signal&.fetch("first_detected_system_available_at", system_available_at.iso8601(6)),
        "initial_input_manifest_id" => signal&.fetch("initial_input_manifest_id", input_manifest_id),
        "initial_method_version" => signal&.fetch("initial_method_version", method_version),
        "initial_capability_version" => signal&.fetch("initial_capability_version", capability_version),
        "forward_denominator_key" => signal&.fetch("forward_denominator_key", forward_denominator_key || signal&.fetch("signal_key", family_value.fetch("family_key")))
      ), family: family_value
    )
    trigger_key = (signal || {}).fetch("initial_trigger_key", "#{signal_value.fetch("signal_id")}:initial:#{input_manifest_id}")
    transaction do
      insert_family_row!(family_value)
      insert_signal_row!(signal_value)
      trigger = append_trigger_in_transaction!(
        "event_key" => trigger_key, "signal_id" => signal_value.fetch("signal_id"),
        "proposition_family_id" => signal_value.fetch("proposition_family_id"),
        "trigger_kind" => "initial_detection", "run_mode" => "operational_detection",
        "as_of" => as_of.iso8601(6), "system_available_at" => system_available_at.iso8601(6),
        "input_manifest_id" => input_manifest_id, "method_version" => method_version,
        "capability_version" => capability_version, "evidence_role" => "unknown",
        "payload" => payload.merge("reason_code" => reason_code)
      )
      state = append_state_in_transaction!(
        "event_key" => "#{signal_value.fetch("signal_id")}:state:1:#{input_manifest_id}",
        "signal_id" => signal_value.fetch("signal_id"),
        "proposition_family_id" => signal_value.fetch("proposition_family_id"),
        "trigger_event_id" => trigger.fetch("trigger_event_id"), "to_state" => "candidate",
        "reason_code" => reason_code, "run_mode" => "operational_detection",
        "as_of" => as_of.iso8601(6), "system_available_at" => system_available_at.iso8601(6),
        "input_manifest_id" => input_manifest_id, "method_version" => method_version,
        "capability_version" => capability_version, "evidence_role" => "unknown", "payload" => payload
      )
      Array(evidence).each do |link|
        append_evidence_in_transaction!(link.merge(
          "signal_id" => signal_value.fetch("signal_id"),
          "proposition_family_id" => signal_value.fetch("proposition_family_id"),
          "as_of" => link.fetch("as_of", as_of.iso8601(6)),
          "system_available_at" => link.fetch("system_available_at", system_available_at.iso8601(6)),
          "input_manifest_id" => link.fetch("input_manifest_id", input_manifest_id),
          "method_version" => link.fetch("method_version", method_version),
          "capability_version" => link.fetch("capability_version", capability_version),
          "run_mode" => link.fetch("run_mode", "operational_detection")
        ))
      end
      { "signal" => signal_value, "trigger" => trigger, "state" => state }
    end
  rescue Error
    raise
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "detection is incomplete: #{error.message}"
  end

  alias publish_detection! record_detection!
  alias record_initial_detection! record_detection!

  def append_trigger_event!(event:)
    value = normalize_trigger(event)
    transaction { append_trigger_in_transaction!(value) }
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "trigger event is incomplete: #{error.message}"
  end

  alias append_trigger! append_trigger_event!

  def append_evidence_link!(link:)
    value = normalize_evidence(link)
    transaction { append_evidence_in_transaction!(value) }
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "evidence link is incomplete: #{error.message}"
  end

  alias add_evidence! append_evidence_link!

  def append_state_event!(event:)
    value = normalize_state_event(event)
    transaction do
      append_state_in_transaction!(value)
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "state event is incomplete: #{error.message}"
  end

  alias append_state! append_state_event!

  def append_relation_event!(event:)
    value = normalize_relation(event)
    transaction do
      payload_hash = hash_payload(value.fetch("payload"))
      insert = value.merge("relation_event_id" => value.fetch("relation_event_id"), "payload_hash" => payload_hash)
      existing = query("SELECT relation_event_id, event_key, payload_hash FROM signal_relation_event WHERE event_key = #{literal(value.fetch("event_key"))}")
      unless existing.empty?
        row = row_to_hash(existing.fetch(0), %w[relation_event_id event_key payload_hash])
        raise Error, "relation event idempotency payload differs" unless row.fetch("payload_hash") == payload_hash
        return read_relation_event(row.fetch("relation_event_id"))
      end
      execute(relation_insert_sql(insert))
      read_relation_event(insert.fetch("relation_event_id"))
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "relation event is incomplete: #{error.message}"
  end

  alias append_relation! append_relation_event!

  # As-known replay.  `as_of` is the world-time cutoff and
  # `system_available_at` is the knowledge cutoff; a late-arriving item whose
  # world timestamp is old cannot appear before its system-availability time.
  def replay(signal_id:, as_of:, system_available_at: nil, run_mode: nil)
    world_cutoff = parse_time(as_of)
    knowledge_cutoff = parse_time(system_available_at || as_of)
    mode = run_mode.nil? ? nil : validate_mode(run_mode)
    signal = read_signal(signal_id: signal_id)
    state_sql = <<~SQL
      SELECT state_event_id, event_key, signal_id, proposition_family_id,
             predecessor_state_event_id, trigger_event_id, state_revision,
             from_state, to_state, reason_code, run_mode, as_of::text,
             system_available_at::text, input_manifest_id, method_version,
             capability_version, evidence_role, payload::text, payload_hash, created_at::text
        FROM signal_state_event
       WHERE signal_id = #{literal(signal_id)}
         AND as_of <= #{literal(world_cutoff.iso8601(6))}
         AND system_available_at <= #{literal(knowledge_cutoff.iso8601(6))}
         #{mode ? "AND run_mode = #{literal(mode)}" : ""}
       ORDER BY state_revision ASC, state_event_id ASC
    SQL
    state_events = query(state_sql).map { |row| normalize_stored_state(row) }
    trigger_events = replay_events("signal_trigger_event", signal_id, world_cutoff, knowledge_cutoff, mode)
    evidence_links = replay_evidence(signal_id, world_cutoff, knowledge_cutoff, mode)
    relation_events = replay_relations(signal_id, world_cutoff, knowledge_cutoff, mode)
    current = state_events.last
    {
      "signal_id" => signal.fetch("signal_id"),
      "proposition_family_id" => signal.fetch("proposition_family_id"),
      "as_of" => world_cutoff.iso8601(6),
      "system_available_at" => knowledge_cutoff.iso8601(6),
      "run_mode" => mode,
      "first_detected_as_of" => signal.fetch("first_detected_as_of"),
      "first_detected_system_available_at" => signal.fetch("first_detected_system_available_at"),
      "first_detection_mode" => signal.fetch("initial_run_mode"),
      "current_state" => current&.fetch("to_state"),
      "current_state_event_id" => current&.fetch("state_event_id"),
      "state_events" => state_events,
      "trigger_events" => trigger_events,
      "evidence_links" => evidence_links,
      "relation_events" => relation_events,
      "retrospective_event_count" => (state_events + trigger_events + evidence_links + relation_events).count { |event| event.fetch("run_mode") == "retrospective_reanalysis" }
    }
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "replay is incomplete: #{error.message}"
  end

  alias replay_as_of replay
  alias point_in_time_replay replay

  def history(signal_id:)
    replay(signal_id: signal_id, as_of: Time.now.utc, system_available_at: Time.now.utc)
  end

  alias signal_history history

  def read_signal(signal_id:)
    row = query("SELECT signal_id, proposition_family_id, signal_key, first_detected_as_of::text, first_detected_system_available_at::text, initial_input_manifest_id, initial_method_version, initial_capability_version, initial_run_mode, forward_denominator_key, created_at::text FROM signal WHERE signal_id = #{literal(signal_id)}").fetch(0)
    row_to_hash(row, %w[signal_id proposition_family_id signal_key first_detected_as_of first_detected_system_available_at initial_input_manifest_id initial_method_version initial_capability_version initial_run_mode forward_denominator_key created_at])
  rescue IndexError
    raise Error, "signal is missing"
  end

  alias signal read_signal

  private

  def normalize_family(family)
    value = (family || {}).transform_keys(&:to_s)
    family_key = value.fetch("family_key", value.fetch("proposition_family_id", "")).to_s
    raise Error, "family_key is required" if family_key.empty?
    created_as_of = parse_time(value.fetch("created_as_of", value.fetch("as_of", Time.now.utc))).iso8601(6)
    system_available_at = parse_time(value.fetch("system_available_at", created_as_of)).iso8601(6)
    {
      "proposition_family_id" => value.fetch("proposition_family_id", proposition_family_id(family_key: family_key)).to_s,
      "family_key" => family_key,
      "proposition_text" => value.fetch("proposition_text", family_key).to_s,
      "created_as_of" => created_as_of,
      "system_available_at" => system_available_at,
      "input_manifest_id" => required(value, "input_manifest_id"),
      "method_version" => required(value, "method_version"),
      "capability_version" => required(value, "capability_version")
    }
  end

  def normalize_signal(signal, family: nil)
    value = (signal || {}).transform_keys(&:to_s)
    family_id = value.fetch("proposition_family_id", family&.fetch("proposition_family_id", "")).to_s
    key = value.fetch("signal_key", value.fetch("signal_id", "")).to_s
    raise Error, "signal_key is required" if key.empty?
    raise Error, "proposition_family_id is required" if family_id.empty?
    first_as_of = parse_time(value.fetch("first_detected_as_of", value.fetch("as_of", Time.now.utc))).iso8601(6)
    first_system = parse_time(value.fetch("first_detected_system_available_at", value.fetch("system_available_at", first_as_of))).iso8601(6)
    {
      "signal_id" => value.fetch("signal_id", signal_id(proposition_family_id: family_id, signal_key: key)).to_s,
      "proposition_family_id" => family_id,
      "signal_key" => key,
      "first_detected_as_of" => first_as_of,
      "first_detected_system_available_at" => first_system,
      "initial_input_manifest_id" => required(value, "initial_input_manifest_id"),
      "initial_method_version" => required(value, "initial_method_version"),
      "initial_capability_version" => required(value, "initial_capability_version"),
      "initial_run_mode" => "operational_detection",
      "forward_denominator_key" => required(value, "forward_denominator_key")
    }
  end

  def family_for_signal(signal, family)
    (family || {}).merge(
      "proposition_family_id" => signal.fetch("proposition_family_id"),
      "family_key" => (family || {}).fetch("family_key", signal.fetch("proposition_family_id")),
      "proposition_text" => (family || {}).fetch("proposition_text", signal.fetch("proposition_family_id")),
      "input_manifest_id" => (family || {}).fetch("input_manifest_id", signal.fetch("initial_input_manifest_id")),
      "method_version" => (family || {}).fetch("method_version", signal.fetch("initial_method_version")),
      "capability_version" => (family || {}).fetch("capability_version", signal.fetch("initial_capability_version")),
      "created_as_of" => (family || {}).fetch("created_as_of", signal.fetch("first_detected_as_of")),
      "system_available_at" => (family || {}).fetch("system_available_at", signal.fetch("first_detected_system_available_at"))
    )
  end

  def normalize_trigger(event)
    value = event.transform_keys(&:to_s)
    mode = validate_mode(value.fetch("run_mode", "operational_detection"))
    trigger_kind = value.fetch("trigger_kind", "retrigger").to_s
    raise Error, "invalid trigger kind" unless TRIGGER_KINDS.include?(trigger_kind)
    as_of = parse_time(required(value, "as_of")).iso8601(6)
    system = parse_time(value.fetch("system_available_at", as_of)).iso8601(6)
    {
      "trigger_event_id" => value.fetch("trigger_event_id", stable_id("trigger", value.fetch("event_key", ""))).to_s,
      "event_key" => required(value, "event_key"), "signal_id" => required(value, "signal_id"),
      "proposition_family_id" => required(value, "proposition_family_id"), "trigger_kind" => trigger_kind,
      "run_mode" => mode, "as_of" => as_of, "system_available_at" => system,
      "input_manifest_id" => required(value, "input_manifest_id"), "method_version" => required(value, "method_version"),
      "capability_version" => required(value, "capability_version"),
      "evidence_role" => validate_evidence_role(value.fetch("evidence_role", "unknown")),
      "evidence_key" => value["evidence_key"], "payload" => value.fetch("payload", {})
    }
  end

  def normalize_evidence(link)
    value = link.transform_keys(&:to_s)
    as_of = parse_time(required(value, "as_of")).iso8601(6)
    system = parse_time(value.fetch("system_available_at", as_of)).iso8601(6)
    {
      "evidence_link_id" => value.fetch("evidence_link_id", stable_id("evidence", value.fetch("evidence_key", ""), value.fetch("signal_id", ""), hash_payload(value.fetch("evidence_payload", {})))).to_s,
      "evidence_key" => required(value, "evidence_key"), "signal_id" => required(value, "signal_id"),
      "proposition_family_id" => required(value, "proposition_family_id"),
      "evidence_role" => validate_evidence_role(value.fetch("evidence_role", "unknown")),
      "as_of" => as_of, "system_available_at" => system,
      "input_manifest_id" => required(value, "input_manifest_id"), "method_version" => required(value, "method_version"),
      "capability_version" => required(value, "capability_version"),
      "run_mode" => validate_mode(value.fetch("run_mode", "operational_detection")),
      "late_evidence" => value.key?("late_evidence") ? !!value.fetch("late_evidence") : Time.parse(system) > Time.parse(as_of),
      "evidence_payload" => value.fetch("evidence_payload", {})
    }
  end

  def normalize_state_event(event)
    value = event.transform_keys(&:to_s)
    to_state = value.fetch("to_state").to_s
    raise Error, "invalid signal state" unless STATES.include?(to_state)
    as_of = parse_time(required(value, "as_of")).iso8601(6)
    system = parse_time(value.fetch("system_available_at", as_of)).iso8601(6)
    {
      "state_event_id" => value.fetch("state_event_id", stable_id("state", value.fetch("event_key", ""))).to_s,
      "event_key" => required(value, "event_key"), "signal_id" => required(value, "signal_id"),
      "proposition_family_id" => required(value, "proposition_family_id"),
      "trigger_event_id" => value["trigger_event_id"], "to_state" => to_state,
      "reason_code" => required(value, "reason_code"), "run_mode" => validate_mode(value.fetch("run_mode", "operational_detection")),
      "as_of" => as_of, "system_available_at" => system,
      "input_manifest_id" => required(value, "input_manifest_id"), "method_version" => required(value, "method_version"),
      "capability_version" => required(value, "capability_version"),
      "evidence_role" => validate_evidence_role(value.fetch("evidence_role", "unknown")),
      "payload" => value.fetch("payload", {}), "expected_predecessor_state_event_id" => value["expected_predecessor_state_event_id"]
    }
  end

  def normalize_relation(event)
    value = event.transform_keys(&:to_s)
    kind = value.fetch("relation_kind").to_s
    raise Error, "invalid relation kind" unless RELATION_KINDS.include?(kind)
    as_of = parse_time(required(value, "as_of")).iso8601(6)
    system = parse_time(value.fetch("system_available_at", as_of)).iso8601(6)
    {
      "relation_event_id" => value.fetch("relation_event_id", stable_id("relation", value.fetch("event_key", ""))).to_s,
      "event_key" => required(value, "event_key"), "relation_kind" => kind,
      "source_signal_id" => required(value, "source_signal_id"), "source_proposition_family_id" => required(value, "source_proposition_family_id"),
      "target_signal_id" => required(value, "target_signal_id"), "target_proposition_family_id" => required(value, "target_proposition_family_id"),
      "run_mode" => validate_mode(value.fetch("run_mode", "retrospective_reanalysis")), "as_of" => as_of, "system_available_at" => system,
      "input_manifest_id" => required(value, "input_manifest_id"), "method_version" => required(value, "method_version"),
      "capability_version" => required(value, "capability_version"), "reason_code" => required(value, "reason_code"),
      "payload" => value.fetch("payload", {})
    }
  end

  def insert_family_row!(value)
    execute(<<~SQL)
      INSERT INTO signal_proposition_family
        (proposition_family_id, family_key, proposition_text, created_as_of, system_available_at, input_manifest_id, method_version, capability_version)
      VALUES (#{literal(value.fetch("proposition_family_id"))}, #{literal(value.fetch("family_key"))}, #{literal(value.fetch("proposition_text"))}, #{literal(value.fetch("created_as_of"))}, #{literal(value.fetch("system_available_at"))}, #{literal(value.fetch("input_manifest_id"))}, #{literal(value.fetch("method_version"))}, #{literal(value.fetch("capability_version"))})
      ON CONFLICT (proposition_family_id) DO NOTHING
    SQL
  end

  def insert_signal_row!(value)
    execute(<<~SQL)
      INSERT INTO signal
        (signal_id, proposition_family_id, signal_key, first_detected_as_of, first_detected_system_available_at, initial_input_manifest_id, initial_method_version, initial_capability_version, initial_run_mode, forward_denominator_key)
      VALUES (#{literal(value.fetch("signal_id"))}, #{literal(value.fetch("proposition_family_id"))}, #{literal(value.fetch("signal_key"))}, #{literal(value.fetch("first_detected_as_of"))}, #{literal(value.fetch("first_detected_system_available_at"))}, #{literal(value.fetch("initial_input_manifest_id"))}, #{literal(value.fetch("initial_method_version"))}, #{literal(value.fetch("initial_capability_version"))}, 'operational_detection', #{literal(value.fetch("forward_denominator_key"))})
      ON CONFLICT (signal_id) DO NOTHING
    SQL
  end

  def append_trigger_in_transaction!(value)
    normalized = normalize_trigger(value)
    payload_hash = hash_payload(normalized.fetch("payload"))
    existing = query("SELECT trigger_event_id, payload_hash FROM signal_trigger_event WHERE event_key = #{literal(normalized.fetch("event_key"))}")
    unless existing.empty?
      row = row_to_hash(existing.fetch(0), %w[trigger_event_id payload_hash])
      raise Error, "trigger event idempotency payload differs" unless row.fetch("payload_hash") == payload_hash
      return read_trigger_event(row.fetch("trigger_event_id"))
    end
    normalized["payload_hash"] = payload_hash
    execute(<<~SQL)
      INSERT INTO signal_trigger_event
        (trigger_event_id, event_key, signal_id, proposition_family_id, trigger_kind, run_mode, as_of, system_available_at, input_manifest_id, method_version, capability_version, evidence_role, evidence_key, payload, payload_hash)
      VALUES (#{literal(normalized.fetch("trigger_event_id"))}, #{literal(normalized.fetch("event_key"))}, #{literal(normalized.fetch("signal_id"))}, #{literal(normalized.fetch("proposition_family_id"))}, #{literal(normalized.fetch("trigger_kind"))}, #{literal(normalized.fetch("run_mode"))}, #{literal(normalized.fetch("as_of"))}, #{literal(normalized.fetch("system_available_at"))}, #{literal(normalized.fetch("input_manifest_id"))}, #{literal(normalized.fetch("method_version"))}, #{literal(normalized.fetch("capability_version"))}, #{literal(normalized.fetch("evidence_role"))}, #{normalized.fetch("evidence_key").nil? ? "NULL" : literal(normalized.fetch("evidence_key"))}, #{json_literal(normalized.fetch("payload"))}, #{literal(payload_hash)})
    SQL
    read_trigger_event(normalized.fetch("trigger_event_id"))
  end

  def append_evidence_in_transaction!(value)
    normalized = normalize_evidence(value)
    evidence_hash = hash_payload(normalized.fetch("evidence_payload"))
    existing = query("SELECT evidence_link_id, evidence_hash FROM signal_evidence_link WHERE signal_id = #{literal(normalized.fetch("signal_id"))} AND evidence_key = #{literal(normalized.fetch("evidence_key"))} AND evidence_hash = #{literal(evidence_hash)} AND system_available_at = #{literal(normalized.fetch("system_available_at"))}")
    unless existing.empty?
      return read_evidence_link(row_to_hash(existing.fetch(0), %w[evidence_link_id evidence_hash]).fetch("evidence_link_id"))
    end
    normalized["evidence_hash"] = evidence_hash
    execute(<<~SQL)
      INSERT INTO signal_evidence_link
        (evidence_link_id, evidence_key, signal_id, proposition_family_id, evidence_role, as_of, system_available_at, input_manifest_id, method_version, capability_version, run_mode, late_evidence, evidence_payload, evidence_hash)
      VALUES (#{literal(normalized.fetch("evidence_link_id"))}, #{literal(normalized.fetch("evidence_key"))}, #{literal(normalized.fetch("signal_id"))}, #{literal(normalized.fetch("proposition_family_id"))}, #{literal(normalized.fetch("evidence_role"))}, #{literal(normalized.fetch("as_of"))}, #{literal(normalized.fetch("system_available_at"))}, #{literal(normalized.fetch("input_manifest_id"))}, #{literal(normalized.fetch("method_version"))}, #{literal(normalized.fetch("capability_version"))}, #{literal(normalized.fetch("run_mode"))}, #{normalized.fetch("late_evidence") ? "TRUE" : "FALSE"}, #{json_literal(normalized.fetch("evidence_payload"))}, #{literal(evidence_hash)})
    SQL
    read_evidence_link(normalized.fetch("evidence_link_id"))
  end

  def append_state_in_transaction!(value)
    normalized = normalize_state_event(value)
    payload_hash = hash_payload(normalized.fetch("payload"))
    existing = query("SELECT state_event_id, payload_hash FROM signal_state_event WHERE event_key = #{literal(normalized.fetch("event_key"))}")
    unless existing.empty?
      row = row_to_hash(existing.fetch(0), %w[state_event_id payload_hash])
      raise Error, "state event idempotency payload differs" unless row.fetch("payload_hash") == payload_hash
      return read_state_event(row.fetch("state_event_id"))
    end
    head = query("SELECT state_event_id, state_revision, to_state FROM signal_state_event WHERE signal_id = #{literal(normalized.fetch("signal_id"))} ORDER BY state_revision DESC LIMIT 1 FOR UPDATE")
    if head.empty?
      normalized["state_revision"] = 1
      normalized["from_state"] = nil
      normalized["predecessor_state_event_id"] = nil
    else
      current = head.fetch(0).split("\t", -1)
      normalized["state_revision"] = current.fetch(1).to_i + 1
      normalized["from_state"] = current.fetch(2)
      normalized["predecessor_state_event_id"] = current.fetch(0)
      if normalized.fetch("expected_predecessor_state_event_id") && normalized.fetch("expected_predecessor_state_event_id") != current.fetch(0)
        raise Error, "signal state expected predecessor differs"
      end
    end
    normalized["payload_hash"] = payload_hash
    execute(<<~SQL)
      INSERT INTO signal_state_event
        (state_event_id, event_key, signal_id, proposition_family_id, predecessor_state_event_id, trigger_event_id, state_revision, from_state, to_state, reason_code, run_mode, as_of, system_available_at, input_manifest_id, method_version, capability_version, evidence_role, payload, payload_hash)
      VALUES (#{literal(normalized.fetch("state_event_id"))}, #{literal(normalized.fetch("event_key"))}, #{literal(normalized.fetch("signal_id"))}, #{literal(normalized.fetch("proposition_family_id"))}, #{normalized.fetch("predecessor_state_event_id").nil? ? "NULL" : literal(normalized.fetch("predecessor_state_event_id"))}, #{normalized.fetch("trigger_event_id").nil? ? "NULL" : literal(normalized.fetch("trigger_event_id"))}, #{normalized.fetch("state_revision")}, #{normalized.fetch("from_state").nil? ? "NULL" : literal(normalized.fetch("from_state"))}, #{literal(normalized.fetch("to_state"))}, #{literal(normalized.fetch("reason_code"))}, #{literal(normalized.fetch("run_mode"))}, #{literal(normalized.fetch("as_of"))}, #{literal(normalized.fetch("system_available_at"))}, #{literal(normalized.fetch("input_manifest_id"))}, #{literal(normalized.fetch("method_version"))}, #{literal(normalized.fetch("capability_version"))}, #{literal(normalized.fetch("evidence_role"))}, #{json_literal(normalized.fetch("payload"))}, #{literal(payload_hash)})
    SQL
    read_state_event(normalized.fetch("state_event_id"))
  end

  def relation_insert_sql(value)
    <<~SQL
      INSERT INTO signal_relation_event
        (relation_event_id, event_key, relation_kind, source_signal_id, source_proposition_family_id, target_signal_id, target_proposition_family_id, run_mode, as_of, system_available_at, input_manifest_id, method_version, capability_version, reason_code, payload, payload_hash)
      VALUES (#{literal(value.fetch("relation_event_id"))}, #{literal(value.fetch("event_key"))}, #{literal(value.fetch("relation_kind"))}, #{literal(value.fetch("source_signal_id"))}, #{literal(value.fetch("source_proposition_family_id"))}, #{literal(value.fetch("target_signal_id"))}, #{literal(value.fetch("target_proposition_family_id"))}, #{literal(value.fetch("run_mode"))}, #{literal(value.fetch("as_of"))}, #{literal(value.fetch("system_available_at"))}, #{literal(value.fetch("input_manifest_id"))}, #{literal(value.fetch("method_version"))}, #{literal(value.fetch("capability_version"))}, #{literal(value.fetch("reason_code"))}, #{json_literal(value.fetch("payload"))}, #{literal(value.fetch("payload_hash"))})
    SQL
  end

  def replay_events(table, signal_id, world, knowledge, mode)
    fields = table == "signal_trigger_event" ? "trigger_event_id, event_key, signal_id, proposition_family_id, trigger_kind, run_mode, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, evidence_role, evidence_key, payload::text, payload_hash, created_at::text" : ""
    query("SELECT #{fields} FROM #{table} WHERE signal_id = #{literal(signal_id)} AND as_of <= #{literal(world.iso8601(6))} AND system_available_at <= #{literal(knowledge.iso8601(6))} #{mode ? "AND run_mode = #{literal(mode)}" : ""} ORDER BY as_of, system_available_at, created_at, event_key").map do |row|
      value = row_to_hash(row, %w[trigger_event_id event_key signal_id proposition_family_id trigger_kind run_mode as_of system_available_at input_manifest_id method_version capability_version evidence_role evidence_key payload payload_hash created_at])
      value["payload"] = JSON.parse(value.fetch("payload")); value
    end
  end

  def replay_evidence(signal_id, world, knowledge, mode)
    query("SELECT evidence_link_id, evidence_key, signal_id, proposition_family_id, evidence_role, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, run_mode, late_evidence::text, evidence_payload::text, evidence_hash, created_at::text FROM signal_evidence_link WHERE signal_id = #{literal(signal_id)} AND as_of <= #{literal(world.iso8601(6))} AND system_available_at <= #{literal(knowledge.iso8601(6))} #{mode ? "AND run_mode = #{literal(mode)}" : ""} ORDER BY as_of, system_available_at, created_at, evidence_key").map do |row|
      value = row_to_hash(row, %w[evidence_link_id evidence_key signal_id proposition_family_id evidence_role as_of system_available_at input_manifest_id method_version capability_version run_mode late_evidence evidence_payload evidence_hash created_at]); value["evidence_payload"] = JSON.parse(value.fetch("evidence_payload")); value["late_evidence"] = truthy?(value.fetch("late_evidence")); value
    end
  end

  def replay_relations(signal_id, world, knowledge, mode)
    query("SELECT relation_event_id, event_key, relation_kind, source_signal_id, source_proposition_family_id, target_signal_id, target_proposition_family_id, run_mode, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, reason_code, payload::text, payload_hash, created_at::text FROM signal_relation_event WHERE (source_signal_id = #{literal(signal_id)} OR target_signal_id = #{literal(signal_id)}) AND as_of <= #{literal(world.iso8601(6))} AND system_available_at <= #{literal(knowledge.iso8601(6))} #{mode ? "AND run_mode = #{literal(mode)}" : ""} ORDER BY as_of, system_available_at, created_at, event_key").map do |row|
      value = row_to_hash(row, %w[relation_event_id event_key relation_kind source_signal_id source_proposition_family_id target_signal_id target_proposition_family_id run_mode as_of system_available_at input_manifest_id method_version capability_version reason_code payload payload_hash created_at]); value["payload"] = JSON.parse(value.fetch("payload")); value
    end
  end

  def read_trigger_event(id)
    row = query("SELECT trigger_event_id, event_key, signal_id, proposition_family_id, trigger_kind, run_mode, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, evidence_role, evidence_key, payload::text, payload_hash, created_at::text FROM signal_trigger_event WHERE trigger_event_id = #{literal(id)}").fetch(0)
    value = row_to_hash(row, %w[trigger_event_id event_key signal_id proposition_family_id trigger_kind run_mode as_of system_available_at input_manifest_id method_version capability_version evidence_role evidence_key payload payload_hash created_at]); value["payload"] = JSON.parse(value.fetch("payload")); value
  end

  def read_evidence_link(id)
    row = query("SELECT evidence_link_id, evidence_key, signal_id, proposition_family_id, evidence_role, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, run_mode, late_evidence::text, evidence_payload::text, evidence_hash, created_at::text FROM signal_evidence_link WHERE evidence_link_id = #{literal(id)}").fetch(0)
    value = row_to_hash(row, %w[evidence_link_id evidence_key signal_id proposition_family_id evidence_role as_of system_available_at input_manifest_id method_version capability_version run_mode late_evidence evidence_payload evidence_hash created_at]); value["evidence_payload"] = JSON.parse(value.fetch("evidence_payload")); value["late_evidence"] = truthy?(value.fetch("late_evidence")); value
  end

  def read_state_event(id)
    row = query("SELECT state_event_id, event_key, signal_id, proposition_family_id, predecessor_state_event_id, trigger_event_id, state_revision, from_state, to_state, reason_code, run_mode, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, evidence_role, payload::text, payload_hash, created_at::text FROM signal_state_event WHERE state_event_id = #{literal(id)}").fetch(0)
    normalize_stored_state(row)
  end

  def read_relation_event(id)
    row = query("SELECT relation_event_id, event_key, relation_kind, source_signal_id, source_proposition_family_id, target_signal_id, target_proposition_family_id, run_mode, as_of::text, system_available_at::text, input_manifest_id, method_version, capability_version, reason_code, payload::text, payload_hash, created_at::text FROM signal_relation_event WHERE relation_event_id = #{literal(id)}").fetch(0)
    value = row_to_hash(row, %w[relation_event_id event_key relation_kind source_signal_id source_proposition_family_id target_signal_id target_proposition_family_id run_mode as_of system_available_at input_manifest_id method_version capability_version reason_code payload payload_hash created_at]); value["payload"] = JSON.parse(value.fetch("payload")); value
  end

  def normalize_stored_state(row)
    value = row_to_hash(row, %w[state_event_id event_key signal_id proposition_family_id predecessor_state_event_id trigger_event_id state_revision from_state to_state reason_code run_mode as_of system_available_at input_manifest_id method_version capability_version evidence_role payload payload_hash created_at])
    value["state_revision"] = value.fetch("state_revision").to_i; value["payload"] = JSON.parse(value.fetch("payload")); value
  end

  def immutable_match!(existing, expected, label)
    expected.each do |key, value|
      next unless existing.key?(key)
      raise Error, "#{label} immutable payload differs" unless existing.fetch(key).to_s == value.to_s
    end
  end

  def required(value, key)
    result = value.fetch(key).to_s
    raise Error, "#{key} is required" if result.empty?
    result
  end

  def validate_mode(value)
    mode = value.to_s
    raise Error, "invalid run mode" unless MODES.include?(mode)
    mode
  end

  def validate_evidence_role(value)
    role = value.to_s
    raise Error, "invalid evidence role" unless EVIDENCE_ROLES.include?(role)
    role
  end

  def parse_time(value)
    (value.is_a?(Time) ? value : Time.parse(value.to_s)).utc
  rescue ArgumentError, TypeError
    raise Error, "invalid timestamp"
  end

  def stable_id(prefix, *parts)
    "#{prefix}-#{Digest::SHA256.hexdigest(parts.map(&:to_s).join("\u0000"))}"
  end

  def hash_payload(value)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(value)))
  end

  def canonicalize(value)
    case value
    when Hash then value.keys.map(&:to_s).sort.to_h { |key| [key, canonicalize(value.key?(key) ? value[key] : value[key.to_sym])] }
    when Array then value.map { |child| canonicalize(child) }
    else value
    end
  end

  def json_literal(value)
    "#{literal(JSON.generate(canonicalize(value)))}::jsonb"
  end

  def truthy?(value)
    %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def row_to_hash(row, keys)
    keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def query(sql)
    return transaction_query(sql) if @transaction_io
    stdout, stderr, status = Open3.capture3(*psql_args + ["-c", sql])
    raise Error, stderr.strip unless status.success?
    stdout.lines(chomp: true).reject(&:empty?)
  end

  def execute(sql)
    query(sql)
    true
  end

  def transaction
    raise Error, "nested transaction is not supported" if @transaction_io
    open_transaction
    transaction_query("BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
    result = yield
    transaction_query("COMMIT")
    result
  rescue StandardError
    begin transaction_query("ROLLBACK") if @transaction_io; rescue StandardError; end
    raise
  ensure
    close_transaction
  end

  def psql_args
    [@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end

  def open_transaction
    @transaction_io = Open3.popen3(*psql_args)
    @transaction_stdin, @transaction_stdout, @transaction_stderr, @transaction_wait_thread = @transaction_io
    @transaction_stdin.sync = true; @transaction_stdout.sync = true
  end

  def transaction_query(sql)
    marker = "__signal_lifecycle_txn_marker_#{SecureRandom.hex(12)}__"
    command = sql.to_s.strip; command = "#{command};" unless command.end_with?(";")
    @transaction_stdin.write("#{command}\nSELECT #{literal(marker)};\n"); @transaction_stdin.flush
    rows = []
    loop do
      line = @transaction_stdout.gets
      raise Error, "transaction connection closed" if line.nil?
      value = line.chomp; break if value == marker; rows << value unless value.empty?
    end
    rows
  end

  def close_transaction
    return unless @transaction_io
    [@transaction_stdin, @transaction_stdout, @transaction_stderr].each { |io| io.close unless io.closed? }
    @transaction_wait_thread.value if @transaction_wait_thread
  rescue IOError
    nil
  ensure
    @transaction_io = nil
  end
end
