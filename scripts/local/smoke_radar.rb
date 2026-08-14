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
  abort "report summary shape is invalid" unless %w[status artifact runs claim_gate_status].all? { |key| summary.key?(key) }
  abort "report summary status is invalid" unless %w[not_generated blocked failed succeeded].include?(summary.fetch("status"))
  abort "report claim gate status is invalid" unless %w[not_generated verified legacy_unverified failed].include?(summary.fetch("claim_gate_status"))
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
world_changes = get_json(base, "/api/world-changes")
abort "world-change not-a-prediction boundary is missing" unless world_changes.fetch("not_a_prediction") == true
# A v1 detector run is intentionally hidden by the public precision gate until
# the detector itself emits the validated version.  `invalidated` is therefore
# a healthy, auditable safety state—not an API failure.
abort "world-change status is invalid" unless %w[not_run warming_up evaluated invalidated error].include?(world_changes.fetch("status"))
abort "world-change response is too large" if JSON.generate(world_changes).bytesize >= 512 * 1024
unless world_changes.fetch("status") == "error"
  run = world_changes["run"] || world_changes
  if world_changes.fetch("status") == "not_run"
    abort "not_run world-change payload is missing candidates" unless world_changes.key?("run") && world_changes.key?("evidence_boundary")
  else
    abort "world-change run shape is invalid" unless %w[run_id as_of detector_version status candidates].all? { |key| run.key?(key) }
    boundary = world_changes.fetch("evidence_boundary")
    abort "world-change evidence boundary is missing" unless boundary.fetch("max_candidates").to_i == 20 && boundary.fetch("summary_body_excluded") == true
    abort "world-change reference boundary is invalid" unless boundary.fetch("per_channel_refs") == { "qualifying" => 3, "supporting" => 2, "contradicting" => 2 }
    ref_fields = %w[version_id title source_url publisher channel role].sort
    run.fetch("candidates").each do |candidate|
      abort "world-change candidate shape is invalid" unless %w[candidate_key candidate_status channels missing_channels contradicting_evidence alternative_explanations next_verification].all? { |key| candidate.key?(key) }
      abort "world-change candidate is scored/predicted" if candidate.keys.any? { |key| %w[score confidence prediction forecast probability].include?(key) }
      channels = candidate.fetch("channels")
      abort "world-change channels are incomplete" unless %w[technical_capability capital_commitment policy_action real_world_adoption public_discussion].all? { |channel| channels.key?(channel) }
      channels.each_value do |channel|
        abort "world-change qualifying refs exceed public limit" if channel.fetch("evidence").length > 3
        abort "world-change support refs exceed public limit" if channel.fetch("supporting_evidence").length > 2
        abort "world-change contradicting refs exceed public limit" if channel.fetch("contradicting_evidence").length > 2
        %w[evidence supporting_evidence contradicting_evidence].each do |role|
          channel.fetch(role).each do |ref|
            abort "world-change ref fields are not bounded" unless ref.keys.sort == ref_fields
            abort "world-change ref leaked raw body" if ref.keys.any? { |key| %w[summary body content].include?(key) }
          end
        end
      end
    end
  end
end
expect_http(base, "/api/world-changes", method: "POST", expected: 405)
lifecycle = get_json(base, "/api/signals/lifecycle")
abort "lifecycle boundary is missing" unless lifecycle.fetch("not_a_prediction") == true && lifecycle.key?("lifecycle")
expect_http(base, "/api/signals/lifecycle", method: "POST", expected: 405)
concepts = get_json(base, "/api/multilingual-concepts")
abort "multilingual concept shape is invalid" unless %w[status candidates boundary denominator run examined_count mapped_count candidate_count].all? { |key| concepts.key?(key) }
abort "multilingual concept status is invalid" unless %w[not_run evaluated error].include?(concepts.fetch("status"))
abort "multilingual denominator is invalid" unless %w[eligible_translation_inputs mapped_source_versions candidate_rows].all? { |key| concepts.fetch("denominator").key?(key) }
expect_http(base, "/api/multilingual-concepts", method: "POST", expected: 405)
conversation = JSON.parse(expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "what changed" }, expected: 200).body)
abort "conversation status is missing" unless %w[generated not_generated failed privacy_blocked].include?(conversation.fetch("answer_status"))
if conversation["turn_id"]
  abort "conversation thread id is missing" if conversation["thread_id"].to_s.empty?
  replay = get_json(base, "/api/conversation/replay/#{conversation.fetch('turn_id')}")
  abort "conversation replay turn mismatch" unless replay.dig("turn", "turn_id") == conversation.fetch("turn_id")
  abort "conversation replay thread mismatch" unless replay.dig("turn", "thread_id") == conversation.fetch("thread_id")
end
expect_http(base, "/api/conversation/query", method: "GET", expected: 405)
expect_http(base, "/api/conversation/replay/not%20an%20id", method: "GET", expected: 400)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "email me at a@example.com" }, expected: 200)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => ("x" * 2001) }, expected: 400)
expect_http(base, "/api/conversation/query", method: "POST", body: { "question" => "content type check" }, content_type: false, expected: 415)
abort "radar trend collection is missing" unless radar.key?("trends")
abort "radar event candidate collection is missing" unless radar.key?("event_candidates")
abort "source matrix is missing" unless radar.key?("sources")
abort "archive status is missing" unless radar.key?("archive")
%w[source_policies archive_attempts translation_queue full_archive_source_count fulltext_archive_count fulltext_translation_count].each do |key|
  abort "archive status field is missing: #{key}" unless radar.fetch("archive").key?(key)
end
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
