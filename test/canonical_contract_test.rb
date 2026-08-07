# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/canonical_contract"

class CanonicalContractTest < Minitest::Test
  def base
    {
      "stable_identity" => %w[ObjectA],
      "immutable_record" => %w[RecordA RecordB],
      "immutable_manifest" => %w[ManifestA]
    }
  end

  def profiles
    {
      "raw_item_version_time" => %w[RecordA],
      "bitemporal_version_time" => [],
      "standalone_snapshot_time" => %w[RecordB],
      "derived_record_time" => [],
      "operational_record_time" => [],
      "immutable_record_time" => []
    }
  end

  def test_repository_contract_has_no_missing_or_duplicate_members
    root = File.expand_path("..", __dir__)
    report = M1::CanonicalContract.repository_report(File.join(root, "docs/05-canonical-data-and-time-contract.md"))
    assert_empty report.fetch("errors")
    assert_equal 169, report.fetch("archetypes").fetch("immutable_record")
  end

  def test_missing_profile_is_rejected
    mutated = profiles
    mutated["standalone_snapshot_time"] = []
    errors = M1::CanonicalContract.validate(archetypes: base, time_profiles: mutated)
    assert_includes errors, "immutable record missing time profile: RecordB"
  end

  def test_duplicate_profile_is_rejected
    mutated = profiles
    mutated["bitemporal_version_time"] = ["RecordA"]
    errors = M1::CanonicalContract.validate(archetypes: base, time_profiles: mutated)
    assert_includes errors, "object appears in multiple time profiles: RecordA"
  end
end
