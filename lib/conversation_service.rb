# frozen_string_literal: true

require "json"
require "digest"
require "time"
require_relative "conversation_retriever"
require_relative "conversation_provider"
require_relative "query_neutralizer"
require_relative "conversation_ledger_store"

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

  attr_reader :global_retriever, :personal_retriever, :provider, :ledger_store, :owner_principal

  def initialize(global_retriever: nil,
                 personal_retriever: nil,
                 provider: ConversationProvider.new,
                 analysis_context: nil,
                 global_limit: DEFAULT_LIMIT,
                 personal_limit: DEFAULT_LIMIT,
                 ledger_store: :auto,
                 owner_principal: ConversationLedgerStore::DEFAULT_OWNER_PRINCIPAL,
                 thread_id: ConversationLedgerStore::DEFAULT_THREAD_ID)
    production_defaults = global_retriever.nil? && personal_retriever.nil?
    @global_retriever = global_retriever || ConversationRetriever.new
    @personal_retriever = personal_retriever || PersonalConversationRetriever.new(global_retriever: @global_retriever)
    @provider = provider
    @analysis_context = analysis_context
    @global_limit = Integer(global_limit)
    @personal_limit = Integer(personal_limit)
    @owner_principal = owner_principal.to_s.strip
    raise Error, "owner_principal is required" if @owner_principal.empty?
    @thread_id = thread_id.to_s.strip
    raise Error, "thread_id is required" if @thread_id.empty?
    @ledger_store = if ledger_store == :auto
                      production_defaults ? ConversationLedgerStore.new(owner_principal: @owner_principal) : nil
                    else
                      ledger_store
                    end
  end

  def answer(question:, user_id: nil, subject_key: nil, limit: nil)
    raw_question = question.to_s
    as_of = Time.now.utc.iso8601(6)
    global_limit = limit ? bounded_limit(limit) : bounded_limit(@global_limit)
    personal_limit = limit ? bounded_limit(limit) : bounded_limit(@personal_limit)

    begin
      neutral_query = normalize_neutral_query(raw_question)
    rescue Error => error
      return finalize_result(raw_question: raw_question, as_of: as_of, answer_status: "privacy_blocked",
                             neutral_query: nil, global_evidence: [], personal_memory: [],
                             analysis_context: [], reason: error.message,
                             query_plan: { "stage" => "neutralization", "status" => "blocked", "reason_code" => error.message })
    end

    global_evidence = []
    personal_memory = []
    context = []
    # Intentionally pass only the neutral string and a numeric limit.  No
    # user_id, subject key, memory text, or conversation object reaches global.
    begin
      global_evidence = @global_retriever.search(neutral_query, limit: global_limit)
      personal_memory = retrieve_personal(neutral_query, user_id: user_id, subject_key: subject_key,
                                           limit: personal_limit)
      context = resolve_analysis_context
      unless provider_available?
        return finalize_result(raw_question: raw_question, as_of: as_of, answer_status: "not_generated",
                               neutral_query: neutral_query, global_evidence: global_evidence,
                               personal_memory: personal_memory, analysis_context: context,
                               query_plan: { "stage" => "two_stage_retrieval", "global_limit" => global_limit,
                                             "personal_limit" => personal_limit })
      end
      generated = @provider.generate(question: raw_question, global_evidence: global_evidence,
                                     personal_memory: personal_memory, analysis_context: context)
      validated = ConversationProvider.validate_answer!(generated, global_evidence: global_evidence,
                                                        personal_memory: personal_memory)
      finalize_result(raw_question: raw_question, as_of: as_of, answer_status: "generated",
                      neutral_query: neutral_query, global_evidence: global_evidence,
                      personal_memory: personal_memory, analysis_context: context,
                      answer: validated,
                      query_plan: { "stage" => "two_stage_retrieval", "global_limit" => global_limit,
                                    "personal_limit" => personal_limit })
    rescue StandardError => error
      finalize_result(raw_question: raw_question, as_of: as_of, answer_status: "failed",
                      neutral_query: neutral_query, global_evidence: global_evidence,
                      personal_memory: personal_memory, analysis_context: context,
                      error: error,
                      query_plan: { "stage" => "two_stage_retrieval", "global_limit" => global_limit,
                                    "personal_limit" => personal_limit })
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, error.message
  end

  alias call answer

  # Read-only replay from the immutable personal ledger.  No global retrieval
  # or provider call is performed, so arrival of newer archive versions cannot
  # change the historical result.
  def replay(turn_id:)
    raise Error, "conversation ledger is not configured" unless @ledger_store

    @ledger_store.replay(turn_id: turn_id, owner_principal: @owner_principal)
  rescue ConversationLedgerStore::Error => error
    raise Error, error.message
  end

  def self.neutral_query(question)
    QueryNeutralizer.neutralize(question, max_length: MAX_QUESTION_LENGTH)
  end

  private

  def normalize_neutral_query(question)
    self.class.neutral_query(question)
  rescue QueryNeutralizer::Error => error
    # The caller must not send raw user wording when no safe public query can
    # be derived.  Keep the error generic so a private canary never enters a
    # global log or response payload.
    raise Error, "global retrieval blocked: #{error.code}"
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
    # The local service has one server-owned principal.  Request-body identity
    # hints are intentionally ignored; callers cannot select another memory
    # subject by supplying user_id/subject_key.
    key = @owner_principal
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
    result["error"] = error.respond_to?(:message) ? error.message : error if error
    result
  end

  def finalize_result(raw_question:, as_of:, answer_status:, neutral_query:, global_evidence:, personal_memory:,
                      analysis_context:, query_plan:, answer: nil, reason: nil, error: nil)
    result = base_result(answer_status: answer_status, neutral_query: neutral_query,
                         global_evidence: global_evidence, personal_memory: personal_memory,
                         analysis_context: analysis_context, answer: answer, reason: reason, error: error)
    return result unless @ledger_store

    provider_receipt = if answer_status == "generated"
                         {
                           "status" => "succeeded", "provider_name" => provider_name,
                           "model" => provider_model, "request_hash" => digest({ "question" => raw_question, "query_plan" => query_plan }),
                           "response_hash" => digest(answer), "response_json" => answer
                         }
                       elsif answer_status == "failed"
                         provider_failure_receipt = error_receipt(error)
                         {
                           "status" => "failed", "provider_name" => provider_name,
                           "model" => provider_model, "request_hash" => digest({ "question" => raw_question, "query_plan" => query_plan }),
                           "error_code" => provider_failure_receipt.fetch("error_code", "conversation_provider_failed"),
                           "error_hash" => digest(error.to_s), "provider_receipt_json" => provider_failure_receipt
                         }
                       else
                         {
                           "status" => "not_attempted", "provider_name" => provider_name,
                           "model" => provider_model, "request_hash" => digest({ "question" => raw_question, "query_plan" => query_plan })
                         }
                       end
    ledger = @ledger_store.record_turn!(thread_id: @thread_id, as_of: as_of,
                                        private_query_context_hash: digest(raw_question),
                                        answer_status: answer_status, neutral_query: neutral_query,
                                        neutralizer_version: QueryNeutralizer::VERSION,
                                        query_plan: query_plan, global_evidence: global_evidence,
                                        personal_memory: personal_memory, provider_receipt: provider_receipt)
    result.merge("thread_id" => ledger.fetch("thread").fetch("thread_id"),
                 "turn_id" => ledger.fetch("turn").fetch("turn_id"),
                 "evidence_snapshot_id" => ledger.fetch("evidence_snapshot").fetch("evidence_snapshot_id"),
                 "provider_receipt_ids" => ledger.fetch("provider_receipts").map { |receipt| receipt.fetch("provider_receipt_id") })
  rescue StandardError => ledger_error
    raise Error, "conversation ledger append failed: #{ledger_error.message}"
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(value))
  end

  def provider_name
    return @provider.provider_name.to_s if @provider.respond_to?(:provider_name)
    "provider"
  end

  def provider_model
    return @provider.model.to_s if @provider.respond_to?(:model)
    "unknown"
  end

  def error_receipt(error)
    value = error.respond_to?(:receipt) ? error.receipt : nil
    if (value.nil? || value.empty?) && error.respond_to?(:cause) && error.cause && error.cause.respond_to?(:receipt)
      value = error.cause.receipt
    end
    value = value.transform_keys(&:to_s) if value.is_a?(Hash)
    return value unless value.nil? || value.empty?

    {
      "status" => "failed", "provider" => provider_name, "model" => provider_model,
      "error_code" => (error.respond_to?(:code) && !error.code.to_s.empty? ? error.code.to_s : "conversation_provider_failed"),
      "error_message" => error.to_s
    }
  end
end

ConversationOrchestrator = ConversationService unless defined?(ConversationOrchestrator)
