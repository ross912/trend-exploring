# frozen_string_literal: true

require "digest"
require "json"
require_relative "report_window_contract"

module M2
  module CoverageContract
    class Error < StandardError; end

    module_function

    def allocate(prevalence_lens:, candidates:, required_strata:, quota:)
      candidates = Array(candidates)
      required_strata = Array(required_strata).map(&:to_s)
      quota = Integer(quota)
      raise Error, "coverage quota must be positive" unless quota.positive?
      grouped = candidates.group_by { |candidate| candidate.fetch("stratum").to_s }
      missing = required_strata.reject { |stratum| grouped.key?(stratum) }
      return {
        "decision" => "blocked",
        "reasonCode" => "QUOTA_INFEASIBLE",
        "missingStrata" => missing,
        "prevalenceLens" => prevalence_lens,
        "explorationLens" => []
      } unless missing.empty?

      selected = required_strata.map { |stratum| grouped.fetch(stratum).first }.first(quota)
      selected = (selected + candidates).uniq { |candidate| candidate.fetch("candidate_id") }.first(quota)
      {
        "decision" => "allow",
        "prevalenceLens" => prevalence_lens,
        "explorationLens" => selected,
        "allocationLane" => "coverage_floor",
        "reasonCodes" => []
      }
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "coverage allocation contract is incomplete: #{error.message}"
    end

    def compare_strata(fixed_ranking:, current_ranking:, top_k:, tolerance:)
      fixed = Array(fixed_ranking).map(&:to_s)
      current = Array(current_ranking).map(&:to_s)
      raise Error, "ranking frames must be non-empty and equal length" unless fixed.length.positive? && fixed.length == current.length && Integer(top_k).positive?

      flips = fixed.each_index.count { |index| fixed[index] != current[index] }
      flip_rate = flips.to_f / fixed.length
      overlap = fixed.first(Integer(top_k)) & current.first(Integer(top_k))
      overlap_rate = overlap.length.to_f / [fixed.first(Integer(top_k)).length, 1].max
      reasons = []
      reasons << "COVERAGE_SHIFT" if flip_rate > tolerance.to_f
      reasons << "DEGRADED_COVERAGE" if overlap_rate < (1.0 - tolerance.to_f)
      {
        "fixedRanking" => fixed,
        "currentRanking" => current,
        "rankingFlipRate" => flip_rate,
        "topKOverlap" => overlap_rate,
        "reasonCodes" => reasons
      }
    end

    def processing_delays(records:)
      grouped = Array(records).group_by { |record| record.fetch("language").to_s }
      grouped.each_with_object({}) do |(language, rows), result|
        discovery = rows.map { |row| delay(row.fetch("discovered_at"), row.fetch("published_at")) }
        processing = rows.map { |row| delay(row.fetch("processed_at"), row.fetch("version_available_at")) }
        result[language] = {
          "discoveryDelay" => quantiles(discovery),
          "processingDelay" => quantiles(processing),
          "reasonCodes" => rows.each_with_object([]) do |row, reasons|
            reasons << "DISCOVERY_DELAY" if parse_time(row.fetch("discovered_at")) > parse_time(row.fetch("published_at"))
            reasons << "PROCESSING_BACKFILL" if parse_time(row.fetch("processed_at")) >= parse_time(row.fetch("nominal_window_end"))
          end.uniq
        }
      end
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "processing delay contract is incomplete: #{error.message}"
    end

    def confidence_preserves_allocation(observation_confidence:, evidence_confidence:, prevalence_magnitude:, allocation:)
      raise Error, "observation confidence is missing" if observation_confidence.to_s.empty?
      raise Error, "evidence confidence is missing" if evidence_confidence.to_s.empty?

      {
        "observationConfidence" => observation_confidence,
        "evidenceConfidence" => evidence_confidence,
        "prevalenceMagnitude" => prevalence_magnitude,
        "allocation" => allocation
      }
    end

    def unknown_open_world(candidate:)
      raise Error, "unknown candidate is required" unless candidate.is_a?(Hash)
      raise Error, "unknown candidate must retain domain and publisher role" unless
        candidate.key?("domain") && candidate.key?("publisher_role")
      raise Error, "unknown candidate must retain explicit unknown values" unless
        candidate.fetch("domain").to_s == "unknown" && candidate.fetch("publisher_role").to_s == "unknown"

      candidate.merge("allocation_lane" => "random_exploration", "open_world_unknown" => true)
    end

    def coverage_debt(opened_at:, as_of:, coverage_debt_id:, reason_code:, next_rotation_at:)
      opened = parse_time(opened_at)
      observed = parse_time(as_of)
      raise Error, "coverage debt opened_at must not be after as_of" if opened > observed
      authority = {
        "coverage_debt_id" => coverage_debt_id.to_s,
        "opened_at" => opened.iso8601,
        "reason_code" => reason_code.to_s,
        "next_rotation_at" => parse_time(next_rotation_at).iso8601
      }
      payload = authority.merge("checksum" => Digest::SHA256.hexdigest(JSON.generate(authority)))
      payload["query_projection"] = { "as_of" => observed.iso8601, "age_seconds" => observed.to_i - opened.to_i }
      payload["state_event"] = { "type" => "COVERAGE_DEBT_STATE", "coverage_debt_id" => coverage_debt_id.to_s }
      payload
    end

    def delay(later, earlier)
      parse_time(later).to_f - parse_time(earlier).to_f
    end

    def quantiles(values)
      sorted = values.sort
      return { "p50" => 0.0, "p95" => 0.0 } if sorted.empty?

      {
        "p50" => sorted[((sorted.length - 1) * 0.50).round],
        "p95" => sorted[((sorted.length - 1) * 0.95).round]
      }
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Error, "invalid timestamp: #{value.inspect}"
    end
    private_class_method :delay, :quantiles, :parse_time
  end

  module LanguageEvaluationContract
    class Error < StandardError; end
    module_function

    def evaluate(rows:, false_support_threshold:, minimum_coverage:)
      grouped = Array(rows).group_by { |row| [row.fetch("language").to_s, row.fetch("assertion_type").to_s] }
      grouped.each_with_object({ "decision" => "allow", "strata" => {}, "reasonCodes" => [] }) do |(key, records), result|
        total = records.length
        false_support = records.count { |record| record.fetch("false_support") }
        abstained = records.count { |record| record.fetch("abstained") }
        coverage = (total - abstained).to_f / [total, 1].max
        rate = false_support.to_f / [total - abstained, 1].max
        metrics = {
          "falseSupportRate" => rate,
          "abstentionRate" => abstained.to_f / [total, 1].max,
          "coverage" => coverage,
          "confidenceInterval" => wilson_interval(false_support, [total - abstained, 1].max)
        }
        result["strata"][key.join("/")] = metrics
        if coverage < minimum_coverage.to_f || rate > false_support_threshold.to_f
          result["decision"] = "blocked"
          result["reasonCodes"] << "LANGUAGE_ASSERTION_QUALITY_BELOW_THRESHOLD"
        end
      end.tap { |result| result["reasonCodes"].uniq! }
    rescue KeyError, TypeError, ArgumentError => error
      raise Error, "language evaluation contract is incomplete: #{error.message}"
    end

    def wilson_interval(successes, trials)
      z = 1.96
      n = [trials.to_i, 1].max
      p = successes.to_f / n
      denominator = 1.0 + (z * z / n)
      centre = p + (z * z / (2.0 * n))
      margin = z * Math.sqrt((p * (1.0 - p) / n) + (z * z / (4.0 * n * n)))
      [[(centre - margin) / denominator, 0.0].max, [(centre + margin) / denominator, 1.0].min]
    end
    private_class_method :wilson_interval
  end

  module ReportPublicationContract
    class Error < StandardError; end
    module_function

    def validate!(windows:, arrivals:, placements:)
      ReportWindowContract.validate_windows!(windows)
      ordered = Array(windows).sort_by { |window| parse_time(window_value(window, :start)) }
      ordered.each_cons(2) do |left, right|
        raise Error, "REPORT_WINDOWS_GAP" unless parse_time(window_value(left, :end)) == parse_time(window_value(right, :start))
      end
      reportable = Array(arrivals).select { |arrival| arrival.fetch("reportable") }
      first_by_arrival = Array(placements).group_by { |placement| placement.fetch("arrival_id") }
      reportable.each do |arrival|
        rows = first_by_arrival.fetch(arrival.fetch("arrival_id"), []).select { |row| row.fetch("is_first_publication") }
        raise Error, "FIRST_PUBLICATION_NOT_UNIQUE" unless rows.length == 1
        raise Error, "PUBLICATION_EVENT_REQUIRED" if rows.first.fetch("publication_event_id").to_s.empty?
      end
      Array(arrivals).reject { |arrival| arrival.fetch("reportable") }.each do |arrival|
        rows = first_by_arrival.fetch(arrival.fetch("arrival_id"), [])
        raise Error, "NON_REPORTABLE_FIRST_PUBLICATION" if rows.any? { |row| row.fetch("is_first_publication") }
      end
      Array(placements).each do |placement|
        if placement.fetch("backfill_of_report_schedule_slot_id", nil) && placement.fetch("backfill_of_report_schedule_slot_id").to_s.empty?
          raise Error, "BACKFILL_SLOT_REQUIRED"
        end
      end
      true
    rescue ReportWindowContract::Error => error
      raise Error, error.message
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "report publication contract is incomplete: #{error.message}"
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Error, "invalid timestamp: #{value.inspect}"
    end
    def window_value(window, key)
      return window.fetch(key) if window.key?(key)
      return window.fetch(key.to_s) if window.key?(key.to_s)

      raise Error, "nominal window field is missing: #{key}"
    end
    private_class_method :parse_time, :window_value
  end

  module PresentationContract
    class Error < StandardError; end
    module_function

    def ai_judgment_disabled(raw_item)
      raise Error, "raw title/source/time/license evidence must remain visible" unless
        %w[title source published_at license_scope evidence coverage_boundary].all? { |key| raw_item.key?(key) }
      raw_item.merge("ai_judgment" => nil)
    end

    def blind_review(samples:, rubric:)
      return { "result" => "blocked", "reasonCode" => "ORACLE_MISSING" } if rubric.to_s.empty?
      rows = Array(samples)
      raise Error, "blind review sample is empty" if rows.empty?
      misses = rows.count { |row| row.fetch("major_omission") }
      { "result" => "complete", "majorOmissionRate" => misses.to_f / rows.length, "rubric" => rubric,
        "confidenceInterval" => wilson_interval(misses, rows.length) }
    end

    def capacity_rotation(selected:, capacity:, quality_floor:)
      selected = Array(selected)
      raise Error, "capacity must be positive" unless Integer(capacity).positive?
      low_quality = selected.select { |item| item.fetch("quality").to_f < quality_floor.to_f }
      raise Error, "LOW_QUALITY_FILL" unless low_quality.empty?
      { "visible" => selected.first(Integer(capacity)), "coverageDebt" => selected.drop(Integer(capacity)).map { |item| item.fetch("stratum") } }
    end

    def selection_reason(candidate:)
      required = %w[signal_types allocation_lane surface_sections reason_codes]
      missing = required.reject { |key| candidate.key?(key) }
      raise Error, "selection reason fields missing: #{missing.join(',')}" unless missing.empty?
      candidate.merge("human_readable_reason" => "#{Array(candidate.fetch('signal_types')).join(', ')} via #{candidate.fetch('allocation_lane')}")
    end

    def attention_budget(placements:, budget:, no_click_input: true)
      raise Error, "attention budget requires fixed K and minutes" unless budget.is_a?(Hash) && budget.key?("k") && budget.key?("minutes")
      raise Error, "CLICK_OR_PROFILE_INPUT_FORBIDDEN" unless no_click_input
      rows = Array(placements)
      raise Error, "ATTENTION_BUDGET_EXCEEDED" if rows.length > Integer(budget.fetch("k"))
      raise Error, "ATTENTION_MINUTES_EXCEEDED" if rows.map { |row| row.fetch("minutes").to_f }.sum > budget.fetch("minutes").to_f
      exploration = rows.select { |row| row.fetch("allocation_lane") == "random_exploration" }
      raise Error, "EXPLORATION_UNREACHABLE" if exploration.any? { |row| row.fetch("fold") == "below_fold" && !row.fetch("delivered") }
      keys = rows.map { |row| [row.fetch("content_id"), row.fetch("surface")] }
      raise Error, "ATTENTION_DUPLICATE" unless keys.uniq.length == keys.length
      true
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "attention budget contract is incomplete: #{error.message}"
    end

    def wilson_interval(successes, trials)
      z = 1.96
      n = [trials.to_i, 1].max
      p = successes.to_f / n
      denominator = 1.0 + (z * z / n)
      centre = p + (z * z / (2.0 * n))
      margin = z * Math.sqrt((p * (1.0 - p) / n) + (z * z / (4.0 * n * n)))
      [[(centre - margin) / denominator, 0.0].max, [(centre + margin) / denominator, 1.0].min]
    end
    private_class_method :wilson_interval
  end
end
