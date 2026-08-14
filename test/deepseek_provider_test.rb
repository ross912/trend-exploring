# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/deepseek_client"
require_relative "../lib/translation_provider"
require_relative "../lib/report_summary_provider"
require_relative "../lib/conversation_provider"

class DeepSeekProviderTest < Minitest::Test
  FakeHttpResponse = Struct.new(:code, :body, :headers) do
    def is_a?(klass); klass == Net::HTTPSuccess || super; end
    def [](key); (headers || {})[key]; end
  end
  class FakeClient
    attr_reader :calls
    def initialize(content); @content = content; @calls = []; end
    def available?; true; end
    def provider_name; "deepseek"; end
    def model; "deepseek-v4-pro"; end
    def base_url; "https://api.deepseek.com"; end
    def chat_json(**args); @calls << args; { "content" => @content, "usage" => { "prompt_tokens" => 2, "completion_tokens" => 3, "total_tokens" => 5 }, "model" => model }; end
  end

  def test_secret_file_requires_mode_600
    Dir.mktmpdir do |dir|
      path = File.join(dir, "key")
      File.write(path, "secret\n")
      File.chmod(0o644, path)
      client = DeepSeekClient.new(secret_file: path)
      refute client.available?
      File.chmod(0o600, path)
      assert client.available?
    end
  end

  def test_only_v4_pro_is_accepted
    assert_raises(DeepSeekClient::Error) { DeepSeekClient.new(api_key: "x", model: "deepseek-chat") }
    assert_equal "deepseek-v4-pro", DeepSeekClient.new(api_key: "x").model
  end

  def test_client_sends_official_model_and_explicit_thinking_mode_without_leaking_key
    captured = nil
    response_body = JSON.generate("model" => "deepseek-v4-pro", "choices" => [{ "message" => { "content" => "{\"ok\":true}" } }], "usage" => { "prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3 })
    transport = lambda do |uri, request|
      captured = [uri, request]
      FakeHttpResponse.new("200", response_body, {})
    end
    client = DeepSeekClient.new(api_key: "test-secret-never-log", transport: transport)
    result = client.chat_json(system: "system", user: "user", thinking: false)
    payload = JSON.parse(captured.fetch(1).body)
    assert_equal "https://api.deepseek.com/chat/completions", captured.fetch(0).to_s
    assert_equal "deepseek-v4-pro", payload.fetch("model")
    assert_equal({ "type" => "disabled" }, payload.fetch("thinking"))
    assert_equal true, result.dig("content", "ok")
    refute_includes result.inspect, "test-secret-never-log"
  end

  def test_non_object_json_response_raises_with_failed_receipt
    response_body = JSON.generate("model" => "deepseek-v4-pro", "choices" => [{ "message" => { "content" => "[]" } }])
    transport = lambda { |_uri, _request| FakeHttpResponse.new("200", response_body, { "x-request-id" => "req-invalid" }) }
    client = DeepSeekClient.new(api_key: "test-secret-never-log", transport: transport)

    error = assert_raises(DeepSeekClient::Error) do
      client.chat_json(system: "system", user: "user", thinking: false)
    end
    assert_equal "invalid_provider_response", error.code
    receipt = error.receipt
    assert_equal "failed", receipt.fetch("status")
    assert_equal true, receipt.fetch("response_available")
    assert_equal "invalid_provider_response", receipt.fetch("error_code")
    assert_match(/\A[a-f0-9]{64}\z/, receipt.fetch("canonical_request_hash"))
    assert_match(/\A[a-f0-9]{64}\z/, receipt.fetch("raw_response_hash"))
    refute_includes receipt.inspect, "test-secret-never-log"
  end

  def test_translation_disables_thinking_and_translates_body
    content = { "title_zh" => "标题", "summary_zh" => "摘要", "body_zh" => "正文 2026", "image_captions_zh" => ["图注"] }
    client = FakeClient.new(content)
    result = TranslationProvider::DeepSeek.new(client: client).translate(title: "Title", summary: "Summary", body: "Body 2026", image_captions: ["Caption"], source_language: "en")
    refute client.calls.fetch(0).fetch(:thinking)
    assert_equal "正文 2026", result.fetch("translated_body")
    assert_equal "deepseek-v4-pro", result.fetch("model")
  end

  def test_summary_and_conversation_enable_high_reasoning
    summary_client = FakeClient.new({ "overview" => { "text" => "概览", "cited_version_ids" => ["v1"] }, "key_changes" => [], "uncertainties" => [] })
    ReportSummaryProvider::DeepSeek.new(client: summary_client).summarize(input: {})
    assert summary_client.calls.fetch(0).fetch(:thinking)
    assert_equal "high", summary_client.calls.fetch(0).fetch(:reasoning_effort)
    assert_includes summary_client.calls.fetch(0).fetch(:system), "输出 schema 与这些元数据完全分离"
    assert_includes summary_client.calls.fetch(0).fetch(:system), "provider_item_count"

    answer = { "answer_sections" => [{ "kind" => "fact", "text" => "事实", "cited_version_ids" => ["v1"] }], "follow_up_questions" => [] }
    conversation_client = FakeClient.new(answer)
    ConversationProvider.new(client: conversation_client).generate(question: "?", global_evidence: [{ "version_id" => "v1" }], personal_memory: [])
    assert conversation_client.calls.fetch(0).fetch(:thinking)
  end
end
