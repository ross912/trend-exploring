# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/conversation_service"

class ConversationRetrieverContextTest < Minitest::Test
  def test_search_prefers_specific_overlap_and_deduplicates_archive_versions
    retriever = Class.new(ConversationRetriever) do
      private

      def query_json(_sql)
        [
          { "item_key" => "solar", "version_id" => "solar-old", "capture_id" => "c1", "content_hash" => "h1",
            "title" => "欧洲太阳日食观测", "summary" => "旧版本", "source_url" => "https://example.test/solar",
            "publisher" => "Example", "language" => "zh", "created_at" => "2026-08-12 00:00:00+08" },
          { "item_key" => "solar", "version_id" => "solar-new", "capture_id" => "c2", "content_hash" => "h2",
            "title" => "欧洲太阳日食观测", "summary" => "新版本", "source_url" => "https://example.test/solar",
            "publisher" => "Example", "language" => "zh", "created_at" => "2026-08-13 00:00:00+08" },
          { "item_key" => "generic", "version_id" => "generic", "capture_id" => "c3", "content_hash" => "h3",
            "title" => "归档信息更新", "summary" => "其他内容", "source_url" => "https://example.test/generic",
            "publisher" => "Example", "language" => "zh", "created_at" => "2026-08-13 01:00:00+08" }
        ]
      end
    end.new

    rows = retriever.search("最近关于太阳日食有哪些已归档信息？")
    assert_equal ["solar-new"], rows.map { |row| row.fetch("version_id") }
  end

  def test_analysis_context_parses_overview_json_into_units
    retriever = Class.new(ConversationRetriever) do
      private

      def query_scalar(_sql)
        "t"
      end

      def bounded_limit(_limit)
        5
      end

      def query_json(_sql)
        [{
          "artifact_id" => "artifact-1", "run_id" => "run-1", "edition_id" => "edition-1",
          "overview" => JSON.generate("text" => "overview", "cited_version_ids" => ["v1"]),
          "key_changes" => JSON.generate([{ "text" => "change", "cited_version_ids" => ["v1"] }]),
          "uncertainties" => "[]", "created_at" => "2026-08-13 00:00:00+08"
        }]
      end
    end.new
    context = retriever.analysis_context
    assert_equal "overview", context.fetch(0).fetch("units").fetch(0).fetch("text")
    assert_equal ["v1"], context.fetch(0).fetch("units").fetch(0).fetch("cited_version_ids")
  end
end

class ConversationServiceTest < Minitest::Test
  class SpyGlobal
    attr_reader :calls

    def initialize(rows = [])
      @rows = rows
      @calls = []
    end

    def search(query, limit:)
      @calls << [query, limit]
      @rows
    end

    def resolve_version_ids(ids)
      ids
    end

    def analysis_context(limit:)
      []
    end
  end

  class FakePersonal
    attr_reader :calls

    def initialize(rows = [])
      @rows = rows
      @calls = []
    end

    def search(query:, subject_key:, limit:)
      @calls << [query, subject_key, limit]
      @rows
    end
  end

  class NoCredentialProvider
    def available?
      false
    end
  end

  class FakeProvider
    def initialize(answer: nil, error: nil)
      @answer = answer
      @error = error
    end

    def available?
      true
    end

    def generate(**_payload)
      raise @error if @error
      @answer
    end
  end

  def evidence
    [{ "version_id" => "v1", "title" => "Global title", "summary" => "Global summary" }]
  end

  def memory
    [{ "memory_entry_id" => "m1", "text" => "personal", "evidence_version_ids" => ["v1"] }]
  end

  def test_sensitive_query_blocks_global_spy_and_personal_lookup
    global = SpyGlobal.new(evidence)
    personal = FakePersonal.new(memory)
    result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                     provider: NoCredentialProvider.new).answer(question: "email me at a@example.com", user_id: "user-secret")
    assert_equal "privacy_blocked", result.fetch("answer_status")
    assert_empty global.calls
    assert_empty personal.calls
    assert_empty result.fetch("global_evidence")
  end

  def test_ordinary_query_passes_only_neutral_string_to_global_and_does_not_save_memory
    global = SpyGlobal.new(evidence)
    personal = FakePersonal.new(memory)
    result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                     provider: NoCredentialProvider.new).answer(question: "  global question  ", user_id: "private-user")
    assert_equal "not_generated", result.fetch("answer_status")
    assert_equal [["global question", 20]], global.calls
    assert_equal [["global question", "private-user", 20]], personal.calls
  end

  def test_valid_provider_answer_is_returned
    answer = { "answer_sections" => [{ "kind" => "fact", "text" => "supported", "cited_version_ids" => ["v1"] }],
               "follow_up_questions" => [] }
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new(memory),
                                      provider: FakeProvider.new(answer: answer))
    result = service.answer(question: "question")
    assert_equal "generated", result.fetch("answer_status")
    assert_equal answer, result.fetch("answer")
  end

  def test_provider_unknown_citation_and_extra_key_are_rejected
    unknown = { "answer_sections" => [{ "kind" => "fact", "text" => "x", "cited_version_ids" => ["unknown"] }],
                "follow_up_questions" => [] }
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new,
                                      provider: FakeProvider.new(answer: unknown))
    result = service.answer(question: "question")
    assert_equal "failed", result.fetch("answer_status")
    assert_match(/unknown|citation/, result.fetch("error"))

    extra = { "answer_sections" => [], "follow_up_questions" => [], "extra" => true }
    result = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new,
                                     provider: FakeProvider.new(answer: extra)).answer(question: "question")
    assert_equal "failed", result.fetch("answer_status")
    assert_match(/unknown keys/, result.fetch("error"))
  end

  def test_provider_failure_keeps_raw_evidence
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new(memory),
                                      provider: FakeProvider.new(error: RuntimeError.new("fixture provider failed")))
    result = service.answer(question: "question")
    assert_equal "failed", result.fetch("answer_status")
    assert_equal "v1", result.fetch("global_evidence").fetch(0).fetch("version_id")
    assert_equal "m1", result.fetch("personal_memory").fetch(0).fetch("memory_entry_id")
  end

  def test_user_memory_requires_personal_ids
    answer = { "answer_sections" => [{ "kind" => "user_memory", "text" => "memory", "cited_version_ids" => [], "memory_entry_ids" => [] }],
               "follow_up_questions" => [] }
    assert_raises(ConversationProvider::Error) do
      ConversationProvider.validate_answer!(answer, global_evidence: evidence, personal_memory: memory)
    end
  end

  def test_analysis_context_is_forwarded_as_structured_cited_units
    global = Class.new(SpyGlobal) do
      def analysis_context(limit:)
        [{ "artifact_id" => "a1", "units" => [{ "text" => "context", "cited_version_ids" => ["v1"] }] }]
      end
    end.new(evidence)
    answer = { "answer_sections" => [{ "kind" => "fact", "text" => "supported", "cited_version_ids" => ["v1"] }],
               "follow_up_questions" => [] }
    provider = Class.new(FakeProvider) do
      attr_reader :received
      def generate(**payload)
        @received = payload
        super
      end
    end.new(answer: answer)
    result = ConversationService.new(global_retriever: global, personal_retriever: FakePersonal.new,
                                     provider: provider).answer(question: "question")
    assert_equal "generated", result.fetch("answer_status")
    assert_equal "context", provider.received.fetch(:analysis_context).fetch(0).fetch("units").fetch(0).fetch("text")
  end
end
