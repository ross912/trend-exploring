#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "webrick"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/local_report_ledger"
require_relative "../../lib/weak_signal_store"
require_relative "../../lib/conversation_service"

root = File.expand_path("../..", __dir__)
public_root = File.join(root, "app/public")
store = LocalRadarStore.new
report_ledger = LocalReportLedger.new
weak_signal_store = WeakSignalStore.new
conversation_service = ConversationService.new
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

server.mount_proc "/api/health" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.health)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message }, 503)
end

server.mount_proc "/api/radar" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.current_radar)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/reports/latest" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  kind = request.query["kind"].to_s
  if !%w[morning evening].include?(kind)
    json_response.call(response, { "error" => "kind must be morning or evening" }, 400)
    next
  end
  json_response.call(response, report_ledger.latest_report(kind: kind))
rescue LocalReportLedger::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

%w[morning evening].each do |kind|
  server.mount_proc "/api/reports/#{kind}" do |request, response|
    if request.request_method != "GET"
      json_response.call(response, { "error" => "method not allowed" }, 405)
      next
    end
    json_response.call(response, report_ledger.latest_report(kind: kind))
  rescue LocalReportLedger::Error => error
    json_response.call(response, { "error" => error.message }, 503)
  end
end

server.mount_proc "/api/weak-signals" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  run = weak_signal_store.latest_any
  json_response.call(response, run ? { "status" => run.fetch("status"), "run" => run } : { "status" => "not_run", "run" => nil })
rescue WeakSignalStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/conversation/query" do |request, response|
  if request.request_method != "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless request["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "application/json"
    json_response.call(response, { "error" => "content-type must be application/json" }, 415)
    next
  end
  if request.body.to_s.bytesize > 64_000
    json_response.call(response, { "error" => "payload too large" }, 413)
    next
  end
  payload = JSON.parse(request.body.to_s)
  raise JSON::ParserError, "payload must be an object" unless payload.is_a?(Hash)
  question = payload.fetch("question")
  raise KeyError, "question is required" unless question.is_a?(String) && !question.strip.empty?
  raise KeyError, "question is too long" if question.length > ConversationService::MAX_QUESTION_LENGTH
  raise KeyError, "unknown payload field" unless (payload.keys.map(&:to_s) - %w[question user_id subject_key limit]).empty?
  result = conversation_service.answer(question: question, user_id: payload["user_id"], subject_key: payload["subject_key"], limit: payload.fetch("limit", ConversationService::DEFAULT_LIMIT))
  json_response.call(response, result)
rescue JSON::ParserError, KeyError, ConversationService::Error, ConversationProvider::Error,
       ConversationRetriever::Error, PersonalMemoryStore::Error, ArgumentError => error
  json_response.call(response, { "error" => error.message }, 400)
rescue StandardError => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/radar/publish" do |request, response|
  if ENV.fetch("LOCAL_ENABLE_PUBLISH_API", "0") != "1"
    json_response.call(response, { "error" => "publish API disabled" }, 403)
    next
  end
  if request.request_method != "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless request["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "application/json"
    json_response.call(response, { "error" => "content-type must be application/json" }, 415)
    next
  end
  if request.body.to_s.bytesize > 1_000_000
    json_response.call(response, { "error" => "payload too large" }, 413)
    next
  end
  payload = JSON.parse(request.body.to_s)
  json_response.call(response, store.publish_snapshot!(snapshot: payload.fetch("snapshot"), cards: payload.fetch("cards"), trends: payload.fetch("trends", []), event_candidates: payload.fetch("event_candidates", []), exploration_items: payload.fetch("exploration_items", []), batch_id: payload["batch_id"]), 201)
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
