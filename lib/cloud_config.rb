# frozen_string_literal: true

# Configuration shared by the public-facing WEBrick process and the
# authentication middleware.  This file deliberately depends only on Ruby's
# standard library so that the small local runtime does not need a native
# extension merely to start safely.
require "ipaddr"
require "securerandom"
require "uri"

class CloudConfig
  class Error < StandardError; end

  DEFAULT_ORIGIN = "https://zixin.space".freeze
  DEFAULT_MAX_CLIENTS = 10
  MIN_MAX_CLIENTS = 8
  MAX_MAX_CLIENTS = 12
  DEFAULT_IDLE_TTL = 30 * 60
  DEFAULT_ABSOLUTE_TTL = 7 * 24 * 60 * 60
  DEFAULT_BODY_LIMIT = 1_000_000
  DEFAULT_LOGIN_BODY_LIMIT = 16_000
  DEFAULT_CONVERSATION_BODY_LIMIT = 64_000
  DEFAULT_TRANSLATION_BODY_LIMIT = 16_000

  attr_reader :bind_address, :public_origin, :trusted_proxies, :max_clients,
              :session_idle_ttl, :session_absolute_ttl, :body_limit,
              :login_body_limit, :conversation_body_limit, :translation_body_limit,
              :identity_pepper, :session_pepper, :cloud_mode, :auth_mode

  def initialize(env: ENV)
    @env = env
    @bind_address = env.fetch("BIND_ADDRESS", "127.0.0.1").to_s.strip
    raise Error, "BIND_ADDRESS must remain loopback (127.0.0.1/::1)" unless bind_address_loopback_for_dev?
    public_origin_explicit = env.key?("PUBLIC_ORIGIN")
    @public_origin = parse_origin(env.fetch("PUBLIC_ORIGIN", DEFAULT_ORIGIN))
    @trusted_proxies = parse_trusted_proxies(env.fetch("TRUSTED_PROXY_CIDRS", env.fetch("TRUSTED_PROXIES", "")))
    @max_clients = bounded_integer(env.fetch("WEBrick_MAX_CLIENTS", env.fetch("MAX_CLIENTS", DEFAULT_MAX_CLIENTS)),
                                   MIN_MAX_CLIENTS, MAX_MAX_CLIENTS, "MaxClients")
    @session_idle_ttl = bounded_integer(env.fetch("CLOUD_SESSION_IDLE_TTL", DEFAULT_IDLE_TTL), 60, 86_400, "session idle TTL")
    @session_absolute_ttl = bounded_integer(env.fetch("CLOUD_SESSION_ABSOLUTE_TTL", DEFAULT_ABSOLUTE_TTL), 300, 31_536_000, "session absolute TTL")
    @body_limit = bounded_integer(env.fetch("CLOUD_BODY_LIMIT", DEFAULT_BODY_LIMIT), 1_024, 10_000_000, "body limit")
    @login_body_limit = bounded_integer(env.fetch("CLOUD_LOGIN_BODY_LIMIT", DEFAULT_LOGIN_BODY_LIMIT), 1_024, 256_000, "login body limit")
    @conversation_body_limit = bounded_integer(env.fetch("CLOUD_CONVERSATION_BODY_LIMIT", DEFAULT_CONVERSATION_BODY_LIMIT), 1_024, 1_000_000, "conversation body limit")
    @translation_body_limit = bounded_integer(env.fetch("CLOUD_TRANSLATION_BODY_LIMIT", DEFAULT_TRANSLATION_BODY_LIMIT), 1_024, 256_000, "translation body limit")
    @cloud_mode = truthy?(env.fetch("CLOUD_PUBLIC_DEPLOYMENT", env.fetch("CLOUD_MODE", "0")))
    requested_auth_mode = env.fetch("AUTH_MODE", "").to_s.strip.downcase
    auto_required = @cloud_mode || !@trusted_proxies.empty? || !bind_address_loopback_for_dev? || env.key?("PUBLIC_ORIGIN")
    @auth_mode = requested_auth_mode.empty? ? (auto_required ? "required" : "local_disabled") : requested_auth_mode
    raise Error, "AUTH_MODE must be required or local_disabled" unless %w[required local_disabled].include?(@auth_mode)
    if @auth_mode == "local_disabled" && (!bind_address_loopback_for_dev? || !@trusted_proxies.empty? || @cloud_mode || public_origin_explicit)
      raise Error, "local_disabled auth is allowed only on an unproxied loopback development bind"
    end
    development = env.fetch("CLOUD_DEVELOPMENT", "0").to_s == "1" && bind_address_loopback_for_dev? && !@cloud_mode && @auth_mode == "local_disabled"
    @identity_pepper = env.fetch("CLOUD_IDENTITY_PEPPER", "").to_s
    @session_pepper = env.fetch("CLOUD_SESSION_PEPPER", "").to_s
    if development
      # Explicitly local-only.  These process-lifetime fallbacks are never
      # accepted when CLOUD_MODE is enabled and are not persisted.
      @identity_pepper = SecureRandom.hex(32) if @identity_pepper.empty?
      @session_pepper = SecureRandom.hex(32) if @session_pepper.empty?
    elsif @auth_mode == "required" && (@identity_pepper.empty? || @session_pepper.empty?)
      raise Error, "CLOUD_IDENTITY_PEPPER and CLOUD_SESSION_PEPPER are required outside explicit development mode"
    end
    validate!
  end

  def loopback_bind?
    ip = IPAddr.new(bind_address)
    ip.loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  def trusted_proxy?(address)
    ip = IPAddr.new(address.to_s)
    trusted_proxies.any? { |network| network.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def public_origin_uri
    URI.parse(public_origin)
  end

  def secure_public_mode?
    cloud_mode || auth_mode == "required" || !loopback_bind? || !trusted_proxies.empty?
  end

  def validate!
    # The application is an upstream.  Exposing WEBrick directly makes the
    # trusted-proxy and HTTPS assumptions false, so a non-loopback bind is
    # always rejected.  Caddy/Nginx should connect to 127.0.0.1 instead.
    raise Error, "BIND_ADDRESS must remain loopback (127.0.0.1/::1)" unless loopback_bind?
    uri = public_origin_uri
    raise Error, "PUBLIC_ORIGIN must use https" unless uri.scheme == "https"
    raise Error, "PUBLIC_ORIGIN must not include credentials" unless uri.userinfo.nil?
    raise Error, "PUBLIC_ORIGIN must not include a path" unless uri.path.to_s.empty? || uri.path == "/"
    raise Error, "CLOUD_MODE requires an https PUBLIC_ORIGIN" if cloud_mode && uri.scheme != "https"
    true
  end

  private

  def parse_origin(value)
    text = value.to_s.strip.sub(%r{/\z}, "")
    raise Error, "PUBLIC_ORIGIN is required" if text.empty?
    uri = URI.parse(text)
    raise Error, "PUBLIC_ORIGIN is invalid" if uri.host.to_s.empty? || uri.query || uri.fragment
    raise Error, "PUBLIC_ORIGIN must use port 443" if uri.port && uri.port != 443
    text
  rescue URI::InvalidURIError => error
    raise Error, "PUBLIC_ORIGIN is invalid: #{error.message}"
  end

  def parse_trusted_proxies(value)
    tokens = value.to_s.split(",").map(&:strip).reject(&:empty?)
    tokens.map do |token|
      # Hostnames are intentionally rejected.  A DNS name in a proxy allowlist
      # would make header trust change underneath the process.
      raise Error, "trusted proxy must be an IP or CIDR: #{token}" if token.match?(/[A-Za-z]/)
      IPAddr.new(token)
    rescue IPAddr::InvalidAddressError
      raise Error, "trusted proxy must be an IP or CIDR: #{token}"
    end.freeze
  end

  def bounded_integer(value, minimum, maximum, label)
    integer = Integer(value)
    raise Error, "#{label} must be between #{minimum} and #{maximum}" unless integer.between?(minimum, maximum)
    integer
  rescue ArgumentError, TypeError
    raise Error, "#{label} must be an integer"
  end

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def bind_address_loopback_for_dev?
    IPAddr.new(@bind_address).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end
end
