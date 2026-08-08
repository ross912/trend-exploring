# frozen_string_literal: true

require "digest"
require "json"

module M5
  module RealtimeContract
    class Error < StandardError; end
    module_function

    def frontier_projection(fast_rows:, slow_rows:, comparison_watermark:)
      watermark = comparison_watermark.to_s
      raise Error, "RTM-001 comparison watermark is required" if watermark.empty?
      rows = Array(fast_rows) + Array(slow_rows)
      raise Error, "RTM-001 every row needs version availability and display latency" unless rows.all? { |row| row.key?("version_available_at") && row.key?("display_latency_ms") }
      { "comparisonWatermark" => watermark,
        "latestFrontier" => rows.map { |row| row.fetch("version_available_at") }.max,
        "displayLatencyMs" => rows.map { |row| row.fetch("display_latency_ms").to_f }.max,
        "fastLayerLocalOnly" => Array(fast_rows).map { |row| row.fetch("item_version_id") } }
    rescue KeyError, TypeError => error
      raise Error, "RTM-001 fixture is incomplete: #{error.message}"
    end

    def deterministic_snapshot(runs:, personal_read_count:)
      rows = Array(runs)
      raise Error, "RTM-002 requires at least two runs" if rows.length < 2
      baseline = rows.first
      comparable = rows.all? do |run|
        %w[candidate_ids feature_ids allocations surface_order].all? { |key| run.fetch(key) == baseline.fetch(key) }
      end
      raise Error, "RTM-002 deterministic runs diverged" unless comparable
      raise Error, "RTM-002 radar read the personal domain" unless Integer(personal_read_count).zero?
      { "deterministic" => true, "runCount" => rows.length, "personalReadCount" => personal_read_count }
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "RTM-002 fixture is incomplete: #{error.message}"
    end

    def replay_dedup(events:)
      rows = Array(events)
      raise Error, "RTM-003 events are empty" if rows.empty?
      keys = rows.map { |row| [row.fetch("item_id"), row.fetch("version_id")] }
      unique = keys.uniq
      gap = rows.any? { |row| row.fetch("cursor_gap", false) }
      sequence_ok = rows.map { |row| row.fetch("sequence").to_i }.each_cons(2).all? { |left, right| right >= left }
      raise Error, "RTM-003 sequence is uncontrolled" unless sequence_ok
      { "logicalArrivalCount" => unique.length, "duplicateSuppressed" => keys.length - unique.length,
        "gapBlocked" => gap, "reasonCode" => gap ? "COLLECTION_MISSING" : nil }
    rescue KeyError, TypeError => error
      raise Error, "RTM-003 fixture is incomplete: #{error.message}"
    end

    def publish_winner(attempts:)
      rows = Array(attempts)
      winners = rows.select { |row| row.fetch("outcome") == "winner" }
      raise Error, "RTM-004 requires exactly one winner" unless winners.length == 1
      ordered = rows.sort_by { |row| row.fetch("revision").to_i }
      ordered.each_cons(2) do |previous, current|
        raise Error, "RTM-004 revision is not strictly contiguous" unless current.fetch("revision").to_i == previous.fetch("revision").to_i + 1
        raise Error, "RTM-004 predecessor mismatch" unless current.fetch("previous_snapshot_id") == previous.fetch("snapshot_id")
        raise Error, "RTM-004 surface changed between revisions" unless current.fetch("surface_id") == previous.fetch("surface_id")
      end
      raise Error, "RTM-004 first predecessor must be null" unless ordered.first.fetch("previous_snapshot_id", nil).nil?
      { "winnerSnapshotId" => winners.first.fetch("snapshot_id"), "revision" => winners.first.fetch("revision"), "strictForward" => true }
    rescue KeyError, TypeError => error
      raise Error, "RTM-004 fixture is incomplete: #{error.message}"
    end

    def revocation_view(token:, current_epoch:, stage:)
      required = %w[surface_id head_revision snapshot_id rights_epoch render_plan_hash]
      raise Error, "RTM-005 token is incomplete" unless required.all? { |key| token.key?(key) }
      stale = token.fetch("rights_epoch").to_i != Integer(current_epoch)
      state = stale ? "RADAR_VIEW_RECOMPUTING" : stage.to_s
      raise Error, "RTM-005 stale view delivered bytes" if stale && state == "delivered"
      { "state" => state, "stale" => stale, "bytesAllowed" => !stale }
    rescue ArgumentError, TypeError => error
      raise Error, "RTM-005 fixture is incomplete: #{error.message}"
    end

    def token_scope(token:, request:)
      fields = %w[surface_id snapshot_id presentation_event_id query_shape]
      mismatch = fields.select { |field| token.fetch(field) != request.fetch(field) }
      member_ok = Array(request.fetch("member_ids")).include?(request.fetch("requested_member_id"))
      if mismatch.any? || !member_ok
        { "decision" => "blocked", "reasonCode" => "RADAR_VIEW_TOKEN_SCOPE_MISMATCH", "bytesAllowed" => false }
      else
        { "decision" => "allow", "reasonCode" => nil, "bytesAllowed" => true }
      end
    rescue KeyError, TypeError => error
      raise Error, "RTM-006 fixture is incomplete: #{error.message}"
    end

    def delivery_mode(mode:, revoked:)
      allowed = %w[full_materialized export]
      raise Error, "RTM-007 unmodelled delivery mode" unless allowed.include?(mode.to_s)
      { "mode" => mode.to_s, "decision" => revoked ? "blocked" : "allow", "bytesAllowed" => !revoked }
    end

    def representation(snapshot:, render_plan:, query:, audience:, content_units:)
      payload = { "snapshot" => snapshot, "renderPlan" => render_plan, "query" => query, "audience" => audience, "contentUnits" => content_units }
      bytes = JSON.generate(payload)
      { "bytes" => bytes, "payloadHash" => Digest::SHA256.hexdigest(bytes), "payloadLength" => bytes.bytesize }
    end

    def envelope(representation:, headers:, policy:)
      body = representation.fetch("bytes")
      required = %w[content_type content_disposition cache_control vary content_security_policy x_content_type_options]
      missing = required.reject { |key| headers.key?(key) }
      raise Error, "RTM-009 security headers missing: #{missing.join(',')}" unless missing.empty?
      raise Error, "RTM-009 body hash/length mismatch" unless Digest::SHA256.hexdigest(body) == representation.fetch("payloadHash") && body.bytesize == representation.fetch("payloadLength")
      raise Error, "RTM-010 executable MIME is not allowed" unless Array(policy.fetch("allowed_mime_types")).include?(headers.fetch("content_type"))
      raise Error, "RTM-010 CRLF header injection" if headers.values.any? { |value| value.to_s.include?("\r") || value.to_s.include?("\n") }
      raise Error, "RTM-010 permissive cache/CSP policy" if headers.fetch("cache_control").to_s.include?("public") || headers.fetch("content_security_policy").to_s == "*"
      { "decision" => "allow", "envelopeHash" => Digest::SHA256.hexdigest(JSON.generate(headers)), "bytesAllowed" => true }
    rescue KeyError, TypeError => error
      raise Error, "RTM-009/010 fixture is incomplete: #{error.message}"
    end
  end
end
