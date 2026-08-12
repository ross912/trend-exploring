# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module TranslationProvider
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "translation_error")
      @code = code
      super(message)
    end
  end

  class MissingCredentials < Error
    def initialize
      super("translation API credentials are not configured", code: "missing_credentials")
    end
  end

  class OpenAICompatible
    DEFAULT_ENDPOINT = "https://api.openai.com/v1/chat/completions"
    DEFAULT_MODEL = "gpt-4o-mini"
    PROVIDER_NAME = "openai-compatible"

    attr_reader :model, :endpoint

    def initialize(api_key: ENV["TRANSLATION_API_KEY"].to_s.empty? ? ENV["OPENAI_API_KEY"] : ENV["TRANSLATION_API_KEY"],
                   endpoint: ENV.fetch("TRANSLATION_API_URL", DEFAULT_ENDPOINT),
                   model: ENV.fetch("TRANSLATION_MODEL", DEFAULT_MODEL),
                   open_timeout: 8, read_timeout: 30)
      @api_key = api_key.to_s
      @endpoint = endpoint
      @model = model
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def available?
      !@api_key.empty?
    end

    def provider_name
      PROVIDER_NAME
    end

    def translate(title:, summary:, source_language:, target_language: "zh-CN")
      raise MissingCredentials unless available?

      uri = URI.parse(@endpoint)
      body = {
        "model" => @model,
        "temperature" => 0,
        "response_format" => { "type" => "json_object" },
        "messages" => [
          {
            "role" => "system",
            "content" => "你是严格的新闻元数据翻译器。把输入翻译为简体中文，只返回 JSON：{\"title_zh\":\"...\",\"summary_zh\":\"...\"}。保留否定、可能性、数字、单位、时间、地点、专名、来源归属，不新增事实，不把推测写成事实。"
          },
          {
            "role" => "user",
            "content" => JSON.generate({
              "source_language" => source_language,
              "target_language" => target_language,
              "title" => title.to_s[0, 500],
              "summary" => summary.to_s[0, 2_000]
            })
          }
        ]
      }
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(body)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("translation provider returned HTTP #{response.code}", code: "provider_http_#{response.code}")
      end

      payload = JSON.parse(response.body.to_s)
      content = payload.dig("choices", 0, "message", "content").to_s
      content = content.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      result = JSON.parse(content)
      translated_title = result.fetch("title_zh").to_s.strip
      translated_summary = result.fetch("summary_zh").to_s.strip
      raise Error.new("translation provider returned empty text", code: "empty_translation") if translated_title.empty? || translated_summary.empty?

      { "translated_title" => translated_title, "translated_summary" => translated_summary,
        "provider" => provider_name, "model" => @model }
    rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      raise Error.new("translation provider request failed: #{error.message}", code: "provider_network_error")
    rescue JSON::ParserError, KeyError => error
      raise Error.new("translation provider response is invalid: #{error.message}", code: "invalid_translation_response")
    end
  end
end
