# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m5_contracts"

class M5ContractsTest < Minitest::Test
  def test_rtm_001_freezes_watermark_and_exposes_frontier_latency
    result = M5::RealtimeContract.frontier_projection(
      fast_rows: [{ "item_version_id" => "fast-1", "version_available_at" => "2026-08-08T08:01:00Z", "display_latency_ms" => 200 }],
      slow_rows: [{ "item_version_id" => "slow-1", "version_available_at" => "2026-08-08T08:00:00Z", "display_latency_ms" => 1000 }], comparison_watermark: "wm-1"
    )
    assert_equal "wm-1", result.fetch("comparisonWatermark")
    assert_equal ["fast-1"], result.fetch("fastLayerLocalOnly")
    assert_raises(M5::RealtimeContract::Error) { M5::RealtimeContract.frontier_projection(fast_rows: [], slow_rows: [{ "item_version_id" => "x" }], comparison_watermark: "wm") }
  end

  def test_rtm_002_is_deterministic_and_never_reads_personal_domain
    run = { "candidate_ids" => %w[a b], "feature_ids" => %w[f1 f2], "allocations" => %w[x y], "surface_order" => %w[a b] }
    assert M5::RealtimeContract.deterministic_snapshot(runs: [run, run.dup], personal_read_count: 0).fetch("deterministic")
    assert_raises(M5::RealtimeContract::Error) { M5::RealtimeContract.deterministic_snapshot(runs: [run, run.merge("surface_order" => %w[b a])], personal_read_count: 0) }
  end

  def test_rtm_003_deduplicates_replay_and_blocks_cursor_gap
    result = M5::RealtimeContract.replay_dedup(events: [
      { "item_id" => "i", "version_id" => "v1", "sequence" => 1 }, { "item_id" => "i", "version_id" => "v1", "sequence" => 2, "cursor_gap" => true }, { "item_id" => "i", "version_id" => "v2", "sequence" => 3 }
    ])
    assert_equal 2, result.fetch("logicalArrivalCount")
    assert_equal "COLLECTION_MISSING", result.fetch("reasonCode")
    assert_raises(M5::RealtimeContract::Error) { M5::RealtimeContract.replay_dedup(events: [{ "item_id" => "i", "version_id" => "v", "sequence" => 2 }, { "item_id" => "j", "version_id" => "v", "sequence" => 1 }]) }
  end

  def test_rtm_004_allows_one_strict_forward_winner
    attempts = [
      { "snapshot_id" => "s1", "surface_id" => "surface", "revision" => 1, "previous_snapshot_id" => nil, "outcome" => "winner" },
      { "snapshot_id" => "s2", "surface_id" => "surface", "revision" => 2, "previous_snapshot_id" => "s1", "outcome" => "rejected" }
    ]
    assert M5::RealtimeContract.publish_winner(attempts: attempts).fetch("strictForward")
    assert_raises(M5::RealtimeContract::Error) { M5::RealtimeContract.publish_winner(attempts: attempts + attempts.map { |row| row.merge("outcome" => "winner") }) }
  end

  def test_rtm_005_stale_epoch_recomputes_without_delivering_bytes
    token = { "surface_id" => "surface", "head_revision" => 2, "snapshot_id" => "s2", "rights_epoch" => 3, "render_plan_hash" => "hash" }
    result = M5::RealtimeContract.revocation_view(token: token, current_epoch: 4, stage: "delivered")
    assert_equal "RADAR_VIEW_RECOMPUTING", result.fetch("state")
    refute result.fetch("bytesAllowed")
  end

  def test_rtm_006_scope_mismatch_is_fail_closed
    token = { "surface_id" => "s2", "snapshot_id" => "snap2", "presentation_event_id" => "event2", "query_shape" => "q" }
    request = token.merge("snapshot_id" => "snap1", "member_ids" => ["m2"], "requested_member_id" => "m1")
    result = M5::RealtimeContract.token_scope(token: token, request: request)
    assert_equal "RADAR_VIEW_TOKEN_SCOPE_MISMATCH", result.fetch("reasonCode")
    refute result.fetch("bytesAllowed")
  end

  def test_rtm_007_rejects_unmodelled_streams_after_revocation
    assert_raises(M5::RealtimeContract::Error) { M5::RealtimeContract.delivery_mode(mode: "sse", revoked: false) }
    assert_equal "blocked", M5::RealtimeContract.delivery_mode(mode: "full_materialized", revoked: true).fetch("decision")
  end

  def representation
    M5::RealtimeContract.representation(snapshot: "snap", render_plan: "plan", query: "q", audience: "public", content_units: ["card-1"])
  end

  def safe_headers
    { "content_type" => "application/json", "content_disposition" => "inline", "cache_control" => "private, no-store", "vary" => "Authorization", "content_security_policy" => "default-src 'none'", "x_content_type_options" => "nosniff" }
  end

  def test_rtm_008_representation_is_the_delivery_byte_contract
    result = representation
    assert_equal result.fetch("payloadLength"), result.fetch("bytes").bytesize
    assert_equal 64, result.fetch("payloadHash").length
  end

  def test_rtm_009_and_010_allow_only_hardened_envelope
    result = M5::RealtimeContract.envelope(representation: representation, headers: safe_headers, policy: { "allowed_mime_types" => ["application/json"] })
    assert result.fetch("bytesAllowed")
    assert_raises(M5::RealtimeContract::Error) do
      M5::RealtimeContract.envelope(representation: representation, headers: safe_headers.merge("content_type" => "text/html", "content_security_policy" => "*"), policy: { "allowed_mime_types" => ["application/json"] })
    end
    assert_raises(M5::RealtimeContract::Error) do
      M5::RealtimeContract.envelope(representation: representation, headers: safe_headers.merge("content_disposition" => "inline\r\nLocation: https://evil"), policy: { "allowed_mime_types" => ["application/json"] })
    end
  end
end
