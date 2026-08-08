# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "time"
require_relative "../lib/m1_readiness"

class M1ReadinessTest < Minitest::Test
  def plan
    <<~MARKDOWN
      | ID | phase | severity | blocking | fixture | oracle |
      |---|---|---|---|---|---|
      | CTR-001 | M0 | P0 | phase-exit | fixture | oracle |
      | COV-002 | M1 | P0 | phase-exit | fixture | oracle |
      | COV-003 | M1 | P0 | release | fixture | oracle |
    MARKDOWN
  end

  def test_fixture_passed_requires_and_validates_artifact_chain
    Dir.mktmpdir("m1-readiness") do |root|
      entry = write_entry(root, "CTR-001")
      report = M1::M1Readiness.evaluate(
        acceptance_plan: plan,
        coverage: { "entries" => [entry, write_entry(root, "COV-002", result: "external_blocked", implementation: false, blocker_reason: "external provider unavailable")] },
        root: root
      )

      assert_equal "blocked", report.fetch("decision")
      assert_equal 1, report.dig("summary", "fixture_passed")
      assert_equal 1, report.dig("summary", "external_blocked")
      assert_equal ["COV-002"], report.fetch("blockedTestCodes")
      assert_equal [], report.fetch("invalidEvidenceTestCodes")
    end
  end

  def test_missing_artifact_is_invalid_evidence_not_a_pass
    Dir.mktmpdir("m1-readiness") do |root|
      entry = write_entry(root, "CTR-001")
      entry["fixture"]["artifactPath"] = "evidence/missing.json"
      report = M1::M1Readiness.evaluate(
        acceptance_plan: plan,
        coverage: { "entries" => [entry, write_entry(root, "COV-002")] },
        root: root
      )

      assert_equal "blocked", report.fetch("decision")
      assert_equal ["CTR-001"], report.fetch("invalidEvidenceTestCodes")
      assert_equal 1, report.dig("summary", "invalid_evidence")
      refute_equal "fixture_passed", report.fetch("entries").find { |item| item["testCode"] == "CTR-001" }.fetch("effectiveStatus")
    end
  end

  def test_not_run_without_implementation_is_not_implemented
    Dir.mktmpdir("m1-readiness") do |root|
      entry = write_entry(root, "CTR-001", result: "not_run", implementation: false, blocker_reason: "implementation not started")
      report = M1::M1Readiness.evaluate(
        acceptance_plan: plan,
        coverage: { "entries" => [entry, write_entry(root, "COV-002")] },
        root: root
      )

      assert_equal 1, report.dig("summary", "implementation_pending")
      assert_equal ["CTR-001"], report.fetch("blockedTestCodes")
    end
  end

  def test_tampered_stdout_invalidates_artifact
    Dir.mktmpdir("m1-readiness") do |root|
      entry = write_entry(root, "CTR-001")
      File.write(File.join(root, "evidence/CTR-001.stdout.log"), "tampered\n")
      report = M1::M1Readiness.evaluate(
        acceptance_plan: plan,
        coverage: { "entries" => [entry, write_entry(root, "COV-002")] },
        root: root
      )

      assert_equal ["CTR-001"], report.fetch("invalidEvidenceTestCodes")
      assert_equal 1, report.dig("summary", "invalid_evidence")
    end
  end

  def test_missing_and_extra_entries_are_visible
    report = M1::M1Readiness.evaluate(
      acceptance_plan: plan,
      coverage: { "entries" => [{ "testCode" => "CTR-001", "status" => "partial" }, { "testCode" => "EXTRA-001", "status" => "fixture_passed" }] }
    )
    assert_equal ["COV-002"], report.fetch("missingTestCodes")
    assert_equal ["EXTRA-001"], report.fetch("extraTestCodes")
    refute_includes report.fetch("entries").map { |entry| entry.fetch("effectiveStatus") }, "partial"
  end

  def test_current_coverage_is_ready_only_after_verified_artifacts
    root = File.expand_path("..", __dir__)
    report = M1::M1Readiness.evaluate(
      acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
      coverage: JSON.parse(File.read(File.join(root, "schema/m1-phase-exit-coverage.json"))),
      root: root
    )
    assert_equal "ready", report.fetch("decision")
    assert_equal 30, report.fetch("requiredCount")
    assert_equal 30, report.dig("summary", "fixture_passed")
    assert_equal 0, report.dig("summary", "invalid_evidence")
    assert_equal [], report.fetch("blockedTestCodes")
  end

  private

  def write_entry(root, code, result: "passed", implementation: true, blocker_reason: nil)
    FileUtils.mkdir_p(File.join(root, "evidence"))
    FileUtils.mkdir_p(File.join(root, "test"))
    File.write(File.join(root, "implementation.rb"), "# implementation evidence\n") if implementation
    File.write(File.join(root, "test/fixture.rb"), "# fixture\n")
    stdout_path = "evidence/#{code}.stdout.log"
    File.write(File.join(root, stdout_path), "#{code}: #{result}\n")
    now = Time.now.utc.iso8601
    runtime = { "name" => "postgresql", "version" => "15.18" }
    artifact = {
      "schemaVersion" => M1::M1Readiness::ARTIFACT_SCHEMA,
      "testCode" => code,
      "command" => "ruby test/fixture.rb",
      "result" => result,
      "verified" => true,
      "verifiedAt" => now,
      "runtime" => runtime,
      "testPaths" => ["test/fixture.rb"],
      "stdoutPath" => stdout_path,
      "stdoutSha256" => Digest::SHA256.file(File.join(root, stdout_path)).hexdigest,
      "commandExitStatus" => result == "passed" ? 0 : nil,
      "runner" => "scripts/record_m1_readiness_evidence.rb"
    }
    artifact_path = "evidence/#{code}.json"
    File.write(File.join(root, artifact_path), JSON.pretty_generate(artifact) + "\n")
    {
      "testCode" => code,
      "status" => "fixture_passed",
      "implementationEvidence" => implementation ? ["implementation.rb"] : [],
      "fixture" => {
        "command" => artifact.fetch("command"),
        "result" => result,
        "testPaths" => artifact.fetch("testPaths"),
        "artifactPath" => artifact_path,
        "runtimeApplicable" => true,
        "runtime" => runtime,
        "lastVerifiedAt" => now
      },
      "blockerReason" => blocker_reason
    }
  end
end
