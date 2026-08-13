# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "securerandom"
require_relative "../lib/world_change_store"

class WorldChangeStorePublicTest < Minitest::Test
  def setup
    @store = WorldChangeStore.allocate
  end

  def validated_run_fields
    {
      "detector_version" => WorldChangeDetector::VERSION,
      "validated_precision" => true,
      "validation_manifest_hash" => WorldChangeDetector::PRECISION_VALIDATION_MANIFEST_HASH
    }
  end

  def test_public_projection_caps_refs_and_excludes_raw_body
    rows = 12.times.map do |index|
      {
        "version_id" => "v#{index}", "item_key" => "item-#{index}", "title" => "title #{index}",
        "summary" => "x" * 20_000, "source_url" => "https://example.test/#{index}",
        "publisher_name" => "publisher-#{index}", "published_at" => format("2026-08-12T%02d:00:00Z", index),
        "channel" => "technical_capability"
      }
    end
    channel = {
      "version_ids" => rows.map { |row| row.fetch("version_id") },
      "publisher_ids" => rows.map { |row| row.fetch("publisher_name") },
      "evidence" => rows,
      "supporting_evidence" => rows,
      "contradicting_evidence" => rows
    }
    candidate = {
      "candidate_key" => "candidate-1", "label" => "bounded", "candidate_status" => "convergence_candidate",
      "detector_version" => "v1", "qualifying_publisher_ids" => %w[p1 p2], "qualifying_publisher_count" => 2,
      "qualifying_version_ids" => rows.map { |row| row.fetch("version_id") }, "channel_count" => 1,
      "channels" => WorldChangeStore::CHANNELS.to_h { |name| [name, name == "technical_capability" ? channel : { "version_ids" => [], "publisher_ids" => [], "evidence" => [], "supporting_evidence" => [], "contradicting_evidence" => [] }] },
      "evidence_items" => rows, "contradicting_evidence" => rows, "missing_channels" => ["policy_action"],
      "alternative_explanations" => ["alternative"], "next_verification" => ["verify"],
      "query_conditioned_evidence_count" => 0, "exploration_evidence_count" => 0,
      "observed_publisher_ids" => %w[p1 p2], "analysis_as_of" => "2026-08-13T00:00:00Z", "sort_order" => 0
    }
    projection = @store.public_projection({ "run_id" => "run-1", "status" => "evaluated", "candidates" => [candidate] }.merge(validated_run_fields))
    public = projection.fetch("candidates").fetch(0)
    refs = public.fetch("channels").fetch("technical_capability")
    assert_equal 12, refs.fetch("counts").fetch("qualifying")
    assert_equal 3, refs.fetch("evidence").length
    assert_equal 2, refs.fetch("supporting_evidence").length
    assert_equal 2, refs.fetch("contradicting_evidence").length
    assert refs.fetch("evidence").all? { |ref| (ref.keys - WorldChangeStore::PUBLIC_REF_FIELDS).empty? }
    refute public.key?("evidence_items")
    refute public.fetch("channels").fetch("technical_capability").fetch("evidence").first.key?("summary")
    assert_equal true, public.fetch("truncated")
    assert_equal true, projection.fetch("truncated")
    assert_operator JSON.generate(projection).bytesize, :<, 512 * 1024
  end

  def test_public_refs_collapse_multiple_versions_of_same_item
    rows = [
      { "version_id" => "old", "item_key" => "same-item", "title" => "old", "published_at" => "2026-08-12T01:00:00Z", "publisher_name" => "p", "source_url" => "https://example.test/old" },
      { "version_id" => "new", "item_key" => "same-item", "title" => "new", "published_at" => "2026-08-12T02:00:00Z", "publisher_name" => "p", "source_url" => "https://example.test/new" }
    ]
    refs = @store.send(:bounded_public_refs, rows, channel: "technical_capability", role: "qualifying", limit: 3)
    assert_equal ["new"], refs.map { |ref| ref.fetch("version_id") }
    assert_equal "new", refs.fetch(0).fetch("title")
  end

  def test_public_candidate_limit_is_twenty
    candidate = { "candidate_key" => "k", "label" => "l", "candidate_status" => "candidate", "channels" => {}, "qualifying_publisher_ids" => %w[p1 p2], "qualifying_publisher_count" => 2, "channel_count" => 0, "analysis_as_of" => "2026-08-13T00:00:00Z" }
    projection = @store.public_projection({ "candidates" => Array.new(21, candidate.merge("candidate_key" => SecureRandom.hex(4))) }.merge(validated_run_fields))
    assert_equal 20, projection.fetch("candidates").length
    assert_equal true, projection.fetch("truncated")
  end

  def test_v1_public_projection_is_invalidated_without_precision_validation
    candidate = {
      "candidate_key" => "legacy", "label" => "legacy candidate", "candidate_status" => "candidate",
      "detector_version" => "world_change_detector_v1", "qualifying_publisher_ids" => %w[p1 p2],
      "qualifying_publisher_count" => 2, "channel_count" => 0, "channels" => {},
      "analysis_as_of" => "2026-08-13T00:00:00Z"
    }
    projection = @store.public_projection({
      "run_id" => "legacy-run", "status" => "evaluated",
      "detector_version" => "world_change_detector_v1", "candidates" => [candidate]
    })

    assert_equal "invalidated", projection.fetch("status")
    assert_equal [], projection.fetch("candidates")
    assert_equal "precision_validation_failed", projection.fetch("reason")
    assert_equal false, projection.fetch("truncated")
  end

  def test_non_v1_public_projection_remains_available
    candidate = {
      "candidate_key" => "validated", "label" => "validated candidate", "candidate_status" => "candidate",
      "detector_version" => WorldChangeDetector::VERSION, "validated_precision" => true,
      "validation_manifest_hash" => WorldChangeDetector::PRECISION_VALIDATION_MANIFEST_HASH,
      "qualifying_publisher_ids" => %w[p1 p2],
      "qualifying_publisher_count" => 2, "channel_count" => 0, "channels" => {},
      "analysis_as_of" => "2026-08-13T00:00:00Z"
    }
    projection = @store.public_projection({
      "run_id" => "validated-run", "status" => "evaluated",
      "detector_version" => WorldChangeDetector::VERSION,
      "validated_precision" => true,
      "validation_manifest_hash" => WorldChangeDetector::PRECISION_VALIDATION_MANIFEST_HASH,
      "candidates" => [candidate]
    })

    assert_equal "evaluated", projection.fetch("status")
    assert_equal 1, projection.fetch("candidates").length
  end
end
