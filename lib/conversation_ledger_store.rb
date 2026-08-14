# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "securerandom"
require_relative "local_runtime"

# Append-only personal ledger for conversation turns.  The ledger stores a
# private-query hash (never the raw question), a frozen evidence snapshot and
# provider receipts.  Replay reads only these rows; it never re-queries the
# mutable global archive.
class ConversationLedgerStore
  class Error < StandardError; end

  DEFAULT_OWNER_PRINCIPAL = ENV.fetch("LOCAL_OWNER_PRINCIPAL", "local-owner").freeze
  DEFAULT_THREAD_ID = "local-thread".freeze

  attr_reader :psql, :host, :port, :database, :user

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user),
                 global_database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 local_database: nil,
                 owner_principal: DEFAULT_OWNER_PRINCIPAL)
    @psql, @host, @port, @database, @user = psql, host, port, database.to_s, user
    @global_database = (local_database || global_database).to_s
    @owner_principal = required(owner_principal, "owner_principal")
    if @database.empty? || @database == @global_database
      raise Error, "personal database must be explicit and differ from global database"
    end
  end

  def owner_principal
    @owner_principal
  end

  def payload_hash(value)
    Digest::SHA256.hexdigest(canonical_json(value))
  end

  # Atomically appends a thread, turn, query plan, evidence snapshot/items and
  # one provider receipt.  A replay with the same turn_id and exact record hash
  # is idempotent.  Any immutable conflict is rejected before writing; any
  # mid-transaction error rolls back the entire append.
  def record_turn!(thread_id: DEFAULT_THREAD_ID, turn_id: SecureRandom.uuid,
                   predecessor_turn_id: nil, turn_ordinal: nil, as_of:,
                   private_query_context_hash:, answer_status:, neutral_query: nil,
                   neutralizer_version: "query_neutralizer_v1", query_plan: {},
                   global_evidence: [], personal_memory: [], provider_receipt:, _attempt: 0)
    raise Error, "conversation turn append retry limit exceeded" if _attempt.to_i > 3
    thread = required(thread_id, "thread_id")
    turn = required(turn_id, "turn_id")
    status = required(answer_status, "answer_status")
    timestamp = required(as_of, "as_of")
    query_hash = required(private_query_context_hash, "private_query_context_hash")
    validate_sha256!(query_hash, "private_query_context_hash")
    predecessor = predecessor_turn_id.to_s.empty? ? nil : predecessor_turn_id.to_s
    receipt = normalize_receipt(provider_receipt, turn)

    existing = find_turn(turn_id: turn, owner_principal: @owner_principal)
    if existing
      stored_turn = existing.fetch("turn")
      predecessor ||= stored_turn.fetch("predecessor_turn_id").to_s.empty? ? nil : stored_turn.fetch("predecessor_turn_id")
      expected_hash = expected_record_hash(thread_id: thread, turn_id: turn, predecessor_turn_id: predecessor,
                                           turn_ordinal: turn_ordinal || stored_turn.fetch("turn_ordinal"), as_of: timestamp,
                                           private_query_context_hash: query_hash, answer_status: status,
                                           neutral_query: neutral_query, neutralizer_version: neutralizer_version,
                                           query_plan: query_plan, global_evidence: global_evidence,
                                           personal_memory: personal_memory, provider_receipt: receipt)
      return replay(turn_id: turn) if existing.fetch("turn").fetch("record_hash") == expected_hash
      raise Error, "conversation turn #{turn} already exists with different immutable payload"
    end

    ordinal = turn_ordinal.nil? ? next_ordinal(thread) : Integer(turn_ordinal)
    raise Error, "turn_ordinal must be positive" unless ordinal.positive?
    predecessor ||= latest_turn_id(thread) if ordinal > 1
    snapshot_id = "evidence-#{turn}"
    plan_id = "query-plan-#{turn}"
    raise Error, "provider receipt attempt_ordinal must be positive" unless receipt.fetch("attempt_ordinal").positive?
    evidence_items = normalize_evidence(global_evidence, personal_memory)
    snapshot_hash = payload_hash(evidence_items)
    plan_payload = {
      "neutralizer_version" => neutralizer_version.to_s,
      "neutral_query" => neutral_query,
      "plan" => query_plan.is_a?(Hash) ? query_plan : {}
    }
    plan_hash = payload_hash(plan_payload)
    record_hash = expected_record_hash(thread_id: thread, turn_id: turn, predecessor_turn_id: predecessor,
                                       turn_ordinal: ordinal, as_of: timestamp,
                                       private_query_context_hash: query_hash, answer_status: status,
                                       neutral_query: neutral_query, neutralizer_version: neutralizer_version,
                                       query_plan: query_plan, global_evidence: global_evidence,
                                       personal_memory: personal_memory, provider_receipt: receipt)
    values = []
    values << "BEGIN"
    values << <<~SQL
      INSERT INTO conversation_thread (thread_id, owner_principal)
      VALUES (#{literal(thread)}, #{literal(@owner_principal)})
      ON CONFLICT (thread_id) DO NOTHING
    SQL
    # Serialize turn allocation for a thread across processes.  The ordinal
    # is computed before this transaction for hash compatibility; if another
    # writer wins the slot, the marker is absent and the caller retries with a
    # fresh ordinal after this transaction commits.
    values << "SELECT pg_advisory_xact_lock(hashtextextended(#{literal(thread)}, 0))"
    values << "SELECT thread_id FROM conversation_thread WHERE thread_id = #{literal(thread)} FOR UPDATE"
    values << <<~SQL
      CREATE TEMP TABLE IF NOT EXISTS conversation_ledger_insert_marker(turn_id text) ON COMMIT DROP
    SQL
    values << <<~SQL
      WITH inserted AS (
        INSERT INTO conversation_turn
        (turn_id, thread_id, predecessor_turn_id, owner_principal, turn_ordinal, as_of,
         private_query_context_hash, answer_status, record_hash)
        VALUES (#{literal(turn)}, #{literal(thread)}, #{predecessor ? literal(predecessor) : "NULL"},
              #{literal(@owner_principal)}, #{ordinal}, #{literal(timestamp)}::timestamptz,
              #{literal(query_hash)}, #{literal(status)}, #{literal(record_hash)})
        ON CONFLICT DO NOTHING
        RETURNING turn_id
      )
      INSERT INTO conversation_ledger_insert_marker(turn_id)
      SELECT turn_id FROM inserted
    SQL
    values << <<~SQL
      INSERT INTO conversation_query_plan
        (query_plan_id, turn_id, owner_principal, neutralizer_version, neutral_query,
         plan_json, plan_hash, as_of)
      SELECT #{literal(plan_id)}, #{literal(turn)}, #{literal(@owner_principal)},
              #{literal(neutralizer_version)}, #{neutral_query.nil? ? "NULL" : literal(neutral_query)},
              #{literal(JSON.generate(plan_payload.fetch("plan")))}::jsonb, #{literal(plan_hash)},
              #{literal(timestamp)}::timestamptz
       WHERE EXISTS (SELECT 1 FROM conversation_ledger_insert_marker)
    SQL
    values << <<~SQL
      INSERT INTO conversation_evidence_snapshot
        (evidence_snapshot_id, turn_id, owner_principal, as_of, snapshot_hash)
      SELECT #{literal(snapshot_id)}, #{literal(turn)}, #{literal(@owner_principal)},
              #{literal(timestamp)}::timestamptz, #{literal(snapshot_hash)}
       WHERE EXISTS (SELECT 1 FROM conversation_ledger_insert_marker)
    SQL
    evidence_items.each do |item|
      values << <<~SQL
        INSERT INTO conversation_evidence_item
          (evidence_snapshot_id, ordinal, evidence_scope, evidence_version_id,
           memory_entry_id, content_hash, evidence_json)
        SELECT #{literal(snapshot_id)}, #{item.fetch("ordinal")}, #{literal(item.fetch("evidence_scope"))},
                #{literal(item.fetch("evidence_version_id"))},
                #{item["memory_entry_id"] ? literal(item.fetch("memory_entry_id")) : "NULL"},
                #{literal(item.fetch("content_hash"))}, #{literal(JSON.generate(item.fetch("evidence_json")))}::jsonb
         WHERE EXISTS (SELECT 1 FROM conversation_ledger_insert_marker)
      SQL
    end
    values << <<~SQL
      UPDATE conversation_evidence_snapshot
         SET item_count = #{evidence_items.length}, closure_hash = #{literal(snapshot_hash)}, finalized = true
       WHERE evidence_snapshot_id = #{literal(snapshot_id)}
         AND EXISTS (SELECT 1 FROM conversation_ledger_insert_marker)
    SQL
    values << <<~SQL
      INSERT INTO conversation_provider_receipt
        (provider_receipt_id, turn_id, attempt_ordinal, provider_name, model, status,
         request_hash, response_hash, response_json, error_code, error_hash, provider_receipt_json)
      SELECT #{literal(receipt.fetch("provider_receipt_id"))}, #{literal(turn)},
              #{receipt.fetch("attempt_ordinal")}, #{literal(receipt.fetch("provider_name"))},
              #{literal(receipt.fetch("model"))}, #{literal(receipt.fetch("status"))},
              #{literal(receipt.fetch("request_hash"))},
              #{receipt["response_hash"] ? literal(receipt.fetch("response_hash")) : "NULL"},
              #{receipt["response_json"] ? literal(JSON.generate(receipt.fetch("response_json"))) + "::jsonb" : "NULL"},
              #{receipt["error_code"] ? literal(receipt.fetch("error_code")) : "NULL"},
              #{receipt["error_hash"] ? literal(receipt.fetch("error_hash")) : "NULL"},
              #{literal(JSON.generate(receipt.fetch("provider_receipt_json")))}::jsonb
       WHERE EXISTS (SELECT 1 FROM conversation_ledger_insert_marker)
    SQL
    values << "COMMIT"
    execute!(values.join(";\n") + ";")
    winner = find_turn(turn_id: turn, owner_principal: @owner_principal)
    if winner
      actual_predecessor = winner.fetch("turn").fetch("predecessor_turn_id").to_s
      actual_hash = expected_record_hash(thread_id: thread, turn_id: turn,
                                         predecessor_turn_id: actual_predecessor.empty? ? nil : actual_predecessor,
                                         turn_ordinal: winner.fetch("turn").fetch("turn_ordinal"), as_of: timestamp,
                                         private_query_context_hash: query_hash, answer_status: status,
                                         neutral_query: neutral_query, neutralizer_version: neutralizer_version,
                                         query_plan: query_plan, global_evidence: global_evidence,
                                         personal_memory: personal_memory, provider_receipt: receipt)
      return replay(turn_id: turn) if winner.fetch("turn").fetch("record_hash") == actual_hash
      raise Error, "conversation turn #{turn} already exists with different immutable payload"
    end
    record_turn!(thread_id: thread, turn_id: turn, predecessor_turn_id: nil,
                 turn_ordinal: nil, as_of: timestamp, private_query_context_hash: query_hash,
                 answer_status: status, neutral_query: neutral_query,
                 neutralizer_version: neutralizer_version, query_plan: query_plan,
                 global_evidence: global_evidence, personal_memory: personal_memory,
                 provider_receipt: receipt, _attempt: _attempt.to_i + 1)
  rescue ArgumentError, TypeError => error
    raise Error, "invalid conversation ledger payload: #{error.message}"
  rescue Error
    raise
  end

  def replay(turn_id:, owner_principal: @owner_principal)
    id = required(turn_id, "turn_id")
    owner = required(owner_principal, "owner_principal")
    turn_rows = query_json(<<~SQL)
      SELECT turn_id, thread_id, predecessor_turn_id, owner_principal, turn_ordinal,
             as_of::text, private_query_context_hash, answer_status, record_hash, created_at::text
        FROM conversation_turn
       WHERE turn_id = #{literal(id)} AND owner_principal = #{literal(owner)}
    SQL
    raise Error, "conversation turn not found" if turn_rows.empty?
    turn = turn_rows.fetch(0).transform_keys(&:to_s)
    plan_rows = query_json("SELECT query_plan_id, turn_id, owner_principal, neutralizer_version, neutral_query, plan_json::text, plan_hash, as_of::text, created_at::text FROM conversation_query_plan WHERE turn_id = #{literal(id)}")
    snapshot_rows = query_json("SELECT evidence_snapshot_id, turn_id, owner_principal, as_of::text, snapshot_hash, item_count, closure_hash, finalized, created_at::text FROM conversation_evidence_snapshot WHERE turn_id = #{literal(id)}")
    raise Error, "conversation ledger is incomplete: query plan or evidence snapshot missing" if plan_rows.empty? || snapshot_rows.empty?
    snapshot = snapshot_rows.fetch(0).transform_keys(&:to_s)
    item_rows = query_json("SELECT ordinal, evidence_scope, evidence_version_id, memory_entry_id, content_hash, evidence_json::text FROM conversation_evidence_item WHERE evidence_snapshot_id = #{literal(snapshot.fetch('evidence_snapshot_id'))} ORDER BY ordinal")
    receipt_rows = query_json("SELECT provider_receipt_id, turn_id, attempt_ordinal, provider_name, model, status, request_hash, response_hash, response_json::text, error_code, error_hash, provider_receipt_json::text, recorded_at::text FROM conversation_provider_receipt WHERE turn_id = #{literal(id)} ORDER BY attempt_ordinal")
    plan = plan_rows.fetch(0).transform_keys(&:to_s)
    plan["plan_json"] = parse_json(plan.delete("plan_json"), "query plan")
    snapshot["items"] = item_rows.map do |row|
      item = row.transform_keys(&:to_s)
      item["evidence_json"] = parse_json(item.delete("evidence_json"), "evidence item")
      item
    end
    validate_evidence_snapshot!(snapshot)
    receipts = receipt_rows.map do |row|
      receipt = row.transform_keys(&:to_s)
      receipt["response_json"] = parse_json(receipt.delete("response_json"), "provider response") unless receipt["response_json"].to_s.empty?
      receipt["provider_receipt_json"] = parse_json(receipt.delete("provider_receipt_json"), "provider receipt") unless receipt["provider_receipt_json"].to_s.empty?
      receipt
    end
    {
      "thread" => { "thread_id" => turn.fetch("thread_id"), "owner_principal" => turn.fetch("owner_principal") },
      "turn" => turn,
      "query_plan" => plan,
      "evidence_snapshot" => snapshot,
      "provider_receipts" => receipts
    }
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, "conversation replay failed: #{error.message}"
  end

  def find_turn(turn_id:, owner_principal: @owner_principal)
    id = required(turn_id, "turn_id")
    owner = required(owner_principal, "owner_principal")
    rows = query_json("SELECT turn_id, thread_id, predecessor_turn_id, owner_principal, turn_ordinal, as_of::text, private_query_context_hash, answer_status, record_hash, created_at::text FROM conversation_turn WHERE turn_id = #{literal(id)} AND owner_principal = #{literal(owner)}")
    return nil if rows.empty?
    { "turn" => rows.fetch(0).transform_keys(&:to_s) }
  end

  private

  def expected_record_hash(thread_id:, turn_id:, predecessor_turn_id:, turn_ordinal:, as_of:,
                           private_query_context_hash:, answer_status:, neutral_query:, neutralizer_version:,
                           query_plan:, global_evidence:, personal_memory:, provider_receipt:)
    payload_hash(
      "thread_id" => thread_id.to_s, "turn_id" => turn_id.to_s,
      "predecessor_turn_id" => predecessor_turn_id, "turn_ordinal" => turn_ordinal,
      "as_of" => as_of.to_s, "private_query_context_hash" => private_query_context_hash.to_s,
      "answer_status" => answer_status.to_s, "neutral_query" => neutral_query,
      "neutralizer_version" => neutralizer_version.to_s,
      "query_plan" => query_plan, "global_evidence" => global_evidence,
      "personal_memory" => personal_memory, "provider_receipt" => provider_receipt
    )
  end

  def next_ordinal(thread_id)
    query_scalar("SELECT COALESCE(MAX(turn_ordinal), 0) + 1 FROM conversation_turn WHERE thread_id = #{literal(thread_id)} AND owner_principal = #{literal(@owner_principal)}").to_i
  end

  def latest_turn_id(thread_id)
    value = query_scalar("SELECT turn_id FROM conversation_turn WHERE thread_id = #{literal(thread_id)} AND owner_principal = #{literal(@owner_principal)} ORDER BY turn_ordinal DESC LIMIT 1")
    value.empty? ? nil : value
  end

  def normalize_receipt(value, turn_id)
    source = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    request_hash = required(source.fetch("request_hash", payload_hash("turn_id" => turn_id)), "request_hash")
    validate_sha256!(request_hash, "request_hash")
    status = source.fetch("status", "not_attempted").to_s
    raise Error, "provider receipt status is invalid" unless %w[succeeded failed not_attempted].include?(status)
    response_hash = source["response_hash"]
    validate_sha256!(response_hash, "response_hash") if response_hash
    error_hash = source["error_hash"]
    validate_sha256!(error_hash, "error_hash") if error_hash
    normalized = {
      "provider_receipt_id" => required(source.fetch("provider_receipt_id", "receipt-#{turn_id}"), "provider_receipt_id"),
      "attempt_ordinal" => Integer(source.fetch("attempt_ordinal", 1)),
      "provider_name" => required(source.fetch("provider_name", "none"), "provider_name"),
      "model" => required(source.fetch("model", "none"), "model"),
      "status" => status, "request_hash" => request_hash, "response_hash" => response_hash,
      "response_json" => source["response_json"], "error_code" => source["error_code"], "error_hash" => error_hash,
      "provider_receipt_json" => source["provider_receipt_json"] || source
    }
    normalized["provider_receipt_json"] = normalized.reject { |key, _| key == "provider_receipt_json" } if normalized["provider_receipt_json"].nil?
    normalized
  end

  def normalize_evidence(global_evidence, personal_memory)
    rows = []
    Array(global_evidence).each { |row| rows << normalize_evidence_row(row, "global") }
    Array(personal_memory).each { |row| rows << normalize_evidence_row(row, "personal_memory") }
    rows.each_with_index { |row, index| row["ordinal"] = index }
    rows
  end

  def normalize_evidence_row(row, scope)
    object = row.is_a?(Hash) ? row.transform_keys(&:to_s) : {}
    version_id = object["version_id"].to_s
    version_id = object["memory_entry_id"].to_s if version_id.empty?
    raise Error, "evidence version_id is required" if version_id.empty?
    memory_id = scope == "personal_memory" ? (object["memory_entry_id"] || version_id).to_s : nil
    content_hash = object["content_hash"].to_s
    content_hash = payload_hash(object) unless content_hash.match?(/\A[a-f0-9]{64}\z/)
    { "ordinal" => 0, "evidence_scope" => scope, "evidence_version_id" => version_id,
      "memory_entry_id" => memory_id, "content_hash" => content_hash, "evidence_json" => object }
  end

  def validate_sha256!(value, name)
    raise Error, "#{name} must be SHA-256" unless value.to_s.match?(/\A[a-f0-9]{64}\z/)
  end

  def validate_evidence_snapshot!(snapshot)
    raise Error, "evidence snapshot is not finalized" unless snapshot["finalized"] == true || snapshot["finalized"].to_s == "t"
    items = Array(snapshot["items"])
    expected_count = Integer(snapshot.fetch("item_count"))
    raise Error, "evidence snapshot item count mismatch" unless expected_count == items.length
    ordinals = items.map { |item| Integer(item.fetch("ordinal")) }
    raise Error, "evidence snapshot ordinals are not contiguous" unless ordinals == (0...expected_count).to_a
    calculated_hash = payload_hash(items.map do |item|
      {
        "ordinal" => Integer(item.fetch("ordinal")),
        "evidence_scope" => item.fetch("evidence_scope").to_s,
        "evidence_version_id" => item.fetch("evidence_version_id").to_s,
        "memory_entry_id" => item["memory_entry_id"],
        "content_hash" => item.fetch("content_hash").to_s,
        "evidence_json" => item.fetch("evidence_json")
      }
    end)
    unless calculated_hash == snapshot.fetch("snapshot_hash") && calculated_hash == snapshot.fetch("closure_hash")
      raise Error, "evidence snapshot hash closure mismatch"
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "evidence snapshot closure invalid: #{error.message}"
  end

  def canonical_json(value)
    case value
    when Hash
      JSON.generate(value.keys.map(&:to_s).sort.each_with_object({}) do |key, memo|
        source_key = value.key?(key) ? key : key.to_sym
        memo[key] = canonical_value(value.fetch(source_key))
      end)
    when Array
      JSON.generate(value.map { |item| canonical_value(item) })
    else
      JSON.generate(value)
    end
  end

  def canonical_value(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.each_with_object({}) do |key, memo|
        source_key = value.key?(key) ? key : key.to_sym
        memo[key] = canonical_value(value.fetch(source_key))
      end
    when Array then value.map { |item| canonical_value(item) }
    else value
    end
  end

  def parse_json(value, label)
    JSON.parse(value.to_s)
  rescue JSON::ParserError => error
    raise Error, "invalid #{label} JSON: #{error.message}"
  end

  def required(value, name)
    text = value.to_s.strip
    raise Error, "#{name} is required" if text.empty?
    text
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def query_json(sql)
    wrapped = "SELECT COALESCE(json_agg(row_to_json(q)), '[]'::json)::text FROM (#{sql}) q"
    stdout, stderr, status = Open3.capture3(*psql_args, "-c", wrapped)
    raise Error, stderr.strip unless status.success?
    JSON.parse(stdout.strip.empty? ? "[]" : stdout.strip)
  rescue JSON::ParserError => error
    raise Error, "personal database returned invalid JSON: #{error.message}"
  end

  def query_scalar(sql)
    stdout, stderr, status = Open3.capture3(*psql_args, "-c", sql)
    raise Error, stderr.strip unless status.success?
    stdout.strip
  end

  def execute!(sql)
    _stdout, stderr, status = Open3.capture3(*psql_args, "-c", sql)
    raise Error, stderr.strip unless status.success?
  end

  def psql_args
    [@psql, "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end
end

ConversationLedger = ConversationLedgerStore unless defined?(ConversationLedger)
