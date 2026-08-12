# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require "time"
require_relative "../lib/local_report_ledger"

class LocalReportLedgerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "local_report_ledger_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(6)}"
    run!([psql_bin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql].each do |file|
      run!([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port,
            "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @ledger = LocalReportLedger.new(psql: psql_bin("psql"), host: pg_host, port: pg_port,
                                    database: @database, user: pg_user)
  end

  def teardown
    return unless @database

    # Never allow a test teardown to target the disposable production database.
    raise "refusing to drop database outside test prefix" unless @database.start_with?(PREFIX)

    run!([psql_bin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
  end

  def test_slots_use_asia_shanghai_half_open_windows_utc_and_are_idempotent
    first = @ledger.generate_slots!(date: "2026-08-10")
    second = @ledger.generate_slots!(date: "2026-08-10")

    assert_equal first, second
    assert_equal %w[morning evening], first.map { |slot| slot.fetch("kind") }
    morning, evening = first
    assert_equal "Asia/Shanghai", morning.fetch("timezone")
    assert_equal Time.iso8601("2026-08-09T11:00:00Z"), parse_time(morning.fetch("window_start"))
    assert_equal Time.iso8601("2026-08-10T00:00:00Z"), parse_time(morning.fetch("window_end"))
    assert_equal Time.iso8601("2026-08-10T00:00:00Z"), parse_time(evening.fetch("window_start"))
    assert_equal Time.iso8601("2026-08-10T11:00:00Z"), parse_time(evening.fetch("window_end"))
    assert_equal 2, psql!("SELECT COUNT(*) FROM local_report_schedule_slot").to_i
    assert_equal "2026-08-10 00:00:00", psql!("SELECT scheduled_at AT TIME ZONE 'UTC' FROM local_report_schedule_slot WHERE slot_id = 'report-morning-20260810'").strip
  end

  def test_created_at_controls_nominal_slot_and_publish_scans_unmaterialized_versions
    slots = slots_for("2026-08-10")
    created = "2026-08-09T23:40:00Z" # morning nominal window, regardless of the fake capture/publish times.
    insert_version(item_key: "created-at-item", version_id: "version-created-at", capture_id: "capture-created-at",
                   content_hash: "hash-created-at", created_at: created,
                   captured_at: "2026-08-10T12:00:00Z", published_at: "2026-08-11T00:00:00Z")

    # No explicit materialize call: publication must scan the immutable archive through its cutoff.
    edition = publish(slots.fetch("morning"), key: "created-at-publish")
    assert_equal 1, edition.fetch("item_count").to_i
    latest = @ledger.latest_report(kind: "morning")
    item = latest.fetch("items").fetch(0)
    assert_equal "2026-08-09T23:40:00Z", parse_time(item.fetch("information_arrival_at")).utc.iso8601
    assert_equal slots.fetch("morning").fetch("slot_id"), item.fetch("nominal_slot_id")
    assert_equal "first_seen", item.fetch("arrival_kind")
  end

  def test_same_item_same_hash_is_one_first_seen_and_one_content_update
    slots_for("2026-08-10")
    insert_version(item_key: "item-a", version_id: "version-a1", capture_id: "capture-a1", content_hash: "hash-a",
                   created_at: "2026-08-09T23:10:00Z")
    insert_version(item_key: "item-a", version_id: "version-a2", capture_id: "capture-a2", content_hash: "hash-a",
                   created_at: "2026-08-09T23:20:00Z")
    insert_version(item_key: "item-a", version_id: "version-b", capture_id: "capture-b", content_hash: "hash-b",
                   created_at: "2026-08-09T23:30:00Z")

    @ledger.materialize_arrivals_through!(frontier: "2026-08-10T00:00:00Z")
    rows = @ledger.reportable_arrivals(include_placed: true).select { |row| row.fetch("item_key") == "item-a" }
    assert_equal 2, rows.length
    assert_equal %w[first_seen content_update], rows.sort_by { |row| row.fetch("information_arrival_at") }.map { |row| row.fetch("arrival_kind") }
    assert_equal ["hash-a", "hash-b"], rows.sort_by { |row| row.fetch("information_arrival_at") }.map { |row| row.fetch("content_hash") }
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_reportable_arrival WHERE item_key = 'item-a' AND arrival_kind = 'first_seen'").to_i
  end

  def test_out_of_order_and_concurrent_materialization_keep_one_first_seen_per_item
    slots_for("2026-08-10")
    insert_version(item_key: "ordered-item", version_id: "ordered-early", capture_id: "ordered-capture-early", content_hash: "ordered-a",
                   created_at: "2026-08-09T23:10:00Z")
    insert_version(item_key: "ordered-item", version_id: "ordered-late", capture_id: "ordered-capture-late", content_hash: "ordered-b",
                   created_at: "2026-08-09T23:20:00Z")
    # The ids are deliberately reversed; the method must derive a frontier, then scan by created_at.
    @ledger.materialize_arrivals!(version_ids: %w[ordered-late ordered-early])

    insert_version(item_key: "concurrent-item", version_id: "concurrent-v1", capture_id: "concurrent-c1", content_hash: "concurrent-a",
                   created_at: "2026-08-09T23:30:00Z", source_url: "https://fixture.test/concurrent")
    insert_version(item_key: "concurrent-item", version_id: "concurrent-v2", capture_id: "concurrent-c2", content_hash: "concurrent-b",
                   created_at: "2026-08-09T23:40:00Z", source_url: "https://fixture.test/concurrent")
    ledgers = 2.times.map { LocalReportLedger.new(psql: psql_bin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user) }
    errors = 2.times.map do |index|
      Thread.new do
        begin
          ledgers.fetch(index).materialize_arrivals_through!(frontier: "2026-08-10T00:00:00Z")
          nil
        rescue StandardError => error
          error
        end
      end
    end.map(&:value)
    assert errors.compact.empty?, errors.compact.map(&:message).join("; ")
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_reportable_arrival WHERE item_key = 'ordered-item' AND arrival_kind = 'first_seen'").to_i
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_reportable_arrival WHERE item_key = 'concurrent-item' AND arrival_kind = 'first_seen'").to_i
    assert_equal 2, psql!("SELECT COUNT(*) FROM local_reportable_arrival WHERE item_key = 'concurrent-item'").to_i
  end

  def test_cutoff_late_arrival_is_next_edition_processing_backfill_once
    slots = {}
    slots["morning"] = @ledger.generate_slots!(date: "2026-08-10", kinds: ["morning"],
                                                configured_data_cutoff: "2026-08-09T23:30:00Z").fetch(0)
    slots["evening"] = @ledger.generate_slots!(date: "2026-08-10", kinds: ["evening"]).fetch(0)
    insert_version(item_key: "late-item", version_id: "late-version", capture_id: "late-capture", content_hash: "late-hash",
                   created_at: "2026-08-09T23:45:00Z")

    morning = publish(slots.fetch("morning"), key: "late-morning", processing: "2026-08-09T23:30:00Z", selection: "2026-08-09T23:30:00Z", comparison: "2026-08-09T23:30:00Z")
    assert_equal 0, morning.fetch("item_count").to_i
    evening = @ledger.publish_slot!(slot_id: slots.fetch("evening").fetch("slot_id"), idempotency_key: "late-evening",
                                    processing_frontier: slots.fetch("evening").fetch("scheduled_at"),
                                    selection_completeness_frontier: slots.fetch("evening").fetch("scheduled_at"),
                                    comparison_watermark: slots.fetch("evening").fetch("scheduled_at"))
    assert_equal 1, evening.fetch("item_count").to_i
    latest = @ledger.latest_report(kind: "evening")
    assert_equal 1, latest.fetch("items").length
    item = latest.fetch("items").fetch(0)
    assert_equal "PROCESSING_BACKFILL", item.fetch("placement_kind")
    assert_equal ["PROCESSING_BACKFILL"], item.fetch("reason_codes")
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_report_item_placement WHERE arrival_id = 'arrival-late-version'").to_i
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_reportable_arrival WHERE version_id = 'late-version'").to_i
  end

  def test_failed_attempt_is_retained_without_edition_and_new_key_can_retry
    slot = slots_for("2026-08-10").fetch("morning")
    assert_raises(LocalReportLedger::Error) do
      @ledger.publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: "failed-first",
                            processing_frontier: "2026-08-09T21:00:00Z",
                            selection_completeness_frontier: "2026-08-09T21:00:00Z",
                            comparison_watermark: "2026-08-09T21:00:00Z")
    end
    assert_equal "failed", psql!("SELECT state FROM local_report_publication_attempt WHERE idempotency_key = 'failed-first'").strip
    assert_equal "scheduled", @ledger.slot!(slot_id: slot.fetch("slot_id")).fetch("state")
    assert_equal 0, psql!("SELECT COUNT(*) FROM local_report_edition WHERE slot_id = '#{slot.fetch("slot_id")}'").to_i

    edition = publish(slot, key: "failed-retry")
    assert_equal slot.fetch("slot_id"), edition.fetch("slot_id")
    assert_equal "published", @ledger.slot!(slot_id: slot.fetch("slot_id")).fetch("state")
  end

  def test_explicit_mark_slot_failed_blocks_later_publication
    slot = slots_for("2026-08-10").fetch("morning")
    failed = @ledger.mark_slot_failed!(slot_id: slot.fetch("slot_id"), reason: "operator deadline")
    assert_equal "failed", failed.fetch("state")
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "blocked-by-failure") }
    assert_equal 0, psql!("SELECT COUNT(*) FROM local_report_edition WHERE slot_id = '#{slot.fetch("slot_id")}'").to_i
  end

  def test_idempotency_same_payload_replays_and_different_payload_is_rejected
    slot = slots_for("2026-08-10").fetch("morning")
    first = publish(slot, key: "idempotent", comparison: slot.fetch("scheduled_at"))
    replay = publish(slot, key: "idempotent", comparison: slot.fetch("scheduled_at"))
    assert_equal first.fetch("edition_id"), replay.fetch("edition_id")
    assert_raises(LocalReportLedger::Error) do
      publish(slot, key: "idempotent", comparison: "2026-08-09T23:59:00Z")
    end
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_report_edition WHERE slot_id = '#{slot.fetch("slot_id")}'").to_i
  end

  def test_different_idempotency_keys_concurrently_publish_at_most_one_and_loser_fails
    slot = slots_for("2026-08-10").fetch("morning")
    ledgers = 2.times.map { LocalReportLedger.new(psql: psql_bin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user) }
    results = 2.times.map do |index|
      Thread.new do
        begin
          [nil, ledgers.fetch(index).publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: "race-#{index}",
                                                    processing_frontier: slot.fetch("scheduled_at"),
                                                    selection_completeness_frontier: slot.fetch("scheduled_at"),
                                                    comparison_watermark: slot.fetch("scheduled_at"))]
        rescue StandardError => error
          [error, nil]
        end
      end
    end.map(&:value)
    assert_equal 1, results.count { |error, edition| error.nil? && edition }
    assert_equal 1, results.count { |error, _edition| error }
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_report_edition WHERE slot_id = '#{slot.fetch("slot_id")}'").to_i
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_report_publication_attempt WHERE slot_id = '#{slot.fetch("slot_id")}' AND state = 'published'").to_i
    assert_equal 1, psql!("SELECT COUNT(*) FROM local_report_publication_attempt WHERE slot_id = '#{slot.fetch("slot_id")}' AND state = 'failed'").to_i
  end

  def test_frontiers_cutoff_lag_comparison_and_degraded_reason_contracts
    slot = slots_for("2026-08-10").fetch("morning")
    assert_raises(LocalReportLedger::Error) { @ledger.publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: "missing-processing", selection_completeness_frontier: slot.fetch("scheduled_at"), comparison_watermark: slot.fetch("scheduled_at")) }
    assert_raises(LocalReportLedger::Error) { @ledger.publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: "missing-selection", processing_frontier: slot.fetch("scheduled_at"), comparison_watermark: slot.fetch("scheduled_at")) }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "bad-config", configured_data_cutoff: "2026-08-09T23:00:00Z") }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "bad-data-cutoff", data_cutoff: "2026-08-09T23:59:00Z") }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "bad-lag", processing: "2026-08-09T21:00:00Z", selection: "2026-08-09T21:00:00Z", comparison: "2026-08-09T21:00:00Z") }

    configured_slot = @ledger.generate_slots!(date: "2026-08-11", kinds: ["morning"], configured_data_cutoff: "2026-08-10T23:30:00Z").fetch(0)
    assert_raises(LocalReportLedger::Error) { publish(configured_slot, key: "bad-comparison", processing: "2026-08-10T23:30:00Z", selection: "2026-08-10T23:30:00Z", comparison: "2026-08-10T23:31:00Z") }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "normal-with-reason", edition_status: "normal", reason_codes: ["DEGRADED_COVERAGE"]) }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "degraded-without-reason", edition_status: "degraded") }
    assert_raises(LocalReportLedger::Error) { publish(slot, key: "degraded-bad-reason", edition_status: "degraded", reason_codes: ["INVENTED_REASON"]) }

    degraded = publish(slot, key: "degraded-valid", edition_status: "degraded", reason_codes: ["DEGRADED_COVERAGE"])
    assert_equal "degraded", degraded.fetch("edition_status")
    assert_equal ["DEGRADED_COVERAGE"], degraded.fetch("reason_codes")
  end

  def test_empty_edition_and_latest_report_are_raw_only_not_generated
    slot = slots_for("2026-08-10").fetch("morning")
    before = @ledger.latest_report(kind: "morning")
    assert_includes %w[not_run scheduled], before.fetch("status")
    assert_equal true, before.dig("boundary", "raw_listing_only")
    assert_equal false, before.dig("boundary", "ai_summary_generated")

    edition = publish(slot, key: "empty-edition")
    assert_equal 0, edition.fetch("item_count").to_i
    latest = @ledger.latest_report(kind: "morning")
    assert_equal "published", latest.fetch("status")
    assert_empty latest.fetch("items")
    assert_equal "not_generated", latest.dig("edition", "summary_status")
    assert_equal true, latest.dig("boundary", "raw_listing_only")
    assert_equal false, latest.dig("boundary", "ai_summary_generated")
    assert_equal "not_generated", psql!("SELECT summary_status FROM local_report_edition WHERE edition_id = '#{edition.fetch("edition_id")}'").strip
  end

  def test_database_rejects_forged_arrival_lineage_duplicate_first_seen_and_duplicate_placement
    slots = slots_for("2026-08-10")
    insert_version(item_key: "forged-item", version_id: "forged-v1", capture_id: "forged-c1", content_hash: "forged-h1", created_at: "2026-08-09T23:10:00Z")
    insert_version(item_key: "forged-item", version_id: "forged-v2", capture_id: "forged-c2", content_hash: "forged-h2", created_at: "2026-08-09T23:20:00Z")
    arrival_sql = lambda do |arrival_id, version_id, item_key: "forged-item", capture_id: "forged-c1", content_hash: "forged-h1", information_arrival_at: "2026-08-09T23:10:00Z", nominal_slot_id: slots.fetch("morning").fetch("slot_id"), arrival_kind: "first_seen"|
      <<~SQL
        INSERT INTO local_reportable_arrival
          (arrival_id, version_id, item_key, capture_id, content_hash, information_arrival_at, nominal_slot_id, arrival_kind)
        VALUES ('#{arrival_id}', '#{version_id}', '#{item_key}', '#{capture_id}', '#{content_hash}', '#{information_arrival_at}', '#{nominal_slot_id}', '#{arrival_kind}')
      SQL
    end
    assert_sql_rejected(arrival_sql.call("bad-item", "forged-v1", item_key: "invented"))
    assert_sql_rejected(arrival_sql.call("bad-capture", "forged-v1", capture_id: "invented-capture"))
    assert_sql_rejected(arrival_sql.call("bad-hash", "forged-v1", content_hash: "invented-hash"))
    assert_sql_rejected(arrival_sql.call("bad-time", "forged-v1", information_arrival_at: "2026-08-09T23:11:00Z"))
    assert_sql_rejected(arrival_sql.call("bad-slot", "forged-v1", nominal_slot_id: slots.fetch("evening").fetch("slot_id")))
    run!(psql_args(arrival_sql.call("valid-first", "forged-v1")))
    assert_sql_rejected(arrival_sql.call("duplicate-first", "forged-v2", capture_id: "forged-c2", content_hash: "forged-h2", information_arrival_at: "2026-08-09T23:20:00Z"))

    edition = publish(slots.fetch("morning"), key: "placement-edition")
    placement = psql!("SELECT placement_id FROM local_report_item_placement WHERE edition_id = '#{edition.fetch("edition_id")}'").strip
    assert_sql_rejected("INSERT INTO local_report_item_placement (placement_id, edition_id, arrival_id, nominal_slot_id, sort_order, placement_kind, reason_codes) VALUES ('duplicate-placement', '#{edition.fetch("edition_id")}', 'valid-first', '#{slots.fetch("morning").fetch("slot_id")}', 99, 'normal', '[]'::jsonb)")
    refute_empty placement
  end

  def test_database_rejects_comparison_after_cutoff_and_illegal_attempt_terminal_shape
    slot = slots_for("2026-08-10").fetch("morning")
    assert_sql_rejected(<<~SQL)
      BEGIN;
      INSERT INTO local_report_publication_attempt (attempt_id, slot_id, idempotency_key, payload_hash, state)
      VALUES ('direct-edition-attempt', '#{slot.fetch("slot_id")}', 'direct-edition-key', 'direct-edition-hash', 'running');
      INSERT INTO local_report_edition
        (edition_id, slot_id, attempt_id, nominal_window_start, nominal_window_end,
         configured_data_cutoff, processing_frontier, selection_completeness_frontier,
         data_cutoff, comparison_watermark, edition_status, reason_codes, summary_status, payload_hash, item_count)
      VALUES ('direct-bad-comparison', '#{slot.fetch("slot_id")}', 'direct-edition-attempt', '#{slot.fetch("window_start")}', '#{slot.fetch("window_end")}',
              '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}',
              '2026-08-10T00:01:00Z', 'normal', '[]'::jsonb, 'not_generated', 'direct-bad', 0);
      COMMIT;
    SQL
    assert_sql_rejected("BEGIN; INSERT INTO local_report_publication_attempt (attempt_id, slot_id, idempotency_key, payload_hash, state, finished_at) VALUES ('orphan-published', '#{slot.fetch("slot_id")}', 'orphan-published-key', 'orphan-published-hash', 'published', now()); COMMIT;")
    assert_sql_rejected(<<~SQL)
      BEGIN;
      INSERT INTO local_report_publication_attempt (attempt_id, slot_id, idempotency_key, payload_hash, state)
      VALUES ('running-orphan-edition', '#{slot.fetch("slot_id")}', 'running-orphan-key', 'running-orphan-hash', 'running');
      INSERT INTO local_report_edition
        (edition_id, slot_id, attempt_id, nominal_window_start, nominal_window_end,
         configured_data_cutoff, processing_frontier, selection_completeness_frontier,
         data_cutoff, comparison_watermark, edition_status, reason_codes, summary_status, payload_hash, item_count)
      VALUES ('running-orphan-edition', '#{slot.fetch("slot_id")}', 'running-orphan-edition', '#{slot.fetch("window_start")}', '#{slot.fetch("window_end")}',
              '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}', '#{slot.fetch("scheduled_at")}',
              '#{slot.fetch("scheduled_at")}', 'normal', '[]'::jsonb, 'not_generated', 'running-orphan-edition-hash', 0);
      COMMIT;
    SQL
    assert_sql_rejected("INSERT INTO local_report_publication_attempt (attempt_id, slot_id, idempotency_key, payload_hash, state, finished_at) VALUES ('bad-terminal', '#{slot.fetch("slot_id")}', 'bad-terminal-key', 'bad-terminal-hash', 'running', now())")
    run!(psql_args("INSERT INTO local_report_publication_attempt (attempt_id, slot_id, idempotency_key, payload_hash, state) VALUES ('transition-attempt', '#{slot.fetch("slot_id")}', 'transition-key', 'transition-hash', 'running')"))
    assert_sql_rejected("UPDATE local_report_publication_attempt SET state = 'bogus' WHERE attempt_id = 'transition-attempt'")
    assert_equal "running", psql!("SELECT state FROM local_report_publication_attempt WHERE attempt_id = 'transition-attempt'").strip
  end

  private

  def slots_for(date)
    @ledger.generate_slots!(date: date).to_h { |row| [row.fetch("kind"), row] }
  end

  def parse_time(value)
    Time.parse(value.to_s)
  end

  def publish(slot, key:, processing: nil, selection: nil, configured_data_cutoff: nil, data_cutoff: nil,
              comparison: nil, edition_status: "normal", reason_codes: [])
    processing ||= slot.fetch("scheduled_at")
    selection ||= slot.fetch("scheduled_at")
    comparison ||= slot.fetch("scheduled_at")
    @ledger.publish_slot!(slot_id: slot.fetch("slot_id"), idempotency_key: key,
                          processing_frontier: processing, selection_completeness_frontier: selection,
                          configured_data_cutoff: configured_data_cutoff, data_cutoff: data_cutoff,
                          comparison_watermark: comparison, edition_status: edition_status, reason_codes: reason_codes)
  end

  def insert_version(item_key:, version_id:, capture_id:, content_hash:, created_at:, source_id: "source-fixture", source_url: nil, captured_at: nil, published_at: nil)
    source_url ||= "https://fixture.test/item-#{item_key}"
    captured_at ||= created_at
    published_sql = published_at ? "'#{published_at}'" : "NULL"
    run!(psql_args(<<~SQL))
      INSERT INTO local_source_capture
        (capture_id, source_id, source_url, source_kind, rights_scope, captured_at, http_status,
         content_type, content_bytes, body_hash, storage_status, storage_uri)
      VALUES ('#{capture_id}', '#{source_id}', '#{source_url}', 'configured', 'metadata_short_summary_link',
              '#{captured_at}', 200, 'application/rss+xml', 10, '#{capture_id}-body', 'metadata_only', '');
      INSERT INTO local_source_item
        (item_key, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id,
         publisher_identity_status, source_kind, capture_id, title, summary, source_url, published_at,
         fetched_at, captured_at, content_hash)
      VALUES ('#{item_key}', '#{source_id}', 'Fixture source', 'en', 'fixture', 'Fixture publisher',
              'https://fixture.test/publisher', 'fixture.test', 'configured', 'configured', '#{capture_id}',
              'Fixture title', 'Fixture summary', '#{source_url}', #{published_sql}, '#{captured_at}', '#{captured_at}', '#{content_hash}')
      ON CONFLICT (item_key) DO NOTHING;
      INSERT INTO local_source_item_version
        (version_id, item_key, capture_id, source_id, source_name, language, region, publisher_name,
         publisher_url, publisher_id, publisher_identity_status, source_kind, query_conditioned,
         lineage_metadata_basis, title, summary, source_url, published_at, fetched_at, captured_at,
         content_hash, created_at, discovery_basis, analysis_policy, aggregator_id, locale_tag,
         market_label, market_label_basis, query_topics)
      VALUES ('#{version_id}', '#{item_key}', '#{capture_id}', '#{source_id}', 'Fixture source', 'en', 'fixture',
              'Fixture publisher', 'https://fixture.test/publisher', 'fixture.test', 'configured', 'configured', false,
              'capture_time', 'Fixture title', 'Fixture summary', '#{source_url}', #{published_sql}, '#{captured_at}', '#{captured_at}',
              '#{content_hash}', '#{created_at}', 'editorial_feed', 'signal_eligible', '', '', '', 'editorial_scope_label', '[]'::jsonb);
    SQL
  end

  def assert_sql_rejected(sql)
    result = run_raw(psql_args(sql))
    refute result.fetch(:status).success?, "expected SQL to be rejected, got: #{result.fetch(:stdout)}"
  end

  def psql_args(sql)
    [psql_bin("psql"), "-XAt", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-c", sql]
  end

  def psql!(sql)
    run!(psql_args(sql)).strip
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
