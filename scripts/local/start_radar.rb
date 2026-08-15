#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "webrick"
require "rbconfig"
require "uri"
require "fileutils"
require "tmpdir"
require "securerandom"
require "digest"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/local_report_ledger"
require_relative "../../lib/weak_signal_store"
require_relative "../../lib/conversation_service"
require_relative "../../lib/world_change_store"
require_relative "../../lib/multilingual_concept_store"
require_relative "../../lib/signal_lifecycle_store"
require_relative "../../lib/local_runtime"
require_relative "../../lib/personal_memory_store"
require_relative "../../lib/cloud_config"
require_relative "../../lib/cloud_request"
require_relative "../../lib/cloud_auth"

root = File.expand_path("../..", __dir__)
public_root = File.join(root, "app/public")
store = LocalRadarStore.new
report_ledger = LocalReportLedger.new
weak_signal_store = WeakSignalStore.new
conversation_service = ConversationService.new
world_change_store = WorldChangeStore.new
multilingual_concept_store = MultilingualConceptStore.new
personal_store = PersonalMemoryStore.new
port = Integer(ENV.fetch("PORT", "3000"))
cloud_config = CloudConfig.new
auth_store = CloudAuth::Store.new(
  psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
  host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
  port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
  database: ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database),
  user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user)
)
auth_manager = if cloud_config.auth_mode == "required"
                 CloudAuth::Manager.new(store: auth_store, config: cloud_config)
               end
if cloud_config.auth_mode == "required"
  raise CloudConfig::Error, "auth schema is not ready" unless auth_store.migration_ready?
  owner = auth_store.owner_any
  raise CloudConfig::Error, "single owner account is not configured" unless owner && !owner["disabled_at"]
end

# Conversation replay is intentionally owner-bound to the server process. The
# browser may supply a turn id only; it can never select an owner principal.
CONVERSATION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/.freeze
TRANSLATION_LIMIT_MAX = 100
TRANSLATION_DAILY_CHARS_MAX = 200_000
TRANSLATION_JOB_OWNER_PATTERN = /\Atranslation-api-[A-Za-z0-9_.:-]{1,120}\z/.freeze

server = WEBrick::HTTPServer.new(
  Port: port,
  BindAddress: cloud_config.bind_address,
  MaxClients: cloud_config.max_clients,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

json_response = lambda do |response, payload, status = 200|
  response.status = status
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-store"
  response["X-Content-Type-Options"] = "nosniff"
  safe_payload = payload.is_a?(Hash) ? payload.dup : payload
  if cloud_config.auth_mode == "required" && status >= 400 && safe_payload.is_a?(Hash) && safe_payload.key?("error")
    safe_errors = ["method not allowed", "payload too large", "content-type must be application/json",
                   "authentication required", "invalid credentials", "recovery failed", "origin not allowed",
                   "csrf validation failed", "secure transport required", "publish API disabled", "request failed"]
    safe_payload["error"] = "request failed" unless safe_errors.include?(safe_payload["error"].to_s)
  end
  response.body = JSON.generate(safe_payload)
end

cookie_value = lambda do |request, name|
  request["cookie"].to_s.split(";").map(&:strip).each do |pair|
    key, value = pair.split("=", 2)
    return value.to_s if key == name
  end
  nil
end

cookie_token = lambda do |request, secure|
  cookie_value.call(request, secure ? "__Host-zixin_session" : "zixin_session")
end

csrf_cookie_token = lambda do |request, secure|
  cookie_value.call(request, secure ? "zixin_csrf" : "zixin_csrf")
end

class CloudCookie < WEBrick::Cookie
  def initialize(name, value, http_only: false, same_site: "Strict")
    super(name, value)
    @http_only = http_only
    @same_site = same_site
  end

  def to_s
    value = super
    value += "; HttpOnly" if @http_only
    value += "; SameSite=#{@same_site}" if @same_site && !@same_site.empty?
    value
  end
end

set_cookie = lambda do |response, name, value, secure:, max_age: nil, http_only: false|
  cookie = CloudCookie.new(name, value, http_only: http_only)
  cookie.path = "/"
  cookie.secure = true if secure
  cookie.max_age = max_age unless max_age.nil?
  response.cookies << cookie
end

cloud_context = lambda do |request|
  existing = request.instance_variable_get(:@cloud_context)
  existing || CloudRequestContext.new(request, config: cloud_config)
end

unauthorized_response = lambda do |request, response, status = 401|
  ctx = cloud_context.call(request)
  json_response.call(response, { "error" => "authentication required", "request_id" => ctx.request_id }, status)
end

mount_route = nil
mount_route = lambda do |path, require_auth: true, write: false, body_limit: cloud_config.body_limit, public_route: false, &handler|
  server.mount_proc(path) do |request, response|
    context = CloudRequestContext.new(request, config: cloud_config)
    request.instance_variable_set(:@cloud_context, context)
    CloudHeaders.apply(response, context)
    if request.request_method == "OPTIONS"
      response.status = context.origin_allowed_for_read? ? 204 : 403
      response.body = ""
      next
    end

    content_length = request["content-length"].to_s
    if content_length.match?(/\A\d+\z/) && content_length.to_i > body_limit
      json_response.call(response, { "error" => "payload too large", "request_id" => context.request_id }, 413)
      next
    end

    # WEBrick has already bounded normal request reads by Content-Length.  For
    # chunked bodies, inspect the buffered body before any route parser uses it.
    if request["transfer-encoding"].to_s.downcase.include?("chunked") && request.body.to_s.bytesize > body_limit
      json_response.call(response, { "error" => "payload too large", "request_id" => context.request_id }, 413)
      next
    end

    session = nil
    public_path = public_route.respond_to?(:call) ? public_route.call(request.path) : public_route
    if require_auth && cloud_config.auth_mode == "required" && !public_path
      raw_session = cookie_token.call(request, context.cookie_secure?)
      session = auth_manager && auth_manager.authenticate(session_token: raw_session, secure: context.secure?)
      unless session
        if request.path.start_with?("/api/")
          unauthorized_response.call(request, response)
        else
          response.status = 302
          response["Location"] = "/login"
          response.body = ""
        end
        next
      end
      request.instance_variable_set(:@cloud_session, session)
    end

    if write
      unless context.origin_allowed_for_write?
        json_response.call(response, { "error" => "origin not allowed", "request_id" => context.request_id }, 403)
        next
      end
      if session && auth_manager
        csrf = request["x-csrf-token"].to_s
        csrf_cookie = csrf_cookie_token.call(request, context.cookie_secure?)
        unless auth_manager.csrf_valid?(session: session, token: csrf, cookie_token: csrf_cookie)
          json_response.call(response, { "error" => "csrf validation failed", "request_id" => context.request_id }, 403)
          next
        end
      end
    end

    handler.call(request, response)
  rescue CloudAuth::SecureTransportRequired
    json_response.call(response, { "error" => "secure transport required" }, 400)
  rescue StandardError => error
    warn "request_id=#{request.instance_variable_get(:@cloud_context)&.request_id || 'unknown'} internal_error=#{error.class}"
    json_response.call(response, { "error" => "request failed" }, 503)
  end
end

livez_handler = lambda do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, { "status" => "ok" })
end
mount_route.call "/livez", require_auth: false, &livez_handler

readyz_handler = lambda do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  checks = {}
  begin
    checks["global_db"] = store.health.fetch("status") == "ok"
  rescue StandardError
    checks["global_db"] = false
  end
  begin
    checks["personal_db"] = personal_store.health.fetch("status") == "ok"
  rescue StandardError
    checks["personal_db"] = false
  end
  checks["auth_schema"] = cloud_config.auth_mode != "required" || auth_store.migration_ready?
  checks["schema"] = checks["global_db"] && checks["personal_db"] && checks["auth_schema"]
  begin
    stat = File.stat(LocalRuntime.state_dir)
    checks["disk"] = stat.directory? && system("df", "-Pk", LocalRuntime.state_dir, out: File::NULL, err: File::NULL)
  rescue StandardError
    checks["disk"] = false
  end
  begin
    translation = store.translation_status(daily_character_limit: TRANSLATION_DAILY_CHARS_MAX)
    updated = Time.parse(translation.fetch("last_updated_at").to_s).utc
    freshness_window = Integer(ENV.fetch("CLOUD_QUEUE_FRESHNESS_SECONDS", "86400"))
    checks["queue_freshness"] = translation.fetch("status").to_s != "not_available" && updated >= Time.now.utc - freshness_window
  rescue StandardError
    checks["queue_freshness"] = false
  end
  ready = checks.values.all?
  json_response.call(response, { "status" => ready ? "ok" : "not_ready", "checks" => checks }, ready ? 200 : 503)
end
mount_route.call "/readyz", require_auth: false, &readyz_handler
mount_route.call "/api/readyz", require_auth: false, &readyz_handler

mount_route.call "/api/auth/login", require_auth: false, body_limit: cloud_config.login_body_limit do |request, response|
  if cloud_config.auth_mode != "required"
    json_response.call(response, { "error" => "authentication is disabled for this local process" }, 404)
    next
  end
  context = cloud_context.call(request)
  unless request.request_method == "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless context.secure? || !cloud_config.secure_public_mode?
    json_response.call(response, { "error" => "secure transport required" }, 400)
    next
  end
  unless context.origin_allowed_for_write?
    json_response.call(response, { "error" => "origin not allowed" }, 403)
    next
  end
  unless request["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "application/json"
    json_response.call(response, { "error" => "content-type must be application/json" }, 415)
    next
  end
  payload = JSON.parse(request.body.to_s)
  raise JSON::ParserError, "payload must be an object" unless payload.is_a?(Hash)
  unknown = payload.keys.map(&:to_s) - %w[username password]
  raise KeyError, "unknown payload field" unless unknown.empty?
  result = auth_manager.login(username: payload["username"], password: payload["password"],
                              ip_hash: context.anonymous_id, request_id: context.request_id,
                              secure: context.secure?)
  unless result.ok
    response["Retry-After"] = result.retry_after.to_i.to_s if result.retry_after
    json_response.call(response, { "error" => "invalid credentials", "request_id" => context.request_id }, 401)
    next
  end
  secure_cookie = context.cookie_secure?
  session_name = secure_cookie ? "__Host-zixin_session" : "zixin_session"
  set_cookie.call(response, session_name, result.session_token, secure: secure_cookie, http_only: true,
                  max_age: cloud_config.session_absolute_ttl)
  set_cookie.call(response, "zixin_csrf", result.csrf_token, secure: secure_cookie, http_only: false,
                  max_age: cloud_config.session_absolute_ttl)
  json_response.call(response, { "status" => "ok", "account" => result.account,
                                  "csrf_token" => result.csrf_token, "request_id" => context.request_id })
rescue JSON::ParserError, KeyError, ArgumentError
  json_response.call(response, { "error" => "invalid credentials" }, 401)
rescue CloudAuth::SecureTransportRequired
  json_response.call(response, { "error" => "secure transport required" }, 400)
end

mount_route.call "/api/auth/recovery", require_auth: false, body_limit: cloud_config.login_body_limit do |request, response|
  if cloud_config.auth_mode != "required"
    json_response.call(response, { "error" => "authentication is disabled for this local process" }, 404)
    next
  end
  context = cloud_context.call(request)
  unless request.request_method == "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless context.secure? || !cloud_config.secure_public_mode?
    json_response.call(response, { "error" => "secure transport required" }, 400)
    next
  end
  unless context.origin_allowed_for_write?
    json_response.call(response, { "error" => "origin not allowed" }, 403)
    next
  end
  unless request["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "application/json"
    json_response.call(response, { "error" => "content-type must be application/json" }, 415)
    next
  end
  payload = JSON.parse(request.body.to_s)
  raise JSON::ParserError, "payload must be an object" unless payload.is_a?(Hash)
  unknown = payload.keys.map(&:to_s) - %w[username recovery_code new_password]
  raise KeyError, "unknown payload field" unless unknown.empty?
  result = auth_manager.recover(username: payload["username"], recovery_code: payload["recovery_code"],
                                 new_password: payload["new_password"], ip_hash: context.anonymous_id,
                                 request_id: context.request_id, secure: context.secure?)
  unless result.ok
    response["Retry-After"] = result.retry_after.to_i.to_s if result.retry_after
    json_response.call(response, { "error" => "recovery failed", "request_id" => context.request_id }, 401)
    next
  end
  json_response.call(response, { "status" => "ok", "request_id" => context.request_id })
rescue JSON::ParserError, KeyError, ArgumentError
  json_response.call(response, { "error" => "recovery failed" }, 401)
end

mount_route.call "/api/auth/session", require_auth: false do |request, response|
  unless request.request_method == "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  if cloud_config.auth_mode != "required"
    json_response.call(response, { "authenticated" => false, "auth_mode" => cloud_config.auth_mode })
    next
  end
  context = cloud_context.call(request)
  raw = cookie_token.call(request, context.cookie_secure?)
  session = auth_manager.authenticate(session_token: raw, secure: context.secure?)
  if session
    json_response.call(response, { "authenticated" => true, "account_id" => session["account_id"], "request_id" => context.request_id })
  else
    json_response.call(response, { "authenticated" => false, "request_id" => context.request_id }, 401)
  end
end

mount_route.call "/api/auth/logout", write: true do |request, response|
  if cloud_config.auth_mode != "required"
    json_response.call(response, { "error" => "authentication is disabled for this local process" }, 404)
    next
  end
  unless request.request_method == "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  context = cloud_context.call(request)
  raw = cookie_token.call(request, context.cookie_secure?)
  auth_manager.logout(session_token: raw)
  secure_cookie = context.cookie_secure?
  set_cookie.call(response, secure_cookie ? "__Host-zixin_session" : "zixin_session", "", secure: secure_cookie,
                  http_only: true, max_age: 0)
  set_cookie.call(response, "zixin_csrf", "", secure: secure_cookie, max_age: 0)
  json_response.call(response, { "status" => "ok", "request_id" => context.request_id })
end

mount_route.call "/api/auth/revoke-all", write: true do |request, response|
  if cloud_config.auth_mode != "required"
    json_response.call(response, { "error" => "authentication is disabled for this local process" }, 404)
    next
  end
  unless request.request_method == "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  context = cloud_context.call(request)
  auth_manager.revoke_all!(account_id: "owner", ip_hash: context.anonymous_id, request_id: context.request_id)
  json_response.call(response, { "status" => "ok", "request_id" => context.request_id })
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

mount_route.call "/api/health", require_auth: cloud_config.auth_mode == "required" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.health)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message }, 503)
end

mount_route.call "/api/livez", require_auth: false, &livez_handler

mount_route.call "/api/radar" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.current_radar)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

mount_route.call "/api/archive/status" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  json_response.call(response, store.archive_summary)
rescue LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

mount_route.call "/api/translations/status" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless cloud_config.auth_mode == "required" || translation_loopback_request.call(request)
    json_response.call(response, { "error" => "loopback origin required" }, 403)
    next
  end
  json_response.call(response, store.translation_status(daily_character_limit: [Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", TRANSLATION_DAILY_CHARS_MAX.to_s)), TRANSLATION_DAILY_CHARS_MAX].min))
rescue ArgumentError, LocalRadarStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

mount_route.call "/api/translations/run", write: true, body_limit: cloud_config.translation_body_limit do |request, response|
  if request.request_method != "POST"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  unless cloud_config.auth_mode == "required" || translation_loopback_request.call(request)
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

mount_route.call "/api/reports/latest" do |request, response|
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
  mount_route.call "/api/reports/#{kind}" do |request, response|
    if request.request_method != "GET"
      json_response.call(response, { "error" => "method not allowed" }, 405)
      next
    end
    json_response.call(response, report_ledger.latest_report(kind: kind))
  rescue LocalReportLedger::Error => error
    json_response.call(response, { "error" => error.message }, 503)
  end
end

mount_route.call "/api/weak-signals" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  run = weak_signal_store.latest_any
  json_response.call(response, run ? { "status" => run.fetch("status"), "run" => run } : { "status" => "not_run", "run" => nil })
rescue WeakSignalStore::Error => error
  json_response.call(response, { "error" => error.message }, 503)
end

mount_route.call "/api/world-changes" do |request, response|
  if request.request_method != "GET"
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  run = world_change_store.latest_public
  json_response.call(response, run ? run.merge("not_a_prediction" => true) : { "status" => "not_run", "run" => nil, "not_a_prediction" => true, "truncated" => false, "evidence_boundary" => world_change_store.public_boundary })
rescue WorldChangeStore::Error => error
  json_response.call(response, { "status" => "error", "error" => error.message, "not_a_prediction" => true }, 503)
end

mount_route.call "/api/signals/lifecycle" do |request, response|
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

mount_route.call "/api/multilingual-concepts" do |request, response|
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

mount_route.call "/api/conversation/query", write: true, body_limit: cloud_config.conversation_body_limit do |request, response|
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

mount_route.call "/api/conversation/replay" do |request, response|
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

mount_route.call "/api/radar/publish", write: true, body_limit: 1_000_000 do |request, response|
  # Public/cloud mode never exposes publication controls.  Publishing remains
  # an operator-side CLI/database action, even for the single authenticated
  # owner.
  json_response.call(response, { "error" => "publish API disabled" }, 403)
  next
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

mount_route.call "/", public_route: lambda { |path|
  path == "/robots.txt" || path == "/favicon.ico" || path == "/login" || path == "/login.html" ||
    path == "/landing.html" || path == "/landing.css" || path == "/landing.js" ||
    path == "/login.css" || path == "/login.js" || path == "/assets/landing-hero-v1.webp" ||
    (path == "/" && File.file?(File.join(public_root, "landing.html"))
  )
} do |request, response|
  unless %w[GET HEAD].include?(request.request_method)
    json_response.call(response, { "error" => "method not allowed" }, 405)
    next
  end
  if request.path == "/robots.txt"
    response.status = 200
    response["Content-Type"] = "text/plain; charset=utf-8"
    response["Cache-Control"] = "no-store"
    response.body = "User-agent: *\nDisallow: /\n"
    next
  end
  if request.path == "/login"
    candidate = File.join(public_root, "login.html")
    unless File.file?(candidate)
      response.status = 404
      response.body = "not found"
      next
    end
  end
  relative = if request.path == "/app"
               "index.html"
             elsif request.path == "/login"
               "login.html"
             elsif request.path == "/"
               File.file?(File.join(public_root, "landing.html")) ? "landing.html" : "index.html"
             else
               request.path.sub(%r{\A/}, "")
             end
  candidate = File.expand_path(relative, public_root)
  prefix = "#{File.expand_path(public_root)}#{File::SEPARATOR}"
  if !candidate.start_with?(prefix) || !File.file?(candidate)
    response.status = 404
    response.body = "not found"
  else
    response["Content-Type"] = WEBrick::HTTPUtils.mime_type(candidate, WEBrick::HTTPUtils::DefaultMimeTypes)
    response.body = File.binread(candidate)
  end
end

trap("INT") { server.shutdown }
puts "Trend Exploring staging server: http://127.0.0.1:#{port}"
server.start
