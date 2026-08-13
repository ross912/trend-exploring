#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "time"
require_relative "../../lib/signal_lifecycle_store"
require_relative "../../lib/world_change_detector"
require_relative "../../lib/world_change_store"

options = { as_of: nil, run_id: nil, limit: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: detect_world_changes.rb --as-of ISO8601 [--run-id ID] [--limit N]"
  parser.on("--as-of TIME", "required controlled analysis cutoff") { |value| options[:as_of] = value }
  parser.on("--run-id ID", "optional deterministic run id") { |value| options[:run_id] = value }
  parser.on("--limit N", Integer, "optional source-version limit") { |value| options[:limit] = value }
end.parse!

abort "--as-of is required" if options.fetch(:as_of).to_s.empty?

def stable_input_hash(items)
  canonical = Array(items).map do |item|
    item.to_h.transform_keys(&:to_s).reject { |key, _| key == "registry_enabled" }
  end.sort_by { |item| [item.fetch("version_id", ""), item.fetch("created_at", "")] }
  Digest::SHA256.hexdigest(JSON.generate(canonical))
end

def lifecycle_for_candidate!(store, candidate, run:, as_of:)
  family_key = candidate.fetch("candidate_key")
  family_id = store.proposition_family_id(family_key: family_key)
  signal_id = store.signal_id(proposition_family_id: family_id, signal_key: family_key)
  system_available_at = [Time.now.utc, as_of].max.iso8601(6)
  evidence = []
  candidate.fetch("channels").each do |channel, channel_value|
    Array(channel_value.fetch("evidence")).each do |row|
      evidence << {
        "evidence_key" => "#{candidate.fetch("candidate_key")}:#{channel}:#{row.fetch("version_id")}",
        "evidence_role" => "support",
        "as_of" => as_of.iso8601(6), "system_available_at" => system_available_at,
        "evidence_payload" => row.merge("candidate_key" => candidate.fetch("candidate_key"), "channel" => channel)
      }
    end
    Array(channel_value.fetch("contradicting_evidence")).each do |row|
      evidence << {
        "evidence_key" => "#{candidate.fetch("candidate_key")}:#{channel}:#{row.fetch("version_id")}:contradicting",
        "evidence_role" => "contradictory",
        "as_of" => as_of.iso8601(6), "system_available_at" => system_available_at,
        "evidence_payload" => row.merge("candidate_key" => candidate.fetch("candidate_key"), "channel" => channel)
      }
    end
  end
  payload = { "candidate_key" => candidate.fetch("candidate_key"), "candidate_status" => candidate.fetch("candidate_status"), "channel_count" => candidate.fetch("channel_count"), "qualifying_version_ids" => candidate.fetch("qualifying_version_ids"), "contradicting_evidence" => candidate.fetch("contradicting_evidence") }
  begin
    store.read_signal(signal_id: signal_id)
    store.append_trigger_event!(event: {
      "event_key" => "#{signal_id}:retrigger:#{run.fetch("run_id")}",
      "signal_id" => signal_id, "proposition_family_id" => family_id,
      "trigger_kind" => "retrigger", "run_mode" => "operational_detection",
      "as_of" => as_of.iso8601(6), "system_available_at" => system_available_at,
      "input_manifest_id" => run.fetch("run_id"), "method_version" => run.fetch("detector_version"),
      "capability_version" => run.fetch("detector_version"),
      "evidence_role" => candidate.fetch("contradicting_evidence").empty? ? "support" : "contradictory",
      "payload" => payload
    })
    state = store.history(signal_id: signal_id).fetch("state_events").last
    to_state = candidate.fetch("contradicting_evidence").empty? ? "watching" : "weakening"
    store.append_state_event!(event: {
      "event_key" => "#{signal_id}:state:#{run.fetch("run_id")}",
      "signal_id" => signal_id, "proposition_family_id" => family_id,
      "to_state" => to_state, "reason_code" => candidate.fetch("contradicting_evidence").empty? ? "world_change_candidate_refresh" : "world_change_contradiction",
      "run_mode" => "operational_detection", "as_of" => as_of.iso8601(6),
      "system_available_at" => system_available_at, "input_manifest_id" => run.fetch("run_id"),
      "method_version" => run.fetch("detector_version"), "capability_version" => run.fetch("detector_version"),
      "evidence_role" => candidate.fetch("contradicting_evidence").empty? ? "support" : "contradictory",
      "expected_predecessor_state_event_id" => state && state.fetch("state_event_id"),
      "payload" => payload
    })
    evidence.each { |link| store.append_evidence_link!(link: link.merge("signal_id" => signal_id, "proposition_family_id" => family_id, "input_manifest_id" => run.fetch("run_id"), "method_version" => run.fetch("detector_version"), "capability_version" => run.fetch("detector_version"), "run_mode" => "operational_detection")) }
  rescue SignalLifecycleStore::Error => error
    if error.message.include?("signal is missing")
      store.record_detection!(
        family: { "family_key" => family_key, "proposition_text" => candidate.fetch("label") },
        signal: { "signal_key" => family_key, "forward_denominator_key" => family_key },
        as_of: as_of.iso8601(6), system_available_at: system_available_at,
        input_manifest_id: run.fetch("run_id"), method_version: run.fetch("detector_version"),
        capability_version: run.fetch("detector_version"), evidence: evidence,
        reason_code: "world_change_candidate_detected", payload: payload
      )
    else
      raise
    end
  end
  { "candidate_key" => candidate.fetch("candidate_key"), "status" => "recorded", "signal_id" => signal_id }
rescue SignalLifecycleStore::Error => error
  { "candidate_key" => candidate.fetch("candidate_key"), "status" => "failed", "error" => error.message }
end

begin
  as_of = Time.iso8601(options.fetch(:as_of)).utc
  source_store = WorldChangeStore.new
  items = source_store.input_items(as_of: as_of, limit: options[:limit])
  detector = WorldChangeDetector.new
  candidates = detector.analyze(items: items, now: as_of)
  input_hash = stable_input_hash(items)
  run_id = options.fetch(:run_id).to_s
  run_id = "scheduled-world-change-#{as_of.strftime('%Y%m%dT%H%M%S')}-#{input_hash[0, 16]}" if run_id.empty?
  status = "evaluated"
  run = source_store.publish!(run: {
    "run_id" => run_id, "as_of" => as_of.iso8601(6), "input_cutoff" => as_of.iso8601(6),
    "input_hash" => input_hash, "detector_version" => detector.detector_version, "status" => status,
    "validated_precision" => true,
    "validation_manifest_hash" => detector.precision_validation_manifest_hash
  }, candidates: candidates)
  lifecycle = Array(run.fetch("candidates")).map { |candidate| lifecycle_for_candidate!(SignalLifecycleStore.new, candidate, run: run, as_of: as_of) }
  run["lifecycle"] = { "status" => lifecycle.any? { |entry| entry.fetch("status") == "failed" } ? "degraded" : "recorded", "events" => lifecycle }
  puts JSON.generate(run)
rescue WorldChangeDetector::Error, WorldChangeStore::Error, ArgumentError => error
  warn error.message
  exit 1
end
