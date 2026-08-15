#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../lib/personal_memory_store"
require_relative "../../lib/local_runtime"

root = File.expand_path("../..", __dir__)
psql = ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql"))
createdb = ENV.fetch("LOCAL_CREATEDB", File.join(File.dirname(psql), "createdb"))
host = ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir)
port = ENV.fetch("LOCAL_PGPORT", LocalRuntime.port)
user = ENV.fetch("LOCAL_PGUSER", LocalRuntime.user)
database = ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database)
global_database = ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database)

def run!(args)
  stdout, stderr, status = Open3.capture3(*args)
  raise stderr unless status.success?
  stdout
end

begin
raise "personal database must differ from LOCAL_PGDATABASE" if database == global_database
literal = "'#{database.gsub("'", "''")}'"
exists = run!([psql, "-XAt", "-h", host, "-p", port, "-U", user, "-d", "postgres", "-c", "SELECT 1 FROM pg_database WHERE datname = #{literal}"]).strip == "1"
run!([createdb, "-h", host, "-p", port, "-U", user, database]) unless exists
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database,
      "-f", File.join(root, "schema/postgres/personal/001_personal_memory.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database,
      "-f", File.join(root, "schema/postgres/personal/002_conversation_ledger.sql")])
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database,
      "-f", File.join(root, "schema/postgres/personal/003_single_owner_auth.sql")])
store = PersonalMemoryStore.new(psql: psql, host: host, port: port, database: database,
                                user: user, global_database: global_database)
puts JSON.generate({ "status" => "ok", "database" => database, "health" => store.health })
rescue StandardError => error
  warn error.message
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
