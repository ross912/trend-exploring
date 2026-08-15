#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "webrick"
require "rbconfig"
require "uri"
require "fileutils"
require "tmpdir"
require "securerandom"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/local_report_ledger"
require_relative "../../lib/weak_signal_store"
require_relative "../../lib/conversation_service"
require_relative "../../lib/world_change_store"
require_relative "../../lib/multilingual_concept_store"
require_relative "../../lib/signal_lifecycle_store"
require_relative "../../lib/local_runtime"

root = File.expand_path("../..", __dir__)
public_root = File.join(root, "app/public")
store = LocalRadarStore.new
report_ledger = LocalReportLedger.new
weak_signal_store = WeakSignalStore.new
conversation_service = ConversationService.new
world_change_store = WorldChangeStore.new
multilingual_concept_store = MultilingualConceptStore.new
port = Integer(ENV.fetch("PORT", "3000"))

# Conversation replay is intentionally owner-bound to the server process. The
# browser may supply a turn id only; it can never select an owner principal.
CONVERSATION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/.freeze
TRANSLATION_LIMIT_MAX = 100
TRANSLATION_DAILY_CHARS_MAX = 200_000
TRANSLATION_JOB_OWNER_PATTERN = /\Atranslation-api-[A-Za-z0-9_.:-]{1,120}\z/.freeze

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

translation_loopback_request = lambda do |request|
  peer = begin
    request.peeraddr[3].to_s
  rescue StandardError
    ""
  end
  next false unless %w[127.0.0.1 ::1 0:0:0:0:0:0:0:1 localhost].include?(peer)
  origin = request["origin"].to_s.strip
  next true if origin.empty?
  begin
    parsed = URI.parse(origin)
    parsed.scheme == "http" && %w[localhost 127.0.0.1 [::1] ::1].include?(parsed.host.to_s)
  rescue URI::InvalidURIError
    false
  end
end

translation_spawn = lambda do |job_id, owner_id, limit, daily_limit|
  worker = File.expand_path("translation_worker.rb", File.join(root, "scripts/local"))
  state_dir = ENV.fetch("LOCAL_STATE_DIR", LocalRuntime.state_dir)
  log_dir = File.join(state_dir, "logs")
  FileUtils.mkdir_p(log_dir, mode: 0o700)
  stdout_path = File.join(log_dir, "translation-api-worker.log")
  stderr_path = File.join(log_dir, "translation-api-worker.error.log")
  env = {
    "LOCAL_TRANSLATION_JOB_ID" => job_id.to_s,
    "LOCAL_TRANSLATION_OWNER" => owner_id.to_s
  }
  pid = Process.spawn(env, RbConfig.ruby, worker, "--limit", limit.to_s,
                      "--daily-character-limit", daily_limit.to_s,
                      out: stdout_path, err: stderr_path, close_others: true)
  Process.detach(pid)
  pid
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

server.mount_proc "/api/archive/status" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.archive_summary)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/translations/status" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless translation_loopback_request.call(request)
    json_response.call(response, { "error" => "loopback origin required" }, 403)
    next
  end
  json_response.call(response, store.translation_status(daily_character_limit: [Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", TRANSLATION_DAILY_CHARS_MAX.to_s)), TRANSLATION_DAILY_CHARS_MAX].min))
rescue ArgumentError, LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

server.mount_proc "/api/translations/run" do |request, response|
  if request.request_method != "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless translation_loopback_request.call(request)
    json_response.call(response, { "error" => "loopback origin required" }, 403)
    next
  end
  content_type = request["content-type"].to_s.split(";", 2).first.to_s.strip.downcase
  unless content_type == "application/json"
    json_response.call(response, { "error" => "content-type must be application/json" }, 415)
    next
  end
  if request.body.to_s.bytesize > 16_000
    json_response.call(response, { "error" => "payload too large" }, 413)
    next
  end
  payload = JSON.parse(request.body.to_s)
  raise JSON::ParserError, "payload must be an object" unless payload.is_a?(Hash)
  unknown = payload.keys.map(&:to_s) - %w[limit daily_character_limit]
  raise KeyError, "unknown payload field" unless unknown.empty?
  default_limit = [Integer(ENV.fetch("LOCAL_TRANSLATION_LIMIT", TRANSLATION_LIMIT_MAX.to_s)), TRANSLATION_LIMIT_MAX].min
  default_daily_limit = [Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", TRANSLATION_DAILY_CHARS_MAX.to_s)), TRANSLATION_DAILY_CHARS_MAX].min
  limit = payload.key?("limit") ? payload.fetch("limit") : payload.fetch(:limit, default_limit)
  daily_limit = if payload.key?("daily_character_limit")
                  payload.fetch("daily_character_limit")
                else
                  payload.fetch(:daily_character_limit, default_daily_limit)
                end
  raise ArgumentError, "limit must be an integer" unless limit.is_a?(Integer)
  raise ArgumentError, "daily_character_limit must be an integer" unless daily_limit.is_a?(Integer)
  limit = Integer(limit)
  daily_limit = Integer(daily_limit)
  raise ArgumentError, "limit must be between 1 and #{default_limit}" unless limit.between?(1, default_limit)
  raise ArgumentError, "daily_character_limit must be between 1 and #{default_daily_limit}" unless daily_limit.between?(1, default_daily_limit)
  active = store.active_translation_batch_job
  if active
    json_response.call(response, { "status" => "active", "job" => active }, 409)
    next
  end
  owner = "translation-api-#{Process.pid}-#{SecureRandom.hex(5)}"
  job_id = store.start_translation_batch_job!(limit: limit, daily_character_limit: daily_limit, owner: owner)
  begin
    pid = translation_spawn.call(job_id, owner, limit, daily_limit)
  rescue StandardError => error
    begin
      store.finish_translation_batch_job!(job_id: job_id, owner: owner, state: "failed", error_reason: "worker spawn failed")
    rescue StandardError
      nil
    end
    raise LocalRadarStore::Error, "translation worker could not be started: #{error.message}"
  end
  json_response.call(response, { "status" => "queued", "job" => { "job_id" => job_id, "owner_id" => owner, "pid" => pid, "requested_limit" => limit, "daily_character_limit" => daily_limit }, "status_url" => "/api/translations/status" }, 202)
rescue JSON::ParserError, KeyError, ArgumentError => error
  json_response.call(response, { "error" => error.message }, 400)
rescue LocalRadarStore::Error => error
  if error.message.include?("already active")
    json_response.call(response, { "status" => "active", "error" => error.message, "job" => store.active_translation_batch_job }, 409)
  else
    json_response.call(response, { "error" => error.message }, 503)
  end
rescue StandardError => error
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

server.mount_proc "/api/world-changes" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  run = world_change_store.latest_public
  json_response.call(response, run ? run.merge("not_a_prediction" => true) : { "status" => "not_run", "run" => nil, "not_a_prediction" => true, "truncated" => false, "evidence_boundary" => world_change_store.public_boundary })
rescue WorldChangeStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message, "not_a_prediction" => true }, 503)
end

server.mount_proc "/api/signals/lifecycle" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  run = world_change_store.latest_any
  lifecycle = Array(run && run["candidates"]).map do |candidate|
    family_id = SignalLifecycleStore.new.proposition_family_id(family_key: candidate.fetch("candidate_key"))
    signal_id = SignalLifecycleStore.new.signal_id(proposition_family_id: family_id, signal_key: candidate.fetch("candidate_key"))
    begin
      SignalLifecycleStore.new.history(signal_id: signal_id)
    rescue SignalLifecycleStore::Error
      { "signal_id" => signal_id, "candidate_key" => candidate.fetch("candidate_key"), "current_state" => nil, "state_events" => [], "trigger_events" => [], "evidence_links" => [], "retrospective_event_count" => 0 }
    end
  end
  json_response.call(response, { "status" => run ? run.fetch("status") : "not_run", "as_of" => run && run["as_of"], "lifecycle" => lifecycle, "not_a_prediction" => true })
rescue SignalLifecycleStore::Error, WorldChangeStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message, "not_a_prediction" => true }, 503)
end

server.mount_proc "/api/multilingual-concepts" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  candidates = multilingual_concept_store.read_candidates
  denominator = multilingual_concept_store.mapping_denominator
  json_response.call(response, {
    "status" => denominator.fetch("status"), "candidates" => candidates,
    "run" => denominator.fetch("run"), "examined_count" => denominator.fetch("examined_count"),
    "mapped_count" => denominator.fetch("mapped_count"), "candidate_count" => denominator.fetch("candidate_count"),
    "denominator" => denominator.fetch("denominator"),
    "boundary" => "provider-backed concept participation only; not an event or prediction"
  })
rescue MultilingualConceptStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message, "candidates" => [], "run" => nil,
                                  "examined_count" => 0, "mapped_count" => 0, "candidate_count" => 0,
                                  "denominator" => { "eligible_translation_inputs" => 0, "mapped_source_versions" => 0, "candidate_rows" => 0 } }, 503)
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

server.mount_proc "/api/conversation/replay" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  # Accept either /api/conversation/replay/:turn_id or a query parameter for
  # simple clients, but never accept a request body or an owner override.
  prefix = "/api/conversation/replay/"
  turn_id = if request.path.start_with?(prefix)
              request.path.delete_prefix(prefix)
            else
              request.query["turn_id"].to_s
            end
  if turn_id.empty? || !CONVERSATION_ID_PATTERN.match?(turn_id) || turn_id.include?("/")
    json_response.call(response, { "error" => "turn_id must be a strict identifier" }, 400)
    next
  end
  if request.body.to_s.bytesize.positive?
    json_response.call(response, { "error" => "replay does not accept a request body" }, 400)
    next
  end
  json_response.call(response, conversation_service.replay(turn_id: turn_id))
rescue ConversationService::Error, ConversationLedgerStore::Error, ArgumentError => error
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
