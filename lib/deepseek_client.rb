# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "local_runtime"

# One narrowly-scoped DeepSeek client shared by translation, report summary
# and conversation. Secrets are resolved at call time and never serialized.
class DeepSeekClient
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "deepseek_error")
      @code = code
      super(message)
    end
  end

  DEFAULT_BASE_URL = "https://api.deepseek.com"
  DEFAULT_MODEL = "deepseek-v4-pro"

  attr_reader :base_url, :model

  def initialize(api_key: nil, base_url: ENV.fetch("DEEPSEEK_BASE_URL", DEFAULT_BASE_URL),
                 model: ENV.fetch("DEEPSEEK_MODEL", DEFAULT_MODEL), open_timeout: 10,
                 read_timeout: 120, secret_file: ENV["DEEPSEEK_API_KEY_FILE"], transport: nil)
    @explicit_api_key = api_key
    @secret_file = secret_file.to_s.empty? ? LocalRuntime.deepseek_secret_file : secret_file.to_s
    @base_url = base_url.to_s.sub(%r{/+\z}, "")
    @model = model.to_s
    @open_timeout = open_timeout
    @read_timeout = read_timeout
    @transport = transport
    validate_configuration!
  end

  def available?
    !api_key.empty?
  rescue Error
    false
  end

  def provider_name
    "deepseek"
  end

  def chat_json(system:, user:, thinking:, reasoning_effort: nil, max_tokens: nil)
    key = api_key
    raise Error.new("DeepSeek API credentials are not configured", code: "missing_credentials") if key.empty?

    body = {
      "model" => model,
      "temperature" => 0,
      "stream" => false,
      "response_format" => { "type" => "json_object" },
      "thinking" => { "type" => thinking ? "enabled" : "disabled" },
      "messages" => [
        { "role" => "system", "content" => system.to_s },
        { "role" => "user", "content" => user.to_s }
      ]
    }
    body["reasoning_effort"] = reasoning_effort.to_s if thinking && !reasoning_effort.to_s.empty?
    body["max_tokens"] = Integer(max_tokens) if max_tokens

    uri = URI.parse("#{base_url}/chat/completions")
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Authorization"] = "Bearer #{key}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(body)
    response = if @transport
                 @transport.call(uri, request)
               else
                 Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout, read_timeout: @read_timeout) { |http| http.request(request) }
               end
    unless response.is_a?(Net::HTTPSuccess)
      request_id = response["x-request-id"].to_s
      suffix = request_id.empty? ? "" : " (request_id=#{request_id})"
      raise Error.new("DeepSeek returned HTTP #{response.code}#{suffix}", code: "provider_http_#{response.code}")
    end
    payload = JSON.parse(response.body.to_s)
    content = payload.dig("choices", 0, "message", "content").to_s
    content = content.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
    result = JSON.parse(content)
    raise Error.new("DeepSeek JSON response must be an object", code: "invalid_provider_response") unless result.is_a?(Hash)

    { "content" => result, "usage" => normalize_usage(payload["usage"]), "model" => payload["model"].to_s.empty? ? model : payload["model"].to_s }
  rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SystemCallError => error
    raise Error.new("DeepSeek request failed: #{error.message}", code: "provider_network_error")
  rescue JSON::ParserError, NoMethodError => error
    raise Error.new("DeepSeek response is invalid: #{error.message}", code: "invalid_provider_response")
  end

  private

  def validate_configuration!
    uri = URI.parse(base_url)
    raise Error.new("DeepSeek base URL must use HTTPS", code: "invalid_configuration") unless uri.scheme == "https" && !uri.host.to_s.empty?
    raise Error.new("DeepSeek model must be deepseek-v4-pro", code: "invalid_configuration") unless model == DEFAULT_MODEL
  rescue URI::InvalidURIError => error
    raise Error.new("DeepSeek base URL is invalid: #{error.message}", code: "invalid_configuration")
  end

  def api_key
    return @explicit_api_key.to_s.strip unless @explicit_api_key.nil?

    explicit = ENV["DEEPSEEK_API_KEY"].to_s
    return explicit.strip unless explicit.strip.empty?
    return "" unless File.file?(@secret_file)

    mode = File.stat(@secret_file).mode & 0o777
    raise Error.new("DeepSeek secret file permissions must be 600", code: "insecure_secret_file") unless mode == 0o600
    File.read(@secret_file, encoding: "UTF-8").strip
  rescue Errno::EACCES, Errno::ENOENT => error
    raise Error.new("DeepSeek secret file cannot be read: #{error.message}", code: "secret_file_error")
  end

  def normalize_usage(value)
    object = value.is_a?(Hash) ? value : {}
    {
      "prompt_tokens" => object.fetch("prompt_tokens", 0).to_i,
      "completion_tokens" => object.fetch("completion_tokens", 0).to_i,
      "total_tokens" => object.fetch("total_tokens", 0).to_i
    }
  end
end
