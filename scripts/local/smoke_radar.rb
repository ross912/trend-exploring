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
puts JSON.pretty_generate({ "status" => "passed", "database" => health.fetch("database"), "serverVersion" => health.fetch("server_version"), "snapshot" => radar.dig("snapshot", "snapshot_id"), "cardCount" => radar.fetch("cards").length })
