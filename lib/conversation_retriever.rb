# frozen_string_literal: true

require "json"
require "open3"
require "time"
require_relative "personal_memory_store"
require_relative "local_runtime"

# Read-only global evidence retrieval.  The query intentionally targets the
# immutable archive relation directly and never the current item projection.
class ConversationRetriever
  class Error < StandardError; end
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100
  ENGLISH_QUERY_STOPWORDS = %w[a an and are can for from has have how in is it of on or the to what when where which who why with].freeze
  CJK_QUERY_STOP_BIGRAMS = %w[关于 最近 哪些 什么 如何 是否 信息 资讯 新闻 已归 归档 资料 事情 情况 帮我 告诉].freeze

  attr_reader :psql, :host, :port, :database, :user

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user))
    @psql, @host, @port, @database, @user = psql, host, port, database, user
  end

  # Returns archive evidence only.  Search scoring is performed in Ruby so it
  # remains stable across PostgreSQL minor versions and locale configurations.
  def search(query = nil, limit: DEFAULT_LIMIT, **kwargs)
    query = kwargs.fetch(:query) if query.nil? && kwargs.key?(:query)
    query = query.to_s
    max = bounded_limit(limit)
    tokens = tokenize(query)
    return [] if tokens.empty?

    rows = query_json(<<~SQL)
      SELECT item_key, version_id, capture_id, content_hash, title, summary, source_url,
             publisher_name AS publisher, language, created_at::text
        FROM local_source_item_version
    SQL
    ranked = rows.map { |row| normalize_row(row) }
                 .map { |row| [score(row, tokens), row] }
                 .select { |score_value, _row| score_value.positive? }
                 .group_by { |_score_value, row| row.fetch("item_key") }
                 .values
                 .map { |versions| versions.max_by { |score_value, row| [score_value, timestamp_value(row.fetch("created_at")), row.fetch("version_id")] } }
    return [] if ranked.empty?
    # Conversational questions often contain generic words such as “最近” or
    # “信息”.  Keep only rows that reach at least half of the best lexical
    # match so one generic overlap cannot swamp a specific two-word subject.
    relevance_floor = [(ranked.map(&:first).max / 2.0).ceil, 1].max
    ranked.select { |score_value, _row| score_value >= relevance_floor }
          .sort_by { |score_value, row| [-score_value, -timestamp_value(row.fetch("created_at")), row.fetch("version_id")] }
          .first(max)
          .map(&:last)
  rescue StandardError => error
    raise error if error.is_a?(Error)
    raise Error, "global conversation retrieval failed: #{error.message}"
  end

  # Batch validation for personal-memory evidence.  This is deliberately one
  # archive query per retrieval, never one query per referenced ID.
  def resolve_version_ids(version_ids)
    ids = Array(version_ids).map(&:to_s).reject(&:empty?).uniq
    return [] if ids.empty?
    rows = query_json(<<~SQL)
      SELECT version_id
        FROM local_source_item_version
       WHERE version_id IN (#{ids.map { |id| literal(id) }.join(', ')})
    SQL
    rows.map { |row| row.fetch("version_id").to_s }
  end

  # Optional latest report context.  The absence of the 014 relation is a
  # normal condition and returns an empty list.  Citation IDs are retained;
  # this method never treats a summary sentence as uncited evidence.
  def analysis_context(limit: 5)
    max = bounded_limit(limit)
    exists = query_scalar("SELECT to_regclass('local_report_summary_artifact') IS NOT NULL")
    return [] unless exists == "t"
    rows = query_json(<<~SQL)
      SELECT a.artifact_id, a.run_id, a.edition_id, a.overview::text, a.key_changes::text,
             a.uncertainties::text, a.created_at::text
        FROM local_report_summary_artifact a
        JOIN local_report_summary_run r ON r.run_id = a.run_id
       WHERE r.state = 'succeeded'
       ORDER BY a.created_at DESC, a.artifact_id ASC
       LIMIT #{max}
    SQL
    rows.map do |row|
      normalized = row.transform_keys(&:to_s)
      {
        "artifact_id" => normalized.fetch("artifact_id"),
        "run_id" => normalized.fetch("run_id"),
        "edition_id" => normalized.fetch("edition_id"),
        "units" => [JSON.parse(normalized.fetch("overview"))].concat(JSON.parse(normalized.fetch("key_changes")) + JSON.parse(normalized.fetch("uncertainties"))).map { |unit| normalize_context_unit(unit) },
        "created_at" => normalized.fetch("created_at")
      }
    end
  rescue StandardError => error
    return [] if error.message =~ /relation .* does not exist|undefined table/i
    raise error if error.is_a?(Error)
    raise Error, "global analysis context retrieval failed: #{error.message}"
  end

  private

  def bounded_limit(limit)
    value = Integer(limit)
    raise Error, "limit must be positive" unless value.positive?
    [value, MAX_LIMIT].min
  rescue ArgumentError, TypeError
    raise Error, "limit must be a positive integer"
  end

  def tokenize(text)
    result = []
    # English/number terms.  A token is case-insensitive and punctuation is a
    # separator; this deliberately excludes URLs from the service before this
    # layer is reached.
    result.concat(text.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.length < 2 || ENGLISH_QUERY_STOPWORDS.include?(token) })
    # Chinese (and other CJK) character bigrams provide deterministic matching
    # without requiring a database text-search extension.
    cjk_runs = text.to_s.scan(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+/u)
    cjk_runs.each do |run|
      chars = run.each_char.to_a
      if chars.length == 1
        result << chars.first
      else
        chars.each_cons(2) do |pair|
          token = pair.join
          result << token unless CJK_QUERY_STOP_BIGRAMS.include?(token)
        end
      end
    end
    result.uniq
  end

  def score(row, tokens)
    title = row.fetch("title").downcase
    summary = row.fetch("summary").downcase
    tokens.sum do |token|
      needle = token.downcase
      title.include?(needle) ? 3 : (summary.include?(needle) ? 1 : 0)
    end
  end

  def timestamp_value(value)
    Time.parse(value.to_s).to_f
  rescue ArgumentError, TypeError
    0.0
  end

  def normalize_row(row)
    row.transform_keys(&:to_s).slice("item_key", "version_id", "capture_id", "content_hash", "title", "summary", "source_url", "publisher", "language", "created_at")
  end

  def normalize_context_unit(unit)
    object = unit.is_a?(Hash) ? unit.transform_keys(&:to_s) : {}
    {
      "text" => object.fetch("text", "").to_s,
      "cited_version_ids" => Array(object.fetch("cited_version_ids", [])).map(&:to_s)
    }
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def query_scalar(sql)
    stdout, stderr, status = Open3.capture3(*psql_args, "-c", sql)
    raise Error, stderr.strip unless status.success?
    stdout.strip
  end

  def query_json(sql)
    wrapped = "SELECT COALESCE(json_agg(row_to_json(q)), '[]'::json)::text FROM (#{sql}) q"
    stdout, stderr, status = Open3.capture3(*psql_args, "-c", wrapped)
    raise Error, stderr.strip unless status.success?
    JSON.parse(stdout.strip.empty? ? "[]" : stdout.strip)
  rescue JSON::ParserError => error
    raise Error, "global database returned invalid JSON: #{error.message}"
  end

  def psql_args
    [@psql, "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end
end

GlobalConversationRetriever = ConversationRetriever unless defined?(GlobalConversationRetriever)

# Personal lexical retrieval adapter.  Kept separate from the global class to
# make the two physical stores explicit in dependency injection and tests.
class PersonalConversationRetriever
  def initialize(store: nil, global_retriever: nil, **store_options)
    @store = store || PersonalMemoryStore.new(**store_options)
    @global_retriever = global_retriever
  end

  attr_reader :store

  def search(query:, subject_key: nil, limit: ConversationRetriever::DEFAULT_LIMIT)
    rows = @store.search(query: query, subject_key: subject_key, limit: limit)
    return rows unless @global_retriever && @global_retriever.respond_to?(:resolve_version_ids)
    refs = rows.flat_map { |row| Array(row["evidence_version_ids"]) }.map(&:to_s).uniq
    resolved = @global_retriever.resolve_version_ids(refs)
    rows.map do |row|
      references = Array(row["evidence_version_ids"])
      row.merge("evidence_resolution" => references.map do |version_id|
        { "version_id" => version_id, "status" => resolved.include?(version_id.to_s) ? "resolved" : "unresolved" }
      end)
    end
  end
end

ConversationPersonalRetriever = PersonalConversationRetriever unless defined?(ConversationPersonalRetriever)
