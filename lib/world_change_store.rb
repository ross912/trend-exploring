# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "time"
require_relative "local_runtime"
require_relative "world_change_detector"

# PostgreSQL adapter for the append-only world-change candidate ledger.
#
# The store keeps the detector's five channel projections and their raw
# version_id lineage. It does not rank, score, predict, or merge candidates.
class WorldChangeStore
  class Error < StandardError; end

  CHANNELS = WorldChangeDetector::CHANNELS
  FORBIDDEN_OUTPUT_KEYS = %w[score confidence prediction forecast probability].freeze
  DEFAULT_PUBLIC_MAX_CANDIDATES = 20
  # Only the frozen v2 detector contract may cross the public read-model
  # boundary. Legacy rows remain available for audit/replay but are always
  # invalidated at the public boundary.
  PRECISION_VALIDATION_REQUIRED_VERSION = WorldChangeDetector::VERSION
  PRECISION_VALIDATION_MANIFEST_HASH = WorldChangeDetector::PRECISION_VALIDATION_MANIFEST_HASH
  PRECISION_VALIDATION_FAILURE_REASON = "precision_validation_failed"
  PUBLIC_EVIDENCE_LIMITS = { "qualifying" => 3, "supporting" => 2, "contradicting" => 2 }.freeze
  PUBLIC_REF_FIELDS = %w[version_id title source_url publisher channel role].freeze
  PUBLIC_TITLE_LIMIT = 320
  PUBLIC_URL_LIMIT = 512
  PUBLIC_PUBLISHER_LIMIT = 200
  PUBLIC_LIST_LIMIT = 50
  PUBLIC_TEXT_LIST_LIMIT = 20
  PUBLIC_TEXT_LIMIT = 512

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

  # Read immutable source versions. Query-conditioned and exploration-only
  # rows are intentionally retained as support evidence; the detector decides
  # whether they can qualify.
  def input_items(as_of:, limit: nil)
    ending = parse_time(as_of)
    limit_sql = limit ? " LIMIT #{Integer(limit)}" : ""
    query(<<~SQL).map do |row|
      SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name,
             v.language, v.region, v.publisher_name, v.publisher_url, v.publisher_id,
             v.publisher_identity_status, v.source_kind, v.query_conditioned::text,
             v.analysis_policy, v.discovery_basis, v.locale_tag, v.title, v.summary,
             v.source_url, v.published_at::text, v.created_at::text, v.fetched_at::text,
             v.captured_at::text, r.enabled::text AS registry_enabled
        FROM local_source_item_version v
        JOIN local_source_registry r ON r.source_id = v.source_id
       WHERE r.enabled
         AND v.published_at IS NOT NULL
         AND v.created_at <= #{literal(ending.iso8601(6))}
       ORDER BY v.created_at ASC, v.version_id ASC
       #{limit_sql}
    SQL
      item = row_to_hash(row, %w[version_id item_key capture_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind query_conditioned analysis_policy discovery_basis locale_tag title summary source_url published_at created_at fetched_at captured_at registry_enabled])
      item["query_conditioned"] = truthy?(item.fetch("query_conditioned"))
      item["registry_enabled"] = truthy?(item.fetch("registry_enabled"))
      item
    end
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  alias read_input input_items

  def publish!(run:, candidates:)
    normalized_run = normalize_run(run)
    normalized_candidates = normalize_candidates(
      candidates,
      run_status: normalized_run.fetch("status"),
      run_detector_version: normalized_run.fetch("detector_version")
    )
    payload = { "run" => normalized_run, "candidates" => normalized_candidates }
    payload_hash = hash_payload(payload)
    normalized_run["payload_hash"] = payload_hash

    result = transaction do
      existing = query(<<~SQL)
        SELECT run_id, as_of::text, input_cutoff::text, input_hash,
               detector_version, status, validated_precision,
               validation_manifest_hash, payload_hash
          FROM world_change_run
         WHERE run_id = #{literal(normalized_run.fetch("run_id"))}
      SQL
      unless existing.empty?
        row = row_to_hash(existing.fetch(0), %w[run_id as_of input_cutoff input_hash detector_version status validated_precision validation_manifest_hash payload_hash])
        raise Error, "run idempotency payload differs" unless row.fetch("payload_hash") == payload_hash

        next latest_run_for_clause("WHERE run_id = #{literal(normalized_run.fetch("run_id"))}")
      end

      execute(<<~SQL)
        INSERT INTO world_change_run
          (run_id, as_of, input_cutoff, input_hash, detector_version, status,
           validated_precision, validation_manifest_hash, payload_hash)
        VALUES (#{literal(normalized_run.fetch("run_id"))}, #{literal(normalized_run.fetch("as_of"))},
                #{literal(normalized_run.fetch("input_cutoff"))}, #{literal(normalized_run.fetch("input_hash"))},
                #{literal(normalized_run.fetch("detector_version"))}, #{literal(normalized_run.fetch("status"))},
                #{normalized_run.fetch("validated_precision") ? "TRUE" : "FALSE"},
                #{nullable_literal(normalized_run.fetch("validation_manifest_hash"))},
                #{literal(payload_hash)})
      SQL

      normalized_candidates.each do |candidate|
        execute(candidate_insert_sql(normalized_run.fetch("run_id"), candidate))
        CHANNELS.each do |channel|
          execute(channel_insert_sql(normalized_run.fetch("run_id"), candidate, channel))
        end
      end
      nil
    end
    result || latest_run(run_id: normalized_run.fetch("run_id"))
  rescue Error
    raise
  rescue StandardError => error
    raise Error, error.message
  end

  alias publish_run! publish!

  def latest_run(run_id: nil)
    clause = run_id ? "WHERE run_id = #{literal(run_id)}" : "WHERE status = 'evaluated'"
    latest_run_for_clause(clause)
  end

  def latest_any
    latest_run_for_clause("WHERE TRUE")
  end

  alias read_latest_any latest_any

  # Bounded public read model. The append-only ledger remains available through
  # latest_any; this projection deliberately removes summaries/bodies and
  # limits references before they cross the HTTP boundary.
  def latest_public(max_candidates: DEFAULT_PUBLIC_MAX_CANDIDATES)
    run = latest_any
    run && public_projection(run, max_candidates: max_candidates)
  end

  def public_projection(run, max_candidates: DEFAULT_PUBLIC_MAX_CANDIDATES)
    limit = Integer(max_candidates)
    raise Error, "public candidate limit must be positive" unless limit.positive?
    value = run.to_h.transform_keys(&:to_s)
    if precision_validation_failed?(value)
      projection = value.reject { |key, _| key == "candidates" }
      projection["status"] = "invalidated"
      projection["candidates"] = []
      projection["reason"] = PRECISION_VALIDATION_FAILURE_REASON
      projection["truncated"] = false
      projection["evidence_boundary"] = public_evidence_boundary(limit)
      return projection
    end
    raw_candidates = Array(value.fetch("candidates", []))
    selected = raw_candidates.first(limit)
    candidates = selected.map { |candidate| public_candidate(candidate) }
    truncated = raw_candidates.length > selected.length || candidates.any? { |candidate| candidate.fetch("truncated") }
    projection = value.reject { |key, _| key == "candidates" }
    projection["candidates"] = candidates
    projection["truncated"] = truncated
    projection["evidence_boundary"] = public_evidence_boundary(limit)
    projection
  rescue ArgumentError, TypeError => error
    raise Error, "invalid public world-change projection: #{error.message}"
  end

  alias read_public latest_public

  def public_boundary(max_candidates: DEFAULT_PUBLIC_MAX_CANDIDATES)
    limit = Integer(max_candidates)
    raise Error, "public candidate limit must be positive" unless limit.positive?
    public_evidence_boundary(limit)
  end

  private

  def precision_validation_failed?(run)
    run.fetch("detector_version", "").to_s != PRECISION_VALIDATION_REQUIRED_VERSION ||
      !truthy?(run.fetch("validated_precision", false)) ||
      run.fetch("validation_manifest_hash", "").to_s != PRECISION_VALIDATION_MANIFEST_HASH
  end

  def latest_run_for_clause(clause)
    rows = query(<<~SQL)
      SELECT run_id, as_of::text, input_cutoff::text, input_hash,
             detector_version, status, validated_precision,
             validation_manifest_hash, payload_hash, created_at::text
        FROM world_change_run
       #{clause}
       ORDER BY as_of DESC, created_at DESC, run_id ASC
       LIMIT 1
    SQL
    return nil if rows.empty?

    run = row_to_hash(rows.fetch(0), %w[run_id as_of input_cutoff input_hash detector_version status validated_precision validation_manifest_hash payload_hash created_at])
    candidates = query(<<~SQL).map { |row| normalize_stored_candidate(row) }
      SELECT candidate_key, label, candidate_status, detector_version,
             qualifying_publisher_ids::text, qualifying_publisher_count,
             qualifying_version_ids::text, channel_count, channels::text,
             evidence_items::text, contradicting_evidence::text,
             missing_channels::text, alternative_explanations::text,
             next_verification::text, query_conditioned_evidence_count,
             exploration_evidence_count, observed_publisher_ids::text,
             first_published_at::text, last_published_at::text,
             analysis_as_of::text, sort_order
        FROM world_change_candidate
       WHERE run_id = #{literal(run.fetch("run_id"))}
       ORDER BY sort_order ASC, candidate_key ASC
    SQL
    channel_rows = query(<<~SQL)
      SELECT candidate_key, channel, version_ids::text, publisher_ids::text,
             evidence::text, supporting_evidence::text, contradicting_evidence::text
        FROM world_change_candidate_channel
       WHERE run_id = #{literal(run.fetch("run_id"))}
       ORDER BY candidate_key ASC, channel ASC
    SQL
    channels_by_candidate = Hash.new { |hash, key| hash[key] = {} }
    channel_rows.each do |row|
      value = row_to_hash(row, %w[candidate_key channel version_ids publisher_ids evidence supporting_evidence contradicting_evidence])
      channels_by_candidate[value.fetch("candidate_key")][value.fetch("channel")] = {
        "version_ids" => parse_json_array(value.fetch("version_ids")),
        "publisher_ids" => parse_json_array(value.fetch("publisher_ids")),
        "evidence" => parse_json_array(value.fetch("evidence")),
        "supporting_evidence" => parse_json_array(value.fetch("supporting_evidence")),
        "contradicting_evidence" => parse_json_array(value.fetch("contradicting_evidence"))
      }
    end
    candidates.each do |candidate|
      stored_channels = channels_by_candidate[candidate.fetch("candidate_key")]
      candidate["channels"] = CHANNELS.to_h do |channel|
        [channel, stored_channels.fetch(channel, candidate.fetch("channels").fetch(channel, empty_channel))]
      end
    end
    run["candidates"] = candidates
    run
  end

  def empty_channel
    { "version_ids" => [], "publisher_ids" => [], "evidence" => [], "supporting_evidence" => [], "contradicting_evidence" => [] }
  end

  def public_candidate(candidate)
    value = candidate.to_h.transform_keys(&:to_s)
    channels = CHANNELS.to_h do |channel|
      raw = (value.fetch("channels", {}) || {}).fetch(channel, empty_channel)
      qualifying = bounded_public_refs(raw.fetch("evidence", []), channel: channel, role: "qualifying", limit: PUBLIC_EVIDENCE_LIMITS.fetch("qualifying"))
      supporting = bounded_public_refs(raw.fetch("supporting_evidence", []), channel: channel, role: "supporting", limit: PUBLIC_EVIDENCE_LIMITS.fetch("supporting"))
      contradicting = bounded_public_refs(raw.fetch("contradicting_evidence", []), channel: channel, role: "contradicting", limit: PUBLIC_EVIDENCE_LIMITS.fetch("contradicting"))
      refs = qualifying + supporting + contradicting
      [channel, {
        "version_ids" => Array(raw.fetch("version_ids", [])).map(&:to_s).uniq.sort,
        "publisher_ids" => Array(raw.fetch("publisher_ids", [])).map(&:to_s).uniq.sort,
        "counts" => { "qualifying" => Array(raw.fetch("evidence", [])).length, "supporting" => Array(raw.fetch("supporting_evidence", [])).length, "contradicting" => Array(raw.fetch("contradicting_evidence", [])).length },
        "evidence" => qualifying,
        "supporting_evidence" => supporting,
        "contradicting_evidence" => contradicting,
        "truncated" => refs.length < (Array(raw.fetch("evidence", [])).length + Array(raw.fetch("supporting_evidence", [])).length + Array(raw.fetch("contradicting_evidence", [])).length)
      }]
    end
    public = value.reject { |key, _| key == "channels" || key == "evidence_items" }
    public["qualifying_publisher_ids"] = Array(value.fetch("qualifying_publisher_ids", [])).map(&:to_s).uniq.sort
    public["qualifying_version_ids"] = Array(value.fetch("qualifying_version_ids", [])).map(&:to_s).uniq.sort
    public["channels"] = channels
    public["counts"] = {
      "qualifying_publishers" => Integer(value.fetch("qualifying_publisher_count", public.fetch("qualifying_publisher_ids").length)),
      "qualifying_versions" => public.fetch("qualifying_version_ids").length,
      "channel_count" => Integer(value.fetch("channel_count", 0)),
      "query_conditioned_evidence" => Integer(value.fetch("query_conditioned_evidence_count", 0)),
      "exploration_evidence" => Integer(value.fetch("exploration_evidence_count", 0)),
      "raw_evidence_items" => Array(value.fetch("evidence_items", [])).length
    }
    public["contradicting_evidence"] = bounded_public_refs(value.fetch("contradicting_evidence", []), channel: "", role: "contradicting", limit: PUBLIC_EVIDENCE_LIMITS.fetch("contradicting"))
    public["contradicting_evidence_count"] = Array(value.fetch("contradicting_evidence", [])).length
    public["missing_channels"] = Array(value.fetch("missing_channels", [])).map(&:to_s).uniq
    public["alternative_explanations"] = bounded_texts(value.fetch("alternative_explanations", []))
    public["next_verification"] = bounded_texts(value.fetch("next_verification", []))
    public["truncated"] = channels.values.any? { |channel| channel.fetch("truncated") } || public.fetch("contradicting_evidence").length < Array(value.fetch("contradicting_evidence", [])).length
    public
  end

  def bounded_public_refs(rows, channel:, role:, limit:)
    normalized = Array(rows).map do |raw|
      value = raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
      version_id = value.fetch("version_id", "").to_s
      next if version_id.empty?
      value.merge("version_id" => version_id)
    end.compact
    # Public refs are item-oriented: several immutable versions of one item
    # collapse to the newest deterministic version, while the ledger retains
    # every version for audit/replay.
    normalized = normalized.group_by do |value|
      value.fetch("item_key", "").to_s.empty? ? value.fetch("version_id") : value.fetch("item_key").to_s
    end.values.map do |versions|
      versions.max_by { |value| [value.fetch("published_at", "").to_s, value.fetch("created_at", "").to_s, value.fetch("version_id")] }
    end.sort_by { |value| [value.fetch("version_id"), value.fetch("item_key", "").to_s] }
    normalized.first(limit).map do |value|
      {
        "version_id" => value.fetch("version_id"),
        "title" => value.fetch("title", "").to_s[0, PUBLIC_TITLE_LIMIT],
        "source_url" => value.fetch("source_url", "").to_s[0, PUBLIC_URL_LIMIT],
        "publisher" => value.fetch("publisher_name", value.fetch("publisher_id", "")).to_s[0, PUBLIC_PUBLISHER_LIMIT],
        "channel" => (value.fetch("channel", channel).to_s.empty? ? channel : value.fetch("channel", channel).to_s),
        "role" => role
      }
    end
  end

  def bounded_texts(values)
    Array(values).map { |value| value.to_s[0, PUBLIC_TEXT_LIMIT] }.reject(&:empty?).uniq.first(PUBLIC_TEXT_LIST_LIMIT)
  end

  def public_evidence_boundary(limit)
    {
      "max_candidates" => limit,
      "per_channel_refs" => PUBLIC_EVIDENCE_LIMITS,
      "ref_fields" => PUBLIC_REF_FIELDS,
      "raw_evidence_items_excluded" => true,
      "summary_body_excluded" => true,
      "note" => "Public refs are bounded lineage pointers; the append-only ledger retains full evidence internally."
    }
  end

  def normalize_run(run)
    value = run.transform_keys(&:to_s)
    required = %w[run_id as_of input_cutoff input_hash detector_version status]
    missing = required.select { |key| value.fetch(key, "").to_s.empty? }
    raise Error, "run is missing #{missing.join(', ')}" unless missing.empty?
    status = value.fetch("status").to_s
    raise Error, "invalid run status" unless %w[warming_up evaluated].include?(status)
    detector_version = value.fetch("detector_version").to_s
    validated_precision = truthy?(value.fetch("validated_precision", false))
    validation_manifest_hash = value.fetch("validation_manifest_hash", "").to_s
    if detector_version == PRECISION_VALIDATION_REQUIRED_VERSION
      raise Error, "v2 run requires validated precision" unless validated_precision
      raise Error, "v2 run validation manifest hash is invalid" unless validation_manifest_hash == PRECISION_VALIDATION_MANIFEST_HASH
    else
      # A legacy version can never be opted into the new public safety gate by
      # sending validated_precision=true.
      validated_precision = false
      validation_manifest_hash = nil
    end
    {
      "run_id" => value.fetch("run_id").to_s,
      "as_of" => parse_time(value.fetch("as_of")).iso8601(6),
      "input_cutoff" => parse_time(value.fetch("input_cutoff")).iso8601(6),
      "input_hash" => value.fetch("input_hash").to_s,
      "detector_version" => detector_version,
      "status" => status,
      "validated_precision" => validated_precision,
      "validation_manifest_hash" => validation_manifest_hash
    }
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  def normalize_candidates(candidates, run_status:, run_detector_version:)
    if run_status == "warming_up" && Array(candidates).any?
      raise Error, "warming_up run cannot publish candidates"
    end
    Array(candidates).map.with_index do |candidate, index|
      value = candidate.transform_keys(&:to_s)
      forbidden = value.keys.map(&:to_s) & FORBIDDEN_OUTPUT_KEYS
      raise Error, "world-change candidate contains forbidden output: #{forbidden.join(', ')}" unless forbidden.empty?
      candidate_key = value.fetch("candidate_key").to_s
      label = value.fetch("label").to_s
      status = value.fetch("candidate_status").to_s
      raise Error, "candidate identity is required" if candidate_key.empty? || label.empty?
      raise Error, "invalid candidate status" unless %w[candidate convergence_candidate].include?(status)
      raise Error, "candidate detector version does not match run" unless value.fetch("detector_version", "").to_s == run_detector_version.to_s

      publisher_ids = Array(value.fetch("qualifying_publisher_ids")).map(&:to_s).reject(&:empty?).uniq.sort
      raise Error, "candidate requires two independent publishers" if publisher_ids.length < 2
      channel_values = CHANNELS.to_h do |channel|
        raw = (value.fetch("channels", {}) || {}).transform_keys(&:to_s).fetch(channel, {})
        [channel, normalize_channel(raw)]
      end
      qualifying_channels = channel_values.count { |_channel, row| !row.fetch("version_ids").empty? }
      channel_count = Integer(value.fetch("channel_count", qualifying_channels))
      raise Error, "candidate channel count is inconsistent" unless channel_count == qualifying_channels
      raise Error, "convergence candidate requires two channels" if status == "convergence_candidate" && channel_count < 2

      {
        "candidate_key" => candidate_key,
        "label" => label,
        "candidate_status" => status,
        "detector_version" => value.fetch("detector_version").to_s,
        "qualifying_publisher_ids" => publisher_ids,
        "qualifying_publisher_count" => publisher_ids.length,
        "qualifying_version_ids" => json_array(value.fetch("qualifying_version_ids", [])),
        "channel_count" => channel_count,
        "channels" => channel_values,
        "evidence_items" => json_array(value.fetch("evidence_items", [])),
        "contradicting_evidence" => json_array(value.fetch("contradicting_evidence", [])),
        "missing_channels" => json_array(value.fetch("missing_channels", [])),
        "alternative_explanations" => json_array(value.fetch("alternative_explanations", [])),
        "next_verification" => json_array(value.fetch("next_verification", [])),
        "query_conditioned_evidence_count" => nonnegative(value.fetch("query_conditioned_evidence_count", 0)),
        "exploration_evidence_count" => nonnegative(value.fetch("exploration_evidence_count", 0)),
        "observed_publisher_ids" => json_array(value.fetch("observed_publisher_ids", [])),
        "first_published_at" => nullable_time(value["first_published_at"]),
        "last_published_at" => nullable_time(value["last_published_at"]),
        "analysis_as_of" => parse_time(value.fetch("analysis_as_of")).iso8601(6),
        "sort_order" => Integer(value.fetch("sort_order", index))
      }
    end.sort_by { |candidate| [candidate.fetch("sort_order"), candidate.fetch("candidate_key")] }
  rescue ArgumentError, TypeError, KeyError => error
    raise Error, "invalid world-change candidate: #{error.message}"
  end

  def normalize_channel(raw)
    value = raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
    {
      "version_ids" => json_array(value.fetch("version_ids", [])),
      "publisher_ids" => json_array(value.fetch("publisher_ids", [])),
      "evidence" => json_array(value.fetch("evidence", [])),
      "supporting_evidence" => json_array(value.fetch("supporting_evidence", [])),
      "contradicting_evidence" => json_array(value.fetch("contradicting_evidence", []))
    }
  end

  def normalize_stored_candidate(row)
    value = row_to_hash(row, %w[candidate_key label candidate_status detector_version qualifying_publisher_ids qualifying_publisher_count qualifying_version_ids channel_count channels evidence_items contradicting_evidence missing_channels alternative_explanations next_verification query_conditioned_evidence_count exploration_evidence_count observed_publisher_ids first_published_at last_published_at analysis_as_of sort_order])
    %w[qualifying_publisher_ids qualifying_version_ids channels evidence_items contradicting_evidence missing_channels alternative_explanations next_verification observed_publisher_ids].each do |key|
      value[key] = JSON.parse(value.fetch(key))
    end
    %w[qualifying_publisher_count channel_count query_conditioned_evidence_count exploration_evidence_count sort_order].each { |key| value[key] = value.fetch(key).to_i }
    value
  rescue JSON::ParserError => error
    raise Error, "stored world-change JSON is invalid: #{error.message}"
  end

  def candidate_insert_sql(run_id, candidate)
    json = ->(key) { json_literal(candidate.fetch(key)) }
    <<~SQL
      INSERT INTO world_change_candidate
        (run_id, candidate_key, label, candidate_status, detector_version,
         qualifying_publisher_ids, qualifying_publisher_count, qualifying_version_ids,
         channel_count, channels, evidence_items, contradicting_evidence,
         missing_channels, alternative_explanations, next_verification,
         query_conditioned_evidence_count, exploration_evidence_count,
         observed_publisher_ids, first_published_at, last_published_at,
         analysis_as_of, sort_order)
      VALUES (#{literal(run_id)}, #{literal(candidate.fetch("candidate_key"))}, #{literal(candidate.fetch("label"))},
              #{literal(candidate.fetch("candidate_status"))}, #{literal(candidate.fetch("detector_version"))},
              #{json.call("qualifying_publisher_ids")}, #{candidate.fetch("qualifying_publisher_count")},
              #{json.call("qualifying_version_ids")}, #{candidate.fetch("channel_count")},
              #{json.call("channels")}, #{json.call("evidence_items")}, #{json.call("contradicting_evidence")},
              #{json.call("missing_channels")}, #{json.call("alternative_explanations")}, #{json.call("next_verification")},
              #{candidate.fetch("query_conditioned_evidence_count")}, #{candidate.fetch("exploration_evidence_count")},
              #{json.call("observed_publisher_ids")}, #{nullable_literal(candidate.fetch("first_published_at"))},
              #{nullable_literal(candidate.fetch("last_published_at"))}, #{literal(candidate.fetch("analysis_as_of"))},
              #{candidate.fetch("sort_order")})
    SQL
  end

  def channel_insert_sql(run_id, candidate, channel)
    row = candidate.fetch("channels").fetch(channel)
    <<~SQL
      INSERT INTO world_change_candidate_channel
        (run_id, candidate_key, channel, version_ids, publisher_ids, evidence,
         supporting_evidence, contradicting_evidence)
      VALUES (#{literal(run_id)}, #{literal(candidate.fetch("candidate_key"))}, #{literal(channel)},
              #{json_literal(row.fetch("version_ids"))}, #{json_literal(row.fetch("publisher_ids"))},
              #{json_literal(row.fetch("evidence"))}, #{json_literal(row.fetch("supporting_evidence"))},
              #{json_literal(row.fetch("contradicting_evidence"))})
    SQL
  end

  def json_array(value)
    array = Array(value)
    array.map { |entry| entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s) : entry }
  end

  def nonnegative(value)
    number = Integer(value)
    raise Error, "count cannot be negative" if number.negative?
    number
  end

  def nullable_time(value)
    value.nil? || value.to_s.empty? ? nil : parse_time(value).iso8601(6)
  end

  def parse_time(value)
    (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
  rescue ArgumentError, TypeError => error
    raise Error, "invalid timestamp: #{error.message}"
  end

  def truthy?(value)
    value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def hash_payload(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def canonical(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.to_h { |key| [key, canonical(value[key] || value[key.to_sym])] }
    when Array
      value.map { |entry| canonical(entry) }
    else
      value
    end
  end

  def json_literal(value)
    "#{literal(JSON.generate(value))}::jsonb"
  end

  def nullable_literal(value)
    value.nil? || value.to_s.empty? ? "NULL" : literal(value)
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def row_to_hash(row, keys)
    keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
  end

  def parse_json_array(value)
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
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
    transaction_query("BEGIN; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
    result = yield
    transaction_query("COMMIT")
    result
  rescue StandardError
    begin transaction_query("ROLLBACK") if @transaction_io; rescue StandardError; end
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

  def transaction_query(sql)
    marker = "__world_change_txn_marker_#{SecureRandom.hex(12)}__"
    command = sql.to_s.strip
    command = "#{command};" unless command.end_with?(";")
    @transaction_stdin.write("#{command}\nSELECT #{literal(marker)};\n")
    @transaction_stdin.flush
    rows = []
    loop do
      line = @transaction_stdout.gets
      raise Error, "local transaction connection closed" if line.nil?
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
    @transaction_wait_thread.value
  rescue IOError
    nil
  ensure
    @transaction_io = nil
  end
end
