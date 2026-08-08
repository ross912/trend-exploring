#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

base = URI(ENV.fetch("LOCAL_RADAR_URL", "http://127.0.0.1:3000"))

def get_json(base, path)
  uri = base.dup
  uri.path = path
  response = Net::HTTP.get_response(uri)
  abort "#{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

health = get_json(base, "/api/health")
abort "database health is not ok" unless health.fetch("status") == "ok"
radar = get_json(base, "/api/radar")
abort "radar snapshot is missing" unless radar.dig("snapshot", "snapshot_id")
abort "radar cards are empty" if radar.fetch("cards").empty?
abort "radar trend collection is missing" unless radar.key?("trends")
abort "source matrix is missing" unless radar.key?("sources")
radar.fetch("trends").each do |trend|
  %w[topic mention_count recent_mention_count prior_mention_count source_count window_start window_end].each do |key|
    abort "trend field is missing: #{key}" unless trend.key?(key)
  end
end
puts JSON.pretty_generate({
  "status" => "passed",
  "database" => health.fetch("database"),
  "serverVersion" => health.fetch("server_version"),
  "snapshot" => radar.dig("snapshot", "snapshot_id"),
  "cardCount" => radar.fetch("cards").length,
  "trendCount" => radar.fetch("trends").length,
  "sourceCount" => radar.fetch("sources").length,
  "activeSourceCount" => radar.fetch("sources").count { |source| source.fetch("enabled") }
})
