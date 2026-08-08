# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/m5_staging_runtime"

class M5StagingRuntimeTest < Minitest::Test
  def runtime
    @runtime ||= M5::StagingRuntime.new(surface_id: "surface-1", signing_secret: "staging-secret-0123456789")
  end

  def snapshot(id, revision)
    {
      "snapshot_id" => id, "revision" => revision, "surface_id" => "surface-1", "presentation_event_id" => "event-#{revision}",
      "render_plan_hash" => "render-#{revision}", "content_units" => ["card-1"], "method_epoch" => "method-v1", "comparison_watermark" => "wm-#{revision}"
    }
  end

  def test_ingest_is_idempotent_and_gap_blocks_watermark
    result = runtime.ingest(events: [
      { "item_id" => "item", "version_id" => "v1", "sequence" => 1 },
      { "item_id" => "item", "version_id" => "v1", "sequence" => 2, "cursor_gap" => true }
    ])
    assert_equal 1, result.fetch("storedLogicalArrivals")
    assert_equal "COLLECTION_MISSING", runtime.watermark_status
  end

  def test_publish_uses_expected_head_cas_and_strict_revision
    assert_equal "winner", runtime.publish(snapshot: snapshot("s1", 1), expected_revision: 0).fetch("decision")
    assert_raises(M5::StagingRuntime::Error) { runtime.publish(snapshot: snapshot("s2", 2), expected_revision: 0) }
    assert_equal "winner", runtime.publish(snapshot: snapshot("s2", 2), expected_revision: 1).fetch("decision")
  end

  def test_concurrent_publish_has_one_winner
    runtime
    outcomes = Queue.new
    threads = ["s1", "s2"].map do |id|
      Thread.new do
        begin
          outcomes << runtime.publish(snapshot: snapshot(id, 1), expected_revision: 0).fetch("decision")
        rescue M5::StagingRuntime::Error => error
          outcomes << error.message
        end
      end
    end
    threads.each(&:join)
    values = 2.times.map { outcomes.pop }
    assert_equal 1, values.count("winner")
    assert_equal 1, values.count("RADAR_HEAD_CAS_MISMATCH")
  end

  def test_signed_view_delivery_and_scope_are_bound_to_current_snapshot
    runtime.publish(snapshot: snapshot("s1", 1), expected_revision: 0)
    token = runtime.issue_view_token(query_shape: "q1")
    delivered = runtime.deliver(token: token, query_shape: "q1", requested_member_id: "card-1")
    assert_equal "delivered", delivered.fetch("status")
    assert delivered.fetch("bytes")
    assert_raises(M5::StagingRuntime::Error) { runtime.deliver(token: token, query_shape: "q2") }
    tampered = token.reverse
    assert_raises(M5::StagingRuntime::Error) { runtime.deliver(token: tampered, query_shape: "q1") }
  end

  def test_revocation_invalidates_old_head_without_partial_delivery
    runtime.publish(snapshot: snapshot("s1", 1), expected_revision: 0)
    token = runtime.issue_view_token(query_shape: "q1")
    runtime.revoke!
    result = runtime.deliver(token: token, query_shape: "q1")
    assert_equal "RADAR_VIEW_RECOMPUTING", result.fetch("status")
    assert_nil result.fetch("bytes")
  end
end
