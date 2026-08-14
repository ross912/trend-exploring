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
      translations.each { |translation| insert_and_verify!(translation_sql(translation), translation_readback_sql(translation), translation) }
      mappings.each { |mapping| insert_and_verify!(mapping_sql(mapping), mapping_readback_sql(mapping), mapping) }
      candidates.each { |candidate| insert_and_verify!(candidate_sql(candidate), candidate_readback_sql(candidate), candidate) }
    end
    candidates.empty? ? [] : read_candidates(ids: candidates.map { |candidate| candidate.fetch("candidate_id") })
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

  # Read-only operational metadata for the public endpoint.  A missing
  # candidate row is not interpreted as "no change": the denominator records
  # how many successful translation inputs were eligible and how many mapping
  # or candidate rows were actually persisted.  Mapping itself remains an
  # explicit, separately scheduled action (default dry-run).
  def mapping_denominator
    eligible = translation_mapping_inputs(limit: 10_000).length
    mapped = query("SELECT COUNT(*) FROM local_multilingual_concept_mapping").fetch(0).to_i
    candidate_rows = query("SELECT COUNT(*) FROM local_multilingual_participation_candidate").fetch(0).to_i
    # psql's unaligned output omits a NULL-only row after the adapter strips
    # blank lines.  An empty database is a valid `not_run` state, so do not
    # turn that absence of a timestamp into an IndexError/HTTP 500.
    latest = query("SELECT MAX(created_at)::text FROM local_multilingual_participation_candidate").fetch(0, "").to_s
    run_status = (mapped.positive? || candidate_rows.positive?) ? "evaluated" : "not_run"
    {
      "status" => run_status,
      "run" => {
        "status" => run_status,
        "mode" => ENV.fetch("LOCAL_CONCEPT_MAPPING_MODE", "dry_run"),
        "persisted" => mapped.positive?,
        "latest_candidate_created_at" => latest.empty? ? nil : latest,
        "reason" => (run_status == "not_run" ? "no persisted concept mapping run; empty is not evidence of no change" : nil)
      }.compact,
      "examined_count" => eligible,
      "mapped_count" => mapped,
      "candidate_count" => candidate_rows,
      "denominator" => {
        "eligible_translation_inputs" => eligible,
        "mapped_source_versions" => mapped,
        "candidate_rows" => candidate_rows
      }
    }
  rescue ArgumentError, TypeError => error
    raise Error, "invalid multilingual mapping denominator: #{error.message}"
  end

  # Return immutable source versions paired with successful metadata
  # translations. The join is deliberately strict: a translation without a
  # succeeded run/prompt version or whose original hash no longer matches the
  # source version is not eligible for concept mapping.
  def translation_mapping_inputs(limit: 20)
    query(<<~SQL).map do |row|
      WITH succeeded_runs AS (
        SELECT source_version_id, item_key, source_content_hash, target_language, provider, model,
               MIN(prompt_version) AS prompt_version
          FROM local_metadata_translation_run
         WHERE state = 'succeeded'
         GROUP BY source_version_id, item_key, source_content_hash, target_language, provider, model
         HAVING COUNT(*) = 1
      )
      SELECT t.artifact_id, t.source_version_id, t.item_key, t.source_language,
             t.target_language, t.original_content_hash, t.provider, t.model,
             r.prompt_version, t.translated_title, t.translated_summary,
             v.content_hash, v.language, v.publisher_id,
             v.publisher_identity_status, v.query_conditioned::text,
             v.analysis_policy, v.title, v.summary, v.source_url,
             v.published_at::text
        FROM local_translation_artifact t
        JOIN local_source_item_version v
          ON v.version_id = t.source_version_id
         AND v.content_hash = t.original_content_hash
         AND v.language = t.source_language
        JOIN succeeded_runs r
          ON r.source_version_id = t.source_version_id
         AND r.provider = t.provider
         AND r.model = t.model
         AND r.target_language = t.target_language
         AND r.item_key = t.item_key
         AND r.source_content_hash = t.original_content_hash
       WHERE t.status = 'translated'
         AND t.target_language <> t.source_language
         AND btrim(v.publisher_id) <> ''
       ORDER BY v.published_at DESC NULLS LAST, t.artifact_id ASC
       LIMIT #{Integer(limit)}
    SQL
      row_to_mapping_input(row)
    end
  rescue ArgumentError, TypeError => error
    raise Error, "invalid concept mapping limit: #{error.message}"
  end

  private

  def row_to_mapping_input(row)
    keys = %w[artifact_id source_version_id item_key source_language target_language original_content_hash provider model prompt_version translated_title translated_summary content_hash language publisher_id publisher_identity_status query_conditioned analysis_policy title summary source_url published_at]
    value = keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
    value["query_conditioned"] = %w[t true].include?(value.fetch("query_conditioned").downcase)
    value
  end

  # PostgreSQL's ON CONFLICT DO NOTHING is retained for idempotent retries,
  # but a conflict is never silently accepted: the immutable row is read back
  # and compared field-by-field with the incoming manifest.  This prevents a
  # changed provider/prompt/hash from being mistaken for the original result.
  def insert_and_verify!(insert_sql, readback_sql, expected)
    execute(insert_sql)
    rows = query(readback_sql)
    raise Error, "multilingual linkage row was not persisted" if rows.empty?
    actual = JSON.parse(rows.fetch(0))
    expected_payload = expected_readback_payload(expected)
    unless actual == expected_payload
      raise Error, "multilingual linkage conflict payload differs"
    end
    true
  end

  def expected_readback_payload(value)
    if value.key?("artifact_id") && value.key?("translated_text")
      return %w[artifact_id source_version_id item_key source_content_hash source_language target_language provider model prompt_version input_hash output_hash translated_text].to_h { |key| [key, value.fetch(key, "").to_s] }
    end
    if value.key?("mapping_id")
      return {
        "mapping_id" => value.fetch("mapping_id").to_s, "source_version_id" => value.fetch("source_version_id").to_s,
        "item_key" => value.fetch("item_key").to_s, "source_content_hash" => value.fetch("source_content_hash").to_s,
        "source_language" => value.fetch("source_language").to_s, "target_language" => value.fetch("target_language").to_s,
        "target_canonical_label" => value.fetch("target_canonical_label").to_s, "canonical_concept_key" => value.fetch("canonical_concept_key").to_s,
        "relation" => value.fetch("relation").to_s, "translation_artifact_id" => value.fetch("translation_artifact_id", "").to_s,
        "provider" => value.fetch("provider").to_s, "model" => value.fetch("model").to_s, "prompt_version" => value.fetch("prompt_version").to_s,
        "prompt_hash" => value.fetch("prompt_hash").to_s, "input_hash" => value.fetch("input_hash").to_s,
        "output_hash" => value.fetch("output_hash").to_s, "derived_from_translation" => !!value.fetch("derived_from_translation")
      }
    end
    if value.key?("candidate_id")
      return {
        "candidate_id" => value.fetch("candidate_id").to_s, "candidate_status" => value.fetch("candidate_status").to_s,
        "candidate_kind" => value.fetch("candidate_kind").to_s, "canonical_concept_key" => value.fetch("canonical_concept_key").to_s,
        "target_language" => value.fetch("target_language").to_s, "target_canonical_label" => value.fetch("target_canonical_label").to_s,
        "relation_set" => value.fetch("relation_set"), "member_mapping_ids" => value.fetch("member_mapping_ids"),
        "member_version_ids" => value.fetch("member_version_ids"), "languages" => value.fetch("languages"), "publishers" => value.fetch("publishers"),
        "source_language_count" => value.fetch("source_language_count").to_i, "publisher_count" => value.fetch("publisher_count").to_i,
        "member_count" => value.fetch("member_count").to_i, "query_conditioned_version_ids" => value.fetch("query_conditioned_version_ids"),
        "exploration_only_version_ids" => value.fetch("exploration_only_version_ids"), "signal_eligible_version_ids" => value.fetch("signal_eligible_version_ids"),
        "query_conditioned_count" => value.fetch("query_conditioned_count").to_i, "exploration_only_count" => value.fetch("exploration_only_count").to_i,
        "signal_eligible_count" => value.fetch("signal_eligible_count").to_i, "evidence" => value.fetch("evidence"),
        "merge_policy" => value.fetch("merge_policy").to_s, "event_merge_allowed" => false, "claim_merge_allowed" => false
      }
    end
    raise Error, "invalid readback value"
  end

  def translation_readback_sql(translation)
    "SELECT json_build_object('artifact_id',artifact_id,'source_version_id',source_version_id,'item_key',item_key,'source_content_hash',source_content_hash,'source_language',source_language,'target_language',target_language,'provider',provider,'model',model,'prompt_version',prompt_version,'input_hash',input_hash,'output_hash',output_hash,'translated_text',translated_text)::text FROM local_multilingual_translation_input WHERE artifact_id = #{literal(translation.fetch('artifact_id'))}"
  end

  def mapping_readback_sql(mapping)
    "SELECT json_build_object('mapping_id',mapping_id,'source_version_id',source_version_id,'item_key',item_key,'source_content_hash',source_content_hash,'source_language',source_language,'target_language',target_language,'target_canonical_label',target_canonical_label,'canonical_concept_key',canonical_concept_key,'relation',relation,'translation_artifact_id',COALESCE(translation_artifact_id,''),'provider',provider,'model',model,'prompt_version',prompt_version,'prompt_hash',prompt_hash,'input_hash',input_hash,'output_hash',output_hash,'derived_from_translation',derived_from_translation)::text FROM local_multilingual_concept_mapping WHERE mapping_id = #{literal(mapping.fetch('mapping_id'))}"
  end

  def candidate_readback_sql(candidate)
    "SELECT json_build_object('candidate_id',candidate_id,'candidate_status',candidate_status,'candidate_kind',candidate_kind,'canonical_concept_key',canonical_concept_key,'target_language',target_language,'target_canonical_label',target_canonical_label,'relation_set',relation_set,'member_mapping_ids',member_mapping_ids,'member_version_ids',member_version_ids,'languages',languages,'publishers',publishers,'source_language_count',source_language_count,'publisher_count',publisher_count,'member_count',member_count,'query_conditioned_version_ids',query_conditioned_version_ids,'exploration_only_version_ids',exploration_only_version_ids,'signal_eligible_version_ids',signal_eligible_version_ids,'query_conditioned_count',query_conditioned_count,'exploration_only_count',exploration_only_count,'signal_eligible_count',signal_eligible_count,'evidence',evidence,'merge_policy',merge_policy,'event_merge_allowed',event_merge_allowed,'claim_merge_allowed',claim_merge_allowed)::text FROM local_multilingual_participation_candidate WHERE candidate_id = #{literal(candidate.fetch('candidate_id'))}"
  end

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
