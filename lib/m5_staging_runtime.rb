# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "thread"
require_relative "m5_contracts"

module M5
  # A deterministic, in-memory staging harness. It intentionally has no
  # network/provider dependency and must not be treated as a production store.
  class StagingRuntime
    class Error < StandardError; end

    attr_reader :surface_id, :personal_read_count, :watermark_status

    def initialize(surface_id:, signing_secret:)
      raise Error, "staging surface_id is required" if surface_id.to_s.empty?
      raise Error, "staging signing secret must be explicit" if signing_secret.to_s.length < 16

      @surface_id = surface_id.to_s
      @signing_secret = signing_secret.to_s
      @mutex = Mutex.new
      @head = nil
      @snapshots = {}
      @rights_epoch = 1
      @seen_events = {}
      @watermark_status = "healthy"
      @personal_read_count = 0
    end

    def ingest(events:)
      result = RealtimeContract.replay_dedup(events: events)
      @mutex.synchronize do
        Array(events).each do |event|
          key = [event.fetch("item_id"), event.fetch("version_id")]
          @seen_events[key] ||= event
        end
        @watermark_status = result.fetch("gapBlocked") ? "COLLECTION_MISSING" : "healthy"
      end
      result.merge("storedLogicalArrivals" => @seen_events.length)
    end

    def publish(snapshot:, expected_revision:)
      @mutex.synchronize do
        current_revision = @head ? @head.fetch("revision").to_i : 0
        raise Error, "RADAR_HEAD_CAS_MISMATCH" unless Integer(expected_revision) == current_revision
        validate_snapshot!(snapshot, current_revision)
        @snapshots.fetch(snapshot.fetch("snapshot_id"), nil)
        @snapshots[snapshot.fetch("snapshot_id")] = deep_copy(snapshot)
        @head = deep_copy(snapshot)
      end
      { "decision" => "winner", "snapshot_id" => snapshot.fetch("snapshot_id"), "revision" => snapshot.fetch("revision") }
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "staging publish is incomplete: #{error.message}"
    end

    def issue_view_token(query_shape:, audience: "public")
      @mutex.synchronize do
        raise Error, "RADAR_VIEW_UNAVAILABLE" unless @head
        payload = {
          "surface_id" => @surface_id,
          "snapshot_id" => @head.fetch("snapshot_id"),
          "head_revision" => @head.fetch("revision"),
          "presentation_event_id" => @head.fetch("presentation_event_id"),
          "rights_epoch" => @rights_epoch,
          "render_plan_hash" => @head.fetch("render_plan_hash"),
          "query_shape" => query_shape.to_s,
          "audience" => audience.to_s
        }
        encode_token(payload)
      end
    end

    def deliver(token:, query_shape:, requested_member_id: nil)
      payload = decode_token(token)
      @mutex.synchronize do
        if payload.fetch("rights_epoch").to_i != @rights_epoch
          return { "status" => "RADAR_VIEW_RECOMPUTING", "bytes" => nil }
        end
        raise Error, "RADAR_VIEW_UNAVAILABLE" unless @head && payload.fetch("snapshot_id") == @head.fetch("snapshot_id")
        raise Error, "RADAR_VIEW_TOKEN_SCOPE_MISMATCH" unless payload.fetch("query_shape") == query_shape.to_s
        content_units = Array(@head.fetch("content_units"))
        if requested_member_id && !content_units.include?(requested_member_id)
          raise Error, "RADAR_VIEW_TOKEN_SCOPE_MISMATCH"
        end
        representation = RealtimeContract.representation(
          snapshot: @head.fetch("snapshot_id"), render_plan: @head.fetch("render_plan_hash"),
          query: query_shape.to_s, audience: payload.fetch("audience"), content_units: content_units
        )
        headers = {
          "content_type" => "application/json", "content_disposition" => "inline",
          "cache_control" => "private, no-store", "vary" => "Authorization",
          "content_security_policy" => "default-src 'none'", "x_content_type_options" => "nosniff"
        }
        envelope = RealtimeContract.envelope(representation: representation, headers: headers, policy: { "allowed_mime_types" => ["application/json"] })
        { "status" => "delivered", "bytes" => representation.fetch("bytes"), "envelope" => envelope }
      end
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "staging delivery is incomplete: #{error.message}"
    end

    def revoke!
      @mutex.synchronize { @rights_epoch += 1 }
    end

    private

    def validate_snapshot!(snapshot, current_revision)
      required = %w[snapshot_id revision presentation_event_id render_plan_hash content_units]
      raise Error, "RADAR_SNAPSHOT_INCOMPLETE" unless required.all? { |key| snapshot.key?(key) }
      revision = Integer(snapshot.fetch("revision"))
      raise Error, "RADAR_REVISION_NOT_FORWARD" unless revision == current_revision + 1
      raise Error, "RADAR_SURFACE_MISMATCH" if snapshot.fetch("surface_id", @surface_id).to_s != @surface_id
      raise Error, "RADAR_METHOD_EPOCH_REQUIRED" if snapshot.fetch("method_epoch", "").to_s.empty?
      raise Error, "RADAR_FRONTIER_REQUIRED" if snapshot.fetch("comparison_watermark", "").to_s.empty?
    end

    def encode_token(payload)
      body = JSON.generate(payload)
      signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, @signing_secret, body)
      Base64.urlsafe_encode64(JSON.generate("payload" => payload, "signature" => signature), padding: false)
    end

    def decode_token(token)
      decoded = JSON.parse(Base64.urlsafe_decode64(token.to_s + "=" * ((4 - token.to_s.length % 4) % 4)))
      payload = decoded.fetch("payload")
      expected = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, @signing_secret, JSON.generate(payload))
      raise Error, "RADAR_TOKEN_SIGNATURE_INVALID" unless secure_compare(expected, decoded.fetch("signature"))
      payload
    rescue ArgumentError, JSON::ParserError, KeyError => error
      raise Error, "RADAR_TOKEN_INVALID: #{error.message}"
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.to_s.bytesize
      result = 0
      left.bytes.zip(right.to_s.bytes) { |a, b| result |= a ^ b }
      result.zero?
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
