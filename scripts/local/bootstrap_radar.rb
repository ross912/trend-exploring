#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/local_runtime"

root = File.expand_path("../..", __dir__)
psql = ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql"))
createdb = ENV.fetch("LOCAL_CREATEDB", File.join(File.dirname(psql), "createdb"))
host = ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir)
port = ENV.fetch("LOCAL_PGPORT", LocalRuntime.port)
user = ENV.fetch("LOCAL_PGUSER", LocalRuntime.user)
database = ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database)

def run!(args)
  stdout, stderr, status = Open3.capture3(*args)
  abort stderr unless status.success?
  stdout
end

literal = "'#{database.gsub("'", "''")}'"
exists = run!([psql, "-XAt", "-h", host, "-p", port, "-U", user, "-d", "postgres", "-c", "SELECT 1 FROM pg_database WHERE datname = #{literal}"]).strip == "1"
run!([createdb, "-h", host, "-p", port, "-U", user, database]) unless exists
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/011_local_radar.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/012_breadth_discovery.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/013_local_report_ledger.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/014_local_report_summary.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/015_local_weak_signal.sql")]) if File.file?(File.join(root, "schema/postgres/015_local_weak_signal.sql"))
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/016_local_fulltext_translation.sql")]) if File.file?(File.join(root, "schema/postgres/016_local_fulltext_translation.sql"))
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/017_raw_archive_immutability.sql")]) if File.file?(File.join(root, "schema/postgres/017_raw_archive_immutability.sql"))
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/018_multilingual_concepts.sql")]) if File.file?(File.join(root, "schema/postgres/018_multilingual_concepts.sql"))
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/019_world_change_candidates.sql")]) if File.file?(File.join(root, "schema/postgres/019_world_change_candidates.sql"))
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/020_signal_lifecycle.sql")]) if File.file?(File.join(root, "schema/postgres/020_signal_lifecycle.sql"))

store = LocalRadarStore.new(psql: psql, host: host, port: port, database: database, user: user)
if ENV.fetch("LOCAL_RESET_DEMO", "0") == "1"
  raise "LOCAL_RESET_DEMO is restricted to trend_exploring_local" unless database == "trend_exploring_local"
  store.reset_demo!
end
radar = store.current_radar
radar = store.seed_demo! if radar["snapshot"].nil? && ENV.fetch("LOCAL_SEED_DEMO", "0") == "1"
puts JSON.pretty_generate({ "status" => "ok", "database" => database, "snapshot" => radar["snapshot"],
                            "archive" => store.archive_summary })
