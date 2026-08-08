# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/m1_readiness"
require_relative "../lib/m3_contracts"

class M3ArchitectureSelfCheckTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_phase_exit_inventory_matches_acceptance_plan
    expected = File.foreach(File.join(ROOT, "docs/04-acceptance-test-plan.md")).each_with_object([]) do |line, ids|
      cells = line.split("|").map(&:strip)
      ids << cells[1] if cells.length >= 6 && cells[1] && cells[1].match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/) && cells[2] == "M3" && cells[4] == "phase-exit"
    end.uniq.sort
    coverage = JSON.parse(File.read(File.join(ROOT, "schema/m3-phase-exit-coverage.json")))
    actual = coverage.fetch("entries").map { |entry| entry.fetch("testCode") }.sort
    assert_equal expected, actual
    refute coverage.fetch("entries").any? { |entry| entry.fetch("status").to_s == "partial" }
  end

  def test_every_m3_entry_has_targeted_fixture_and_real_artifact
    coverage = JSON.parse(File.read(File.join(ROOT, "schema/m3-phase-exit-coverage.json")))
    coverage.fetch("entries").each do |entry|
      fixture = entry.fetch("fixture")
      assert_match(/--name \/test_[a-z0-9_]+\//, fixture.fetch("command"))
      assert fixture.fetch("testPaths").all? { |path| File.file?(File.join(ROOT, path)) }
      assert File.file?(File.join(ROOT, fixture.fetch("artifactPath")))
      artifact = JSON.parse(File.read(File.join(ROOT, fixture.fetch("artifactPath"))))
      assert_equal entry.fetch("testCode"), artifact.fetch("testCode")
      assert_equal fixture.fetch("lastVerifiedAt"), artifact.fetch("verifiedAt")
    end
  end

  def test_checker_supports_m3_artifacts_and_contracts_are_present
    assert_includes M1::M1Readiness::ARTIFACT_SCHEMAS, "m3.readiness-artifact.v1"
    assert_respond_to M3::SignalContract, :fdr_scan
    assert_respond_to M3::SelectionContract, :pareto_tie_break
    assert_respond_to M3::AdversarialContract, :manipulation_event
    assert_respond_to M3::ModelContract, :retire
    assert_respond_to M3::WarmingContract, :history_break
  end
end
