#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../lib/local_radar_store"

root = File.expand_path("../..", __dir__)
psql = ENV.fetch("LOCAL_PSQL", "/private/tmp/pg15-build-20260808/install/bin/psql")
createdb = ENV.fetch("LOCAL_CREATEDB", File.join(File.dirname(psql), "createdb"))
host = ENV.fetch("LOCAL_PGHOST", "/private/tmp/m1-pg-socket-20260808")
port = ENV.fetch("LOCAL_PGPORT", "55432")
user = ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
database = ENV.fetch("LOCAL_PGDATABASE", "trend_exploring_local")

def run!(args)
  stdout, stderr, status = Open3.capture3(*args)
  abort stderr unless status.success?
  stdout
end

literal = "'#{database.gsub("'", "''")}'"
exists = run!([psql, "-XAt", "-h", host, "-p", port, "-U", user, "-d", "postgres", "-c", "SELECT 1 FROM pg_database WHERE datname = #{literal}"]).strip == "1"
run!([createdb, "-h", host, "-p", port, "-U", user, database]) unless exists
run!([psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", database, "-f", File.join(root, "schema/postgres/011_local_radar.sql")])

store = LocalRadarStore.new(psql: psql, host: host, port: port, database: database, user: user)
store.reset_demo!
puts JSON.pretty_generate(store.seed_demo!)
