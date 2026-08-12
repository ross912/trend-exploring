# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/local_radar_store"
require_relative "../lib/rss_ingest"

class BreadthDiscoveryStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "trend_exploring_breadth_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(5)}"
    run!([psql_bin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    ["011_local_radar.sql", "012_breadth_discovery.sql"].each do |file|
      run!([psql_bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = LocalRadarStore.new(psql: psql_bin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user)
  end

  def teardown
    run!([psql_bin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_success_empty_failed_denominator_and_immutable_attempt
    sources = [locale_source("en-US", "s-en"), locale_source("es-419", "s-es"), locale_source("ja-JP", "s-ja"), locale_source("ar-EG", "s-ar"), locale_source("de-DE", "s-de"), locale_source("pt-BR", "s-pt")]
    @store.register_sources!(sources: sources)
    batch = @store.create_collection_batch!(batch_id: "batch-1", registry_hash: @store.registry_contract_hash(sources: sources), planned_source_count: 6, sources: sources)
    assert_equal 0, batch.fetch("selected_count")
    hashes = sources.to_h { |source| [source.fetch("id"), @store.registry_contract_hash(sources: [source])] }
    @store.record_source_fetch_attempt!(batch_id: "batch-1", source_id: "s-en", outcome: "succeeded_empty", item_count: 0, http_status: 200, source_config_hash: hashes.fetch("s-en"))
    @store.record_source_fetch_attempt!(batch_id: "batch-1", source_id: "s-es", outcome: "failed", item_count: 0, http_status: 500, source_config_hash: hashes.fetch("s-es"), error_code: "http_500", error_message: "fixture")
    assert_equal 6, @store.current_radar.dig("exploration", "latest_batch", "planned_source_count")
    assert_raises(LocalRadarStore::Error) { @store.freeze_collection_selection!(batch_id: "batch-1", version_ids: []) }
    sources.drop(2).each do |source|
      @store.record_source_fetch_attempt!(batch_id: "batch-1", source_id: source.fetch("id"), outcome: "failed", item_count: 0, source_config_hash: hashes.fetch(source.fetch("id")), error_code: "timeout", error_message: "fixture")
    end
    @store.freeze_collection_selection!(batch_id: "batch-1", version_ids: [])
    assert_raises(LocalRadarStore::Error) do
      @store.record_source_fetch_attempt!(batch_id: "batch-1", source_id: "s-es", outcome: "succeeded_empty", item_count: 0, http_status: 200, source_config_hash: hashes.fetch("s-es"))
    end
    @store.finalize_collection_batch!(batch_id: "batch-1", status: "failed")
    radar = @store.current_radar
    assert_equal "partial_failure", radar.dig("exploration", "latest_batch", "worker_state")
    assert_equal 6, radar.dig("exploration", "latest_batch", "planned_source_count")
    assert_equal 1, radar.dig("exploration", "latest_batch", "empty_source_count")
    assert_equal 5, radar.dig("exploration", "latest_batch", "failed_source_count")
    assert_equal false, radar.dig("exploration", "boundary", "topic_conditioned")
  end

  def test_coverage_planned_source_count_does_not_use_selected_count
    sources = (0...8).map { |index| locale_source("en-#{index}", "coverage-source-#{index}") }
    @store.register_sources!(sources: sources)
    batch_id = "coverage-planned-vs-selected"
    @store.create_collection_batch!(
      batch_id: batch_id,
      registry_hash: @store.registry_contract_hash(sources: sources),
      planned_source_count: 8,
      sources: sources
    )
    @store.ingest_source_items!(items: [locale_item(source: sources.first, item_key: "coverage-item", capture_id: "coverage-capture", publisher_id: "coverage.example")])
    sources.each_with_index do |source, index|
      hash = @store.registry_contract_hash(sources: [source])
      if index.zero?
        @store.record_source_fetch_attempt!(batch_id: batch_id, source_id: source.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: "coverage-capture", http_status: 200, source_config_hash: hash)
      elsif index < 3
        @store.record_source_fetch_attempt!(batch_id: batch_id, source_id: source.fetch("id"), outcome: "succeeded_empty", item_count: 0, http_status: 200, source_config_hash: hash)
      else
        @store.record_source_fetch_attempt!(batch_id: batch_id, source_id: source.fetch("id"), outcome: "failed", item_count: 0, source_config_hash: hash, error_code: "fixture_failure", error_message: "failure #{index}")
      end
    end
    # selected_count is a separate item projection and may exceed the number
    # of planned source feeds (for example, 12 selected rows from 8 feeds).
    @store.send(:execute, "UPDATE local_collection_batch SET selected_count = 12 WHERE batch_id = 'coverage-planned-vs-selected'")

    coverage = @store.coverage
    assert_equal 8, coverage.fetch("last_batch_planned_source_count")
    assert_equal 1, coverage.fetch("last_batch_succeeded_source_count")
    assert_equal 2, coverage.fetch("last_batch_empty_source_count")
    assert_equal 5, coverage.fetch("last_batch_failed_source_count")
    assert_equal 12, @store.collection_batch(batch_id: batch_id).fetch("selected_count")
  end

  def test_legacy_editorial_item_empty_market_basis_uses_registry_default
    source = signal_source("legacy-editorial-default")
    @store.register_sources!(sources: [source])
    item = signal_item(source).merge("item_key" => "legacy-editorial-item", "capture_id" => "legacy-editorial-capture", "market_label_basis" => "")

    assert_equal 1, @store.ingest_source_items!(items: [item])
    stored = @store.source_item_versions(item_key: "legacy-editorial-item").fetch(0)
    assert_equal "editorial_scope_label", stored.fetch("market_label_basis")
    assert_equal "editorial_scope_label", @store.source_summary.find { |row| row.fetch("source_id") == source.fetch("id") }.fetch("market_label_basis")
  end

  def test_locale_item_empty_market_basis_is_still_rejected
    source = locale_source("en-US", "locale-empty-market-basis")
    @store.register_sources!(sources: [source])
    item = locale_item(source: source, item_key: "locale-empty-market-item", capture_id: "locale-empty-market-capture", publisher_id: "publisher.example").merge("market_label_basis" => "")

    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [item]) }
  end

  def test_rss_editorial_default_item_round_trips_canonical_market_basis
    source = signal_source("rss-editorial-default").merge("source_kind" => "configured", "url" => "https://signal.example/feed.xml")
    @store.register_sources!(sources: [source])
    xml = '<rss version="2.0"><channel><item><title>Legacy feed item</title><link>https://signal.example/item</link><description>short fixture</description><pubDate>Sun, 09 Aug 2026 00:00:00 GMT</pubDate></item></channel></rss>'
    item = RSSIngest::Fetcher.new.send(:parse, source, xml, {
      "capture_id" => "rss-editorial-capture", "captured_at" => "2026-08-09T01:00:00Z",
      "http_status" => 200, "content_type" => "application/rss+xml", "content_bytes" => xml.bytesize,
      "body_hash" => "rss-editorial-body", "feed_url" => source.fetch("url"),
      "storage_status" => "metadata_only", "rights_scope" => "metadata_short_summary_link"
    }).fetch(0)

    assert_equal "", item.fetch("market_label_basis")
    assert_equal 1, @store.ingest_source_items!(items: [item])
    stored = @store.source_item_versions(item_key: item.fetch("item_key")).fetch(0)
    assert_equal "editorial_scope_label", stored.fetch("market_label_basis")
  end

  def test_membership_reorder_and_pseudo_version_are_rejected
    source = locale_source("en-US", "s-one")
    @store.register_sources!(sources: [source])
    item = locale_item(source: source, item_key: "item-1", capture_id: "capture-1", publisher_id: "publisher.example")
    @store.ingest_source_items!(items: [item])
    assert_empty @store.translation_candidates(limit: 20)
    assert_empty @store.latest_source_items(limit: 20, analysis_policy: "signal_eligible")
    assert_empty @store.event_analysis_items(limit: 20, analysis_policy: "signal_eligible")
    hash = @store.registry_contract_hash(sources: [source])
    @store.create_collection_batch!(batch_id: "batch-2", registry_hash: hash, planned_source_count: 1, sources: [source])
    @store.record_source_fetch_attempt!(batch_id: "batch-2", source_id: source.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: "capture-1", http_status: 200, source_config_hash: hash)
    selected = @store.selected_versions_for_batch(batch_id: "batch-2")
    version_id = selected.fetch(0).fetch("version_id")
    assert_raises(LocalRadarStore::Error) { @store.freeze_collection_selection!(batch_id: "batch-2", version_ids: ["forged-version"]) }
    @store.freeze_collection_selection!(batch_id: "batch-2", version_ids: [version_id])
    assert_raises(LocalRadarStore::Error) { @store.finalize_collection_batch!(batch_id: "batch-2", status: "published") }
    baseline = { "snapshot_id" => "breadth-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "baseline" }
    @store.publish_snapshot!(snapshot: baseline, cards: [card])
    snapshot = baseline.merge("snapshot_id" => "breadth-snapshot", "revision" => 2, "render_plan_hash" => "test-render", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "breadth-baseline")
    result = @store.publish_snapshot!(snapshot: snapshot, cards: [card.merge("card_id" => "breadth-card-reused")], batch_id: "batch-2", exploration_items: [{ "version_id" => version_id, "sort_order" => 0, "resolution" => "resolved" }])
    assert_equal "raw_listing", result.dig("exploration", "items", 0, "claim_status")
    assert_equal "locale_frontier", result.dig("exploration", "items", 0, "lane")
  end

  def test_membership_untrusted_capture_hash_and_title_roll_back_snapshot
    source, version = prepare_membership_batch(batch_id: "membership-untrusted")
    %w[capture_id content_hash title].each_with_index do |field, index|
      assert_raises(LocalRadarStore::Error) do
        @store.publish_snapshot!(
          snapshot: { "snapshot_id" => "untrusted-#{field}", "surface_id" => "public-radar", "revision" => index + 2, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "untrusted-#{field}", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "membership-untrusted-baseline" },
          cards: [card.merge("card_id" => "untrusted-card-#{field}")],
          batch_id: "membership-untrusted",
          exploration_items: [{ "version_id" => version.fetch("version_id"), "sort_order" => 0, "resolution" => "resolved", field => "caller-injected" }]
        )
      end
      assert_equal "membership-untrusted-baseline", @store.current_radar.dig("snapshot", "snapshot_id")
    end
    assert_equal "frozen", @store.collection_batch(batch_id: "membership-untrusted").fetch("status")
    assert_equal source.fetch("id"), version.fetch("source_id")
  end

  def test_locale_batch_without_signal_head_rejects_fresh_and_reused_projection
    _source, version = prepare_membership_batch(batch_id: "membership-no-head", with_signal_head: false)
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "no-head-fresh", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "no-head-fresh" },
        cards: [card], batch_id: "membership-no-head",
        exploration_items: [{ "version_id" => version.fetch("version_id"), "sort_order" => 0, "resolution" => "resolved" }]
      )
    end
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "no-head-reused", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "no-head-reused", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "missing-signal-head" },
        cards: [card], batch_id: "membership-no-head",
        exploration_items: [{ "version_id" => version.fetch("version_id"), "sort_order" => 0, "resolution" => "resolved" }]
      )
    end
    assert_nil @store.current_radar.fetch("snapshot")
  end

  def test_locale_batch_fresh_rejects_unrelated_signal_version_after_batch_start
    locale = locale_source("en-US", "post-start-locale")
    signal = signal_source("post-start-signal")
    @store.register_sources!(sources: [locale, signal])
    batch_id = "post-start-fresh"
    batch_hash = @store.registry_contract_hash(sources: [locale])
    @store.create_collection_batch!(batch_id: batch_id, registry_hash: batch_hash, planned_source_count: 1, sources: [locale])
    @store.record_source_fetch_attempt!(batch_id: batch_id, source_id: locale.fetch("id"), outcome: "succeeded_empty", item_count: 0, http_status: 200, source_config_hash: batch_hash)
    @store.freeze_collection_selection!(batch_id: batch_id, version_ids: [])

    captured_at = Time.now.utc.iso8601(6)
    @store.ingest_source_items!(items: [signal_item(signal).merge("capture_captured_at" => captured_at, "fetched_at" => captured_at)])
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(
        snapshot: { "snapshot_id" => "post-start-fresh-snapshot", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "post-start-fresh" },
        cards: [card], batch_id: batch_id, exploration_items: []
      )
    end
    assert_nil @store.current_radar.fetch("snapshot")
  end

  def test_membership_rejects_disabled_and_mutated_registry_contract
    source, version = prepare_membership_batch(batch_id: "membership-registry")
    @store.send(:execute, "UPDATE local_source_registry SET enabled = FALSE WHERE source_id = '#{source.fetch("id")}'")
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "registry-disabled", "surface_id" => "public-radar", "revision" => 2, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "registry-disabled", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "membership-registry-baseline" }, cards: [card.merge("card_id" => "registry-disabled-card")], batch_id: "membership-registry", exploration_items: [{ "version_id" => version.fetch("version_id"), "sort_order" => 0, "resolution" => "resolved" }])
    end
    assert_equal "membership-registry-baseline", @store.current_radar.dig("snapshot", "snapshot_id")

    @store.send(:execute, "UPDATE local_source_registry SET enabled = TRUE, market_label = 'mutated-market' WHERE source_id = '#{source.fetch("id")}'")
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "registry-mutated", "surface_id" => "public-radar", "revision" => 2, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "registry-mutated", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "membership-registry-baseline" }, cards: [card.merge("card_id" => "registry-mutated-card")], batch_id: "membership-registry", exploration_items: [{ "version_id" => version.fetch("version_id"), "sort_order" => 0, "resolution" => "resolved" }])
    end
    assert_equal "membership-registry-baseline", @store.current_radar.dig("snapshot", "snapshot_id")
  end

  def test_one_success_and_five_failures_keep_succeeded_denominator_and_publish_one
    sources = (0...6).map { |index| locale_source("en-#{index}", "s-six-#{index}") }
    @store.register_sources!(sources: sources)
    first_item = locale_item(source: sources.first, item_key: "six-item", capture_id: "six-capture", publisher_id: "six.example")
    @store.ingest_source_items!(items: [first_item])
    @store.create_collection_batch!(batch_id: "batch-six", registry_hash: @store.registry_contract_hash(sources: sources), planned_source_count: 6, sources: sources)
    sources.each_with_index do |source, index|
      hash = @store.registry_contract_hash(sources: [source])
      if index.zero?
        @store.record_source_fetch_attempt!(batch_id: "batch-six", source_id: source.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: "six-capture", http_status: 200, source_config_hash: hash)
      else
        @store.record_source_fetch_attempt!(batch_id: "batch-six", source_id: source.fetch("id"), outcome: "failed", item_count: 0, source_config_hash: hash, error_code: "fixture_failure", error_message: "failure #{index}")
      end
    end
    selected = @store.selected_versions_for_batch(batch_id: "batch-six")
    @store.freeze_collection_selection!(batch_id: "batch-six", version_ids: selected.map { |version| version.fetch("version_id") })
    version_id = selected.fetch(0).fetch("version_id")
    baseline = { "snapshot_id" => "snapshot-six-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "six-baseline" }
    @store.publish_snapshot!(snapshot: baseline, cards: [card])
    result = @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "snapshot-six", "revision" => 2, "render_plan_hash" => "six", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "snapshot-six-baseline"), cards: [card.merge("card_id" => "six-card-reused")], batch_id: "batch-six", exploration_items: [{ "version_id" => version_id, "sort_order" => 0, "resolution" => "resolved" }])
    assert_equal 1, result.dig("exploration", "latest_batch", "succeeded_source_count")
    assert_equal 5, result.dig("exploration", "latest_batch", "failed_source_count")
    assert_equal 6, result.dig("exploration", "latest_batch", "planned_source_count")
    assert_equal version_id, result.dig("exploration", "items", 0, "version_id")
  end

  def test_two_membership_reorder_rolls_back_snapshot
    sources = [locale_source("en-US", "s-a"), locale_source("es-419", "s-b")]
    @store.register_sources!(sources: sources)
    sources.each_with_index do |source, index|
      @store.ingest_source_items!(items: [locale_item(source: source, item_key: "item-#{index}", capture_id: "capture-#{index}", publisher_id: "publisher-#{index}.example").merge("published_at" => format("2026-08-09T0#{index + 1}:00:00Z"))])
    end
    @store.create_collection_batch!(batch_id: "batch-3", registry_hash: @store.registry_contract_hash(sources: sources), planned_source_count: 2, sources: sources)
    sources.each_with_index do |source, index|
      @store.record_source_fetch_attempt!(batch_id: "batch-3", source_id: source.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: "capture-#{index}", http_status: 200, source_config_hash: @store.registry_contract_hash(sources: [source]))
    end
    selected = @store.selected_versions_for_batch(batch_id: "batch-3")
    ids = selected.map { |version| version.fetch("version_id") }
    @store.freeze_collection_selection!(batch_id: "batch-3", version_ids: ids)
    baseline = { "snapshot_id" => "reorder-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "reorder-baseline" }
    @store.publish_snapshot!(snapshot: baseline, cards: [card])
    reversed = ids.reverse.each_with_index.map { |id, index| { "version_id" => id, "sort_order" => index, "resolution" => "resolved" } }
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "reordered", "revision" => 2, "render_plan_hash" => "reordered", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "reorder-baseline"), cards: [card.merge("card_id" => "reorder-card")], batch_id: "batch-3", exploration_items: reversed)
    end
    assert_equal "reorder-baseline", @store.current_radar.dig("snapshot", "snapshot_id")

    # The array itself is canonical, but the caller swaps sort_order values.
    # Hashing the pre-sort array must not permit the DB write to reorder it.
    sort_swapped = ids.each_with_index.map { |id, index| { "version_id" => id, "sort_order" => 1 - index, "resolution" => "resolved" } }
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "sort-swapped", "revision" => 2, "render_plan_hash" => "sort-swapped", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "reorder-baseline"), cards: [card.merge("card_id" => "sort-card")], batch_id: "batch-3", exploration_items: sort_swapped)
    end
    assert_equal "reorder-baseline", @store.current_radar.dig("snapshot", "snapshot_id")
  end

  def test_locale_exploration_does_not_expand_signal_coverage_translation_or_publishers
    signal = signal_source("signal-source")
    locale = locale_source("ar-EG", "locale-source")
    @store.register_sources!(sources: [signal, locale])
    @store.ingest_source_items!(items: [signal_item(signal)])
    signal_card_inputs = @store.latest_source_items(limit: 20).map { |item| item.fetch("item_key") }
    signal_event_inputs = @store.event_analysis_items(limit: 20).map { |item| item.fetch("item_key") }
    locale_resolved = locale_item(source: locale, item_key: "locale-resolved", capture_id: "locale-capture", publisher_id: "locale.example")
    locale_unresolved = locale_item(source: locale, item_key: "locale-unresolved", capture_id: "locale-capture", publisher_id: "").merge(
      "publisher_name" => "", "publisher_url" => "", "publisher_identity_status" => "unresolved",
      "source_url" => "https://news.google.com/locale-unresolved"
    )
    @store.ingest_source_items!(items: [locale_resolved, locale_unresolved])
    assert_equal ["signal-item"], signal_card_inputs
    assert_equal signal_card_inputs, @store.latest_source_items(limit: 20).map { |item| item.fetch("item_key") }
    assert_equal signal_event_inputs, @store.event_analysis_items(limit: 20).map { |item| item.fetch("item_key") }
    assert_equal "2026-08-09T01:00:00Z", @store.signal_comparison_watermark(items: [signal_item(signal), locale_resolved])
    assert_equal "no_signal_eligible_capture", @store.signal_comparison_watermark(items: [locale_resolved])

    batch_hash = @store.registry_contract_hash(sources: [locale])
    @store.create_collection_batch!(batch_id: "locale-isolation", registry_hash: batch_hash, planned_source_count: 1, sources: [locale])
    @store.record_source_fetch_attempt!(batch_id: "locale-isolation", source_id: locale.fetch("id"), outcome: "succeeded_with_items", item_count: 2, capture_id: "locale-capture", http_status: 200, source_config_hash: batch_hash)
    selected = @store.selected_versions_for_batch(batch_id: "locale-isolation")
    @store.freeze_collection_selection!(batch_id: "locale-isolation", version_ids: selected.map { |version| version.fetch("version_id") })
    memberships = selected.each_with_index.map { |version, index| { "version_id" => version.fetch("version_id"), "sort_order" => index } }
    baseline = { "snapshot_id" => "locale-signal-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "locale-baseline" }
    @store.publish_snapshot!(snapshot: baseline, cards: [card])
    @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "locale-isolation-snapshot", "revision" => 2, "render_plan_hash" => "locale-isolation", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "locale-signal-baseline"), cards: [card.merge("card_id" => "locale-isolation-card")], batch_id: "locale-isolation", exploration_items: memberships)
    assert_equal "2026-08-09T00:00:00Z", @store.signal_comparison_watermark(items: [locale_resolved])
    assert_equal "reused_previous", @store.current_radar.dig("snapshot", "signal_projection_status")
    assert_equal "locale-signal-baseline", @store.current_radar.dig("snapshot", "signal_source_snapshot_id")

    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "projection-forged-fresh", "surface_id" => "public-radar", "revision" => 3, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection-forged-fresh", "signal_projection_status" => "fresh_batch", "signal_source_snapshot_id" => "locale-isolation-snapshot" }, cards: [card.merge("card_id" => "projection-forged-fresh-card")])
    end
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "projection-forged-reused", "surface_id" => "public-radar", "revision" => 3, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection-forged-reused", "signal_projection_status" => "reused_previous" }, cards: [card.merge("card_id" => "projection-forged-reused-card")])
    end
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "projection-changed-card", "surface_id" => "public-radar", "revision" => 3, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection-changed-card", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "locale-isolation-snapshot" }, cards: [card.merge("card_id" => "projection-changed-card-id", "title" => "tampered")])
    end
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: { "snapshot_id" => "projection-changed-watermark", "surface_id" => "public-radar", "revision" => 3, "comparison_watermark" => "2026-08-09T00:00:01Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection-changed-watermark", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "locale-isolation-snapshot" }, cards: [card.merge("card_id" => "projection-changed-watermark-card")])
    end
    reused = @store.publish_snapshot!(snapshot: { "snapshot_id" => "locale-reused-snapshot", "surface_id" => "public-radar", "revision" => 3, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "locale-reused", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "locale-isolation-snapshot" }, cards: [card.merge("card_id" => "locale-reused-card")])
    assert_equal "reused_previous", reused.dig("snapshot", "signal_projection_status")
    assert_equal "locale-isolation-snapshot", reused.dig("snapshot", "signal_source_snapshot_id")

    coverage = @store.coverage
    assert_equal ["en"], coverage.fetch("observed_languages")
    assert_equal 0, coverage.fetch("unresolved_publisher_item_count")
    assert_equal ["ar-EG"], coverage.fetch("observed_locale_tags")
    assert_equal ["ar"], coverage.fetch("observed_original_languages")
    assert_equal 2, coverage.fetch("exploration_only_item_count")
    assert_equal 1, coverage.fetch("locale_discovery_observed_publisher_domain_count")
    assert_equal 1, coverage.fetch("locale_discovery_unresolved_item_count")
    assert_equal 1, @store.translation_summary.fetch("english_items")
    assert_equal ["signal-item"], @store.translation_candidates(limit: 20).map { |item| item.fetch("item_key") }
    publisher_ids = @store.discovered_publishers.map { |publisher| publisher.fetch("publisher_id") }
    assert_includes publisher_ids, "signal.example"
    refute_includes publisher_ids, "locale.example"
  end

  def test_mixed_signal_locale_publishes_fresh_then_reused_next_revision
    signal = signal_source("mixed-signal")
    locale = locale_source("en-US", "mixed-locale")
    @store.register_sources!(sources: [signal, locale])
    signal_item_row = signal_item(signal)
    locale_item_row = locale_item(source: locale, item_key: "mixed-locale-item", capture_id: "mixed-locale-capture", publisher_id: "locale.example")
    @store.ingest_source_items!(items: [signal_item_row, locale_item_row])
    batch_hash = @store.registry_contract_hash(sources: [locale])
    @store.create_collection_batch!(batch_id: "mixed-locale-batch", registry_hash: batch_hash, planned_source_count: 1, sources: [locale])
    @store.record_source_fetch_attempt!(batch_id: "mixed-locale-batch", source_id: locale.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: "mixed-locale-capture", http_status: 200, source_config_hash: batch_hash)
    selected = @store.selected_versions_for_batch(batch_id: "mixed-locale-batch")
    @store.freeze_collection_selection!(batch_id: "mixed-locale-batch", version_ids: selected.map { |version| version.fetch("version_id") })
    memberships = selected.each_with_index.map { |version, index| { "version_id" => version.fetch("version_id"), "sort_order" => index } }
    watermark = @store.signal_comparison_watermark(items: [signal_item_row, locale_item_row])
    fresh = @store.publish_snapshot!(snapshot: { "snapshot_id" => "mixed-fresh", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => watermark, "method_epoch" => "mixed-method", "rights_epoch" => 1, "render_plan_hash" => "mixed-fresh" }, cards: [card])
    reused = @store.publish_snapshot!(snapshot: { "snapshot_id" => "mixed-reused", "surface_id" => "public-radar", "revision" => 2, "comparison_watermark" => watermark, "method_epoch" => "mixed-method", "rights_epoch" => 1, "render_plan_hash" => "mixed-reused", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "mixed-fresh" }, cards: [card.merge("card_id" => "mixed-reused-card")], batch_id: "mixed-locale-batch", exploration_items: memberships)
    assert_equal "mixed-fresh", fresh.dig("snapshot", "snapshot_id")
    assert_equal "mixed-reused", reused.dig("snapshot", "snapshot_id")
    assert_equal "reused_previous", reused.dig("snapshot", "signal_projection_status")
    assert_equal "mixed-fresh", reused.dig("snapshot", "signal_source_snapshot_id")
    assert_equal watermark, reused.dig("snapshot", "comparison_watermark")
    assert_equal "published", @store.collection_batch(batch_id: "mixed-locale-batch").fetch("status")
    assert_equal "mixed-reused", @store.current_radar.dig("snapshot", "snapshot_id")
  end

  def test_mixed_signal_locale_empty_closes_batch_without_reused_revision
    signal = signal_source("mixed-empty-signal")
    locale = locale_source("en-US", "mixed-empty-locale")
    @store.register_sources!(sources: [signal, locale])
    signal_item_row = signal_item(signal)
    @store.ingest_source_items!(items: [signal_item_row])
    batch_hash = @store.registry_contract_hash(sources: [locale])
    @store.create_collection_batch!(batch_id: "mixed-empty-batch", registry_hash: batch_hash, planned_source_count: 1, sources: [locale])
    @store.record_source_fetch_attempt!(batch_id: "mixed-empty-batch", source_id: locale.fetch("id"), outcome: "succeeded_empty", item_count: 0, http_status: 200, source_config_hash: batch_hash)
    @store.freeze_collection_selection!(batch_id: "mixed-empty-batch", version_ids: [])
    watermark = @store.signal_comparison_watermark(items: [signal_item_row])
    fresh = @store.publish_snapshot!(snapshot: { "snapshot_id" => "mixed-empty-fresh", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => watermark, "method_epoch" => "mixed-method", "rights_epoch" => 1, "render_plan_hash" => "mixed-empty-fresh" }, cards: [card])
    @store.finalize_collection_batch!(batch_id: "mixed-empty-batch", status: "published")
    assert_equal "mixed-empty-fresh", fresh.dig("snapshot", "snapshot_id")
    assert_equal "mixed-empty-fresh", @store.current_radar.dig("snapshot", "snapshot_id")
    assert_equal "published", @store.collection_batch(batch_id: "mixed-empty-batch").fetch("status")
    assert_nil @store.current_radar.dig("exploration", "latest_batch", "snapshot_id")
  end

  def test_installed_breadth_query_errors_fail_closed
    @store.send(:execute, "INSERT INTO local_collection_batch (batch_id, started_at, registry_hash, planned_source_count) VALUES ('broken-batch', now(), 'broken', 1)")
    @store.send(:execute, "DROP TABLE local_source_fetch_attempt CASCADE")
    assert_raises(LocalRadarStore::Error) { @store.current_radar }
  end

  def test_missing_all_breadth_relations_after_012_marker_fails_closed
    %w[local_source_fetch_attempt local_radar_exploration_item local_collection_batch_source local_collection_batch].each do |table|
      @store.send(:execute, "DROP TABLE #{table} CASCADE")
    end
    assert_raises(LocalRadarStore::Error) { @store.current_radar }
  end

  def test_reused_projection_rejects_missing_or_changed_trend_semantics
    baseline = { "snapshot_id" => "projection-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "projection-baseline" }
    @store.publish_snapshot!(snapshot: baseline, cards: [card], trends: [trend])
    assert_raises(LocalRadarStore::Error) do
      @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "projection-missing-trend", "revision" => 2, "render_plan_hash" => "projection-missing-trend", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "projection-baseline"), cards: [card.merge("card_id" => "projection-missing-trend-card")], trends: [])
    end
    assert_raises(LocalRadarStore::Error) do
      changed = trend.merge("trend_id" => "projection-changed-trend-id", "summary" => "tampered")
      @store.publish_snapshot!(snapshot: baseline.merge("snapshot_id" => "projection-changed-trend", "revision" => 2, "render_plan_hash" => "projection-changed-trend", "signal_projection_status" => "reused_previous", "signal_source_snapshot_id" => "projection-baseline"), cards: [card.merge("card_id" => "projection-changed-trend-card")], trends: [changed])
    end
  end

  def test_immutable_version_replay_conflicts_after_registry_contract_change_but_old_version_is_readable
    source = locale_source("en-US", "version-replay")
    @store.register_sources!(sources: [source])
    original = locale_item(source: source, item_key: "version-replay-item", capture_id: "version-replay-old", publisher_id: "publisher.example")
    @store.ingest_source_items!(items: [original])
    old_version = @store.source_item_versions(item_key: original.fetch("item_key")).fetch(0)

    changed_source = source.merge("market_label" => "CA")
    @store.register_sources!(sources: [changed_source])
    replay = original.merge("capture_id" => "version-replay-replayed", "capture_captured_at" => "2026-08-09T02:00:00Z", "fetched_at" => "2026-08-09T02:00:00Z")
    assert_raises(LocalRadarStore::Error) { @store.ingest_source_items!(items: [replay]) }

    versions = @store.source_item_versions(item_key: original.fetch("item_key"))
    assert_equal [old_version.fetch("version_id")], versions.map { |version| version.fetch("version_id") }
    assert_equal old_version.fetch("market_label"), versions.fetch(0).fetch("market_label")
  end

  private

  def prepare_membership_batch(batch_id:, with_signal_head: true)
    source = locale_source("en-US", "#{batch_id}-source")
    @store.register_sources!(sources: [source])
    item = locale_item(source: source, item_key: "#{batch_id}-item", capture_id: "#{batch_id}-capture", publisher_id: "publisher.example")
    @store.ingest_source_items!(items: [item])
    hash = @store.registry_contract_hash(sources: [source])
    @store.create_collection_batch!(batch_id: batch_id, registry_hash: hash, planned_source_count: 1, sources: [source])
    @store.record_source_fetch_attempt!(batch_id: batch_id, source_id: source.fetch("id"), outcome: "succeeded_with_items", item_count: 1, capture_id: item.fetch("capture_id"), http_status: 200, source_config_hash: hash)
    version = @store.selected_versions_for_batch(batch_id: batch_id).fetch(0)
    @store.freeze_collection_selection!(batch_id: batch_id, version_ids: [version.fetch("version_id")])
    if with_signal_head
      baseline = { "snapshot_id" => "#{batch_id}-baseline", "surface_id" => "public-radar", "revision" => 1, "comparison_watermark" => "2026-08-09T00:00:00Z", "method_epoch" => "test", "rights_epoch" => 1, "render_plan_hash" => "#{batch_id}-baseline" }
      @store.publish_snapshot!(snapshot: baseline, cards: [card])
    end
    [source, version]
  end

  def locale_source(locale, id)
    { "id" => id, "name" => id, "url" => "https://news.google.com/rss?hl=#{locale}&gl=US&ceid=US:en", "language" => locale.split("-").first, "locale_tag" => locale, "market_label" => "US", "market_label_basis" => "aggregator_locale_label", "region" => "US", "region_basis" => "aggregator_locale_label", "source_kind" => "discovery", "discovery_basis" => "locale_headlines", "query_conditioned" => false, "analysis_policy" => "exploration_only", "aggregator_id" => "google-news", "query_topics" => [], "enabled" => true }
  end

  def signal_source(id)
    { "id" => id, "name" => id, "url" => "https://signal.example/feed", "language" => "en", "region" => "editorial",
      "publisher_id" => "signal.example", "publisher_region" => "", "region_basis" => "editorial_scope_label",
      "source_kind" => "discovery", "discovery_basis" => "editorial_feed", "query_conditioned" => false,
      "analysis_policy" => "signal_eligible", "query_topics" => [], "enabled" => true }
  end

  def signal_item(source)
    locale_item(source: source, item_key: "signal-item", capture_id: "signal-capture", publisher_id: "signal.example").merge(
      "source_url" => "https://signal.example/item", "capture_source_url" => source.fetch("url"), "language" => "en",
      "region" => "editorial", "source_kind" => "discovery", "discovery_basis" => "editorial_feed",
      "analysis_policy" => "signal_eligible", "query_conditioned" => false, "query_topics" => []
    )
  end

  def locale_item(source:, item_key:, capture_id:, publisher_id:)
    source.merge("item_key" => item_key, "source_id" => source.fetch("id"), "source_name" => source.fetch("name"), "publisher_id" => publisher_id, "publisher_name" => publisher_id, "publisher_url" => "https://#{publisher_id}/", "publisher_identity_status" => "observed_domain", "title" => "fixture", "summary" => "fixture", "source_url" => "https://#{publisher_id}/#{item_key}", "published_at" => "2026-08-09T00:00:00Z", "fetched_at" => "2026-08-09T01:00:00Z", "capture_captured_at" => "2026-08-09T01:00:00Z", "capture_id" => capture_id, "capture_http_status" => 200, "capture_content_type" => "application/rss+xml", "capture_content_bytes" => 10, "capture_body_hash" => "body-#{capture_id}", "capture_storage_status" => "metadata_only", "capture_source_url" => source.fetch("url"))
  end

  def card
    { "card_id" => "breadth-card", "signal_type" => "news", "title" => "fixture", "summary" => "fixture", "metric_label" => "fixture", "metric_value" => "fixture", "source_count" => 1, "stance" => "unknown", "action_stage" => "review", "evidence_label" => "fixture", "sort_order" => 0 }
  end

  def trend
    { "trend_id" => "projection-trend", "topic_key" => "en:fixture", "topic" => "fixture", "topic_language" => "en",
      "topic_kind" => "term", "semantic_status" => "statistical_candidate", "topic_label" => "fixture",
      "topic_explanation" => "fixture", "signal_state" => "watching", "summary" => "fixture",
      "mention_count" => 3, "recent_mention_count" => 2, "prior_mention_count" => 1, "source_count" => 2,
      "region_count" => 1, "language_count" => 1, "growth_rate" => 100.0, "window_hours" => 48,
      "recent_window_hours" => 12, "window_start" => "2026-08-08T00:00:00Z", "window_end" => "2026-08-09T00:00:00Z",
      "source_names" => ["fixture-a", "fixture-b"], "regions" => ["fixture"], "languages" => ["en"],
      "evidence_urls" => ["https://example.test/fixture"], "sort_order" => 0 }
  end

  def run!(args)
    stdout, stderr, status = Open3.capture3(*args)
    raise "command failed: #{stderr}" unless status.success?
    stdout
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
