# frozen_string_literal: true

require "digest"
require "json"
require "time"

module M4
  module MemoryContract
    class Error < StandardError; end
    module_function

    def create_candidate(assumption:, personal_scope_id:, evidence_ids:, counterevidence_ids:, created_at:)
      raise Error, "PRI-004 assumption is required" if assumption.to_s.strip.empty?
      raise Error, "PRI-004 personal scope is required" if personal_scope_id.to_s.strip.empty?
      raise Error, "PRI-004 evidence and counterevidence must be explicit" if Array(evidence_ids).empty? && Array(counterevidence_ids).empty?
      raise Error, "PRI-004 created_at is required" if created_at.to_s.strip.empty?
      candidate = {
        "memory_candidate_id" => Digest::SHA256.hexdigest([personal_scope_id, assumption, created_at].join("\u0000"))[0, 16],
        "assumption" => assumption,
        "personal_scope_id" => personal_scope_id,
        "evidence_ids" => Array(evidence_ids),
        "counterevidence_ids" => Array(counterevidence_ids),
        "state" => "pending",
        "created_at" => created_at,
        "personal_interpretation_eligible" => false,
        "decision_event_ids" => []
      }
      candidate.merge("candidate_checksum" => Digest::SHA256.hexdigest(JSON.generate(candidate)))
    end

    def decide_candidate(candidate:, decision:, user_confirmed: false, auto_rule: nil, event_id:)
      raise Error, "PRI-004 candidate must remain pending before a decision" unless candidate.fetch("state") == "pending"
      raise Error, "PRI-004 decision event is required" if event_id.to_s.strip.empty?
      decision = decision.to_s
      unless %w[accepted rejected].include?(decision)
        raise Error, "PRI-004 decision must be accepted or rejected"
      end
      authorized = user_confirmed || (auto_rule.is_a?(Hash) && auto_rule.fetch("enabled", false) && !auto_rule.fetch("rule_version", "").to_s.empty?)
      raise Error, "PRI-004 acceptance requires user confirmation or an explicit auto-memory rule" if decision == "accepted" && !authorized
      event = {
        "event_id" => event_id,
        "type" => "MemoryCandidateDecisionEvent",
        "candidate_id" => candidate.fetch("memory_candidate_id"),
        "decision" => decision,
        "recorded_at" => Time.now.utc.iso8601,
        "user_confirmed" => user_confirmed,
        "auto_rule_version" => auto_rule && auto_rule["rule_version"]
      }
      candidate.merge(
        "state" => decision,
        "personal_interpretation_eligible" => decision == "accepted",
        "decision_event_ids" => Array(candidate.fetch("decision_event_ids")) + [event_id],
        "decision_event" => event
      )
    rescue KeyError, TypeError => error
      raise Error, "PRI-004 candidate decision is incomplete: #{error.message}"
    end
  end
end
