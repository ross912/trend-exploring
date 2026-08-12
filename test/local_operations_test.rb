# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class LocalOperationsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @integration_enabled = ENV["RUN_LOCAL_OPERATIONS_TEST"] == "1"
    @pg_bin = ENV["PG_BIN"]
    @pg_bin ||= "/private/tmp/trend-exploring-postgres15-runtime/bin" if File.executable?("/private/tmp/trend-exploring-postgres15-runtime/bin/pg_ctl")
    @pg_available = @pg_bin && File.executable?(File.join(@pg_bin, "pg_ctl"))
    @tmp = "/tmp/teops-#{Process.pid}"
    FileUtils.mkdir_p(@tmp)
    @port = (55_000 + Process.pid % 500).to_s
    @env = {
      "PG_BIN" => @pg_bin, "LOCAL_STATE_DIR" => @tmp,
      "LOCAL_PSQL" => File.join(@pg_bin.to_s, "psql"),
      "LOCAL_CREATEDB" => File.join(@pg_bin.to_s, "createdb"),
      "LOCAL_PGDATA" => File.join(@tmp, "postgres"), "LOCAL_PGSOCKET" => File.join(@tmp, "socket"),
      "LOCAL_PGPORT" => @port, "LOCAL_PGUSER" => ENV.fetch("USER", "postgres"),
      "LOCAL_PGDATABASE" => "trend_exploring_ops_#{Process.pid}",
      "PERSONAL_PGDATABASE" => "trend_exploring_personal_ops_#{Process.pid}",
      "LOCAL_INGEST_LIVE" => "0"
    }
  end

  def teardown
    return unless @tmp
    pgdata = @env.fetch("LOCAL_PGDATA")
    Open3.capture3(@env, File.join(@pg_bin, "pg_ctl"), "-D", pgdata, "-m", "fast", "stop") if @pg_available && File.file?(File.join(pgdata, "PG_VERSION"))
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def run!(script, *args)
    stdout, stderr, status = Open3.capture3(@env, "ruby", File.join(ROOT, "scripts/local", script), *args)
    raise "#{script} failed: #{stderr}\n#{stdout}" unless status.success?
    stdout
  end

  def start_db!
    stdout, stderr, status = Open3.capture3(@env, "bash", File.join(ROOT, "scripts/local/start_postgres.sh"), "--env")
    raise stderr unless status.success?
    stdout
  end

  def run_shell!(script, *args)
    stdout, stderr, status = Open3.capture3(@env, "bash", File.join(ROOT, "scripts/local", script), *args)
    raise "#{script} failed: #{stderr}\n#{stdout}" unless status.success?
    stdout
  end

  def test_disposable_start_bootstrap_due_idempotency_and_socket_boundary
    return unless @integration_enabled && @pg_available
    start_stdout, start_stderr, start_status = Open3.capture3(@env, "bash", File.join(ROOT, "scripts/local/start_postgres.sh"), "--env")
    raise start_stderr unless start_status.success?
    assert_includes start_stdout, "LOCAL_PGDATA"
    run!("bootstrap_radar.rb")
    run!("bootstrap_personal_memory.rb")
    outside = JSON.parse(run!("run_scheduled_cycle.rb", "--now", "2026-08-13T07:00:00+08:00", "--skip-ingest"))
    assert_equal "not_due", outside.dig("report", "status")
    first = JSON.parse(run!("run_scheduled_cycle.rb", "--now", "2026-08-13T08:05:00+08:00", "--skip-ingest"))
    second = JSON.parse(run!("run_scheduled_cycle.rb", "--now", "2026-08-13T08:14:00+08:00", "--skip-ingest"))
    assert_equal "published", first.dig("report", "status")
    assert_equal first.dig("report", "edition_id"), second.dig("report", "edition_id")
    assert_equal first.dig("weak_signal", "run_id"), second.dig("weak_signal", "run_id")
    psql = File.join(@pg_bin, "psql")
    listen = Open3.capture3(@env, psql, "-XAt", "-h", @env.fetch("LOCAL_PGSOCKET"), "-p", @port, "-U", @env.fetch("LOCAL_PGUSER"), "-d", "postgres", "-c", "SHOW listen_addresses").first.strip
    assert_equal "", listen
    assert_equal "700", File.stat(@env.fetch("LOCAL_PGSOCKET")).mode.to_s(8)[-3, 3]
  end

  def test_backup_restore_manifest_and_cleanup
    return unless @integration_enabled && @pg_available
    start_db!
    run!("bootstrap_radar.rb")
    run!("bootstrap_personal_memory.rb")
    backup_dir = File.join(@tmp, "backup")
    run_shell!("backup_local.sh", backup_dir)
    restore_env = @env.merge("LOCAL_RESTORE_GLOBAL_DATABASE" => "ops_restore_#{Process.pid}", "LOCAL_RESTORE_PERSONAL_DATABASE" => "personal_restore_#{Process.pid}", "LOCAL_RESTORE_CLEANUP" => "1")
    stdout, stderr, status = Open3.capture3(restore_env, "bash", File.join(ROOT, "scripts/local/restore_local.sh"), backup_dir)
    raise stderr unless status.success?
    assert_includes stdout, "verified and cleaned"
  end

  def test_launch_agents_are_valid_and_idempotent
    state = File.join(@tmp, "launch-state")
    env = @env.merge(
      "LOCAL_STATE_DIR" => state,
      "LOCAL_LAUNCH_AGENT_DIR" => File.join(state, "LaunchAgents"),
      "LOCAL_SKIP_LAUNCHCTL" => "1"
    )
    first, stderr, status = Open3.capture3(env, "bash", File.join(ROOT, "scripts/local/install_launch_agent.sh"))
    raise stderr unless status.success?
    second, stderr, status = Open3.capture3(env, "bash", File.join(ROOT, "scripts/local/install_launch_agent.sh"))
    raise stderr unless status.success?
    assert_equal first.lines.map(&:strip), second.lines.map(&:strip)
    paths = second.lines.map(&:strip)
    paths.each { |path| assert File.file?(path) }
    uninstall = Open3.capture3(env, "bash", File.join(ROOT, "scripts/local/uninstall_launch_agent.sh"))
    assert uninstall.last.success?, uninstall[1]
    paths.each { |path| refute File.exist?(path) }
  end
end
