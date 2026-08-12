# frozen_string_literal: true

require "json"
require_relative "conversation_retriever"
require_relative "conversation_provider"

# Two-stage conversation orchestration:
#   1. retrieve public/global evidence with a neutral query;
#   2. retrieve isolated personal memory and (optionally) ask a provider.
# No path in this class writes memory automatically.
class ConversationService
  class Error < StandardError; end
  DEFAULT_LIMIT = 20
  MAX_QUESTION_LENGTH = 2000

  SENSITIVE_PATTERNS = [
    /https?:\/\//i,
    /\bwww\./i,
    /\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i,
    /\b(?:\+?\d[\d\s().\-]{7,}\d)\b/,
    /\b(?:sk|pk|api[_-]?key|token|secret)[_-]?[A-Za-z0-9]{8,}\b/i,
    /\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b/i,
    /\bBearer\s+[A-Za-z0-9._\-]{12,}\b/i,
    /\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/
  ].freeze

  attr_reader :global_retriever, :personal_retriever, :provider

  def initialize(global_retriever: nil,
                 personal_retriever: nil,
                 provider: ConversationProvider.new,
                 analysis_context: nil,
                 global_limit: DEFAULT_LIMIT,
                 personal_limit: DEFAULT_LIMIT)
    @global_retriever = global_retriever || ConversationRetriever.new
    @personal_retriever = personal_retriever || PersonalConversationRetriever.new(global_retriever: @global_retriever)
    @provider = provider
    @analysis_context = analysis_context
    @global_limit = Integer(global_limit)
    @personal_limit = Integer(personal_limit)
  end

  def answer(question:, user_id: nil, subject_key: nil, limit: nil)
    raw_question = question.to_s
    neutral_query = normalize_neutral_query(raw_question)
    global_limit = limit ? bounded_limit(limit) : bounded_limit(@global_limit)
    personal_limit = limit ? bounded_limit(limit) : bounded_limit(@personal_limit)

    if sensitive_query?(raw_question)
      return base_result(answer_status: "privacy_blocked", neutral_query: nil,
                         global_evidence: [], personal_memory: [],
                         reason: "sensitive_query_not_sent_to_global")
    end

    # Intentionally pass only the neutral string and a numeric limit.  No
    # user_id, subject key, memory text, or conversation object reaches global.
    global_evidence = @global_retriever.search(neutral_query, limit: global_limit)
    personal_memory = retrieve_personal(neutral_query, user_id: user_id, subject_key: subject_key,
                                         limit: personal_limit)
    context = resolve_analysis_context
    unless provider_available?
      return base_result(answer_status: "not_generated", neutral_query: neutral_query,
                         global_evidence: global_evidence, personal_memory: personal_memory,
                         analysis_context: context)
    end

    begin
      generated = @provider.generate(question: raw_question, global_evidence: global_evidence,
                                     personal_memory: personal_memory, analysis_context: context)
      validated = ConversationProvider.validate_answer!(generated, global_evidence: global_evidence,
                                                        personal_memory: personal_memory)
      base_result(answer_status: "generated", neutral_query: neutral_query,
                  global_evidence: global_evidence, personal_memory: personal_memory,
                  analysis_context: context, answer: validated)
    rescue StandardError => error
      base_result(answer_status: "failed", neutral_query: neutral_query,
                  global_evidence: global_evidence, personal_memory: personal_memory,
                  analysis_context: context, error: error.message)
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, error.message
  end

  alias call answer

  def self.neutral_query(question)
    question.to_s.strip[0, MAX_QUESTION_LENGTH]
  end

  private

  def normalize_neutral_query(question)
    text = self.class.neutral_query(question)
    raise Error, "question is empty" if text.empty?
    text
  end

  def bounded_limit(value)
    integer = Integer(value)
    raise Error, "limit must be positive" unless integer.positive?
    [integer, 100].min
  rescue ArgumentError, TypeError
    raise Error, "limit must be a positive integer"
  end

  def sensitive_query?(question)
    SENSITIVE_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
  end

  def retrieve_personal(query, user_id:, subject_key:, limit:)
    key = subject_key || user_id
    if @personal_retriever.respond_to?(:search)
      begin
        @personal_retriever.search(query: query, subject_key: key, limit: limit)
      rescue ArgumentError => error
        # Keep simple test doubles useful without ever sending personal data to
        # the global retriever.  The fallback still receives only local args.
        if error.message =~ /unknown keyword|wrong number/
          @personal_retriever.search(query, limit: limit)
        else
          raise
        end
      end
    else
      []
    end
  end

  def provider_available?
    return @provider.available? if @provider.respond_to?(:available?)
    true
  end

  def resolve_analysis_context
    return Array(@analysis_context.call).first(10) if @analysis_context.respond_to?(:call)
    return Array(@analysis_context).first(10) if @analysis_context
    return @global_retriever.analysis_context(limit: 5) if @global_retriever.respond_to?(:analysis_context)
    []
  rescue StandardError
    []
  end

  def base_result(answer_status:, neutral_query:, global_evidence:, personal_memory:, analysis_context: [], answer: nil, reason: nil, error: nil)
    result = {
      "answer_status" => answer_status,
      "global_evidence" => Array(global_evidence),
      "personal_memory" => Array(personal_memory),
      "analysis_context" => Array(analysis_context)
    }
    result["neutral_query"] = neutral_query if neutral_query
    result["answer"] = answer if answer
    result["reason"] = reason if reason
    result["error"] = error if error
    result
  end
end

ConversationOrchestrator = ConversationService unless defined?(ConversationOrchestrator)
