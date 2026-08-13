# frozen_string_literal: true

require "json"
require_relative "deepseek_client"

# Thin OpenAI-compatible chat provider.  The provider is optional: callers can
# inject a fake object in tests, while production remains deterministic when
# credentials are absent.
class ConversationProvider
  class Error < StandardError; end

  KINDS = %w[fact source_claim inference user_memory insufficient_evidence].freeze
  TOP_LEVEL_KEYS = %w[answer_sections follow_up_questions].freeze
  SECTION_KEYS = {
    "fact" => %w[cited_version_ids kind text],
    "source_claim" => %w[cited_version_ids kind text],
    "inference" => %w[cited_version_ids kind text],
    "insufficient_evidence" => %w[cited_version_ids kind text],
    "user_memory" => %w[cited_version_ids kind memory_entry_ids text]
  }.freeze

  attr_reader :client

  def initialize(client: nil, api_key: nil,
                 base_url: ENV.fetch("DEEPSEEK_BASE_URL", DeepSeekClient::DEFAULT_BASE_URL),
                 model: ENV.fetch("DEEPSEEK_MODEL", DeepSeekClient::DEFAULT_MODEL),
                 open_timeout: 10, read_timeout: 120)
    @client = client || DeepSeekClient.new(api_key: api_key, base_url: base_url, model: model,
                                           open_timeout: open_timeout, read_timeout: read_timeout)
  end

  def available?
    client.available?
  end

  def model; client.model; end
  def base_url; client.base_url; end

  def generate(question:, global_evidence:, personal_memory:, analysis_context: [])
    raise Error, "conversation provider credentials are missing" unless available?
    prompt = build_prompt(question: question, global_evidence: global_evidence,
                          personal_memory: personal_memory, analysis_context: analysis_context)
    parsed = client.chat_json(system: system_prompt, user: prompt, thinking: true,
                              reasoning_effort: "high",
                              max_tokens: Integer(ENV.fetch("DEEPSEEK_CONVERSATION_MAX_OUTPUT_TOKENS", "8192"))).fetch("content")
    self.class.validate_answer!(parsed, global_evidence: global_evidence, personal_memory: personal_memory)
  rescue DeepSeekClient::Error => error
    raise Error, error.message
  end

  def self.validate_answer!(answer, global_evidence:, personal_memory:)
    object = answer.is_a?(Hash) ? answer.transform_keys(&:to_s) : nil
    raise Error, "provider answer must be an object" unless object
    reject_unknown!(object.keys, TOP_LEVEL_KEYS, "answer")
    sections = object["answer_sections"]
    follow_up = object["follow_up_questions"]
    raise Error, "answer_sections must be an array" unless sections.is_a?(Array)
    raise Error, "follow_up_questions must be an array" unless follow_up.is_a?(Array)
    follow_up.each { |q| raise Error, "follow-up question must be non-empty text" unless q.is_a?(String) && !q.strip.empty? }

    global_ids = Array(global_evidence).map { |row| row.fetch("version_id").to_s }
    personal_ids = Array(personal_memory).map { |row| row.fetch("memory_entry_id").to_s }
    normalized_sections = sections.map do |section|
      section = section.is_a?(Hash) ? section.transform_keys(&:to_s) : nil
      raise Error, "answer section must be an object" unless section
      kind = section["kind"].to_s
      raise Error, "unknown answer section kind" unless KINDS.include?(kind)
      reject_unknown!(section.keys, SECTION_KEYS.fetch(kind), "#{kind} section")
      text = section["text"]
      raise Error, "answer section text must be non-empty" unless text.is_a?(String) && !text.strip.empty?
      citations = section["cited_version_ids"]
      raise Error, "cited_version_ids must be an array" unless citations.is_a?(Array)
      citations = citations.map(&:to_s)
      raise Error, "unknown or empty global citation" if citations.any? { |id| id.empty? || !global_ids.include?(id) }
      raise Error, "duplicate global citation" unless citations.uniq.length == citations.length
      if %w[fact source_claim inference].include?(kind) && citations.empty?
        raise Error, "#{kind} sections require a global citation"
      end
      if kind == "user_memory"
        memory_ids = section["memory_entry_ids"]
        raise Error, "user_memory requires memory_entry_ids" unless memory_ids.is_a?(Array)
        memory_ids = memory_ids.map(&:to_s)
        raise Error, "user_memory requires at least one memory citation" if memory_ids.empty?
        raise Error, "unknown or empty memory citation" if memory_ids.any? { |id| id.empty? || !personal_ids.include?(id) }
        raise Error, "duplicate memory citation" unless memory_ids.uniq.length == memory_ids.length
        section = section.merge("memory_entry_ids" => memory_ids)
      end
      section.merge("kind" => kind, "text" => text, "cited_version_ids" => citations)
    end
    { "answer_sections" => normalized_sections, "follow_up_questions" => follow_up.map(&:to_s) }
  end

  private

  def self.reject_unknown!(keys, allowed, name)
    unknown = keys.map(&:to_s) - allowed
    raise Error, "unknown keys in #{name}: #{unknown.join(', ')}" unless unknown.empty?
    missing = allowed - keys.map(&:to_s)
    raise Error, "missing keys in #{name}: #{missing.join(', ')}" unless missing.empty?
  end

  def system_prompt
    <<~PROMPT
      只使用提供的证据，用简体中文回答。返回且只返回包含 answer_sections 与 follow_up_questions 的 JSON 对象。
      每个 section 包含 kind、text、cited_version_ids；kind 只能是 fact、source_claim、inference、user_memory、insufficient_evidence。
      fact/source_claim/inference 必须引用一个或多个已提供的全球 version_id。user_memory 还必须包含 memory_entry_ids，且只能引用已提供的个人记忆。
      不得创造 ID。明确分开事实、来源主张、推断和个人记忆；证据不足时使用 insufficient_evidence。不要输出 Markdown 或额外字段。
    PROMPT
  end

  def build_prompt(question:, global_evidence:, personal_memory:, analysis_context:)
    JSON.generate(
      "current_question" => question.to_s,
      "global_evidence" => global_evidence,
      "personal_memory" => personal_memory,
      "analysis_context" => analysis_context
    )
  end

end
