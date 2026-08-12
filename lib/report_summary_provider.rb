# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module ReportSummaryProvider
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "report_summary_error")
      @code = code
      super(message)
    end
  end

  class MissingCredentials < Error
    def initialize
      super("report summary API credentials are not configured", code: "missing_credentials")
    end
  end

  # OpenAI-compatible chat-completions provider.  The provider only receives
  # the short, edition-bound metadata assembled by ReportSummaryRunner; it
  # never receives URLs, full text, or personal-memory context.
  class OpenAICompatible
    DEFAULT_ENDPOINT = "https://api.openai.com/v1/chat/completions"
    DEFAULT_MODEL = "gpt-4o-mini"
    PROVIDER_NAME = "openai-compatible"
    PROMPT_VERSION = "local-report-summary-v1"

    attr_reader :model, :endpoint, :prompt_version

    def initialize(api_key: ENV["REPORT_SUMMARY_API_KEY"].to_s.empty? ? ENV["OPENAI_API_KEY"] : ENV["REPORT_SUMMARY_API_KEY"],
                   endpoint: ENV.fetch("REPORT_SUMMARY_API_URL", DEFAULT_ENDPOINT),
                   model: ENV.fetch("REPORT_SUMMARY_MODEL", DEFAULT_MODEL),
                   open_timeout: 8, read_timeout: 45,
                   prompt_version: PROMPT_VERSION)
      @api_key = api_key.to_s
      @endpoint = endpoint.to_s
      @model = model.to_s
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @prompt_version = prompt_version.to_s
    end

    def available?
      !@api_key.empty?
    end

    def provider_name
      PROVIDER_NAME
    end

    def summarize(input:)
      raise MissingCredentials unless available?

      uri = URI.parse(@endpoint)
      body = {
        "model" => @model,
        "temperature" => 0,
        "response_format" => { "type" => "json_object" },
        "messages" => [
          {
            "role" => "system",
            "content" => <<~PROMPT.strip
              你是严格的本地日报元数据摘要器。只根据用户消息中的本 edition 短摘要元数据输出 JSON，不得新增事实，不得调用外部来源，不得使用个人记忆。
              请明确区分“发生了什么”“为什么值得看”和“不确定性”。输出顶层且只能有 overview、key_changes、uncertainties 三个键。
              overview 是一个对象，key_changes 和 uncertainties 是数组；每个单元且只能有 text 与 cited_version_ids 两个键。
              text 必须是非空短文本；cited_version_ids 必须是本 edition 中给出的一个或多个 version_id，且每个单元都必须引用至少一个 version_id。
              不要输出 URL、source、title 或其他权威字段；来源详情由系统依据 version_id 回查归档。
            PROMPT
          },
          {
            "role" => "user",
            "content" => JSON.generate(input)
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
        raise Error.new("report summary provider returned HTTP #{response.code}", code: "provider_http_#{response.code}")
      end

      payload = JSON.parse(response.body.to_s)
      content = payload.dig("choices", 0, "message", "content").to_s
      content = content.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      JSON.parse(content)
    rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      raise Error.new("report summary provider request failed: #{error.message}", code: "provider_network_error")
    rescue JSON::ParserError, NoMethodError => error
      raise Error.new("report summary provider response is invalid: #{error.message}", code: "invalid_summary_response")
    end
  end
end
