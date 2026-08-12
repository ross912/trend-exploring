#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

base = URI(ENV.fetch("LOCAL_RADAR_URL", "http://127.0.0.1:3000"))

def get_json(base, path)
  uri = base.dup
  uri.path, uri.query = path.split("?", 2)
  response = Net::HTTP.get_response(uri)
  abort "#{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

def expect_http(base, path, method: "GET", body: nil, content_type: true, expected:)
  uri = base.dup
  uri.path, uri.query = path.split("?", 2)
  request = method == "POST" ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  request["Content-Type"] = "application/json" if body && content_type
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  abort "#{path}: expected HTTP #{expected}, got #{response.code}" unless response.code.to_i == expected
  response
end

health = get_json(base, "/api/health")
abort "database health is not ok" unless health.fetch("status") == "ok"
radar = get_json(base, "/api/radar")
reports = %w[morning evening].to_h do |kind|
  direct = get_json(base, "/api/reports/#{kind}")
  legacy = get_json(base, "/api/reports/latest?kind=#{kind}")
  abort "report route mismatch" unless direct.fetch("kind") == legacy.fetch("kind") && direct.fetch("status") == legacy.fetch("status")
  report = direct
  abort "report kind mismatch" unless report.fetch("kind") == kind
  abort "report status is invalid" unless %w[not_run scheduled published failed].include?(report.fetch("status"))
  summary = report.fetch("summary")
  abort "report summary shape is invalid" unless %w[status artifact runs].all? { |key| summary.key?(key) }
  abort "report summary status is invalid" unless %w[not_generated blocked failed succeeded].include?(summary.fetch("status"))
  if summary.fetch("status") == "succeeded"
    artifact = summary.fetch("artifact")
    abort "summary artifact missing" unless artifact.is_a?(Hash)
    abort "summary evidence missing" unless artifact.key?("evidence")
  else
    abort "non-success summary has an artifact" unless summary.fetch("artifact").nil?
  end
  if report.fetch("status") == "failed"
    abort "failed report slot reason is missing" if report.dig("slot", "failure_reason").to_s.empty?
  end
  [kind, report]
end
weak = get_json(base, "/api/weak-signals")
abort "weak signal status is invalid" unless %w[not_run warming_up evaluated].include?(weak.fetch("status"))
expect_http(base, "/api/weak-signals", method: "POST", expected: 405)
conversation = JSON.parse(expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "what changed" }, expected: 200).body)
abort "conversation status is missing" unless %w[generated not_generated failed privacy_blocked].include?(conversation.fetch("answer_status"))
expect_http(base, "/api/conversation/query", method: "GET", expected: 405)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "email me at a@example.com" }, expected: 200)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => ("x" * 2001) }, expected: 400)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "content type check" }, content_type: false, expected: 415)
abort "radar trend collection is missing" unless radar.key?("trends")
abort "radar event candidate collection is missing" unless radar.key?("event_candidates")
abort "source matrix is missing" unless radar.key?("sources")
abort "exploration collection is missing" unless radar.key?("exploration")
exploration = radar.fetch("exploration")
%w[latest_batch items boundary].each { |key| abort "exploration field is missing: #{key}" unless exploration.key?(key) }
unless radar.dig("snapshot", "snapshot_id")
  state = exploration.dig("latest_batch", "worker_state")
  abort "radar snapshot is missing" unless state.nil? || %w[not_run success_empty failed partial_failure snapshot_no_selection].include?(state)
else
  abort "radar cards are empty" if radar.fetch("cards").empty?
  projection = radar.fetch("snapshot")
  abort "signal projection status is missing" unless %w[fresh_batch reused_previous].include?(projection.fetch("signal_projection_status"))
  if projection.fetch("signal_projection_status") == "reused_previous"
    abort "reused signal projection source is missing" if projection.fetch("signal_source_snapshot_id").to_s.empty?
  end
end
boundary = exploration.fetch("boundary")
abort "exploration boundary is not fixed" unless boundary.fetch("topic_conditioned") == false && boundary.fetch("aggregator_mediated") == true && boundary.fetch("event_geography_status") == "unverified" && boundary.fetch("signal_eligible") == false
exploration.fetch("items").each do |item|
  %w[version_id capture_id content_hash title summary source_url locale_tag market_label market_label_basis publisher_id publisher_identity_status analysis_policy lane reason claim_status raw_listing].each do |key|
    abort "exploration item field is missing: #{key}" unless item.key?(key)
  end
  abort "exploration item lane is invalid" unless item.fetch("lane") == "locale_frontier"
  abort "exploration item reason is invalid" unless item.fetch("reason") == "topic_unconditioned_locale_sample"
  abort "exploration item is not raw_listing" unless item.fetch("claim_status") == "raw_listing"
end
radar.fetch("trends").each do |trend|
  %w[topic mention_count recent_mention_count prior_mention_count source_count window_start window_end].each do |key|
    abort "trend field is missing: #{key}" unless trend.key?(key)
  end
end
radar.fetch("event_candidates").each do |candidate|
  %w[candidate_key candidate_status label language matching_method dedup_source_count qualifying_source_count query_conditioned_evidence_count shared_anchors shared_phrases evidence_items].each do |key|
    abort "event candidate field is missing: #{key}" unless candidate.key?(key)
  end
  abort "event candidate status is invalid" unless candidate.fetch("candidate_status") == "event_candidate"
  abort "event candidate qualification is invalid" unless candidate.fetch("qualifying_source_count").to_i >= 2
  candidate.fetch("shared_anchors").each do |anchor|
    abort "event candidate anchor kind is missing" unless anchor.key?("kind") && anchor.key?("value") && anchor.key?("supporting_qualifying_source_count")
    abort "event candidate anchor support is inconsistent" unless anchor.fetch("supporting_qualifying_source_count").to_i == candidate.fetch("qualifying_source_count").to_i
  end
end
puts JSON.pretty_generate({
  "status" => "passed",
  "database" => health.fetch("database"),
  "serverVersion" => health.fetch("server_version"),
  "snapshot" => radar.dig("snapshot", "snapshot_id"),
  "cardCount" => radar.fetch("cards").length,
  "trendCount" => radar.fetch("trends").length,
  "eventCandidateCount" => radar.fetch("event_candidates").length,
  "explorationItemCount" => exploration.fetch("items").length,
  "sourceCount" => radar.fetch("sources").length,
  "activeSourceCount" => radar.fetch("sources").count { |source| source.fetch("enabled") },
  "reportStatuses" => reports.transform_values { |report| report.fetch("status") }
})
