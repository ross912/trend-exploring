# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"

class ReportSummaryStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_summary_migration_declares_append_only_tables_and_terminal_states
    sql = File.read(File.join(ROOT, "schema/postgres/014_local_report_summary.sql"))
    assert_includes sql, "CREATE TABLE IF NOT EXISTS local_report_summary_run"
    assert_includes sql, "CREATE TABLE IF NOT EXISTS local_report_summary_artifact"
    assert_includes sql, "CHECK (state IN ('running', 'succeeded', 'failed', 'blocked'))"
    assert_includes sql, "local_report_summary_artifact_immutable_trigger"
  end

  def test_input_hash_changes_with_ordered_placement_metadata
    first = { "edition_id" => "edition-1", "placements" => [{ "version_id" => "v1" }, { "version_id" => "v2" }] }
    second = first.merge("placements" => first.fetch("placements").reverse)
    refute_equal Digest::SHA256.hexdigest(JSON.generate(first)), Digest::SHA256.hexdigest(JSON.generate(second))
  end
end
