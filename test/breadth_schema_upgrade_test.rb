# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"

class BreadthSchemaUpgradeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "trend_exploring_schema_upgrade_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([psql_bin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    run!([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/011_local_radar.sql")])
  end

  def teardown
    run!([psql_bin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_empty_early_draft_relations_upgrade_and_rerun
    sql = <<~SQL
      CREATE TABLE local_collection_batch (batch_id text);
      CREATE TABLE local_collection_batch_source (batch_id text, source_id text);
      CREATE TABLE local_source_fetch_attempt (attempt_id text, batch_id text, source_id text, outcome text, item_count integer, capture_id text NOT NULL);
      CREATE TABLE local_radar_exploration_item (exploration_item_id text, snapshot_id text, batch_id text, version_id text);
    SQL
    psql!(sql)
    apply_012!
    apply_012!
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_source_fetch_attempt'::regclass AND conname = 'local_source_fetch_attempt_batch_source_fkey'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_radar_exploration_item'::regclass AND conname = 'local_radar_exploration_item_snapshot_version_key'").strip
  end

  def test_nonempty_ambiguous_draft_fails_before_mutation
    psql!("CREATE TABLE local_collection_batch (batch_id text); INSERT INTO local_collection_batch VALUES ('ambiguous');")
    result = run_raw([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/012_breadth_discovery.sql")])
    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "unsupported early-draft data"
    assert_equal "1", psql!("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_collection_batch'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM local_collection_batch").strip
  end

  private

  def apply_012!
    run!([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres/012_breadth_discovery.sql")])
  end

  def psql!(sql)
    run!([psql_bin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-c", sql])
  end

  def run!(args)
    result = run_raw(args)
    raise "command failed: #{result.fetch(:stderr)}" unless result.fetch(:status).success?
    result.fetch(:stdout)
  end

  def run_raw(args)
    stdout, stderr, status = Open3.capture3(*args)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def psql_bin(name)
    File.join(ENV.fetch("LOCAL_PSQL", "/private/tmp/trend-exploring-postgres15-runtime/bin/psql").sub(/\/psql\z/, ""), name)
  end

  def pg_host
    ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket")
  end

  def pg_port
    ENV.fetch("LOCAL_PGPORT", "55433")
  end

  def pg_user
    ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
  end
end
