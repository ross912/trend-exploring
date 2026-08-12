# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"

class ReportSchemaUpgradeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "local_report_schema_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(6)}"
    run!([psql_bin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    apply!("011_local_radar.sql")
  end

  def teardown
    return unless @database

    raise "refusing to drop database outside test prefix" unless @database.start_with?(PREFIX)

    run!([psql_bin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
  end

  def test_clean_011_012_013_chain_is_idempotent
    apply!("012_breadth_discovery.sql")
    apply!("013_local_report_ledger.sql")
    apply!("013_local_report_ledger.sql")

    assert_equal "1", psql!("SELECT COUNT(*) FROM local_report_ledger_schema_meta WHERE schema_version = '013_local_report_ledger_v1'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_report_schedule_slot'::regclass AND conname = 'local_report_schedule_slot_failure_reason_check'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_reportable_arrival'::regclass AND conname = 'local_reportable_arrival_version_id_fkey'").strip
  end

  def test_empty_early_draft_report_relations_upgrade
    apply!("012_breadth_discovery.sql")
    psql!(<<~SQL)
      CREATE TABLE local_report_schedule_slot (slot_id text);
      CREATE TABLE local_report_publication_attempt (attempt_id text);
      CREATE TABLE local_reportable_arrival (arrival_id text);
      CREATE TABLE local_report_edition (edition_id text);
      CREATE TABLE local_report_item_placement (placement_id text);
    SQL

    apply!("013_local_report_ledger.sql")
    assert_equal "1", psql!("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_report_schedule_slot' AND column_name = 'failure_reason'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_report_item_placement'::regclass AND conname = 'local_report_item_placement_arrival_id_fkey'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM local_report_ledger_schema_meta WHERE schema_version = '013_local_report_ledger_v1'").strip
  end

  def test_nonempty_early_draft_without_marker_is_rejected_before_mutation
    apply!("012_breadth_discovery.sql")
    psql!("CREATE TABLE local_report_schedule_slot (slot_id text); INSERT INTO local_report_schedule_slot VALUES ('retained-draft');")
    result = apply_raw("013_local_report_ledger.sql")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "unsupported early-draft data"
    assert_equal "1", psql!("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'local_report_schedule_slot'").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM local_report_schedule_slot WHERE slot_id = 'retained-draft'").strip
    assert_equal "0", psql!("SELECT COUNT(*) FROM pg_tables WHERE tablename = 'local_report_ledger_schema_meta'").strip
  end

  def test_pseudo_marker_empty_relation_with_columns_and_primary_key_but_missing_fk_check_is_rejected_unchanged
    apply!("012_breadth_discovery.sql")
    psql!(<<~SQL)
      CREATE TABLE local_report_schedule_slot (
        slot_id text PRIMARY KEY,
        kind text,
        timezone text,
        window_start timestamptz,
        window_end timestamptz,
        scheduled_at timestamptz,
        configured_data_cutoff timestamptz,
        config_hash text,
        state text,
        failure_reason text,
        created_at timestamptz,
        updated_at timestamptz
      );
      CREATE TABLE local_report_ledger_schema_meta (schema_version text PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT now());
      INSERT INTO local_report_ledger_schema_meta (schema_version) VALUES ('013_local_report_ledger_v1');
    SQL
    before = psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_report_schedule_slot'::regclass").strip
    result = apply_raw("013_local_report_ledger.sql")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "unsupported early-draft"
    assert_equal "1", psql!("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'local_report_schedule_slot'").strip
    assert_equal before, psql!("SELECT COUNT(*) FROM pg_constraint WHERE conrelid = 'local_report_schedule_slot'::regclass").strip
    assert_equal "1", psql!("SELECT COUNT(*) FROM local_report_ledger_schema_meta WHERE schema_version = '013_local_report_ledger_v1'").strip
  end

  private

  def apply!(file)
    result = apply_raw(file)
    raise "migration #{file} failed: #{result.fetch(:stderr)}" unless result.fetch(:status).success?

    result.fetch(:stdout)
  end

  def apply_raw(file)
    run_raw([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
             "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
  end

  def psql!(sql)
    result = run_raw([psql_bin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
                      "-U", pg_user, "-d", @database, "-c", sql])
    raise "psql failed: #{result.fetch(:stderr)}" unless result.fetch(:status).success?

    result.fetch(:stdout).strip
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
