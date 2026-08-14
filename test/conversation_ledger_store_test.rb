# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/conversation_ledger_store"
require_relative "../lib/conversation_service"

class ConversationLedgerStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @database = "conversation_ledger_test_#{Process.pid}_#{SecureRandom.hex(4)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, @database])
    run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
          "-d", @database, "-f", File.join(ROOT, "schema/postgres/personal/001_personal_memory.sql")])
    run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
          "-d", @database, "-f", File.join(ROOT, "schema/postgres/personal/002_conversation_ledger.sql")])
    @store = ConversationLedgerStore.new(psql: bin("psql"), host: host, port: port, user: user,
                                         database: @database, global_database: "trend_exploring_local",
                                         owner_principal: "local-owner")
    @hash = Digest::SHA256.hexdigest("private question")
  end

  def teardown
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, @database]) if @database
  end

  def receipt(status: "succeeded", request: "request", response: nil)
    value = {
      "status" => status, "provider_name" => "deepseek", "model" => "deepseek-v4-pro",
      "request_hash" => Digest::SHA256.hexdigest(request)
    }
    if status == "succeeded"
      value["response_hash"] = Digest::SHA256.hexdigest(JSON.generate(response || { "ok" => true }))
      value["response_json"] = response || { "ok" => true }
    else
      value["error_code"] = "timeout"
      value["error_hash"] = Digest::SHA256.hexdigest("timeout")
    end
    value
  end

  def evidence(version_id, title)
    { "version_id" => version_id, "title" => title,
      "content_hash" => Digest::SHA256.hexdigest(title) }
  end

  def test_failed_call_is_replayed_with_receipt_and_evidence_is_frozen
    first = @store.record_turn!(thread_id: "thread-1", turn_id: "turn-1", as_of: "2026-08-13T00:00:00Z",
                                private_query_context_hash: @hash, answer_status: "failed", neutral_query: "ai policy",
                                query_plan: { "stage" => "retrieval" }, global_evidence: [evidence("v-old", "old")],
                                personal_memory: [], provider_receipt: receipt(status: "failed"))
    replay = @store.replay(turn_id: "turn-1")
    assert_equal "failed", replay.dig("turn", "answer_status")
    assert_equal "failed", replay.dig("provider_receipts", 0, "status")
    assert_equal "timeout", replay.dig("provider_receipts", 0, "error_code")
    assert_equal "v-old", replay.dig("evidence_snapshot", "items", 0, "evidence_version_id")

    # A newer archive version is not consulted by replay: the original snapshot
    # remains the only source of historical evidence.
    refute_equal "v-new", replay.dig("evidence_snapshot", "items", 0, "evidence_version_id")
    assert_equal first.dig("turn", "record_hash"), replay.dig("turn", "record_hash")
  end

  def test_turn_predecessor_is_closed_and_owner_body_hint_cannot_change_service_key
    second = @store.record_turn!(thread_id: "thread-2", turn_id: "turn-2", as_of: "2026-08-13T00:00:00Z",
                                 private_query_context_hash: @hash, answer_status: "not_generated", turn_ordinal: 1,
                                 provider_receipt: receipt(status: "failed"))
    assert_nil second.dig("turn", "predecessor_turn_id")
    next_turn = @store.record_turn!(thread_id: "thread-2", turn_id: "turn-3", as_of: "2026-08-13T00:01:00Z",
                                    private_query_context_hash: @hash, answer_status: "not_generated",
                                    provider_receipt: receipt(status: "failed", request: "next"))
    assert_equal "turn-2", next_turn.dig("turn", "predecessor_turn_id")

    personal = Class.new do
      attr_reader :keys
      def search(query:, subject_key:, limit:)
        (@keys ||= []) << subject_key
        []
      end
    end.new
    global = Class.new do
      def search(_query, limit:); []; end
      def analysis_context(limit:); []; end
    end.new
    service = ConversationService.new(global_retriever: global, personal_retriever: personal,
                                      provider: Object.new, ledger_store: nil)
    service.answer(question: "AI policy", user_id: "forged", subject_key: "forged")
    assert_equal ["local-owner"], personal.keys
  end

  def test_update_delete_and_conflicting_replay_are_rejected
    @store.record_turn!(thread_id: "thread-3", turn_id: "turn-4", as_of: "2026-08-13T00:00:00Z",
                        private_query_context_hash: @hash, answer_status: "not_generated",
                        provider_receipt: receipt(status: "failed"))
    assert_raises(ConversationLedgerStore::Error) do
      @store.record_turn!(thread_id: "thread-3", turn_id: "turn-4", as_of: "2026-08-13T00:00:00Z",
                          private_query_context_hash: Digest::SHA256.hexdigest("different"), answer_status: "failed",
                          provider_receipt: receipt(status: "failed", request: "different"))
    end
    assert_raises(RuntimeError) do
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
            "-d", @database, "-c", "UPDATE conversation_turn SET answer_status='failed'"])
    end
    assert_raises(RuntimeError) do
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
            "-d", @database, "-c", "DELETE FROM conversation_turn"])
    end
    assert_equal 1, scalar("SELECT COUNT(*) FROM conversation_turn").to_i
  end

  def test_truncate_is_rejected_and_snapshot_membership_is_closed
    @store.record_turn!(thread_id: "thread-truncate", turn_id: "turn-truncate", as_of: "2026-08-13T00:00:00Z",
                        private_query_context_hash: @hash, answer_status: "not_generated",
                        global_evidence: [evidence("v1", "one")], provider_receipt: receipt(status: "failed"))
    assert_raises(RuntimeError) do
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
            "-d", @database, "-c", "TRUNCATE conversation_thread CASCADE"])
    end
    assert_raises(RuntimeError) do
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
            "-d", @database, "-c", "INSERT INTO conversation_evidence_item (evidence_snapshot_id, ordinal, evidence_scope, evidence_version_id, content_hash, evidence_json) VALUES ('evidence-turn-truncate', 1, 'global', 'v2', repeat('a', 64), '{\"version_id\":\"v2\"}'::jsonb)"])
    end
    assert_equal ["v1"], @store.replay(turn_id: "turn-truncate").fetch("evidence_snapshot").fetch("items").map { |item| item.fetch("evidence_version_id") }
  end

  def test_concurrent_turns_share_ordinals_without_unique_key_race
    gate = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        gate.pop
        ConversationLedgerStore.new(psql: bin("psql"), host: host, port: port, user: user,
                                     database: @database, global_database: "trend_exploring_local",
                                     owner_principal: "local-owner").record_turn!(
                                       thread_id: "thread-concurrent", turn_id: "turn-concurrent-#{index}",
                                       as_of: "2026-08-13T00:00:00Z", private_query_context_hash: @hash,
                                       answer_status: "not_generated", provider_receipt: receipt(status: "failed"))
      end
    end
    2.times { gate << true }
    results = threads.map(&:value)
    assert_equal [1, 2], results.map { |row| row.fetch("turn").fetch("turn_ordinal") }.sort
  end

  private

  def scalar(sql)
    run!([bin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
          "-d", @database, "-c", sql]).strip
  end

  def run!(args)
    stdout, stderr, status = Open3.capture3(*args)
    raise RuntimeError, stderr unless status.success?
    stdout
  end

  def bin(name)
    File.join(ENV.fetch("LOCAL_PSQL", "/private/tmp/trend-exploring-postgres15-runtime/bin/psql").sub(/\/psql\z/, ""), name)
  end

  def host
    ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket")
  end

  def port
    ENV.fetch("LOCAL_PGPORT", "55433")
  end

  def user
    ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
  end
end
