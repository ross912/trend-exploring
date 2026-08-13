# frozen_string_literal: true

require "json"
require_relative "deepseek_client"

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

  class DeepSeek
    attr_reader :client

    def initialize(client: nil, api_key: nil, endpoint: ENV.fetch("DEEPSEEK_BASE_URL", DeepSeekClient::DEFAULT_BASE_URL),
                   model: ENV.fetch("DEEPSEEK_MODEL", DeepSeekClient::DEFAULT_MODEL), open_timeout: 10, read_timeout: 120)
      @client = client || DeepSeekClient.new(api_key: api_key, base_url: endpoint, model: model,
                                             open_timeout: open_timeout, read_timeout: read_timeout)
    end

    def available?; client.available?; end
    def provider_name; client.provider_name; end
    def model; client.model; end
    def endpoint; client.base_url; end

    def translate(title:, summary:, body: "", image_captions: [], source_language:, target_language: "zh-CN")
      raise MissingCredentials unless available?

      response = client.chat_json(
        thinking: false,
        max_tokens: Integer(ENV.fetch("DEEPSEEK_TRANSLATION_MAX_OUTPUT_TOKENS", "32768")),
        system: <<~PROMPT.strip,
          你是严格的新闻档案翻译器。把输入完整翻译为简体中文，只返回 JSON 对象，且只能包含 title_zh、summary_zh、body_zh、image_captions_zh。
          不删减正文，不总结，不新增事实。保留否定、可能性、数字、单位、时间、地点、专名、引文归属、段落顺序和换行。
          人名、机构名首次出现可保留原文括注；代码、URL、公式不翻译。image_captions_zh 必须与输入数组等长。
        PROMPT
        user: JSON.generate({
          "source_language" => source_language,
          "target_language" => target_language,
          "title" => title.to_s,
          "summary" => summary.to_s,
          "body" => body.to_s,
          "image_captions" => Array(image_captions).map(&:to_s)
        })
      )
      result = response.fetch("content")
      expected = %w[body_zh image_captions_zh summary_zh title_zh]
      raise Error.new("translation provider returned unknown or missing keys", code: "invalid_translation_response") unless result.keys.map(&:to_s).sort == expected
      title_zh = result.fetch("title_zh").to_s.strip
      summary_zh = result.fetch("summary_zh").to_s.strip
      body_zh = result.fetch("body_zh").to_s
      captions_zh = result.fetch("image_captions_zh")
      raise Error.new("translated title/summary is empty", code: "empty_translation") if title_zh.empty? || summary_zh.empty?
      raise Error.new("translated body is empty", code: "empty_translation") if !body.to_s.empty? && body_zh.strip.empty?
      unless captions_zh.is_a?(Array) && captions_zh.length == Array(image_captions).length && captions_zh.all? { |value| value.is_a?(String) }
        raise Error.new("translated image captions do not match input", code: "invalid_translation_response")
      end
      {
        "translated_title" => title_zh, "translated_summary" => summary_zh,
        "translated_body" => body_zh, "translated_image_captions" => captions_zh,
        "provider" => provider_name, "model" => response.fetch("model"), "usage" => response.fetch("usage")
      }
    rescue DeepSeekClient::Error => error
      raise MissingCredentials if error.code == "missing_credentials"
      raise Error.new(error.message, code: error.code)
    rescue KeyError, TypeError => error
      raise Error.new("translation provider response is invalid: #{error.message}", code: "invalid_translation_response")
    end
  end

  # Compatibility constant for callers from the initial local slice.
  OpenAICompatible = DeepSeek
end
