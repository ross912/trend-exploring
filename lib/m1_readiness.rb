# frozen_string_literal: true

require "digest"
require "json"
require "time"

module M1
  module M1Readiness
    class Error < StandardError; end

    # `status` in the coverage file is only a historical claim. The checker computes
    # effectiveStatus from implementation evidence and a verifiable fixture artifact.
    STATUSES = %w[
      not_implemented implemented fixture_failed fixture_passed
      environment_blocked external_blocked invalid_evidence
    ].freeze
    FIXTURE_RESULTS = %w[not_run passed failed environment_blocked external_blocked].freeze
    ARTIFACT_SCHEMA = "m1.readiness-artifact.v1"
    ARTIFACT_SCHEMAS = [ARTIFACT_SCHEMA, "m2.readiness-artifact.v1", "m3.readiness-artifact.v1"].freeze

    module_function

    def required_test_codes(acceptance_plan, phases: %w[M0 M1])
      acceptance_plan.each_line.each_with_object([]) do |line, ids|
        cells = line.split("|").map(&:strip)
        next unless cells.length >= 6 && cells[1].match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/)
        next unless phases.include?(cells[2]) && cells[4] == "phase-exit"

        ids << cells[1]
      end.uniq.sort
    end

    def evaluate(acceptance_plan:, coverage:, root: Dir.pwd, phases: %w[M0 M1])
      required = required_test_codes(acceptance_plan, phases: phases)
      entries = coverage.fetch("entries")
      by_code = entries.each_with_object({}) do |entry, memo|
        code = entry.fetch("testCode")
        raise Error, "duplicate coverage entry: #{code}" if memo.key?(code)

        memo[code] = evaluate_entry(entry, root: root)
      end

      missing = required - by_code.keys
      extra = by_code.keys - required
      details = required.each_with_object([]) do |code, result|
        result << by_code[code] if by_code.key?(code)
      end
      counts = details.group_by { |entry| entry.fetch("effectiveStatus") }.transform_values(&:length)
      blocked = required.select { |code| by_code[code].nil? || by_code.fetch(code).fetch("effectiveStatus") != "fixture_passed" }
      invalid_evidence = required.select do |code|
        by_code[code]&.fetch("effectiveStatus", "invalid_evidence") == "invalid_evidence"
      end
      mismatches = details.select do |entry|
        entry.fetch("declaredStatus").to_s != "" &&
          entry.fetch("declaredStatus") != entry.fetch("effectiveStatus")
      end.map { |entry| entry.fetch("testCode") }

      summary = {
        "fixture_passed" => counts.fetch("fixture_passed", 0),
        "implementation_pending" => counts.fetch("not_implemented", 0),
        "fixture_failed" => counts.fetch("fixture_failed", 0),
        "environment_blocked" => counts.fetch("environment_blocked", 0),
        "external_blocked" => counts.fetch("external_blocked", 0),
        "implemented" => counts.fetch("implemented", 0),
        "invalid_evidence" => counts.fetch("invalid_evidence", 0)
      }

      {
        "decision" => missing.empty? && extra.empty? && blocked.empty? ? "ready" : "blocked",
        "requiredCount" => required.length,
        "summary" => summary,
        "fixturePassedCount" => summary.fetch("fixture_passed"),
        "implementationPendingCount" => summary.fetch("implementation_pending"),
        "fixtureFailedCount" => summary.fetch("fixture_failed"),
        "environmentBlockedCount" => summary.fetch("environment_blocked"),
        "externalBlockedCount" => summary.fetch("external_blocked"),
        "implementedCount" => summary.fetch("implemented"),
        "invalidEvidenceCount" => summary.fetch("invalid_evidence"),
        "missingTestCodes" => missing,
        "extraTestCodes" => extra,
        "blockedTestCodes" => blocked,
        "invalidEvidenceTestCodes" => invalid_evidence,
        "statusMismatches" => mismatches,
        "entries" => details
      }
    end

    def evaluate_entry(entry, root:)
      code = entry["testCode"]
      declared = entry["status"]
      errors = []
      errors << "testCode is missing" if code.to_s.strip.empty?
      implementation_value = entry["implementationEvidence"]
      errors << "implementationEvidence field is missing" unless entry.key?("implementationEvidence")
      errors << "implementationEvidence must be an array" unless implementation_value.is_a?(Array)
      implementation_paths = evidence_paths(implementation_value)
      implementation_paths.each do |path|
        errors << "implementation evidence missing: #{path}" unless existing_file?(root, path)
      end

      fixture = entry["fixture"]
      unless fixture.is_a?(Hash)
        errors << "fixture object is missing"
        return entry_result(entry, code, declared, "invalid_evidence", errors)
      end

      command = fixture["command"]
      result = fixture["result"]
      test_paths = Array(fixture["testPaths"])
      artifact_path = fixture["artifactPath"]
      runtime = fixture["runtime"]
      runtime_applicable = fixture["runtimeApplicable"]
      last_verified_at = fixture["lastVerifiedAt"]
      errors << "fixture command is missing" if command.to_s.strip.empty?
      errors << "unknown fixture result" unless FIXTURE_RESULTS.include?(result)
      errors << "fixture testPaths must be non-empty" if test_paths.empty?
      test_paths.each do |path|
        errors << "fixture/test path missing: #{path}" unless existing_file?(root, path)
      end
      errors << "fixture artifactPath is missing" if artifact_path.to_s.strip.empty?
      errors << "fixture runtimeApplicable must be true or false" unless [true, false].include?(runtime_applicable)
      errors << "fixture runtime must be an object or null" unless runtime.nil? || runtime.is_a?(Hash)
      if runtime_applicable == true
        errors << "fixture runtime name/version are required" unless runtime.is_a?(Hash) &&
          !runtime["name"].to_s.strip.empty? && !runtime["version"].to_s.strip.empty?
      end
      errors << "lastVerifiedAt is invalid" unless timestamp?(last_verified_at)
      errors << "blockerReason is required for blocked/not-run fixture" if
        %w[not_run environment_blocked external_blocked].include?(result) && entry["blockerReason"].to_s.strip.empty?

      artifact = read_artifact(root, artifact_path, errors)
      validate_artifact!(artifact, code, fixture, root, errors) if artifact

      return entry_result(entry, code, declared, "invalid_evidence", errors) unless errors.empty?
      return entry_result(entry, code, declared, "not_implemented", errors) if result == "not_run" && implementation_paths.empty?
      return entry_result(entry, code, declared, "implemented", errors) if result == "not_run"
      return entry_result(entry, code, declared, "fixture_failed", errors) if result == "failed"
      return entry_result(entry, code, declared, result, errors) if %w[environment_blocked external_blocked].include?(result)

      entry_result(entry, code, declared, "fixture_passed", errors)
    rescue KeyError => error
      entry_result(entry, code, declared, "invalid_evidence", ["missing required field: #{error.message}"])
    end

    def evidence_paths(value)
      Array(value).each_with_object([]) do |item, paths|
        path = item.is_a?(Hash) ? item["path"] : item
        paths << path if path.is_a?(String) && !path.strip.empty?
      end
    end

    def existing_file?(root, path)
      File.file?(resolve_path(root, path))
    rescue Error
      false
    end

    def read_artifact(root, path, errors)
      return nil unless path.is_a?(String) && !path.strip.empty?

      artifact_path = resolve_path(root, path)
      unless File.file?(artifact_path)
        errors << "evidence artifact missing: #{path}"
        return nil
      end
      JSON.parse(File.read(artifact_path))
    rescue JSON::ParserError => error
      errors << "evidence artifact is not valid JSON: #{error.message}"
      nil
    rescue Error => error
      errors << error.message
      nil
    end

    def validate_artifact!(artifact, code, fixture, root, errors)
      errors << "artifact schema mismatch" unless ARTIFACT_SCHEMAS.include?(artifact["schemaVersion"])
      errors << "artifact testCode mismatch" unless artifact["testCode"] == code
      errors << "artifact command mismatch" unless artifact["command"] == fixture["command"]
      errors << "artifact result mismatch" unless artifact["result"] == fixture["result"]
      errors << "artifact verified flag is not true" unless artifact["verified"] == true
      errors << "artifact verifiedAt is invalid" unless timestamp?(artifact["verifiedAt"])
      errors << "artifact verifiedAt does not match fixture lastVerifiedAt" unless artifact["verifiedAt"] == fixture["lastVerifiedAt"]
      errors << "artifact runtime does not match fixture runtime" unless artifact["runtime"] == fixture["runtime"]
      errors << "artifact runner is missing or untrusted" unless artifact["runner"] == "scripts/record_m1_readiness_evidence.rb"
      exit_status = artifact["commandExitStatus"]
      errors << "artifact commandExitStatus is missing or invalid" unless exit_status.nil? || exit_status.is_a?(Integer)
      if fixture["result"] == "passed"
        errors << "passed artifact must have exit status 0" unless exit_status == 0
      elsif fixture["result"] == "failed"
        errors << "failed artifact must have a non-zero exit status" unless exit_status.is_a?(Integer) && exit_status != 0
      elsif %w[not_run environment_blocked external_blocked].include?(fixture["result"])
        errors << "blocked/not-run artifact must not claim a command exit status" unless exit_status.nil?
      end
      artifact_test_paths = Array(artifact["testPaths"])
      errors << "artifact testPaths do not match fixture" unless artifact_test_paths.sort == Array(fixture["testPaths"]).sort
      stdout_path = artifact["stdoutPath"]
      if !existing_file?(root, stdout_path)
        errors << "artifact stdout is missing: #{stdout_path}"
      else
        actual_hash = Digest::SHA256.file(resolve_path(root, stdout_path)).hexdigest
        errors << "artifact stdout hash mismatch" unless actual_hash == artifact["stdoutSha256"]
      end
    end

    def entry_result(entry, code, declared, effective, errors)
      {
        "testCode" => code,
        "declaredStatus" => declared,
        "effectiveStatus" => effective,
        "errors" => errors,
        "implementationEvidence" => entry["implementationEvidence"],
        "fixture" => entry["fixture"],
        "blockerReason" => entry["blockerReason"]
      }
    end

    def timestamp?(value)
      Time.iso8601(value.to_s)
      true
    rescue ArgumentError
      false
    end

    def resolve_path(root, path)
      raise Error, "evidence path must be a relative string" unless path.is_a?(String) && !path.empty? && !path.start_with?("/")

      root_path = File.expand_path(root)
      candidate = File.expand_path(path, root_path)
      prefix = "#{root_path}#{File::SEPARATOR}"
      raise Error, "evidence path escapes repository: #{path}" unless candidate.start_with?(prefix)

      candidate
    end
    private_class_method :evidence_paths, :existing_file?, :read_artifact,
      :validate_artifact!, :entry_result, :timestamp?, :resolve_path
  end
end
