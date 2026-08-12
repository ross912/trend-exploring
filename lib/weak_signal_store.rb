# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "time"
require_relative "weak_signal_detector"
require_relative "local_runtime"

# PostgreSQL adapter for the immutable weak-signal run/candidate tables.
# Input rows are read from local_source_item_version plus its frozen registry
# contract; publication is one serializable transaction and never partially
# commits a candidate set.
class WeakSignalStore
  class Error < StandardError; end

  attr_reader :psql, :host, :port, :database, :user

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user))
    @psql = psql
    @host = host
    @port = port
    @database = database
    @user = user
    @transaction_io = nil
  end

  def input_items(as_of:, limit: nil)
    ending = parse_time(as_of)
    cutoff = literal(ending.iso8601(6))
    limit_sql = limit ? " LIMIT #{Integer(limit)}" : ""
    rows = query(<<~SQL)
      SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name,
             v.language, v.region, v.publisher_name, v.publisher_url, v.publisher_id,
             v.publisher_identity_status, v.source_kind, v.query_conditioned::text,
             v.analysis_policy, v.discovery_basis, v.locale_tag, v.title, v.summary,
             v.source_url, v.published_at::text, v.created_at::text, v.fetched_at::text,
             v.captured_at::text, r.enabled::text AS registry_enabled,
             r.analysis_policy AS registry_analysis_policy,
             r.discovery_basis AS registry_discovery_basis,
             r.locale_tag AS registry_locale_tag
        FROM local_source_item_version v
        JOIN local_source_registry r ON r.source_id = v.source_id
       WHERE r.enabled
         AND v.analysis_policy = 'signal_eligible'
         AND v.created_at <= #{cutoff}
       ORDER BY v.created_at ASC, v.version_id ASC
       #{limit_sql}
    SQL
    rows.map do |row|
      item = row_to_hash(row, %w[version_id item_key capture_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind query_conditioned analysis_policy discovery_basis locale_tag title summary source_url published_at created_at fetched_at captured_at registry_enabled registry_analysis_policy registry_discovery_basis registry_locale_tag])
      item["query_conditioned"] = truthy?(item.fetch("query_conditioned"))
      item["registry_enabled"] = truthy?(item.fetch("registry_enabled"))
      item["analysis_policy"] = item.fetch("registry_analysis_policy") if item.fetch("analysis_policy").empty?
      item["discovery_basis"] = item.fetch("registry_discovery_basis") if item.fetch("discovery_basis").empty?
      item["locale_tag"] = item.fetch("registry_locale_tag") if item.fetch("locale_tag").empty?
      item.delete("registry_analysis_policy")
      item.delete("registry_discovery_basis")
      item.delete("registry_locale_tag")
      item
    end
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  alias read_input input_items
  alias signal_input_items input_items

  def publish!(run:, candidates:)
    normalized_run = normalize_run(run)
    normalized_candidates = normalize_candidates(candidates, run_status: normalized_run.fetch("status"))
    payload = { "run" => normalized_run, "candidates" => normalized_candidates }
    payload_hash = Digest::SHA256.hexdigest(JSON.generate(payload))
    normalized_run["payload_hash"] = payload_hash

    transaction do
      existing = query(<<~SQL)
        SELECT run_id, as_of::text, recent_window_hours, prior_window_days,
               prior_bucket_count, input_cutoff::text, input_hash, detector_version,
               status, payload_hash
          FROM weak_signal_run WHERE run_id = #{literal(normalized_run.fetch("run_id"))}
      SQL
      if existing.any?
        row = row_to_hash(existing.fetch(0), %w[run_id as_of recent_window_hours prior_window_days prior_bucket_count input_cutoff input_hash detector_version status payload_hash])
        raise Error, "run idempotency payload differs" unless row.fetch("payload_hash") == payload_hash
        existing_result = latest_run(run_id: normalized_run.fetch("run_id"))
        next existing_result
      end

      execute(<<~SQL)
        INSERT INTO weak_signal_run
          (run_id, as_of, recent_window_hours, prior_window_days, prior_bucket_count,
           input_cutoff, input_hash, detector_version, status, payload_hash)
        VALUES (#{literal(normalized_run.fetch("run_id"))}, #{literal(normalized_run.fetch("as_of"))},
                #{normalized_run.fetch("recent_window_hours")}, #{normalized_run.fetch("prior_window_days")},
                #{normalized_run.fetch("prior_bucket_count")}, #{literal(normalized_run.fetch("input_cutoff"))},
                #{literal(normalized_run.fetch("input_hash"))}, #{literal(normalized_run.fetch("detector_version"))},
                #{literal(normalized_run.fetch("status"))}, #{literal(payload_hash)})
      SQL

      normalized_candidates.each do |candidate|
        execute(candidate_insert_sql(normalized_run.fetch("run_id"), candidate))
      end
    end
    latest_run(run_id: normalized_run.fetch("run_id"))
  rescue Error
    raise
  rescue StandardError => error
    raise Error, error.message
  end

  alias publish_run! publish!
  alias save_run! publish!

  def latest_run(run_id: nil)
    clause = run_id ? "WHERE run_id = #{literal(run_id)}" : "WHERE status = 'evaluated'"
    latest_run_for_clause(clause)
  end

  # Additive read for the product surface.  Unlike latest_evaluated, this
  # includes a warming_up run so the UI can distinguish an empty detector from
  # a detector that does not yet have the required baseline.
  def latest_any
    latest_run_for_clause("WHERE TRUE")
  end

  alias read_latest_any latest_any

  def latest_run_for_clause(clause)
    rows = query(<<~SQL)
      SELECT run_id, as_of::text, recent_window_hours, prior_window_days,
             prior_bucket_count, input_cutoff::text, input_hash, detector_version,
             status, payload_hash, created_at::text
        FROM weak_signal_run
       #{clause}
       ORDER BY as_of DESC, created_at DESC, run_id ASC
       LIMIT 1
    SQL
    return nil if rows.empty?

    run = row_to_hash(rows.fetch(0), %w[run_id as_of recent_window_hours prior_window_days prior_bucket_count input_cutoff input_hash detector_version status payload_hash created_at])
    run["recent_window_hours"] = run.fetch("recent_window_hours").to_i
    run["prior_window_days"] = run.fetch("prior_window_days").to_i
    run["prior_bucket_count"] = run.fetch("prior_bucket_count").to_i
    run["candidates"] = query(<<~SQL).map { |row| normalize_stored_candidate(row) }
      SELECT phrase, language, reason_codes::text, counts::text, prior_bucket_counts::text,
             recent_evidence_version_ids::text, prior_evidence_version_ids::text,
             evidence::text, publishers::text, languages::text, locales::text,
             explanation, sort_order
        FROM weak_signal_candidate
       WHERE run_id = #{literal(run.fetch("run_id"))}
       ORDER BY sort_order ASC, phrase ASC, language ASC
    SQL
    run
  end

  alias read_latest latest_run

  def latest_evaluated
    latest_run
  end

  private

  def normalize_run(run)
    value = run.transform_keys(&:to_s)
    required = %w[run_id as_of input_cutoff input_hash detector_version status]
    missing = required.select { |key| value.fetch(key, "").to_s.empty? }
    raise Error, "run is missing #{missing.join(', ')}" unless missing.empty?
    status = value.fetch("status").to_s
    raise Error, "invalid run status" unless %w[warming_up evaluated].include?(status)
    {
      "run_id" => value.fetch("run_id").to_s,
      "as_of" => parse_time(value.fetch("as_of")).iso8601(6),
      "recent_window_hours" => Integer(value.fetch("recent_window_hours", WeakSignalDetector::RECENT_WINDOW_HOURS)),
      "prior_window_days" => Integer(value.fetch("prior_window_days", WeakSignalDetector::PRIOR_WINDOW_DAYS)),
      "prior_bucket_count" => Integer(value.fetch("prior_bucket_count", WeakSignalDetector::PRIOR_BUCKET_COUNT)),
      "input_cutoff" => parse_time(value.fetch("input_cutoff")).iso8601(6),
      "input_hash" => value.fetch("input_hash").to_s,
      "detector_version" => value.fetch("detector_version").to_s,
      "status" => status
    }
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  def normalize_candidates(candidates, run_status:)
    return [] if run_status == "warming_up" && !Array(candidates).empty? && (raise Error, "warming_up run cannot publish candidates")

    Array(candidates).map.with_index do |candidate, index|
      value = candidate.transform_keys(&:to_s)
      reasons = Array(value.fetch("reason_codes", [])).map(&:to_s).uniq.sort
      raise Error, "candidate has no reason code" if reasons.empty?
      raise Error, "unknown reason code" unless (reasons - WeakSignalDetector::REASONS).empty?
      phrase = value.fetch("phrase").to_s
      language = value.fetch("language").to_s
      raise Error, "candidate phrase/language is required" if phrase.empty? || language.empty?
      counts = {
        "recent_publisher_count" => Integer(value.fetch("recent_publisher_count", 0)),
        "prior_publisher_count" => Integer(value.fetch("prior_publisher_count", 0)),
        "recent_observation_count" => Integer(value.fetch("recent_observation_count", 0)),
        "prior_observation_count" => Integer(value.fetch("prior_observation_count", 0)),
        "recent_qualifying_observation_count" => Integer(value.fetch("recent_qualifying_observation_count", 0)),
        "prior_qualifying_observation_count" => Integer(value.fetch("prior_qualifying_observation_count", 0)),
        "query_evidence_count" => Integer(value.fetch("query_evidence_count", 0)),
        "unresolved_evidence_count" => Integer(value.fetch("unresolved_evidence_count", 0))
      }
      counts.each_value { |count| raise Error, "candidate count cannot be negative" if count.negative? }
      evidence = {
        "recent_evidence_count" => Integer(value.fetch("recent_evidence_count", Array(value["recent_evidence_version_ids"]).length)),
        "prior_evidence_count" => Integer(value.fetch("prior_evidence_count", Array(value["prior_evidence_version_ids"]).length)),
        "recent_query_evidence_count" => Integer(value.fetch("recent_query_evidence_count", 0)),
        "prior_query_evidence_count" => Integer(value.fetch("prior_query_evidence_count", 0)),
        "first_created_at" => value["first_created_at"],
        "last_created_at" => value["last_created_at"]
      }
      {
        "phrase" => phrase,
        "language" => language,
        "reason_codes" => reasons,
        "counts" => counts,
        "prior_bucket_counts" => Array(value.fetch("prior_bucket_counts", [])).map { |entry| Integer(entry) },
        "recent_evidence_version_ids" => Array(value.fetch("recent_evidence_version_ids", [])).map(&:to_s).uniq.first(20),
        "prior_evidence_version_ids" => Array(value.fetch("prior_evidence_version_ids", [])).map(&:to_s).uniq.first(20),
        "evidence" => evidence,
        "publishers" => { "all" => Array(value.fetch("publishers", [])).map(&:to_s).uniq.sort,
                           "recent" => Array(value.fetch("recent_publishers", [])).map(&:to_s).uniq.sort,
                           "prior" => Array(value.fetch("prior_publishers", [])).map(&:to_s).uniq.sort,
                           "support" => Array(value.fetch("support_publishers", [])).map(&:to_s).uniq.sort },
        "languages" => { "all" => Array(value.fetch("languages", [])).map(&:to_s).uniq.sort,
                          "recent" => Array(value.fetch("recent_languages", [])).map(&:to_s).uniq.sort,
                          "prior" => Array(value.fetch("prior_languages", [])).map(&:to_s).uniq.sort },
        "locales" => { "all" => Array(value.fetch("locales", [])).map(&:to_s).uniq.sort,
                        "recent" => Array(value.fetch("recent_locales", [])).map(&:to_s).uniq.sort,
                        "prior" => Array(value.fetch("prior_locales", [])).map(&:to_s).uniq.sort },
        "explanation" => value.fetch("explanation").to_s,
        "sort_order" => Integer(value.fetch("sort_order", index))
      }
    end.sort_by { |candidate| [candidate.fetch("sort_order"), candidate.fetch("language"), candidate.fetch("phrase")] }
  rescue ArgumentError, TypeError, KeyError => error
    raise Error, "invalid candidate: #{error.message}"
  end

  def candidate_insert_sql(run_id, candidate)
    <<~SQL
      INSERT INTO weak_signal_candidate
        (run_id, phrase, language, reason_codes, counts, recent_publisher_count,
         prior_publisher_count, recent_observation_count, prior_observation_count,
         prior_bucket_counts, recent_evidence_version_ids, prior_evidence_version_ids,
         evidence, publishers, languages, locales, explanation, sort_order)
      VALUES (#{literal(run_id)}, #{literal(candidate.fetch("phrase"))}, #{literal(candidate.fetch("language"))},
              #{json_literal(candidate.fetch("reason_codes"))}, #{json_literal(candidate.fetch("counts"))},
              #{candidate.dig("counts", "recent_publisher_count")}, #{candidate.dig("counts", "prior_publisher_count")},
              #{candidate.dig("counts", "recent_observation_count")}, #{candidate.dig("counts", "prior_observation_count")},
              #{json_literal(candidate.fetch("prior_bucket_counts"))},
              #{json_literal(candidate.fetch("recent_evidence_version_ids"))}, #{json_literal(candidate.fetch("prior_evidence_version_ids"))},
              #{json_literal(candidate.fetch("evidence"))}, #{json_literal(candidate.fetch("publishers"))},
              #{json_literal(candidate.fetch("languages"))}, #{json_literal(candidate.fetch("locales"))},
              #{literal(candidate.fetch("explanation"))}, #{candidate.fetch("sort_order")})
    SQL
  end

  def normalize_stored_candidate(row)
    value = row_to_hash(row, %w[phrase language reason_codes counts prior_bucket_counts recent_evidence_version_ids prior_evidence_version_ids evidence publishers languages locales explanation sort_order])
    %w[reason_codes counts prior_bucket_counts recent_evidence_version_ids prior_evidence_version_ids evidence publishers languages locales].each { |key| value[key] = JSON.parse(value.fetch(key)) }
    value["sort_order"] = value.fetch("sort_order").to_i
    value
  end

  def parse_time(value)
    (value.is_a?(Time) ? value : Time.parse(value.to_s)).utc
  rescue ArgumentError, TypeError => error
    raise Error, "invalid timestamp: #{error.message}"
  end

  def truthy?(value)
    %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def json_literal(value)
    "#{literal(JSON.generate(value))}::jsonb"
  end

  def row_to_hash(row, keys)
    keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def query(sql)
    return transaction_query(sql) if @transaction_io
    stdout, stderr, status = Open3.capture3(*psql_args + ["-c", sql])
    raise Error, stderr.strip unless status.success?

    stdout.lines(chomp: true).reject(&:empty?)
  end

  def execute(sql)
    query(sql)
    true
  end

  def transaction
    raise Error, "nested transaction is not supported" if @transaction_io

    open_transaction
    begin_transaction
    result = yield
    transaction_query("COMMIT")
    result
  rescue StandardError
    begin
      transaction_query("ROLLBACK") if @transaction_io
    rescue StandardError
      nil
    end
    raise
  ensure
    close_transaction
  end

  def psql_args
    [@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end

  def open_transaction
    @transaction_io = Open3.popen3(*psql_args)
    @transaction_stdin, @transaction_stdout, @transaction_stderr, @transaction_wait_thread = @transaction_io
    @transaction_stdin.sync = true
    @transaction_stdout.sync = true
  end

  def begin_transaction
    transaction_query("BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
  end

  def transaction_query(sql)
    marker = "__weak_signal_txn_marker_#{SecureRandom.hex(12)}__"
    command = sql.to_s.strip
    command = "#{command};" unless command.end_with?(";")
    @transaction_stdin.write("#{command}\nSELECT #{literal(marker)};\n")
    @transaction_stdin.flush
    rows = []
    loop do
      line = @transaction_stdout.gets
      if line.nil?
        error = @transaction_stderr.read.to_s.strip
        raise Error, error.empty? ? "local transaction connection closed" : error
      end
      value = line.chomp
      break if value == marker
      rows << value unless value.empty?
    end
    rows
  end

  def close_transaction
    return unless @transaction_io

    @transaction_stdin.close unless @transaction_stdin.closed?
    @transaction_stdout.close unless @transaction_stdout.closed?
    @transaction_stderr.close unless @transaction_stderr.closed?
    @transaction_wait_thread.value unless @transaction_wait_thread.nil?
  rescue IOError
    nil
  ensure
    @transaction_io = nil
  end
end
