#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "webrick"
require_relative "../../lib/local_radar_store"

root = File.expand_path("../..", __dir__)
public_root = File.join(root, "app/public")
store = LocalRadarStore.new
port = Integer(ENV.fetch("PORT", "3000"))

server = WEBrick::HTTPServer.new(
  Port: port,
  BindAddress: ENV.fetch("BIND_ADDRESS", "127.0.0.1"),
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

json_response = lambda do |response, payload, status = 200|
  response.status = status
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-store"
  response["X-Content-Type-Options"] = "nosniff"
  response.body = JSON.generate(payload)
end

server.mount_proc "/api/health" do |_request, response|
  json_response.call(response, store.health)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message }, 503)
end

server.mount_proc "/api/radar" do |_request, response|
  json_response.call(response, store.current_radar)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/radar/publish" do |request, response|
  if request.request_method != "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  if request.body.to_s.bytesize > 1_000_000
    json_response.call(response, { "error" => "payload too large" }, 413)
    next
  end
  payload = JSON.parse(request.body.to_s)
  json_response.call(response, store.publish_snapshot!(snapshot: payload.fetch("snapshot"), cards: payload.fetch("cards")), 201)
rescue JSON::ParserError, KeyError, LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 400)
end

server.mount_proc "/" do |request, response|
  relative = request.path == "/" ? "index.html" : request.path.sub(%r{\A/}, "")
  candidate = File.expand_path(relative, public_root)
  prefix = "#{File.expand_path(public_root)}#{File::SEPARATOR}"
  if !candidate.start_with?(prefix) || !File.file?(candidate)
    response.status = 404
    response.body = "not found"
  else
    response["Cache-Control"] = "no-store"
    response["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:"
    response["X-Content-Type-Options"] = "nosniff"
    response["Referrer-Policy"] = "no-referrer"
    response["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response["Content-Type"] = WEBrick::HTTPUtils.mime_type(candidate, WEBrick::HTTPUtils::DefaultMimeTypes)
    response.body = File.binread(candidate)
  end
end

trap("INT") { server.shutdown }
puts "Trend Exploring staging server: http://127.0.0.1:#{port}"
server.start
