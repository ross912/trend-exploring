# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/report_window_contract"

class ReportWindowContractTest < Minitest::Test
  WINDOWS = [
    { id: "morning", start: "2026-08-07T19:00:00+08:00", end: "2026-08-08T08:00:00+08:00" },
    { id: "evening", start: "2026-08-08T08:00:00+08:00", end: "2026-08-08T19:00:00+08:00" },
    { id: "next_morning", start: "2026-08-08T19:00:00+08:00", end: "2026-08-09T08:00:00+08:00" }
  ].freeze

  def test_half_open_boundaries_assign_exactly_once
    assert_equal "evening", M2::ReportWindowContract.assign("2026-08-08T08:00:00+08:00", WINDOWS)
    assert_equal "morning", M2::ReportWindowContract.assign("2026-08-07T19:00:00+08:00", WINDOWS)
    assert_equal "next_morning", M2::ReportWindowContract.assign("2026-08-08T19:00:00+08:00", WINDOWS)
    assert_raises(M2::ReportWindowContract::Error) { M2::ReportWindowContract.assign("2026-08-09T08:00:00+08:00", WINDOWS) }
  end

  def test_overlapping_windows_are_rejected
    assert_raises(M2::ReportWindowContract::Error) do
      M2::ReportWindowContract.validate_windows!(WINDOWS + [{ id: "overlap", start: "2026-08-08T18:00:00+08:00", end: "2026-08-08T20:00:00+08:00" }])
    end
  end

  def test_gapped_windows_are_rejected
    gapped = [WINDOWS.first, WINDOWS.last.merge(start: "2026-08-08T09:00:00+08:00")]
    assert_raises(M2::ReportWindowContract::Error) { M2::ReportWindowContract.validate_windows!(gapped) }
  end

  def test_late_version_is_processing_backfill
    result = M2::ReportWindowContract.classify_processing(
      nominal_window: WINDOWS.first, version_available_at: "2026-08-08T08:03:00+08:00", actual_window_id: "evening"
    )
    assert_equal "PROCESSING_BACKFILL", result.fetch("reasonCode")
    assert_equal "evening", result.fetch("actualWindowId")
  end
end
