# frozen_string_literal: true

require "json"
require_relative "deepseek_client"

module ReportSummaryProvider
  class Error < StandardError
    attr_reader :code, :receipt
    def initialize(message, code: "report_summary_error", receipt: nil); @code = code; @receipt = receipt; super(message); end
  end

  class DeepSeek
    PROMPT_VERSION = "local-report-summary-deepseek-v4-pro-v4"
    attr_reader :client, :prompt_version, :last_receipt

    def initialize(client: nil, api_key: nil, endpoint: ENV.fetch("DEEPSEEK_BASE_URL", DeepSeekClient::DEFAULT_BASE_URL),
                   model: ENV.fetch("DEEPSEEK_MODEL", DeepSeekClient::DEFAULT_MODEL), prompt_version: PROMPT_VERSION)
      @client = client || DeepSeekClient.new(api_key: api_key, base_url: endpoint, model: model)
      @prompt_version = prompt_version.to_s
    end

    def available?; client.available?; end
    def provider_name; client.provider_name; end
    def model; client.model; end

    def summarize(input:)
      response = client.chat_json(
        thinking: true, reasoning_effort: "high",
        max_tokens: Integer(ENV.fetch("DEEPSEEK_SUMMARY_MAX_OUTPUT_TOKENS", "32768")),
        system: <<~PROMPT.strip,
          你是严格的本地日报证据摘要器。只根据用户消息中的本 edition 已归档证据输出简体中文 JSON，不得新增事实，不得调用外部来源，不得使用个人记忆。
          顶层只能有 overview、key_changes、uncertainties。overview 是对象，后两项是数组；每个单元必须是原子 claim，字段只能是 claim_id、kind、text、epistemic_status、evidence_scopes、以及 ai_inference 必须的 premise_scope_ids、inference_support_status。
          kind 只能是 fact、source_claim、ai_inference、uncertainty。每个 evidence_scope 必须含 scope_id、version_id、field(title 或 summary)、text（从对应原文字段逐字摘录）和 relation(supports、contradicts、alternative、unknown)。每个 claim 至少一个 supports scope；unknown 或无法定位的 scope 不得输出。source_claim 必须保留“某来源称/指控/分析”等归属，不能冒充 fact。ai_inference 必须只使用 premise_scope_ids 中的 supports scope，并将 inference_support_status 明确为 supported；不要把推断写成事实。
          每个非空陈述必须引用一个或多个本 edition 提供的短 version_id（例如 E001），不要改写、截断或自行生成 ID。区分已报道事实、来源主张、推断和不确定性。
          输出务必简洁：key_changes 最多 8 项，uncertainties 最多 5 项，每项 text 最多 180 个中文字符。不要输出 Markdown、代码围栏或多个 JSON 对象。
        PROMPT
        user: JSON.generate(input)
      )
      @last_receipt = response["receipt"] if response.is_a?(Hash)
      if @last_receipt.is_a?(Hash)
        @last_receipt = @last_receipt.merge("prompt_version" => prompt_version)
      end
      response.fetch("content")
    rescue DeepSeekClient::Error => error
      @last_receipt = error.receipt && error.receipt.merge("prompt_version" => prompt_version)
      raise Error.new(error.message, code: error.code, receipt: @last_receipt)
    end
  end

  OpenAICompatible = DeepSeek
end
