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
    "local_metadata_translation_run" => "SELECT run_id, source_version_id, item_key, state, source_content_hash, prompt_tokens, completion_tokens FROM local_metadata_translation_run ORDER BY run_id"
  },
  "personal" => {
    "memory_entry" => "SELECT memory_entry_id, subject_key, memory_kind, text, recorded_at::text, supersedes_entry_id, status, evidence_version_ids::text, source FROM memory_entry ORDER BY memory_entry_id"
  }
}.freeze

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

def table_stats(options, database, role, selected_tables = nil)
  definitions = TABLES.fetch(role)
  definitions = definitions.select { |table, _sql| Array(selected_tables).include?(table) } if selected_tables
  definitions.each_with_object({}) do |(table, sql), result|
    present = psql!(options, database, "SELECT to_regclass(#{shell_sql_literal(table)}) IS NOT NULL").strip == "t"
    raise "#{role} database #{database} is missing table #{table}" unless present
    result[table] = { "count" => psql!(options, database, "SELECT COUNT(*) FROM #{shell_ident(table)}").strip.to_i,
                      "sha256" => Digest::SHA256.hexdigest(psql!(options, database, sql)) }
  end
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
  stats = { "global" => table_stats(options, options.fetch(:global_database), "global"), "personal" => table_stats(options, options.fetch(:personal_database), "personal") }
  File.write(options.fetch(:manifest), JSON.pretty_generate(stats) + "\n")
  puts JSON.pretty_generate({ "status" => "written_stats", "path" => options.fetch(:manifest), "table_stats" => stats })
elsif options.fetch(:mode) == "write"
  stats = { "global" => table_stats(options, options.fetch(:global_database), "global"), "personal" => table_stats(options, options.fetch(:personal_database), "personal") }
  if options[:expected_stats]
    expected = JSON.parse(File.read(options[:expected_stats]))
    raise "live database changed during backup; retry" unless stats == expected
  end
  manifest = { "manifest_version" => 1, "generated_at" => Time.now.utc.iso8601(6), "global_database" => options.fetch(:global_database), "personal_database" => options.fetch(:personal_database), "dump_files" => { "global" => "global.dump", "personal" => "personal.dump" }, "table_stats" => stats }
  manifest["dump_stats"] = dump_stats(options[:dump_dir], manifest) unless options[:dump_dir].to_s.empty?
  File.write(options.fetch(:manifest), JSON.pretty_generate(manifest) + "\n")
  puts JSON.pretty_generate({ "status" => "written", "manifest" => options.fetch(:manifest), "table_stats" => manifest.fetch("table_stats"), "dump_stats" => manifest.fetch("dump_stats", {}) })
else
  manifest = JSON.parse(File.read(options.fetch(:manifest)))
  raise "unsupported manifest version" unless manifest.fetch("manifest_version") == 1
  raise "dump hash mismatch" unless options[:dump_dir].to_s.empty? || dump_stats(options[:dump_dir], manifest) == manifest.fetch("dump_stats")
  actual = {
    "global" => table_stats(options, options.fetch(:global_database), "global", manifest.fetch("table_stats").fetch("global").keys),
    "personal" => table_stats(options, options.fetch(:personal_database), "personal", manifest.fetch("table_stats").fetch("personal").keys)
  }
  raise "restored table counts/hashes mismatch" unless actual == manifest.fetch("table_stats")
  puts JSON.pretty_generate({ "status" => "verified", "manifest" => options.fetch(:manifest), "table_stats" => actual })
end
