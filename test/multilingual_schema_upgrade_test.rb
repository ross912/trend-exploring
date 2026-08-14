# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"

class MultilingualSchemaUpgradeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "multilingual_schema_upgrade_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([pgbin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    apply!("011_local_radar.sql")
    apply!("012_breadth_discovery.sql")
  end

  def teardown
    run!([pgbin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_empty_early_draft_relation_is_rejected_before_018_mutation
    psql!("CREATE TABLE local_multilingual_translation_input (artifact_id text PRIMARY KEY);")
    result = apply_raw("018_multilingual_concepts.sql")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "unsupported early-draft data"
    assert_equal "1", psql!("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_multilingual_translation_input'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_multilingual_translation_input'::regclass AND contype = 'p'").strip
    assert_equal "0", psql!("SELECT COUNT(*) FROM pg_tables WHERE tablename = 'local_multilingual_concept_schema_meta'").strip
    assert_equal "0", psql!("SELECT COUNT(*) FROM pg_tables WHERE tablename = 'local_multilingual_concept_mapping'").strip
  end

  private

  def apply!(file)
    result = apply_raw(file)
    raise "migration #{file} failed: #{result.fetch(:stderr)}" unless result.fetch(:status).success?
    result.fetch(:stdout)
  end

  def apply_raw(file)
    run_raw([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
             "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
  end

  def psql!(sql)
    result = run_raw([pgbin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
                      "-U", pg_user, "-d", @database, "-c", sql])
    raise "psql failed: #{result.fetch(:stderr)}" unless result.fetch(:status).success?
    result.fetch(:stdout)
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

  def pgbin(name)
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
