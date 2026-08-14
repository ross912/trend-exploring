#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "time"

TABLES = {
  "global" => {
    "local_source_capture" => "SELECT capture_id, source_id, captured_at::text, body_hash FROM local_source_capture ORDER BY capture_id",
    "local_source_item_version" => "SELECT version_id, item_key, capture_id, content_hash, created_at::text FROM local_source_item_version ORDER BY version_id",
    "local_radar_snapshot" => "SELECT snapshot_id, revision, comparison_watermark, snapshot_status, created_at::text FROM local_radar_snapshot ORDER BY snapshot_id",
    "local_report_edition" => "SELECT edition_id, slot_id, data_cutoff::text, payload_hash, item_count FROM local_report_edition ORDER BY edition_id",
    "weak_signal_run" => "SELECT run_id, as_of::text, input_hash, detector_version, status, payload_hash FROM weak_signal_run ORDER BY run_id",
    "local_article_archive" => "SELECT archive_id, source_version_id, body_hash, body_chars, archived_at::text FROM local_article_archive ORDER BY archive_id",
    "local_article_translation_run" => "SELECT run_id, archive_id, state, source_body_hash, prompt_tokens, completion_tokens FROM local_article_translation_run ORDER BY run_id",
    "local_metadata_translation_run" => "SELECT run_id, source_version_id, item_key, state, source_content_hash, prompt_tokens, completion_tokens FROM local_metadata_translation_run ORDER BY run_id",
    "local_report_summary_run" => "SELECT run_id, edition_id, idempotency_key, input_hash, provider, model, prompt_version, retry_policy_version, state, started_at::text, finished_at::text, error_reason, created_at::text, updated_at::text FROM local_report_summary_run ORDER BY run_id",
    "local_report_summary_artifact" => "SELECT artifact_id, run_id, edition_id, input_hash, provider, model, prompt_version, overview::text, key_changes::text, uncertainties::text, output_hash, claim_gate_status, provider_receipt_id, generation_attempt_count, repaired, repair_from_receipt_id, created_at::text FROM local_report_summary_artifact ORDER BY artifact_id",
    "provider_response_receipt" => "SELECT receipt_id, run_id, provider, model, prompt_version, exchange_id, canonical_request_hash, raw_response_hash, http_status, request_id, captured_at::text, status, response_available, error_code, error_message, attempt_ordinal, exchange_kind, repair_from_receipt_id, created_at::text FROM provider_response_receipt ORDER BY receipt_id",
    "report_claim_gate_schema_meta" => "SELECT schema_version, installed_at::text FROM report_claim_gate_schema_meta ORDER BY schema_version",
    "report_summary_repair_schema_meta" => "SELECT schema_version, installed_at::text FROM report_summary_repair_schema_meta ORDER BY schema_version"
  },
  "personal" => {
    "memory_entry" => "SELECT memory_entry_id, subject_key, memory_kind, text, recorded_at::text, supersedes_entry_id, status, evidence_version_ids::text, source FROM memory_entry ORDER BY memory_entry_id",
    "conversation_thread" => "SELECT thread_id, owner_principal, created_at::text FROM conversation_thread ORDER BY thread_id",
    "conversation_turn" => "SELECT turn_id, thread_id, predecessor_turn_id, owner_principal, turn_ordinal, as_of::text, private_query_context_hash, answer_status, record_hash, created_at::text FROM conversation_turn ORDER BY turn_id",
    "conversation_query_plan" => "SELECT query_plan_id, turn_id, owner_principal, neutralizer_version, neutral_query, plan_json::text, plan_hash, as_of::text, created_at::text FROM conversation_query_plan ORDER BY query_plan_id",
    "conversation_evidence_snapshot" => "SELECT evidence_snapshot_id, turn_id, owner_principal, as_of::text, snapshot_hash, created_at::text FROM conversation_evidence_snapshot ORDER BY evidence_snapshot_id",
    "conversation_evidence_item" => "SELECT evidence_snapshot_id, ordinal, evidence_scope, evidence_version_id, memory_entry_id, content_hash, evidence_json::text FROM conversation_evidence_item ORDER BY evidence_snapshot_id, ordinal",
    "conversation_provider_receipt" => "SELECT provider_receipt_id, turn_id, attempt_ordinal, provider_name, model, status, request_hash, response_hash, response_json::text, error_code, error_hash, recorded_at::text FROM conversation_provider_receipt ORDER BY provider_receipt_id"
  }
}.freeze

# The local product is upgraded in place.  A backup can therefore be taken
# immediately before an additive migration, when the new relations/columns
# are not present yet.  Keep the feature probes explicit so a missing relation
# is never silently represented as a zero-row table in the manifest.
GLOBAL_021_RELATIONS = %w[provider_response_receipt report_claim_gate_schema_meta].freeze
GLOBAL_021_COLUMNS = %w[claim_gate_status provider_receipt_id].freeze
GLOBAL_022_RELATIONS = %w[report_summary_repair_schema_meta].freeze
GLOBAL_022_COLUMNS = {
  "local_report_summary_run" => %w[retry_policy_version],
  "local_report_summary_artifact" => %w[generation_attempt_count repaired repair_from_receipt_id],
  "provider_response_receipt" => %w[attempt_ordinal exchange_kind repair_from_receipt_id]
}.freeze
PERSONAL_002_RELATIONS = %w[
  conversation_thread
  conversation_turn
  conversation_query_plan
  conversation_evidence_snapshot
  conversation_evidence_item
  conversation_provider_receipt
].freeze
LEGACY_REPORT_SUMMARY_ARTIFACT_QUERY = <<~SQL.freeze
  SELECT artifact_id, run_id, edition_id, input_hash, provider, model,
         prompt_version, overview::text, key_changes::text,
         uncertainties::text, output_hash, created_at::text
    FROM local_report_summary_artifact
   ORDER BY artifact_id
SQL
POST_021_REPORT_SUMMARY_RUN_QUERY = "SELECT run_id, edition_id, idempotency_key, input_hash, provider, model, prompt_version, state, started_at::text, finished_at::text, error_reason, created_at::text, updated_at::text FROM local_report_summary_run ORDER BY run_id".freeze
POST_021_REPORT_SUMMARY_ARTIFACT_QUERY = "SELECT artifact_id, run_id, edition_id, input_hash, provider, model, prompt_version, overview::text, key_changes::text, uncertainties::text, output_hash, claim_gate_status, provider_receipt_id, created_at::text FROM local_report_summary_artifact ORDER BY artifact_id".freeze
POST_021_PROVIDER_RECEIPT_QUERY = "SELECT receipt_id, run_id, provider, model, prompt_version, exchange_id, canonical_request_hash, raw_response_hash, http_status, request_id, captured_at::text, status, response_available, error_code, error_message, created_at::text FROM provider_response_receipt ORDER BY receipt_id".freeze

options = { mode: "verify", manifest: nil, expected_stats: nil, dump_dir: nil, global_database: ENV["LOCAL_PGDATABASE"], personal_database: ENV["PERSONAL_PGDATABASE"], host: ENV["LOCAL_PGHOST"], port: ENV["LOCAL_PGPORT"], user: ENV["LOCAL_PGUSER"], psql: ENV["LOCAL_PSQL"] }
OptionParser.new do |parser|
  parser.on("--write-manifest PATH") { |value| options[:mode] = "write"; options[:manifest] = value }
  parser.on("--write-stats PATH") { |value| options[:mode] = "write_stats"; options[:manifest] = value }
  parser.on("--verify-manifest PATH") { |value| options[:mode] = "verify"; options[:manifest] = value }
  parser.on("--expected-stats PATH") { |value| options[:expected_stats] = value }
  parser.on("--dump-dir DIR") { |value| options[:dump_dir] = value }
  parser.on("--global-database NAME") { |value| options[:global_database] = value }
  parser.on("--personal-database NAME") { |value| options[:personal_database] = value }
  parser.on("--host PATH") { |value| options[:host] = value }
  parser.on("--port PORT") { |value| options[:port] = value }
  parser.on("--user NAME") { |value| options[:user] = value }
  parser.on("--psql PATH") { |value| options[:psql] = value }
end.parse!(ARGV)

%i[manifest global_database personal_database psql].each { |key| raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" if options[key].to_s.empty? }

def shell_sql_literal(value)
  "'#{value.to_s.gsub("'", "''")}'"
end

def shell_ident(value)
  '"' + value.to_s.gsub('"', '""') + '"'
end

def psql!(options, database, sql)
  args = [options.fetch(:psql), "-X", "-A", "-t", "-F", "\t", "-h", options.fetch(:host).to_s, "-p", options.fetch(:port).to_s, "-U", options.fetch(:user).to_s, "-d", database.to_s, "-v", "ON_ERROR_STOP=1", "-c", sql]
  stdout, stderr, status = Open3.capture3(*args)
  raise stderr unless status.success?
  stdout
end

def relation_present?(options, database, relation)
  psql!(options, database, "SELECT to_regclass(#{shell_sql_literal(relation)}) IS NOT NULL").strip == "t"
end

def column_present?(options, database, relation, column)
  sql = <<~SQL
    SELECT EXISTS (
      SELECT 1
        FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = #{shell_sql_literal(relation)}
         AND column_name = #{shell_sql_literal(column)}
    )
  SQL
  psql!(options, database, sql).strip == "t"
end

def schema_states(options)
  global_relation_flags = GLOBAL_021_RELATIONS.to_h { |relation| [relation, relation_present?(options, options.fetch(:global_database), relation)] }
  global_column_flags = GLOBAL_021_COLUMNS.to_h { |column| [column, column_present?(options, options.fetch(:global_database), "local_report_summary_artifact", column)] }
  global_features = global_relation_flags.values + global_column_flags.values
  global_state = if global_features.all?
                   "post_021"
                 elsif global_features.none?
                   "pre_021"
                 else
                   raise "global database has a partial 021 schema; refusing backup verification"
                 end

  if global_state == "post_021"
    global_022_relation_flags = GLOBAL_022_RELATIONS.to_h { |relation| [relation, relation_present?(options, options.fetch(:global_database), relation)] }
    global_022_column_flags = GLOBAL_022_COLUMNS.each_with_object({}) do |(relation, columns), result|
      columns.each { |column| result["#{relation}.#{column}"] = column_present?(options, options.fetch(:global_database), relation, column) }
    end
    global_022_features = global_022_relation_flags.values + global_022_column_flags.values
    global_state = if global_022_features.all?
                     "post_022"
                   elsif global_022_features.none?
                     "post_021"
                   else
                     raise "global database has a partial 022 schema; refusing backup verification"
                   end
  end

  personal_relation_flags = PERSONAL_002_RELATIONS.to_h { |relation| [relation, relation_present?(options, options.fetch(:personal_database), relation)] }
  personal_features = personal_relation_flags.values
  personal_state = if personal_features.all?
                     "post_002"
                   elsif personal_features.none?
                     "pre_002"
                   else
                     raise "personal database has a partial 002 schema; refusing backup verification"
                   end
  { "global" => global_state, "personal" => personal_state }
end

def table_definitions(options, database, role, schema_state)
  definitions = TABLES.fetch(role).dup
  if role == "global" && schema_state == "pre_021"
    definitions["local_report_summary_artifact"] = LEGACY_REPORT_SUMMARY_ARTIFACT_QUERY
    GLOBAL_021_RELATIONS.each { |relation| definitions.delete(relation) }
  elsif role == "global" && schema_state == "post_021"
    definitions["local_report_summary_run"] = POST_021_REPORT_SUMMARY_RUN_QUERY
    definitions["local_report_summary_artifact"] = POST_021_REPORT_SUMMARY_ARTIFACT_QUERY
    definitions["provider_response_receipt"] = POST_021_PROVIDER_RECEIPT_QUERY
    definitions.delete("report_summary_repair_schema_meta")
  elsif role == "personal" && schema_state == "pre_002"
    PERSONAL_002_RELATIONS.each { |relation| definitions.delete(relation) }
  end
  definitions
end

def table_stats(options, database, role, selected_tables = nil, schema_state: nil)
  schema_state ||= schema_states(options).fetch(role)
  definitions = table_definitions(options, database, role, schema_state)
  definitions = definitions.select { |table, _sql| Array(selected_tables).include?(table) } if selected_tables
  definitions.each_with_object({}) do |(table, sql), result|
    present = psql!(options, database, "SELECT to_regclass(#{shell_sql_literal(table)}) IS NOT NULL").strip == "t"
    raise "#{role} database #{database} is missing table #{table}" unless present
    result[table] = { "count" => psql!(options, database, "SELECT COUNT(*) FROM #{shell_ident(table)}").strip.to_i,
                      "sha256" => Digest::SHA256.hexdigest(psql!(options, database, sql)) }
  end
end

def stats_for(options)
  states = schema_states(options)
  stats = {
    "global" => table_stats(options, options.fetch(:global_database), "global", schema_state: states.fetch("global")),
    "personal" => table_stats(options, options.fetch(:personal_database), "personal", schema_state: states.fetch("personal"))
  }
  [states, stats]
end

def inferred_schema_states(table_stats)
  global_tables = table_stats.fetch("global", {}).keys
  personal_tables = table_stats.fetch("personal", {}).keys
  {
    "global" => if GLOBAL_022_RELATIONS.all? { |relation| global_tables.include?(relation) }
                  "post_022"
                elsif GLOBAL_021_RELATIONS.all? { |relation| global_tables.include?(relation) }
                  "post_021"
                else
                  "pre_021"
                end,
    "personal" => (PERSONAL_002_RELATIONS.all? { |relation| personal_tables.include?(relation) } ? "post_002" : "pre_002")
  }
end

def dump_stats(dump_dir, manifest)
  return {} if dump_dir.to_s.empty?
  manifest.fetch("dump_files").each_with_object({}) do |(role, filename), result|
    path = File.join(dump_dir, filename)
    raise "missing dump #{path}" unless File.file?(path)
    result[role] = { "filename" => filename, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
  end
end

if options.fetch(:mode) == "write_stats"
  states, stats = stats_for(options)
  payload = { "schema_state" => states, "table_stats" => stats }
  File.write(options.fetch(:manifest), JSON.pretty_generate(payload) + "\n")
  puts JSON.pretty_generate({ "status" => "written_stats", "path" => options.fetch(:manifest), "schema_state" => states, "table_stats" => stats })
elsif options.fetch(:mode) == "write"
  states, stats = stats_for(options)
  if options[:expected_stats]
    expected = JSON.parse(File.read(options[:expected_stats]))
    expected_states = expected["schema_state"] || inferred_schema_states(expected)
    expected_stats = expected["table_stats"] || expected
    raise "live database schema changed during backup; retry" unless states == expected_states
    raise "live database changed during backup; retry" unless stats == expected_stats
  end
  manifest = { "manifest_version" => 1, "generated_at" => Time.now.utc.iso8601(6), "global_database" => options.fetch(:global_database), "personal_database" => options.fetch(:personal_database), "dump_files" => { "global" => "global.dump", "personal" => "personal.dump" }, "schema_state" => states, "table_stats" => stats }
  manifest["dump_stats"] = dump_stats(options[:dump_dir], manifest) unless options[:dump_dir].to_s.empty?
  File.write(options.fetch(:manifest), JSON.pretty_generate(manifest) + "\n")
  puts JSON.pretty_generate({ "status" => "written", "manifest" => options.fetch(:manifest), "schema_state" => states, "table_stats" => manifest.fetch("table_stats"), "dump_stats" => manifest.fetch("dump_stats", {}) })
else
  manifest = JSON.parse(File.read(options.fetch(:manifest)))
  raise "unsupported manifest version" unless manifest.fetch("manifest_version") == 1
  raise "dump hash mismatch" unless options[:dump_dir].to_s.empty? || dump_stats(options[:dump_dir], manifest) == manifest.fetch("dump_stats")
  expected_schema_state = manifest["schema_state"] || inferred_schema_states(manifest.fetch("table_stats"))
  actual_schema_state = schema_states(options)
  raise "restored database schema state mismatch" unless actual_schema_state == expected_schema_state
  manifest_stats = manifest.fetch("table_stats")
  actual = {
    "global" => table_stats(options, options.fetch(:global_database), "global", manifest_stats.fetch("global").keys, schema_state: actual_schema_state.fetch("global")),
    "personal" => table_stats(options, options.fetch(:personal_database), "personal", manifest_stats.fetch("personal").keys, schema_state: actual_schema_state.fetch("personal"))
  }
  raise "restored table counts/hashes mismatch" unless actual == manifest_stats
  puts JSON.pretty_generate({ "status" => "verified", "manifest" => options.fetch(:manifest), "schema_state" => actual_schema_state, "table_stats" => actual })
end
