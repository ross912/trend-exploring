# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m4_contracts"

class M4ContractsTest < Minitest::Test
  def candidate
    M4::MemoryContract.create_candidate(
      assumption: "market adoption will accelerate", personal_scope_id: "scope-1", evidence_ids: ["e-1"], counterevidence_ids: ["c-1"], created_at: "2026-08-08T07:00:00Z"
    )
  end

  def test_pri_004_candidate_is_pending_and_not_used_for_interpretation
    result = candidate
    assert_equal "pending", result.fetch("state")
    refute result.fetch("personal_interpretation_eligible")
    assert result.fetch("candidate_checksum")
    assert_raises(M4::MemoryContract::Error) do
      M4::MemoryContract.create_candidate(assumption: "x", personal_scope_id: "scope-1", evidence_ids: [], counterevidence_ids: [], created_at: "2026-08-08T07:00:00Z")
    end
  end

  def test_pri_004_acceptance_requires_confirmation_or_explicit_rule_and_is_auditable
    assert_raises(M4::MemoryContract::Error) do
      M4::MemoryContract.decide_candidate(candidate: candidate, decision: "accepted", event_id: "event-1")
    end
    accepted = M4::MemoryContract.decide_candidate(candidate: candidate, decision: "accepted", user_confirmed: true, event_id: "event-2")
    assert_equal "accepted", accepted.fetch("state")
    assert accepted.fetch("personal_interpretation_eligible")
    assert_equal "MemoryCandidateDecisionEvent", accepted.dig("decision_event", "type")
    rejected = M4::MemoryContract.decide_candidate(candidate: candidate, decision: "rejected", event_id: "event-3")
    refute rejected.fetch("personal_interpretation_eligible")
    ruled = M4::MemoryContract.decide_candidate(candidate: candidate, decision: "accepted", auto_rule: { "enabled" => true, "rule_version" => "rule-v1" }, event_id: "event-4")
    assert_equal "rule-v1", ruled.dig("decision_event", "auto_rule_version")
  end
end
