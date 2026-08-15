# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "open3"
require "rbconfig"
require "socket"
require "uri"
require_relative "../lib/cloud_config"
require_relative "../lib/cloud_request"

class CloudHttpSecurityTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze

  class FakeRequest
    def initialize(headers: {}, peer: "127.0.0.1", ssl: false)
      @headers = headers.transform_keys(&:downcase)
      @peer = peer
      @ssl = ssl
    end

    def [](key)
      @headers[key.to_s.downcase]
    end

    def peeraddr
      [nil, nil, nil, @peer]
    end

    def ssl?
      @ssl
    end
  end

  class FakeResponse
    attr_reader :headers

    def initialize
      @headers = {}
    end

    def [](key)
      @headers[key.downcase]
    end

    def []=(key, value)
      @headers[key.downcase] = value
    end
  end

  def config(extra = {})
    CloudConfig.new(env: {
      "BIND_ADDRESS" => "127.0.0.1", "CLOUD_DEVELOPMENT" => "1",
      "CLOUD_IDENTITY_PEPPER" => "identity-test", "CLOUD_SESSION_PEPPER" => "session-test"
    }.merge(extra))
  end

  def test_untrusted_forwarded_headers_are_ignored
    request = FakeRequest.new(
      headers: { "X-Forwarded-For" => "1.2.3.4", "X-Forwarded-Proto" => "https", "X-Forwarded-Host" => "zixin.space" },
      peer: "198.51.100.2"
    )
    context = CloudRequestContext.new(request, config: config)
    assert_equal "198.51.100.2", context.client_ip
    assert_equal "http", context.proto
    refute context.trusted_proxy
  end

  def test_trusted_proxy_headers_are_accepted_only_for_configured_peer
    request = FakeRequest.new(
      headers: { "X-Forwarded-For" => "1.2.3.4, 10.0.0.2", "X-Forwarded-Proto" => "https", "X-Forwarded-Host" => "zixin.space" },
      peer: "10.0.0.2"
    )
    context = CloudRequestContext.new(request, config: config("TRUSTED_PROXY_CIDRS" => "10.0.0.0/8"))
    assert_equal "1.2.3.4", context.client_ip
    assert_equal "https", context.proto
    assert_equal "zixin.space", context.host
    assert context.secure?
  end

  def test_trusted_proxy_configuration_rejects_hostnames
    assert_raises(CloudConfig::Error) { config("TRUSTED_PROXY_CIDRS" => "proxy.example") }
    assert_raises(CloudConfig::Error) { config("TRUSTED_PROXY_CIDRS" => "10.0.0.1:443") }
  end

  def test_cloud_mode_requires_peppers_and_https
    assert_raises(CloudConfig::Error) do
      CloudConfig.new(env: { "BIND_ADDRESS" => "127.0.0.1", "CLOUD_PUBLIC_DEPLOYMENT" => "1" })
    end
    assert_raises(CloudConfig::Error) do
      CloudConfig.new(env: {
        "BIND_ADDRESS" => "127.0.0.1", "CLOUD_PUBLIC_DEPLOYMENT" => "1",
        "CLOUD_IDENTITY_PEPPER" => "i", "CLOUD_SESSION_PEPPER" => "s", "PUBLIC_ORIGIN" => "http://zixin.space"
      })
    end
  end

  def test_local_disabled_cannot_be_used_with_a_trusted_proxy
    assert_raises(CloudConfig::Error) do
      CloudConfig.new(env: {
        "BIND_ADDRESS" => "127.0.0.1", "AUTH_MODE" => "local_disabled",
        "TRUSTED_PROXY_CIDRS" => "10.0.0.0/8", "CLOUD_DEVELOPMENT" => "1"
      })
    end
  end

  def test_local_disabled_cannot_be_used_with_explicit_public_origin
    assert_raises(CloudConfig::Error) do
      CloudConfig.new(env: {
        "BIND_ADDRESS" => "127.0.0.1", "AUTH_MODE" => "local_disabled",
        "PUBLIC_ORIGIN" => "https://zixin.space", "CLOUD_DEVELOPMENT" => "1"
      })
    end
  end

  def test_anonymous_id_is_digest_and_does_not_contain_source_ip
    context = CloudRequestContext.new(FakeRequest.new(peer: "203.0.113.10"), config: config)
    refute_includes context.anonymous_id, "203.0.113.10"
    assert_match(/\A[a-f0-9]{64}\z/, context.anonymous_id)
  end

  def test_headers_hsts_only_when_effective_proto_is_https
    secure_request = FakeRequest.new(
      headers: { "X-Forwarded-Proto" => "https", "Origin" => "https://zixin.space" },
      peer: "10.0.0.2"
    )
    secure_context = CloudRequestContext.new(secure_request, config: config("TRUSTED_PROXY_CIDRS" => "10.0.0.0/8"))
    secure_response = FakeResponse.new
    CloudHeaders.apply(secure_response, secure_context)
    assert_includes secure_response["Strict-Transport-Security"], "max-age"
    assert_includes secure_response["Content-Security-Policy"], "frame-ancestors 'none'"
    assert_includes secure_response["Content-Security-Policy"], "base-uri 'self'"

    spoofed = FakeRequest.new(headers: { "X-Forwarded-Proto" => "https" }, peer: "198.51.100.2")
    spoofed_response = FakeResponse.new
    CloudHeaders.apply(spoofed_response, CloudRequestContext.new(spoofed, config: config))
    assert_nil spoofed_response["Strict-Transport-Security"]
  end

  def test_real_local_server_serves_login_and_rejects_static_writes
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr.fetch(1)
    probe.close
    stdin, stdout, stderr, waiter = start_local_server(port)
    stdin.close
    response = wait_for_http(port)
    assert_equal "200", response.code
    assert_includes response.body, "<!doctype html>"

    uri = URI("http://127.0.0.1:#{port}/login")
    post = Net::HTTP::Post.new(uri)
    post_response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(post) }
    assert_equal "405", post_response.code
  ensure
    if waiter && waiter.alive?
      Process.kill("TERM", waiter.pid)
      waiter.join(5)
      Process.kill("KILL", waiter.pid) if waiter.alive?
    end
    Process.wait(waiter.pid) if waiter && !waiter.alive? rescue nil
    [stdout, stderr].compact.each { |io| io.close unless io.closed? }
  end

  private

  def start_local_server(port)
    child_env = {
      "PORT" => port.to_s,
      "BIND_ADDRESS" => "127.0.0.1",
      "AUTH_MODE" => "local_disabled",
      "CLOUD_DEVELOPMENT" => "1",
      "PUBLIC_ORIGIN" => nil,
      "CLOUD_PUBLIC_DEPLOYMENT" => nil,
      "CLOUD_MODE" => nil,
      "TRUSTED_PROXY_CIDRS" => nil,
      "TRUSTED_PROXIES" => nil
    }
    Open3.popen3(child_env, RbConfig.ruby, File.join(ROOT, "scripts/local/start_radar.rb"), chdir: ROOT)
  end

  def wait_for_http(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    uri = URI("http://127.0.0.1:#{port}/login")
    loop do
      begin
        response = Net::HTTP.get_response(uri)
        return response
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
    end
  end
end
