# frozen_string_literal: true

require "digest"
require "ipaddr"
require "securerandom"
require "uri"

# Request metadata is derived from the socket peer first.  Forwarded headers
# are consulted only after the immediate peer has matched a configured IP/CIDR
# proxy.  In particular, an internet client cannot spoof HTTPS, host or its
# source address by sending X-Forwarded-* headers directly to WEBrick.
class CloudRequestContext
  REQUEST_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z/.freeze

  attr_reader :request, :config, :request_id, :peer_ip, :client_ip, :host,
              :proto, :origin, :trusted_proxy

  def initialize(request, config: CloudConfig.new)
    @request = request
    @config = config
    @peer_ip = socket_peer
    @trusted_proxy = config.trusted_proxy?(@peer_ip)
    @client_ip = effective_client_ip
    @proto = effective_proto
    @host = effective_host
    @origin = request["origin"].to_s.strip
    @request_id = trusted_request_id || SecureRandom.uuid
  end

  def secure?
    proto == "https"
  end

  def peer_loopback?
    IPAddr.new(peer_ip).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  def public_origin?
    return false if origin.empty?

    origin == config.public_origin
  end

  # Empty Origin is fine for safe GETs and direct browser navigation.  A
  # state-changing browser request must carry the configured origin; this also
  # gives API clients an explicit, testable CSRF boundary.
  def origin_allowed_for_write?
    return false if origin.empty?

    public_origin? || loopback_origin?
  end

  def origin_allowed_for_read?
    origin.empty? || public_origin? || loopback_origin?
  end

  def anonymous_id
    # Only a keyed digest leaves this object.  The source address is never
    # written to the database or included in request logs.
    Digest::SHA256.hexdigest("#{config.identity_pepper}\0#{client_ip}")
  end

  def cookie_secure?
    config.secure_public_mode? ? secure? : false
  end

  def forwarded_headers_trusted?
    trusted_proxy
  end

  private

  def socket_peer
    request.peeraddr[3].to_s
  rescue StandardError
    ""
  end

  def effective_client_ip
    return peer_ip unless trusted_proxy

    forwarded = request["x-forwarded-for"].to_s
    chain = forwarded.split(",").map(&:strip).reject(&:empty?)
    addresses = chain.select { |value| valid_ip?(value) }
    # Walk from the proxy towards the client.  The first non-trusted address
    # is the client; malformed values are ignored rather than trusted.
    addresses.reverse_each do |address|
      return address unless config.trusted_proxy?(address)
    end
    peer_ip
  end

  def effective_proto
    return request_proto unless trusted_proxy

    value = request["x-forwarded-proto"].to_s.split(",").first.to_s.strip.downcase
    %w[http https].include?(value) ? value : request_proto
  end

  def effective_host
    return request_host unless trusted_proxy

    value = request["x-forwarded-host"].to_s.split(",").first.to_s.strip
    return request_host if value.empty? || !valid_host?(value)

    value
  end

  def request_proto
    if request.respond_to?(:ssl?) && request.ssl?
      "https"
    else
      "http"
    end
  end

  def request_host
    request["host"].to_s.split(",").first.to_s.strip
  end

  def trusted_request_id
    value = request["x-request-id"].to_s.strip
    value if REQUEST_ID.match?(value)
  end

  def valid_ip?(value)
    IPAddr.new(value)
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def valid_host?(value)
    return false if value.include?("@") || value.include?("/") || value.include?("\\")

    if value.start_with?("[")
      closing = value.index("]")
      return false unless closing
      host = value[1...closing]
      suffix = value[(closing + 1)..-1].to_s
      return false unless suffix.empty? || suffix.start_with?(":")
      port = suffix.empty? ? nil : suffix[1..-1]
    else
      host, port = value.split(":", 2)
    end
    return false if host.to_s.empty?
    return false unless host.match?(/\A[A-Za-z0-9.:-]+\z/)
    return false if port && (!port.match?(/\A\d+\z/) || !port.to_i.between?(1, 65_535))

    true
  end

  def loopback_origin?
    uri = URI.parse(origin)
    return false unless %w[http https].include?(uri.scheme)
    return false unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    return false unless uri.path.to_s.empty? || uri.path == "/"
    %w[localhost 127.0.0.1 [::1] ::1].include?(uri.host.to_s.downcase)
  rescue URI::InvalidURIError
    false
  end
end

module CloudHeaders
  module_function

  def apply(response, context, cache_control: "no-store", content_type: nil)
    response["X-Request-ID"] = context.request_id
    response["X-Content-Type-Options"] = "nosniff"
    response["Referrer-Policy"] = "no-referrer"
    response["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    response["Content-Security-Policy"] = [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self'",
      "img-src 'self' data:",
      "connect-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'"
    ].join("; ")
    response["Cache-Control"] = cache_control if cache_control
    response["Vary"] = merge_vary(response["Vary"], "Origin")
    response["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains" if context.secure?
    response["Content-Type"] = content_type if content_type

    origin = context.origin
    if !origin.empty? && context.public_origin?
      response["Access-Control-Allow-Origin"] = context.config.public_origin
      response["Access-Control-Allow-Credentials"] = "true"
      response["Access-Control-Allow-Headers"] = "Content-Type, X-CSRF-Token, X-Request-ID"
      response["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    end
    response
  end

  def merge_vary(existing, value)
    values = existing.to_s.split(",").map(&:strip).reject(&:empty?)
    values << value unless values.include?(value)
    values.join(", ")
  end
end
