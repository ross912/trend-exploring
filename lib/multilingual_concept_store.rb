# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require_relative "local_runtime"
require_relative "multilingual_concept_linker"

# Narrow PostgreSQL adapter for the 018 append-only concept linkage tables.
# It does not read or mutate LocalRadarStore's current projection.
class MultilingualConceptStore
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

  def save_linkage!(linkage:)
    value = linkage.transform_keys(&:to_s)
    sources = Array(value.fetch("source_versions"))
    translations = Array(value.fetch("translation_inputs"))
    mappings = Array(value.fetch("mappings"))
    candidates = Array(value.fetch("participation_candidates"))
    transaction do
      translations.each { |translation| execute(translation_sql(translation)) }
      mappings.each { |mapping| execute(mapping_sql(mapping)) }
      candidates.each { |candidate| execute(candidate_sql(candidate)) }
    end
    read_candidates(ids: candidates.map { |candidate| candidate.fetch("candidate_id") })
  rescue KeyError, TypeError => error
    raise Error, "invalid multilingual linkage: #{error.message}"
  rescue Error
    raise
  rescue StandardError => error
    raise Error, error.message
  end

  def read_candidates(ids: nil)
    clause = Array(ids).empty? ? "TRUE" : "candidate_id IN (#{Array(ids).map { |id| literal(id) }.join(', ')})"
    query(<<~SQL).map { |row| normalize_candidate(row) }
      SELECT candidate_id, candidate_status, candidate_kind, canonical_concept_key,
             target_language, target_canonical_label, relation_set::text,
             member_mapping_ids::text, member_version_ids::text, languages::text,
             publishers::text, source_language_count, publisher_count, member_count,
             query_conditioned_version_ids::text, exploration_only_version_ids::text,
             signal_eligible_version_ids::text, query_conditioned_count,
             exploration_only_count, signal_eligible_count, evidence::text,
             merge_policy, event_merge_allowed::text, claim_merge_allowed::text,
             created_at::text
        FROM local_multilingual_participation_candidate
       WHERE #{clause}
       ORDER BY created_at ASC, candidate_id ASC
    SQL
  end

  private

  def translation_sql(translation)
    <<~SQL
      INSERT INTO local_multilingual_translation_input
        (artifact_id, source_version_id, item_key, source_content_hash, source_language,
         target_language, provider, model, prompt_version, input_hash, output_hash,
         translated_text)
      VALUES (#{literal(translation.fetch("artifact_id"))}, #{literal(translation.fetch("source_version_id"))},
              #{literal(translation.fetch("item_key"))}, #{literal(translation.fetch("source_content_hash"))},
              #{literal(translation.fetch("source_language"))}, #{literal(translation.fetch("target_language"))},
              #{literal(translation.fetch("provider"))}, #{literal(translation.fetch("model"))},
              #{literal(translation.fetch("prompt_version"))}, #{literal(translation.fetch("input_hash"))},
              #{literal(translation.fetch("output_hash"))}, #{literal(translation.fetch("translated_text", ""))})
      ON CONFLICT (artifact_id) DO NOTHING
    SQL
  end

  def mapping_sql(mapping)
    <<~SQL
      INSERT INTO local_multilingual_concept_mapping
        (mapping_id, source_version_id, item_key, source_content_hash, source_language,
         target_language, target_canonical_label, canonical_concept_key, relation,
         translation_artifact_id, provider, model, prompt_version, prompt_hash,
         input_hash, output_hash, derived_from_translation)
      VALUES (#{literal(mapping.fetch("mapping_id"))}, #{literal(mapping.fetch("source_version_id"))},
              #{literal(mapping.fetch("item_key"))}, #{literal(mapping.fetch("source_content_hash"))},
              #{literal(mapping.fetch("source_language"))}, #{literal(mapping.fetch("target_language"))},
              #{literal(mapping.fetch("target_canonical_label"))}, #{literal(mapping.fetch("canonical_concept_key"))},
              #{literal(mapping.fetch("relation"))}, #{nullable_literal(mapping["translation_artifact_id"])},
              #{literal(mapping.fetch("provider"))}, #{literal(mapping.fetch("model"))},
              #{literal(mapping.fetch("prompt_version"))}, #{literal(mapping.fetch("prompt_hash"))},
              #{literal(mapping.fetch("input_hash"))}, #{literal(mapping.fetch("output_hash"))},
              #{mapping.fetch("derived_from_translation") ? 'TRUE' : 'FALSE'})
      ON CONFLICT (mapping_id) DO NOTHING
    SQL
  end

  def candidate_sql(candidate)
    json = lambda { |key| "#{literal(JSON.generate(candidate.fetch(key)))}::jsonb" }
    <<~SQL
      INSERT INTO local_multilingual_participation_candidate
        (candidate_id, candidate_status, candidate_kind, canonical_concept_key,
         target_language, target_canonical_label, relation_set, member_mapping_ids,
         member_version_ids, languages, publishers, source_language_count,
         publisher_count, member_count, query_conditioned_version_ids,
         exploration_only_version_ids, signal_eligible_version_ids,
         query_conditioned_count, exploration_only_count, signal_eligible_count,
         evidence, merge_policy, event_merge_allowed, claim_merge_allowed)
      VALUES (#{literal(candidate.fetch("candidate_id"))}, #{literal(candidate.fetch("candidate_status"))},
              #{literal(candidate.fetch("candidate_kind"))}, #{literal(candidate.fetch("canonical_concept_key"))},
              #{literal(candidate.fetch("target_language"))}, #{literal(candidate.fetch("target_canonical_label"))},
              #{json.call("relation_set")}, #{json.call("member_mapping_ids")}, #{json.call("member_version_ids")},
              #{json.call("languages")}, #{json.call("publishers")}, #{candidate.fetch("source_language_count")},
              #{candidate.fetch("publisher_count")}, #{candidate.fetch("member_count")},
              #{json.call("query_conditioned_version_ids")}, #{json.call("exploration_only_version_ids")},
              #{json.call("signal_eligible_version_ids")}, #{candidate.fetch("query_conditioned_count")},
              #{candidate.fetch("exploration_only_count")}, #{candidate.fetch("signal_eligible_count")},
              #{json.call("evidence")}, #{literal(candidate.fetch("merge_policy"))}, FALSE, FALSE)
      ON CONFLICT (candidate_id) DO NOTHING
    SQL
  end

  def normalize_candidate(row)
    keys = %w[candidate_id candidate_status candidate_kind canonical_concept_key target_language target_canonical_label relation_set member_mapping_ids member_version_ids languages publishers source_language_count publisher_count member_count query_conditioned_version_ids exploration_only_version_ids signal_eligible_version_ids query_conditioned_count exploration_only_count signal_eligible_count evidence merge_policy event_merge_allowed claim_merge_allowed created_at]
    value = keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
    %w[relation_set member_mapping_ids member_version_ids languages publishers query_conditioned_version_ids exploration_only_version_ids signal_eligible_version_ids evidence].each { |key| value[key] = JSON.parse(value.fetch(key)) }
    %w[source_language_count publisher_count member_count query_conditioned_count exploration_only_count signal_eligible_count].each { |key| value[key] = value.fetch(key).to_i }
    %w[event_merge_allowed claim_merge_allowed].each { |key| value[key] = %w[t true].include?(value.fetch(key).downcase) }
    value
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def nullable_literal(value)
    value.nil? || value.to_s.empty? ? "NULL" : literal(value)
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
    marker = "__multilingual_txn_marker_#{SecureRandom.hex(12)}__"
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
