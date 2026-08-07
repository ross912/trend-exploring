# frozen_string_literal: true

require "json"

module M1
  module M1Readiness
    class Error < StandardError; end
    STATUSES = %w[fixture_passed partial not_implemented].freeze

    module_function

    def required_test_codes(acceptance_plan)
      acceptance_plan.each_line.each_with_object([]) do |line, ids|
        cells = line.split("|").map(&:strip)
        next unless cells.length >= 6 && cells[1].match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/)
        next unless %w[M0 M1].include?(cells[2]) && cells[4] == "phase-exit"

        ids << cells[1]
      end.uniq.sort
    end

    def evaluate(acceptance_plan:, coverage:)
      required = required_test_codes(acceptance_plan)
      entries = coverage.fetch("entries")
      by_code = entries.each_with_object({}) do |entry, memo|
        code = entry.fetch("testCode")
        raise Error, "duplicate coverage entry: #{code}" if memo.key?(code)
        raise Error, "unknown coverage status: #{entry.fetch('status')}" unless STATUSES.include?(entry.fetch("status"))
        memo[code] = entry
      end
      missing = required - by_code.keys
      extra = by_code.keys - required
      blocked = required.select { |code| by_code[code].nil? || by_code.fetch(code).fetch("status") != "fixture_passed" }
      empty_evidence = required.select do |code|
        entry = by_code[code]
        next true if entry.nil?

        entry.fetch("status") != "fixture_passed" && entry.fetch("evidence").to_s.empty?
      end
      {
        "decision" => missing.empty? && extra.empty? && blocked.empty? && empty_evidence.empty? ? "ready" : "blocked",
        "requiredCount" => required.length,
        "fixturePassedCount" => required.count { |code| by_code[code]&.fetch("status") == "fixture_passed" },
        "partialCount" => required.count { |code| by_code[code]&.fetch("status") == "partial" },
        "notImplementedCount" => required.count { |code| by_code[code]&.fetch("status") == "not_implemented" },
        "missingTestCodes" => missing,
        "extraTestCodes" => extra,
        "blockedTestCodes" => blocked,
        "missingEvidenceTestCodes" => empty_evidence
      }
    end
  end
end
