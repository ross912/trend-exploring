# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

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

  attr_reader :api_key, :base_url, :model

  def initialize(api_key: ENV["CONVERSATION_API_KEY"] || ENV["OPENAI_API_KEY"],
                 base_url: ENV.fetch("CONVERSATION_API_BASE_URL", "https://api.openai.com/v1"),
                 model: ENV.fetch("CONVERSATION_MODEL", "gpt-4o-mini"),
                 open_timeout: 10, read_timeout: 60)
    @api_key = api_key.to_s.strip
    @base_url = base_url.to_s.sub(%r{/\z}, "")
    @model = model.to_s
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def available?
    !@api_key.empty?
  end

  def generate(question:, global_evidence:, personal_memory:, analysis_context: [])
    raise Error, "conversation provider credentials are missing" unless available?
    prompt = build_prompt(question: question, global_evidence: global_evidence,
                          personal_memory: personal_memory, analysis_context: analysis_context)
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      "model" => @model,
      "temperature" => 0,
      "response_format" => { "type" => "json_object" },
      "messages" => [
        { "role" => "system", "content" => system_prompt },
        { "role" => "user", "content" => prompt }
      ]
    )
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "conversation provider HTTP #{response.code}: #{response.body.to_s[0, 500]}"
    end
    payload = JSON.parse(response.body)
    content = payload.dig("choices", 0, "message", "content")
    raise Error, "conversation provider response has no JSON content" unless content
    parsed = content.is_a?(String) ? JSON.parse(content) : content
    self.class.validate_answer!(parsed, global_evidence: global_evidence, personal_memory: personal_memory)
  rescue JSON::ParserError => error
    raise Error, "conversation provider returned invalid JSON: #{error.message}"
  rescue SocketError, Timeout::Error, SystemCallError => error
    raise Error, "conversation provider request failed: #{error.message}"
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
      You answer using only the supplied evidence. Return one JSON object with exactly
      answer_sections and follow_up_questions. Each section has kind, text,
      cited_version_ids. Kinds are fact, source_claim, inference, user_memory,
      insufficient_evidence. Fact/source_claim/inference must cite one or more supplied
      global version IDs. user_memory must additionally include memory_entry_ids and may
      cite only supplied personal memory IDs. Never invent IDs. Separate facts, source
      claims, inferences, and user memory explicitly. If evidence is insufficient use
      insufficient_evidence. Do not include markdown or extra keys.
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

  def uri
    @uri ||= URI.parse("#{@base_url}/chat/completions")
  end
end
