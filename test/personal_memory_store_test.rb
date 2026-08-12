# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/personal_memory_store"
require_relative "../lib/conversation_retriever"

class PersonalMemoryStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "trend_exploring_personal_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, @database])
    run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
          "-d", @database, "-f", File.join(ROOT, "schema/postgres/personal/001_personal_memory.sql")])
    @store = PersonalMemoryStore.new(psql: bin("psql"), host: host, port: port, user: user,
                                     database: @database, global_database: "trend_exploring_local")
  end

  def teardown
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, @database]) if @database
  end

  def test_personal_database_must_differ_from_global_database
    error = assert_raises(PersonalMemoryStore::Error) do
      PersonalMemoryStore.new(database: "trend_exploring_local", global_database: "trend_exploring_local")
    end
    assert_match(/differ from global/, error.message)
  end

  def test_append_is_immutable_and_exact_replay_is_idempotent
    first = @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "belief",
                           text: "prefers concise answers", source: "manual_import",
                           evidence_version_ids: ["v1"])
    replay = @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "belief",
                            text: "prefers concise answers", source: "manual_import",
                            evidence_version_ids: ["v1"])
    assert_equal first, replay
    assert_equal ["v1"], first.fetch("evidence_version_ids")
    assert_raises(PersonalMemoryStore::Error) do
      @store.append!(memory_entry_id: "m-duplicate", subject_key: "user-1", memory_kind: "belief",
                     text: "duplicate refs", source: "manual_import", evidence_version_ids: %w[v1 v1])
    end
    assert_raises(PersonalMemoryStore::Error) do
      @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "belief",
                     text: "different", source: "manual_import")
    end
    assert_equal 1, psql!("SELECT COUNT(*) FROM memory_entry").to_i
  end

  def test_retraction_appends_history_and_search_returns_only_active_head
    @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "focus",
                   text: "research privacy", source: "conversation_explicit")
    retraction = @store.retract!(memory_entry_id: "m1", retraction_entry_id: "m2", text: "no longer active")
    assert_equal "retracted", retraction.fetch("status")
    assert_equal %w[m1 m2], @store.entries.map { |row| row.fetch("memory_entry_id") }
    assert_empty @store.search(query: "research privacy", subject_key: "user-1")
    assert_equal 2, psql!("SELECT COUNT(*) FROM memory_entry").to_i
  end

  def test_personal_evidence_is_revalidated_without_dropping_history
    @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "belief",
                   text: "archive fact", source: "manual_import", evidence_version_ids: %w[v1 v_missing])
    global = Class.new do
      attr_reader :ids
      def resolve_version_ids(ids)
        @ids = ids
        ["v1"]
      end
    end.new
    retriever = PersonalConversationRetriever.new(store: @store, global_retriever: global)
    result = retriever.search(query: "archive", subject_key: "user-1", limit: 5).fetch(0)
    assert_equal %w[v1 v_missing], result.fetch("evidence_version_ids")
    assert_equal({ "version_id" => "v1", "status" => "resolved" }, result.fetch("evidence_resolution")[0])
    assert_equal({ "version_id" => "v_missing", "status" => "unresolved" }, result.fetch("evidence_resolution")[1])
    assert_equal %w[v1 v_missing], global.ids
  end

  def test_database_has_no_cross_database_evidence_foreign_key
    assert_equal 0, psql!(<<~SQL).to_i
      SELECT COUNT(*) FROM pg_constraint
       WHERE conrelid = 'memory_entry'::regclass
         AND contype = 'f'
         AND conname LIKE '%evidence%'
    SQL
  end

  def test_database_guard_rejects_cross_subject_and_retracted_predecessor_links
    @store.append!(memory_entry_id: "m1", subject_key: "user-1", memory_kind: "belief",
                   text: "fact", source: "manual_import")
    assert_raises(PersonalMemoryStore::Error) do
      @store.append!(memory_entry_id: "m2", subject_key: "user-2", memory_kind: "belief",
                     text: "forged", source: "manual_import", supersedes_entry_id: "m1")
    end
    @store.retract!(memory_entry_id: "m1", retraction_entry_id: "m2")
    assert_raises(PersonalMemoryStore::Error) do
      @store.append!(memory_entry_id: "m3", subject_key: "user-1", memory_kind: "belief",
                     text: "forged active", source: "manual_import", supersedes_entry_id: "m2")
    end
  end

  private

  def psql!(sql)
    run!([bin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user,
          "-d", @database, "-c", sql]).strip
  end

  def run!(args)
    stdout, stderr, status = Open3.capture3(*args)
    raise "command failed: #{stderr}" unless status.success?
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
