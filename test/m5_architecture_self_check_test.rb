# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/m1_readiness"
require_relative "../lib/m5_contracts"

class M5ArchitectureSelfCheckTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_m5_inventory_matches_acceptance_plan
    expected = File.foreach(File.join(ROOT, "docs/04-acceptance-test-plan.md")).each_with_object([]) do |line, ids|
      cells = line.split("|").map(&:strip)
      ids << cells[1] if cells.length >= 6 && cells[1] && cells[1].match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/) && cells[2] == "M5"
    end.uniq.sort
    coverage = JSON.parse(File.read(File.join(ROOT, "schema/m5-release-coverage.json")))
    assert_equal expected, coverage.fetch("entries").map { |entry| entry.fetch("testCode") }.sort
    assert_equal 10, expected.length
    assert coverage.fetch("entries").all? { |entry| entry.fetch("status") == "environment_blocked" }
  end

  def test_blocked_artifacts_are_real_and_do_not_claim_pass
    coverage = JSON.parse(File.read(File.join(ROOT, "schema/m5-release-coverage.json")))
    coverage.fetch("entries").each do |entry|
      fixture = entry.fetch("fixture")
      artifact_path = File.join(ROOT, fixture.fetch("artifactPath"))
      assert File.file?(artifact_path)
      artifact = JSON.parse(File.read(artifact_path))
      assert_equal entry.fetch("testCode"), artifact.fetch("testCode")
      assert_equal "environment_blocked", artifact.fetch("result")
      assert_equal "environment_blocked", fixture.fetch("result")
      refute_equal 0, artifact.fetch("commandExitStatus", nil)
    end
  end

  def test_m5_contract_surfaces_are_present
    assert_includes M1::M1Readiness::ARTIFACT_SCHEMAS, "m5.readiness-artifact.v1"
    assert_respond_to M5::RealtimeContract, :frontier_projection
    assert_respond_to M5::RealtimeContract, :publish_winner
    assert_respond_to M5::RealtimeContract, :envelope
  end
end
