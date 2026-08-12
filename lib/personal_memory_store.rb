# frozen_string_literal: true

require "json"
require "open3"
require "time"
require_relative "local_runtime"

# Append-only access to the personal memory database.  This class deliberately
# knows nothing about the global database except for the optional, read-only
# evidence lookup supplied by a caller.
class PersonalMemoryStore
  class Error < StandardError; end

  KINDS = %w[belief hypothesis question focus].freeze
  STATUSES = %w[active retracted].freeze
  SOURCES = %w[conversation_explicit manual_import].freeze
  DEFAULT_DATABASE = "trend_exploring_personal"

  attr_reader :psql, :host, :port, :database, :user

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user),
                 global_database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 local_database: nil)
    @psql = psql
    @host = host
    @port = port
    @database = database.to_s
    @user = user
    @global_database = (local_database || global_database).to_s
    if @database.empty? || @database == @global_database
      raise Error, "personal database must be explicit and differ from global database"
    end
  end

  def health
    rows = query_json("SELECT current_database() AS database, current_setting('server_version') AS server_version")
    row = rows.fetch(0)
    row.merge("status" => "ok")
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, "personal database health check failed: #{error.message}"
  end

  # Add one memory entry.  recorded_at is always database-controlled.  A
  # repeated id with identical payload is an idempotent replay; changing any
  # immutable field is rejected.
  def append!(memory_entry_id:, subject_key:, memory_kind:, text:, source:, evidence_version_ids: [],
              status: "active", supersedes_entry_id: nil)
    id = required(memory_entry_id, "memory_entry_id")
    payload = normalize_payload(memory_entry_id: id, subject_key: subject_key, memory_kind: memory_kind,
                                text: text, source: source, evidence_version_ids: evidence_version_ids,
                                status: status, supersedes_entry_id: supersedes_entry_id)
    existing = find(id)
    if existing
      return existing if replay_matches?(existing, payload)
      raise Error, "memory entry #{id} already exists with different immutable payload"
    end

    if payload.fetch("supersedes_entry_id")
      predecessor = find(payload.fetch("supersedes_entry_id"))
      raise Error, "superseded memory entry not found" unless predecessor
      if predecessor.fetch("subject_key") != payload.fetch("subject_key") || predecessor.fetch("memory_kind") != payload.fetch("memory_kind")
        raise Error, "superseded memory entry subject or kind differs"
      end
      if payload.fetch("status") == "retracted" && predecessor.fetch("status") == "retracted"
        raise Error, "cannot retract an already retracted memory entry"
      end
      if payload.fetch("status") == "active" && predecessor.fetch("status") != "active"
        raise Error, "active memory entry must supersede an active entry"
      end
    elsif payload.fetch("status") == "retracted"
      raise Error, "retracted memory entry must supersede an existing entry"
    end

    sql = <<~SQL
      WITH inserted AS (
        INSERT INTO memory_entry
          (memory_entry_id, subject_key, memory_kind, text, supersedes_entry_id,
           status, evidence_version_ids, source)
        VALUES (#{literal(payload.fetch("memory_entry_id"))},
                #{literal(payload.fetch("subject_key"))},
                #{literal(payload.fetch("memory_kind"))},
                #{literal(payload.fetch("text"))},
                #{payload.fetch("supersedes_entry_id") ? literal(payload.fetch("supersedes_entry_id")) : "NULL"},
                #{literal(payload.fetch("status"))},
                #{literal(JSON.generate(payload.fetch("evidence_version_ids")))}::jsonb,
                #{literal(payload.fetch("source"))})
        RETURNING memory_entry_id, subject_key, memory_kind, text, recorded_at::text,
                  supersedes_entry_id, status, evidence_version_ids::text, source
      )
      SELECT row_to_json(inserted)::text FROM inserted
    SQL
    rows = query_json_direct(sql)
    raise Error, "memory entry insert returned no row" if rows.empty?
    normalize_row(rows.fetch(0))
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, error.message
  end

  alias save! append!
  alias record! append!

  def retract!(memory_entry_id:, retraction_entry_id:, text: "Retracted", source: "manual_import", evidence_version_ids: [])
    predecessor = find(required(memory_entry_id, "memory_entry_id"))
    raise Error, "memory entry not found: #{memory_entry_id}" unless predecessor
    append!(memory_entry_id: retraction_entry_id, subject_key: predecessor.fetch("subject_key"),
           memory_kind: predecessor.fetch("memory_kind"), text: text, source: source,
           evidence_version_ids: evidence_version_ids, status: "retracted",
           supersedes_entry_id: predecessor.fetch("memory_entry_id"))
  end

  def find(memory_entry_id)
    rows = query_json(<<~SQL)
      SELECT memory_entry_id, subject_key, memory_kind, text, recorded_at::text,
             supersedes_entry_id, status, evidence_version_ids::text, source
        FROM memory_entry
       WHERE memory_entry_id = #{literal(memory_entry_id.to_s)}
    SQL
    rows.empty? ? nil : normalize_row(rows.fetch(0))
  end

  def entries(subject_key: nil, include_retracted: true)
    clauses = []
    clauses << "subject_key = #{literal(subject_key.to_s)}" if subject_key
    clauses << "status = 'active'" unless include_retracted
    sql = <<~SQL
      SELECT memory_entry_id, subject_key, memory_kind, text, recorded_at::text,
             supersedes_entry_id, status, evidence_version_ids::text, source
        FROM memory_entry
       #{clauses.empty? ? "" : "WHERE #{clauses.join(" AND ")}"}
       ORDER BY recorded_at ASC, memory_entry_id ASC
    SQL
    query_json(sql).map { |row| normalize_row(row) }
  end

  # Lexical retrieval only over active heads.  Evidence references remain
  # intact even when an optional global lookup marks them unresolved.
  def search(query:, subject_key: nil, limit: 20, evidence_lookup: nil)
    text = query.to_s.strip
    max = Integer(limit)
    raise Error, "limit must be positive" unless max.positive?
    clauses = ["status = 'active'", "NOT EXISTS (SELECT 1 FROM memory_entry newer WHERE newer.supersedes_entry_id = memory_entry.memory_entry_id)"]
    clauses << "subject_key = #{literal(subject_key.to_s)}" if subject_key
    terms = lexical_terms(text)
    # Search is intentionally deterministic and portable: use PostgreSQL's
    # plain substring predicates, then apply a Ruby score/tie-break.
    unless terms.empty?
      clauses << "(#{terms.map { |term| "lower(text) LIKE #{literal("%#{term.downcase}%")}" }.join(" OR ")})"
    end
    rows = query_json(<<~SQL)
      SELECT memory_entry_id, subject_key, memory_kind, text, recorded_at::text,
             supersedes_entry_id, status, evidence_version_ids::text, source
        FROM memory_entry
       WHERE #{clauses.join(" AND ")}
       ORDER BY recorded_at DESC, memory_entry_id DESC
       LIMIT #{terms.empty? ? max : max * 5}
    SQL
    result = rows.map { |row| normalize_row(row) }
    result.sort_by! { |row| [-terms.count { |term| row.fetch("text").downcase.include?(term.downcase) }, row.fetch("recorded_at").to_s, row.fetch("memory_entry_id")] }
    result.first(max).map do |row|
      next row unless evidence_lookup
      refs = row.fetch("evidence_version_ids")
      resolved = refs.select { |ref| evidence_lookup.call(ref) }
      row.merge("evidence_resolution" => refs.map { |ref| { "version_id" => ref, "status" => resolved.include?(ref) ? "resolved" : "unresolved" } })
    end
  rescue ArgumentError => error
    raise Error, "invalid personal memory search: #{error.message}"
  end

  private

  def normalize_payload(memory_entry_id:, subject_key:, memory_kind:, text:, source:, evidence_version_ids:, status:, supersedes_entry_id:)
    kind = memory_kind.to_s
    raise Error, "memory_kind is invalid" unless KINDS.include?(kind)
    state = status.to_s
    raise Error, "status is invalid" unless STATUSES.include?(state)
    source_name = source.to_s
    raise Error, "source is invalid" unless SOURCES.include?(source_name)
    raw_refs = Array(evidence_version_ids)
    raise Error, "evidence_version_ids must contain strings only" unless raw_refs.all? { |ref| ref.is_a?(String) }
    refs = raw_refs.map(&:strip)
    raise Error, "evidence_version_ids must contain non-empty strings" if refs.any?(&:empty?)
    raise Error, "evidence_version_ids must not contain duplicates" unless refs.uniq.length == refs.length
    {
      "memory_entry_id" => required(memory_entry_id, "memory_entry_id"),
      "subject_key" => required(subject_key, "subject_key"),
      "memory_kind" => kind,
      "text" => required(text, "text"),
      "source" => source_name,
      "evidence_version_ids" => refs,
      "status" => state,
      "supersedes_entry_id" => supersedes_entry_id.nil? || supersedes_entry_id.to_s.empty? ? nil : supersedes_entry_id.to_s
    }
  end

  def replay_matches?(existing, payload)
    %w[memory_entry_id subject_key memory_kind text source status supersedes_entry_id evidence_version_ids].all? do |key|
      existing.fetch(key) == payload.fetch(key)
    end
  end

  def normalize_row(row)
    row = row.transform_keys(&:to_s)
    row["evidence_version_ids"] = JSON.parse(row.fetch("evidence_version_ids", "[]"))
    row
  rescue JSON::ParserError => error
    raise Error, "invalid evidence_version_ids in personal database: #{error.message}"
  end

  def lexical_terms(text)
    text.to_s.downcase.scan(/[[:alnum:]]+|[^\s[:punct:]]/).reject { |term| term.length < 2 && term !~ /[^\x00-\x7f]/ }
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

  # Execute a top-level data-modifying CTE and parse one JSON object per row.
  # Such a statement cannot legally be nested inside the SELECT wrapper used
  # by query_json.
  def query_json_direct(sql)
    stdout, stderr, status = Open3.capture3(*psql_args, "-c", sql)
    raise Error, stderr.strip unless status.success?
    stdout.lines.map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
  rescue JSON::ParserError => error
    raise Error, "personal database returned invalid JSON: #{error.message}"
  end

  def psql_args
    [@psql, "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end
end
