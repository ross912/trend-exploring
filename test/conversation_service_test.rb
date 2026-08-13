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
    assert_equal [["global", 20]], global.calls
    assert_equal [["global", "private-user", 20]], personal.calls
  end

  def test_opposite_personal_stance_and_framing_produce_identical_global_query_and_evidence
    global = Class.new(SpyGlobal) do
      def search(query, limit:)
        @calls << [query, limit]
        [{ "version_id" => "v-#{query}" }]
      end
    end
    first_global = global.new
    second_global = global.new
    first = ConversationService.new(global_retriever: first_global, personal_retriever: FakePersonal.new,
                                    provider: NoCredentialProvider.new).answer(
                                      question: "I only care about AI startups; what do you think?",
                                      user_id: "profile-a")
    second = ConversationService.new(global_retriever: second_global, personal_retriever: FakePersonal.new,
                                     provider: NoCredentialProvider.new).answer(
                                       question: "I oppose AI startups. In my opinion, please tell me the latest AI startups update.",
                                       user_id: "profile-b")
    assert_equal "ai startups", first.fetch("neutral_query")
    assert_equal first.fetch("neutral_query"), second.fetch("neutral_query")
    assert_equal first.fetch("global_evidence").map { |row| row.fetch("version_id") }, second.fetch("global_evidence").map { |row| row.fetch("version_id") }
    assert_equal first_global.calls, second_global.calls
  end

  def test_private_canary_is_never_sent_to_global_or_personal_retriever
    global = SpyGlobal.new(evidence)
    personal = FakePersonal.new(memory)
    result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                     provider: NoCredentialProvider.new).answer(
                                       question: "I care about climate; private canary-7f3a9c2e, what happened?",
                                       user_id: "user-secret")
    assert_equal "privacy_blocked", result.fetch("answer_status")
    assert_empty global.calls
    assert_empty personal.calls
    refute_includes JSON.generate(result), "canary-7f3a9c2e"
  end

  def test_chinese_private_canaries_are_blocked_before_global_or_personal_retrieval
    [
      "我的病历号 ABC123456 最近有什么变化？",
      "身份证号 11010519491231002X 的办理政策",
      "联系电话 13812345678 的公共健康政策",
      "我的家庭住址 上海市浦东新区世纪大道100号附近",
      "未公开公司 星河计划的融资进展"
    ].each do |question|
      global = SpyGlobal.new(evidence)
      personal = FakePersonal.new(memory)
      result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                       provider: NoCredentialProvider.new).answer(
                                         question: question, user_id: "用户-隐私-canary")
      assert_equal "privacy_blocked", result.fetch("answer_status"), question
      assert_empty global.calls, question
      assert_empty personal.calls, question
      refute_includes JSON.generate(result), "ABC123456"
      refute_includes JSON.generate(result), "11010519491231002X"
      refute_includes JSON.generate(result), "13812345678"
      refute_includes JSON.generate(result), "世纪大道100号"
      refute_includes JSON.generate(result), "星河计划"
    end
  end

  def test_public_place_and_topic_are_not_false_positive_blocked
    global = SpyGlobal.new(evidence)
    personal = FakePersonal.new(memory)
    result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                     provider: NoCredentialProvider.new).answer(
                                       question: "上海 AI 政策最近如何？", user_id: "public-user")
    assert_equal "not_generated", result.fetch("answer_status")
    assert_equal [["ai 上海 政策最近", 20]], global.calls
    assert_equal [["ai 上海 政策最近", "public-user", 20]], personal.calls
  end

  def test_question_without_public_terms_fails_closed
    global = SpyGlobal.new(evidence)
    personal = FakePersonal.new(memory)
    result = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                     provider: NoCredentialProvider.new).answer(question: "what do you think?", user_id: "u")
    assert_equal "privacy_blocked", result.fetch("answer_status")
    assert_empty global.calls
    assert_empty personal.calls
  end

  def test_valid_provider_answer_is_returned
    answer = { "answer_sections" => [{ "kind" => "fact", "text" => "supported", "cited_version_ids" => ["v1"] }],
               "follow_up_questions" => [] }
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new(memory),
                                      provider: FakeProvider.new(answer: answer))
    result = service.answer(question: "global evidence")
    assert_equal "generated", result.fetch("answer_status")
    assert_equal answer, result.fetch("answer")
  end

  def test_provider_unknown_citation_and_extra_key_are_rejected
    unknown = { "answer_sections" => [{ "kind" => "fact", "text" => "x", "cited_version_ids" => ["unknown"] }],
                "follow_up_questions" => [] }
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new,
                                      provider: FakeProvider.new(answer: unknown))
    result = service.answer(question: "global evidence")
    assert_equal "failed", result.fetch("answer_status")
    assert_match(/unknown|citation/, result.fetch("error"))

    extra = { "answer_sections" => [], "follow_up_questions" => [], "extra" => true }
    result = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new,
                                     provider: FakeProvider.new(answer: extra)).answer(question: "global evidence")
    assert_equal "failed", result.fetch("answer_status")
    assert_match(/unknown keys/, result.fetch("error"))
  end

  def test_provider_failure_keeps_raw_evidence
    service = ConversationService.new(global_retriever: SpyGlobal.new(evidence), personal_retriever: FakePersonal.new(memory),
                                      provider: FakeProvider.new(error: RuntimeError.new("fixture provider failed")))
    result = service.answer(question: "global evidence")
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
                                     provider: provider).answer(question: "global evidence")
    assert_equal "generated", result.fetch("answer_status")
    assert_equal "context", provider.received.fetch(:analysis_context).fetch(0).fetch("units").fetch(0).fetch("text")
  end
end
