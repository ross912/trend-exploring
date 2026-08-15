#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../lib/local_runtime"

psql = ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql"))
host = ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir)
port = ENV.fetch("LOCAL_PGPORT", LocalRuntime.port)
user = ENV.fetch("LOCAL_PGUSER", LocalRuntime.user)
global_db = ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database)
personal_db = ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database)

def query(psql, host, port, user, database, sql)
  stdout, stderr, status = Open3.capture3(psql, "-X", "-A", "-t", "-F", "\t", "-h", host, "-p", port, "-U", user, "-d", database, "-v", "ON_ERROR_STOP=1", "-c", sql)
  raise stderr unless status.success?
  stdout.lines.map { |line| line.chomp.split("\t", -1) }
end

result = { "status" => "ok", "runtime" => { "state_dir" => LocalRuntime.state_dir, "pg_bin" => LocalRuntime.pg_bin, "pgdata" => LocalRuntime.pgdata, "socket" => LocalRuntime.socket_dir, "port" => port }, "server" => nil, "global_database" => nil, "personal_database" => nil, "migrations" => nil, "latest_ingest" => nil, "latest_report" => {}, "weak_signal" => nil, "deepseek" => nil, "fulltext" => nil }
begin
  server = query(psql, host, port, user, "postgres", "SELECT current_setting('server_version'), current_database()")
  result["server"] = { "status" => "ok", "version" => server.dig(0, 0), "database" => server.dig(0, 1) }
rescue StandardError => error
  result["status"] = "degraded"
  result["server"] = { "status" => "error", "error" => error.message }
end

begin
  tables = query(psql, host, port, user, global_db, "SELECT to_regclass('local_radar_snapshot'), to_regclass('local_source_item_version'), to_regclass('local_report_schedule_slot'), to_regclass('weak_signal_run')").fetch(0)
  result["global_database"] = { "status" => "ok", "database" => global_db, "tables" => { "radar" => tables[0], "archive" => tables[1], "reports" => tables[2], "weak_signal" => tables[3] } }
  marker_rows = query(psql, host, port, user, global_db, "SELECT table_name FROM information_schema.tables WHERE table_name IN ('local_collection_batch','local_report_summary_run','weak_signal_run','local_article_archive','local_article_translation_run','local_metadata_translation_run','local_translation_batch_job','local_translation_batch_attempt') ORDER BY table_name")
  result["migrations"] = { "status" => "ok", "applied_relations" => marker_rows.flatten }
  latest_ingest = query(psql, host, port, user, global_db, "SELECT COALESCE(MAX(captured_at)::text, ''), COUNT(*) FROM local_source_capture").fetch(0)
  result["latest_ingest"] = { "last_captured_at" => latest_ingest[0], "capture_count" => latest_ingest[1].to_i }
  %w[morning evening].each do |kind|
    latest_rows = query(psql, host, port, user, global_db, "SELECT scheduled_at::text, state FROM local_report_schedule_slot WHERE kind = '#{kind}' ORDER BY scheduled_at DESC LIMIT 1")
    latest = latest_rows.empty? ? ["", "not_run"] : latest_rows.fetch(0)
    result["latest_report"][kind] = { "scheduled_at" => latest.fetch(0), "state" => latest.fetch(1) }
  end
  weak = query(psql, host, port, user, global_db, "SELECT COALESCE(status, 'not_run'), COALESCE(as_of::text, ''), COUNT(c.run_id) FROM weak_signal_run r LEFT JOIN weak_signal_candidate c ON c.run_id = r.run_id GROUP BY r.run_id, r.status, r.as_of ORDER BY r.as_of DESC LIMIT 1")
  result["weak_signal"] = weak.empty? ? { "status" => "not_run" } : { "status" => weak.dig(0, 0), "as_of" => weak.dig(0, 1), "candidate_count" => weak.dig(0, 2).to_i }
  fulltext = query(psql, host, port, user, global_db, "SELECT (SELECT COUNT(*) FROM local_article_archive), (SELECT COUNT(*) FROM local_article_translation_run WHERE state='pending'), (SELECT COUNT(*) FROM local_article_translation_run WHERE state='succeeded'), (SELECT COUNT(*) FROM local_article_translation_run WHERE state IN ('failed','credential_blocked','budget_blocked')), (SELECT COUNT(*) FROM local_metadata_translation_run WHERE state='pending'), (SELECT COUNT(*) FROM local_metadata_translation_run WHERE state='succeeded'), (SELECT COUNT(*) FROM local_metadata_translation_run WHERE state IN ('failed','credential_blocked','budget_blocked','interrupted'))").fetch(0)
  result["fulltext"] = { "archived_count" => fulltext[0].to_i, "pending_fulltext_translation_count" => fulltext[1].to_i, "fulltext_translated_count" => fulltext[2].to_i, "fulltext_blocked_or_failed_count" => fulltext[3].to_i, "pending_metadata_translation_count" => fulltext[4].to_i, "metadata_translated_count" => fulltext[5].to_i, "metadata_blocked_or_failed_count" => fulltext[6].to_i }
  if marker_rows.flatten.include?("local_translation_batch_job")
    batch = query(psql, host, port, user, global_db, "SELECT COUNT(*) FILTER (WHERE state='running'), COUNT(*) FILTER (WHERE state='succeeded'), COUNT(*) FILTER (WHERE state IN ('failed','blocked','interrupted')) FROM local_translation_batch_job").fetch(0)
    result["translation"] = { "running_jobs" => batch[0].to_i, "succeeded_jobs" => batch[1].to_i, "failed_or_interrupted_jobs" => batch[2].to_i }
  end
  key_path = LocalRuntime.deepseek_secret_file
  result["deepseek"] = { "model" => "deepseek-v4-pro", "credential_status" => (File.file?(key_path) && (File.stat(key_path).mode & 0o777) == 0o600 ? "configured" : "not_configured") }
rescue StandardError => error
  result["status"] = "degraded"
  result["global_database"] = { "status" => "error", "database" => global_db, "error" => error.message }
end

begin
  personal = query(psql, host, port, user, personal_db, "SELECT current_database(), COUNT(*) FROM memory_entry").fetch(0)
  result["personal_database"] = { "status" => "ok", "database" => personal[0], "memory_entry_count" => personal[1].to_i }
rescue StandardError => error
  result["status"] = "degraded"
  result["personal_database"] = { "status" => "error", "database" => personal_db, "error" => error.message }
end
puts JSON.pretty_generate(result)
