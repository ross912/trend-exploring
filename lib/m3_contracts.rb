# frozen_string_literal: true

require "digest"
require "json"

module M3
  module SignalContract
    class Error < StandardError; end
    module_function

    def emergence_diffusion(signal_types:, observations:, actions:)
      languages = observations.map { |row| row.fetch("language").to_s }.uniq
      actors = observations.map { |row| row.fetch("actor_class").to_s }.uniq
      raise Error, "SIG-001 requires three languages" unless languages.length >= 3
      raise Error, "SIG-001 requires three independent actor classes" unless actors.length >= 3
      raise Error, "SIG-001 requires a verifiable real-world action" if Array(actions).empty?

      types = Array(signal_types).map(&:to_s).uniq
      raise Error, "SIG-001 requires emergence and diffusion signal types" unless %w[emergence diffusion].all? { |type| types.include?(type) }

      {
        "signalTypes" => types,
        "languageCount" => languages.length,
        "actorClassCount" => actors.length,
        "actionEvidenceIds" => Array(actions).map { |action| action.fetch("evidence_id").to_s }
      }
    rescue KeyError, TypeError => error
      raise Error, "SIG-001 fixture is incomplete: #{error.message}"
    end

    def independent_actor_adoption(adoptions:)
      rows = Array(adoptions)
      raise Error, "SIG-005 requires at least three adoptions" if rows.length < 3
      actors = rows.map { |row| row.fetch("actor_id").to_s }
      raise Error, "SIG-005 actor adoption must be independent" unless actors.uniq.length == actors.length
      rows.each do |row|
        raise Error, "SIG-005 requires a local evidence edge" if row.fetch("evidence_id").to_s.empty?
        raise Error, "SIG-005 cited adoption is not independent" if row.fetch("cited_source", false)
      end
      { "actorAdoption" => true, "diffusionPath" => rows.map { |row| row.fetch("actor_id") }, "edgeCount" => rows.length }
    rescue KeyError, TypeError => error
      raise Error, "SIG-005 fixture is incomplete: #{error.message}"
    end

    def separate_gold_clusters(translations:, gold_cluster_ids:)
      expected = Array(gold_cluster_ids).map(&:to_s).uniq
      raise Error, "SIG-006 requires at least two gold clusters" if expected.length < 2
      rows = Array(translations)
      raise Error, "SIG-006 translations are empty" if rows.empty?
      mismatches = rows.select { |row| row.fetch("predicted_cluster_id").to_s != row.fetch("gold_cluster_id").to_s }
      raise Error, "SIG-006 gold cluster merge detected" unless mismatches.empty?
      { "goldClusterIds" => expected, "clustersSeparated" => true, "translationCount" => rows.length }
    rescue KeyError, TypeError => error
      raise Error, "SIG-006 fixture is incomplete: #{error.message}"
    end

    def stance_report(baseline_mentions:, current_mentions:, current_stances:, baseline_actions:, current_actions:)
      raise Error, "SIG-007 mentions did not increase" unless Integer(current_mentions) > Integer(baseline_mentions)
      stances = Array(current_stances).map { |stance| stance.to_s }
      raise Error, "SIG-007 stance observations are empty" if stances.empty?
      negative = stances.count { |stance| %w[opposed skeptical sarcastic negative].include?(stance) }
      raise Error, "SIG-007 negative stance is not dominant" unless negative.to_f / stances.length > 0.5
      raise Error, "SIG-007 action stage changed" unless Array(baseline_actions) == Array(current_actions)
      { "mentionDelta" => Integer(current_mentions) - Integer(baseline_mentions), "negativeStanceRate" => negative.to_f / stances.length,
        "actionStageUnchanged" => true, "interpretation" => "attention_increased_without_adoption" }
    rescue ArgumentError, TypeError => error
      raise Error, "SIG-007 fixture is incomplete: #{error.message}"
    end

    def action_stage(baseline_mentions:, current_mentions:, baseline_action_stage:, current_action_stage:, missing_action_evidence:)
      raise Error, "SIG-008 attention did not increase" unless Integer(current_mentions) > Integer(baseline_mentions)
      raise Error, "SIG-008 action stage changed" unless baseline_action_stage.to_s == current_action_stage.to_s
      raise Error, "SIG-008 missing action evidence must be explicit" if Array(missing_action_evidence).empty?
      { "attentionDelta" => Integer(current_mentions) - Integer(baseline_mentions), "actionStage" => current_action_stage,
        "missingActionEvidence" => Array(missing_action_evidence), "interpretation" => "attention_without_action" }
    rescue ArgumentError, TypeError => error
      raise Error, "SIG-008 fixture is incomplete: #{error.message}"
    end

    def reactivate(previous_cycle:, new_actions:)
      raise Error, "SIG-010 previous cycle is missing" unless previous_cycle.is_a?(Hash)
      raise Error, "SIG-010 previous cycle must be decayed or extinct" unless %w[decayed extinct].include?(previous_cycle.fetch("status").to_s)
      raise Error, "SIG-010 requires a new independent action" if Array(new_actions).empty?
      raise Error, "SIG-010 action must be independently evidenced" unless Array(new_actions).all? { |row| row.fetch("independent", false) && !row.fetch("evidence_id").to_s.empty? }
      { "status" => "reactivated", "previousSignalId" => previous_cycle.fetch("signal_id"),
        "previousVersion" => previous_cycle.fetch("version"), "newActionEvidenceIds" => Array(new_actions).map { |row| row.fetch("evidence_id") } }
    rescue KeyError, TypeError => error
      raise Error, "SIG-010 fixture is incomplete: #{error.message}"
    end

    def causal_claim(relation:)
      relation = relation.dup
      raise Error, "SIG-012 relation is missing" unless relation.is_a?(Hash)
      has_intervention = relation.fetch("intervention_evidence", false)
      has_mechanism = relation.fetch("mechanism_evidence", false)
      has_temporal = relation.fetch("temporal_order", false)
      if relation.fetch("source_claimed_cause", false)
        relation["relationType"] = "source_claimed_cause"
      elsif has_temporal && !has_intervention && !has_mechanism
        relation["relationType"] = "observed_association"
      else
        raise Error, "SIG-012 cannot support a mechanism without intervention or mechanism evidence"
      end
      relation["supportedMechanism"] = false
      relation
    end

    def seasonal_anomaly(observations:, baseline:, threshold:, baseline_version:, seasonal_features:)
      raise Error, "SIG-013 baseline version is required" if baseline_version.to_s.empty?
      raise Error, "SIG-013 seasonal features are required" if Array(seasonal_features).empty?
      observed = Array(observations).map { |row| row.fetch("count").to_f }
      expected = Array(baseline).map { |row| row.fetch("count").to_f }
      raise Error, "SIG-013 observations and baseline lengths differ" unless observed.length == expected.length && observed.any?
      deviation = observed.zip(expected).map { |actual, normal| normal.zero? ? 0.0 : (actual - normal).abs / normal }.max
      { "triggered" => deviation > threshold.to_f, "maxRelativeDeviation" => deviation, "baselineVersion" => baseline_version,
        "seasonalFeatures" => seasonal_features }
    rescue KeyError, TypeError => error
      raise Error, "SIG-013 fixture is incomplete: #{error.message}"
    end

    def fdr_scan(tests:, alpha:)
      rows = Array(tests)
      raise Error, "SIG-014 tests are empty" if rows.empty?
      if rows.all? { |row| row.key?("p_value") }
        p_values = rows.map { |row| Float(row.fetch("p_value")) }
        raise Error, "SIG-014 p values must be in [0,1]" unless p_values.all? { |value| value.between?(0.0, 1.0) }
        ordered = p_values.sort.each_with_index.map { |value, index| [value, value * rows.length / (index + 1)] }
        q_value = ordered.map(&:last).min
        discoveries = p_values.count { |value| value <= alpha.to_f / rows.length }
        false_discoveries = rows.each_with_index.count { |row, index| row.fetch("gold_anomaly", false) == false && p_values[index] <= alpha.to_f / rows.length }
        fdr = discoveries.zero? ? 0.0 : false_discoveries.to_f / discoveries
        { "detectorType" => "probabilistic", "testsCount" => rows.length, "qValue" => q_value, "falseDiscoveryRate" => fdr,
          "decision" => fdr <= alpha.to_f }
      else
        raise Error, "SIG-014 empirical detector requires false_alarm" unless rows.all? { |row| row.key?("false_alarm") }
        false_alarm = rows.count { |row| row.fetch("false_alarm") }.to_f / rows.length
        { "detectorType" => "non_probability", "testsCount" => rows.length, "empiricalFalseAlarmRate" => false_alarm,
          "qValue" => nil, "decision" => false_alarm <= alpha.to_f }
      end
    rescue ArgumentError, TypeError => error
      raise Error, "SIG-014 fixture is incomplete: #{error.message}"
    end

    def sparse_series(rows:)
      records = Array(rows)
      raise Error, "SIG-016 series are empty" if records.empty?
      records.each do |row|
        denominator = Integer(row.fetch("denominator"))
        numerator = Integer(row.fetch("numerator"))
        raise Error, "SIG-016 numerator exceeds denominator" if denominator.positive? && numerator > denominator
      end
      total_numerator = records.sum { |row| Integer(row.fetch("numerator")) }
      total_denominator = records.sum { |row| Integer(row.fetch("denominator")) }
      proportion = total_denominator.zero? ? 0.0 : total_numerator.to_f / total_denominator
      z = 1.96
      n = [total_denominator, 1].max
      centre = proportion + z * z / (2 * n)
      margin = z * Math.sqrt((proportion * (1 - proportion) / n) + z * z / (4 * n * n))
      denominator = 1 + z * z / n
      interval = [[(centre - margin) / denominator, 0.0].max, [(centre + margin) / denominator, 1.0].min]
      independent = records.select { |row| row.fetch("independent", false) }
      { "rawCount" => total_numerator, "sampleSize" => total_denominator, "shrunkEstimate" => proportion,
        "interval" => interval, "reasonCodes" => ["SPARSE_SUPPORT"], "independentConfirmationCount" => independent.length,
        "zeroDenominatorHandled" => total_denominator.zero? }
    rescue ArgumentError, TypeError => error
      raise Error, "SIG-016 fixture is incomplete: #{error.message}"
    end

    def detector_manifest(manifest:, detectors:)
      entries = Array(manifest)
      inventory = Array(detectors).each_with_object({}) { |detector, memo| memo[[detector.fetch("detector_id"), detector.fetch("detector_version_id")]] = detector }
      raise Error, "SIG-017 manifest is empty" if entries.empty?
      entries.each do |entry|
        key = [entry.fetch("detector_id"), entry.fetch("detector_version_id")]
        raise Error, "SIG-017 detector version is not in inventory" unless inventory.key?(key)
      end
      versions_by_key = entries.group_by { |entry| entry.fetch("d05_key") }
      raise Error, "SIG-017 distinct detector versions required under D05 key" unless versions_by_key.values.all? { |rows| rows.map { |row| row.fetch("detector_version_id") }.uniq.length >= 2 }
      hash = Digest::SHA256.hexdigest(JSON.generate(entries.sort_by { |entry| [entry.fetch("d05_key"), entry.fetch("detector_version_id")] }))
      { "manifestHash" => hash, "manifestEntries" => entries.length, "generationUnitKeys" => entries.map { |entry| "#{entry.fetch('d05_key')}:#{entry.fetch('detector_version_id')}" } }
    rescue KeyError, TypeError => error
      raise Error, "SIG-017 fixture is incomplete: #{error.message}"
    end

    def unknown_exploration(items:, detector_results:)
      rows = Array(items)
      raise Error, "SIG-021 items are empty" if rows.empty?
      results = Array(detector_results)
      rows.each do |item|
        qualified = item.fetch("domain").to_s == "unknown" && item.fetch("publisher_role").to_s == "unknown" && item.fetch("quality").to_s == "qualified"
        item_results = results.select { |result| result.fetch("coverage_item_id") == item.fetch("coverage_item_id") }
        if qualified
          raise Error, "SIG-021 qualified item must have all detector no-candidate" unless item_results.any? && item_results.all? { |result| result.fetch("decision") == "no-candidate" }
        elsif item_results.any? { |result| result.fetch("decision") == "candidate" }
          raise Error, "SIG-021 ineligible item generated candidate"
        end
      end
      { "eligibleCount" => rows.count { |item| item.fetch("quality") == "qualified" }, "notASignal" => true,
        "candidateCountAdded" => 0, "prevalenceCountAdded" => 0 }
    rescue KeyError, TypeError => error
      raise Error, "SIG-021 fixture is incomplete: #{error.message}"
    end

    def exploration_eligibility(items:, decisions:)
      rows = Array(items)
      terminal = Array(decisions)
      raise Error, "SIG-024 terminal denominator must cover every item" unless terminal.map { |row| row.fetch("coverage_item_id") }.uniq.sort == rows.map { |row| row.fetch("coverage_item_id") }.uniq.sort
      raise Error, "SIG-024 each item requires one eligibility decision" unless terminal.group_by { |row| row.fetch("coverage_item_id") }.values.all? { |group| group.length == 1 }
      terminal.each do |decision|
        exploration = decision.fetch("exploration_unit_id", nil)
        raise Error, "SIG-024 exploration unit created before eligibility" if exploration && decision.fetch("eligible") == false
      end
      { "terminalDenominator" => terminal.length, "eligibleCount" => terminal.count { |row| row.fetch("eligible") }, "gap" => false }
    rescue KeyError, TypeError => error
      raise Error, "SIG-024 fixture is incomplete: #{error.message}"
    end
  end

  module SelectionContract
    class Error < StandardError; end
    module_function

    def multi_signal_allocation(candidate:)
      types = Array(candidate.fetch("signal_types")).map(&:to_s).uniq
      raise Error, "SEL-001 requires emergence and diffusion" unless %w[emergence diffusion].all? { |type| types.include?(type) }
      raise Error, "SEL-001 requires exactly one allocation lane" unless Array(candidate.fetch("allocation_lane")).length == 1
      sections = Array(candidate.fetch("surface_sections"))
      raise Error, "SEL-001 requires independent surface sections" if sections.empty? || sections.uniq.length != sections.length
      candidate.merge("signal_types" => types, "selectionValid" => true)
    rescue KeyError, TypeError => error
      raise Error, "SEL-001 fixture is incomplete: #{error.message}"
    end

    def quota_infeasible(constraints:, candidates:)
      constraints = Array(constraints)
      candidates = Array(candidates)
      missing = constraints.select { |constraint| candidates.none? { |candidate| candidate.fetch("dimensions").to_h.fetch(constraint.fetch("dimension"), 0).to_f >= constraint.fetch("minimum").to_f } }
      return { "decision" => "allow", "reasonCode" => nil, "missingConstraints" => [] } if missing.empty?

      { "decision" => "blocked", "reasonCode" => "QUOTA_INFEASIBLE", "missingConstraints" => missing.map { |constraint| constraint.fetch("dimension") },
        "candidateGap" => missing }
    rescue KeyError, TypeError => error
      raise Error, "SEL-003 fixture is incomplete: #{error.message}"
    end

    def pareto_tie_break(candidates:, core_dimensions:, signal_type:)
      dimensions = Array(core_dimensions).map(&:to_s)
      raise Error, "SEL-004 requires two or three core dimensions" unless (2..3).cover?(dimensions.length)
      rows = Array(candidates)
      raise Error, "SEL-004 candidates are empty" if rows.empty?
      rows.each { |row| dimensions.each { |dimension| row.fetch("scores").fetch(dimension) } }
      ordered = rows.sort_by { |row| [-dimensions.sum { |dimension| row.fetch("scores").fetch(dimension).to_f }, row.fetch("candidate_id").to_s] }
      { "signalType" => signal_type.to_s, "coreDimensions" => dimensions, "orderedCandidateIds" => ordered.map { |row| row.fetch("candidate_id") },
        "reasonCode" => "STABLE_TIE_BREAK", "uniqueOrder" => ordered.map { |row| row.fetch("candidate_id") }.uniq.length == ordered.length }
    rescue KeyError, TypeError => error
      raise Error, "SEL-004 fixture is incomplete: #{error.message}"
    end
  end

  module AdversarialContract
    class Error < StandardError; end
    module_function

    def sybil_risk(domains:)
      rows = Array(domains)
      raise Error, "ADV-001 domains are empty" if rows.empty?
      synchronized = rows.count { |row| row.fetch("synchronized", false) }
      template_matches = rows.count { |row| row.fetch("template_match", false) }
      references = rows.count { |row| row.fetch("引用链", row.fetch("reference_chain", false)) }
      score = [synchronized, template_matches, references].count { |count| count.positive? }
      { "sybilRisk" => score >= 2 ? "high" : "low", "domainCount" => rows.length, "independentOriginCount" => rows.map { |row| row.fetch("origin_id") }.uniq.length,
        "signals" => { "synchronized" => synchronized.positive?, "templateMatch" => template_matches.positive?, "referenceChain" => references.positive? } }
    rescue KeyError, TypeError => error
      raise Error, "ADV-001 fixture is incomplete: #{error.message}"
    end

    def unverifiable_action(evidence:)
      evidence = evidence.dup
      raise Error, "ADV-004 evidence is missing" unless evidence.is_a?(Hash)
      verified = evidence.fetch("registry_verified", false) || evidence.fetch("original_record_verified", false)
      evidence["evidenceScope"] = verified ? "confirmed_action" : "unverified_claim"
      evidence["actionStatus"] = verified ? "confirmed" : "unconfirmed"
      evidence
    end

    def manipulation_event(posts:)
      rows = Array(posts)
      raise Error, "ADV-005 posts are empty" if rows.empty?
      coordinated = rows.any? { |row| row.fetch("bot", false) || row.fetch("coordinated", false) }
      raise Error, "ADV-005 fixture must contain a manipulation signal" unless coordinated
      { "surfaceSections" => ["manipulation_event"], "naturalPublicSupport" => false, "propagationFactPreserved" => true,
        "risk" => "high" }
    rescue KeyError, TypeError => error
      raise Error, "ADV-005 fixture is incomplete: #{error.message}"
    end
  end

  module ModelContract
    class Error < StandardError; end
    module_function

    def retire(model_snapshot:)
      required = %w[model_id input_manifest output_artifact_ids config_hash evidence_ids]
      missing = required.reject { |key| model_snapshot.key?(key) && !Array(model_snapshot[key]).empty? && model_snapshot[key].to_s != "" }
      raise Error, "MOD-003 audit fields missing: #{missing.join(',')}" unless missing.empty?
      model_snapshot.merge("status" => "retired", "recomputeRequired" => false)
    end
  end

  module WarmingContract
    class Error < StandardError; end
    module_function

    def history_break(records:, new_capability_version:)
      rows = Array(records)
      raise Error, "WRM-004 records are empty" if rows.empty?
      raise Error, "WRM-004 capability version is required" if new_capability_version.to_s.empty?
      boundary = rows.map { |row| row.fetch("observed_at").to_s }.max
      { "coverageShift" => true, "breakAt" => boundary, "capabilityVersion" => new_capability_version,
        "conceptNoveltyAllowed" => false, "timeSeriesAction" => "segment_or_reset" }
    rescue KeyError, TypeError => error
      raise Error, "WRM-004 fixture is incomplete: #{error.message}"
    end
  end
end
