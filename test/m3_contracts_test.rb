# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m3_contracts"

class M3ContractsTest < Minitest::Test
  def test_sig_001_requires_cross_language_actor_diffusion_and_action
    result = M3::SignalContract.emergence_diffusion(
      signal_types: %w[emergence diffusion],
      observations: [
        { "language" => "zh", "actor_class" => "researcher" },
        { "language" => "en", "actor_class" => "buyer" },
        { "language" => "es", "actor_class" => "operator" }
      ],
      actions: [{ "evidence_id" => "action-1" }]
    )
    assert_equal 3, result.fetch("languageCount")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.emergence_diffusion(signal_types: ["emergence"], observations: [{ "language" => "en", "actor_class" => "one" }], actions: [])
    end
  end

  def test_sig_005_records_independent_local_adoption_edges
    result = M3::SignalContract.independent_actor_adoption(
      adoptions: %w[a b c].map { |actor| { "actor_id" => actor, "evidence_id" => "e-#{actor}", "cited_source" => false } }
    )
    assert_equal 3, result.fetch("edgeCount")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.independent_actor_adoption(adoptions: [{ "actor_id" => "a", "evidence_id" => "e", "cited_source" => true }] * 3)
    end
  end

  def test_sig_006_does_not_merge_gold_clusters
    result = M3::SignalContract.separate_gold_clusters(
      translations: [{ "predicted_cluster_id" => "gold-a", "gold_cluster_id" => "gold-a" }, { "predicted_cluster_id" => "gold-b", "gold_cluster_id" => "gold-b" }],
      gold_cluster_ids: %w[gold-a gold-b]
    )
    assert result.fetch("clustersSeparated")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.separate_gold_clusters(translations: [{ "predicted_cluster_id" => "gold-a", "gold_cluster_id" => "gold-b" }], gold_cluster_ids: %w[gold-a gold-b])
    end
  end

  def test_sig_007_distinguishes_negative_attention_from_adoption
    result = M3::SignalContract.stance_report(
      baseline_mentions: 10, current_mentions: 20, current_stances: %w[opposed sarcastic negative supportive],
      baseline_actions: ["discussion"], current_actions: ["discussion"]
    )
    assert_equal "attention_increased_without_adoption", result.fetch("interpretation")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.stance_report(baseline_mentions: 10, current_mentions: 20, current_stances: %w[supportive supportive negative], baseline_actions: ["discussion"], current_actions: ["deployment"])
    end
  end

  def test_sig_008_reports_missing_action_evidence
    result = M3::SignalContract.action_stage(
      baseline_mentions: 5, current_mentions: 8, baseline_action_stage: "discussion", current_action_stage: "discussion", missing_action_evidence: ["procurement"]
    )
    assert_equal "attention_without_action", result.fetch("interpretation")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.action_stage(baseline_mentions: 5, current_mentions: 8, baseline_action_stage: "discussion", current_action_stage: "deployment", missing_action_evidence: ["procurement"])
    end
  end

  def test_sig_010_reactivates_without_rewriting_old_cycle
    result = M3::SignalContract.reactivate(
      previous_cycle: { "signal_id" => "sig-1", "version" => 2, "status" => "extinct" },
      new_actions: [{ "evidence_id" => "new-action", "independent" => true }]
    )
    assert_equal "reactivated", result.fetch("status")
    assert_equal "sig-1", result.fetch("previousSignalId")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.reactivate(previous_cycle: { "signal_id" => "sig-1", "version" => 2, "status" => "active" }, new_actions: [{ "evidence_id" => "new-action", "independent" => true }])
    end
  end

  def test_sig_012_never_promotes_temporal_correlation_to_mechanism
    association = M3::SignalContract.causal_claim(relation: { "temporal_order" => true })
    assert_equal "observed_association", association.fetch("relationType")
    refute association.fetch("supportedMechanism")
    source = M3::SignalContract.causal_claim(relation: { "source_claimed_cause" => true })
    assert_equal "source_claimed_cause", source.fetch("relationType")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.causal_claim(relation: { "temporal_order" => true, "mechanism_evidence" => true })
    end
  end

  def test_sig_013_uses_frozen_seasonal_baseline
    result = M3::SignalContract.seasonal_anomaly(
      observations: [{ "count" => 102 }, { "count" => 98 }], baseline: [{ "count" => 100 }, { "count" => 100 }], threshold: 0.05,
      baseline_version: "season-v1", seasonal_features: %w[weekday holiday month_end]
    )
    refute result.fetch("triggered")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.seasonal_anomaly(observations: [{ "count" => 100 }], baseline: [{ "count" => 100 }, { "count" => 100 }], threshold: 0.05, baseline_version: "season-v1", seasonal_features: ["weekday"])
    end
  end

  def test_sig_014_controls_multiple_testing
    result = M3::SignalContract.fdr_scan(
      tests: [{ "p_value" => 0.001, "gold_anomaly" => true }] + Array.new(9) { { "p_value" => 0.5, "gold_anomaly" => false } }, alpha: 0.05
    )
    assert_equal 10, result.fetch("testsCount")
    assert result.fetch("decision")
    empirical = M3::SignalContract.fdr_scan(tests: [{ "false_alarm" => false }, { "false_alarm" => true }], alpha: 0.6)
    assert_equal "non_probability", empirical.fetch("detectorType")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.fdr_scan(tests: [{ "p_value" => 2.0 }], alpha: 0.05)
    end
  end

  def test_sig_016_handles_sparse_zero_denominator_and_independence
    result = M3::SignalContract.sparse_series(rows: [
      { "numerator" => 0, "denominator" => 0, "independent" => false },
      { "numerator" => 1, "denominator" => 4, "independent" => true }
    ])
    assert_includes result.fetch("reasonCodes"), "SPARSE_SUPPORT"
    assert result.fetch("interval").all? { |value| value.finite? }
    assert_equal 1, result.fetch("independentConfirmationCount")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.sparse_series(rows: [{ "numerator" => 5, "denominator" => 4 }])
    end
  end

  def test_sig_017_manifest_binds_concrete_detector_versions
    manifest = [
      { "d05_key" => "topic-x", "detector_id" => "detector", "detector_version_id" => "v1" },
      { "d05_key" => "topic-x", "detector_id" => "detector", "detector_version_id" => "v2" }
    ]
    result = M3::SignalContract.detector_manifest(manifest: manifest, detectors: manifest)
    assert_equal 2, result.fetch("manifestEntries")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.detector_manifest(manifest: [{ "d05_key" => "topic-x", "detector_id" => "detector", "detector_version_id" => "v1" }], detectors: manifest)
    end
  end

  def test_sig_021_keeps_unknown_exploration_out_of_signal_counts
    result = M3::SignalContract.unknown_exploration(
      items: [
        { "coverage_item_id" => "u", "domain" => "unknown", "publisher_role" => "unknown", "quality" => "qualified" },
        { "coverage_item_id" => "bad", "domain" => "known", "publisher_role" => "low", "quality" => "low" }
      ],
      detector_results: [{ "coverage_item_id" => "u", "decision" => "no-candidate" }, { "coverage_item_id" => "bad", "decision" => "no-candidate" }]
    )
    assert_equal 0, result.fetch("candidateCountAdded")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.unknown_exploration(items: [{ "coverage_item_id" => "u", "domain" => "unknown", "publisher_role" => "unknown", "quality" => "qualified" }], detector_results: [{ "coverage_item_id" => "u", "decision" => "candidate" }])
    end
  end

  def test_sig_024_materializes_eligibility_for_every_item
    result = M3::SignalContract.exploration_eligibility(
      items: [{ "coverage_item_id" => "a" }, { "coverage_item_id" => "b" }],
      decisions: [{ "coverage_item_id" => "a", "eligible" => true, "exploration_unit_id" => "unit-a" }, { "coverage_item_id" => "b", "eligible" => false }]
    )
    assert_equal 2, result.fetch("terminalDenominator")
    assert_raises(M3::SignalContract::Error) do
      M3::SignalContract.exploration_eligibility(items: [{ "coverage_item_id" => "a" }, { "coverage_item_id" => "b" }], decisions: [{ "coverage_item_id" => "a", "eligible" => true }])
    end
  end

  def test_sel_001_keeps_signal_types_lane_and_surfaces_separate
    result = M3::SelectionContract.multi_signal_allocation(candidate: { "signal_types" => %w[emergence diffusion], "allocation_lane" => ["random_exploration"], "surface_sections" => %w[daily explore] })
    assert result.fetch("selectionValid")
    assert_raises(M3::SelectionContract::Error) do
      M3::SelectionContract.multi_signal_allocation(candidate: { "signal_types" => ["emergence"], "allocation_lane" => ["daily", "explore"], "surface_sections" => ["daily"] })
    end
  end

  def test_sel_003_reports_quota_infeasibility_without_silent_reweighting
    result = M3::SelectionContract.quota_infeasible(
      constraints: [{ "dimension" => "language:ar", "minimum" => 1 }], candidates: [{ "dimensions" => { "language:en" => 4 } }]
    )
    assert_equal "QUOTA_INFEASIBLE", result.fetch("reasonCode")
    assert_equal "language:ar", result.fetch("missingConstraints").first
  end

  def test_sel_004_stably_breaks_pareto_ties
    result = M3::SelectionContract.pareto_tie_break(
      candidates: [{ "candidate_id" => "b", "scores" => { "novelty" => 1, "independence" => 1 } }, { "candidate_id" => "a", "scores" => { "novelty" => 1, "independence" => 1 } }],
      core_dimensions: %w[novelty independence], signal_type: "diffusion"
    )
    assert_equal %w[a b], result.fetch("orderedCandidateIds")
    assert_equal "STABLE_TIE_BREAK", result.fetch("reasonCode")
  end

  def test_adv_001_counts_origins_once_and_marks_sybil_risk
    result = M3::AdversarialContract.sybil_risk(domains: [
      { "origin_id" => "origin-1", "synchronized" => true, "template_match" => true, "reference_chain" => true },
      { "origin_id" => "origin-1", "synchronized" => true, "template_match" => true, "reference_chain" => true }
    ])
    assert_equal "high", result.fetch("sybilRisk")
    assert_equal 1, result.fetch("independentOriginCount")
  end

  def test_adv_004_does_not_confirm_unverifiable_claim
    result = M3::AdversarialContract.unverifiable_action(evidence: { "registry_verified" => false, "original_record_verified" => false })
    assert_equal "unverified_claim", result.fetch("evidenceScope")
    verified = M3::AdversarialContract.unverifiable_action(evidence: { "registry_verified" => true, "original_record_verified" => false })
    assert_equal "confirmed_action", verified.fetch("evidenceScope")
  end

  def test_adv_005_preserves_manipulation_as_a_distinct_event
    result = M3::AdversarialContract.manipulation_event(posts: [{ "bot" => true, "coordinated" => true }])
    assert_includes result.fetch("surfaceSections"), "manipulation_event"
    refute result.fetch("naturalPublicSupport")
  end

  def test_mod_003_retirement_preserves_replay_audit_inputs
    result = M3::ModelContract.retire(model_snapshot: { "model_id" => "closed-v1", "input_manifest" => "manifest-1", "output_artifact_ids" => ["out-1"], "config_hash" => "cfg", "evidence_ids" => ["e-1"] })
    assert_equal "retired", result.fetch("status")
    refute result.fetch("recomputeRequired")
    assert_raises(M3::ModelContract::Error) do
      M3::ModelContract.retire(model_snapshot: { "model_id" => "closed-v1" })
    end
  end

  def test_wrm_004_segments_series_when_collection_capability_changes
    result = M3::WarmingContract.history_break(records: [{ "observed_at" => "2026-01-01" }, { "observed_at" => "2026-02-01" }], new_capability_version: "translation-v2")
    assert result.fetch("coverageShift")
    refute result.fetch("conceptNoveltyAllowed")
    assert_equal "segment_or_reset", result.fetch("timeSeriesAction")
  end
end
