#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "time"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/rss_ingest"
require_relative "../../lib/trend_analyzer"
require_relative "../../lib/event_candidate_analyzer"
require_relative "../../lib/translation_provider"
require_relative "../../lib/translation_runner"
require_relative "../../lib/breadth_discovery_selector"

root = File.expand_path("../..", __dir__)
config_path = ENV.fetch("LOCAL_SOURCES_CONFIG", File.join(root, "config/sources.json"))
config = JSON.parse(File.read(config_path))
selected_ids = ENV["LOCAL_SOURCE_IDS"]&.split(",")&.map(&:strip)
configured_sources = Array(config.fetch("sources"))
discovery_sources = ENV.fetch("LOCAL_SOURCE_DISCOVERY", "1") == "1" ? Array(config.fetch("discovery_sources", [])) : []
locale_sources = ENV.fetch("LOCAL_SOURCE_LOCALE_HEADLINES", "1") == "1" ? Array(config.fetch("locale_headlines", [])) : []
all_sources = configured_sources + discovery_sources + locale_sources
sources = all_sources.select do |source|
  selected_ids.nil? ? source.fetch("enabled", true) : selected_ids.include?(source.fetch("id"))
end
abort "no configured sources selected" if sources.empty?
store = LocalRadarStore.new
# A filtered run is an isolated collection batch: keep unselected editorial or
# topic-conditioned registry rows out of this disposable database. With no
# LOCAL_SOURCE_IDS filter, preserve the normal all-enabled source matrix.
store.register_sources!(sources: sources)

selected_locale_sources = locale_sources.select do |source|
  source.fetch("enabled", true) && (selected_ids.nil? || selected_ids.include?(source.fetch("id")))
end
locale_batch_id = "locale-frontier-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-#{Digest::SHA256.hexdigest(selected_locale_sources.map { |source| source.fetch('id') }.sort.join(','))[0, 10]}"
locale_batch = if selected_locale_sources.empty?
                 nil
               else
                 store.create_collection_batch!(
                   batch_id: locale_batch_id,
                   registry_hash: store.registry_contract_hash(sources: selected_locale_sources),
                   planned_source_count: selected_locale_sources.length,
                   selected_count: 0,
                   sources: selected_locale_sources
                 )
               end

fetcher = RSSIngest::Fetcher.new
items = []
errors = []
locale_attempts = []
sources.each do |source|
  begin
    fetched = fetcher.fetch(source)
    items.concat(fetched)
    store.record_source_fetch!(source_id: source.fetch("id"), item_count: fetched.length)
    if selected_locale_sources.any? { |candidate| candidate.fetch("id") == source.fetch("id") }
      capture_ids = fetched.map { |item| item.fetch("capture_id", "") }.uniq.reject(&:empty?)
      locale_attempts << {
        batch_id: locale_batch_id, source_id: source.fetch("id"),
        outcome: fetched.empty? ? "succeeded_empty" : "succeeded_with_items",
        item_count: fetched.length, capture_id: fetched.empty? ? nil : capture_ids.fetch(0),
        http_status: fetcher.last_capture.fetch("http_status"), discovery_basis: "locale_headlines", query_conditioned: false,
        analysis_policy: "exploration_only", source_config_hash: store.registry_contract_hash(sources: [source])
      }
    end
    # Keep stdout machine-readable for the final JSON report; per-source
    # progress belongs on stderr so callers can persist/report the batch
    # without scraping mixed logs.
    warn "fetched #{source.fetch('id')}: #{fetched.length} items"
  rescue RSSIngest::Error => error
    errors << { "source_id" => source.fetch("id"), "error" => error.message }
    store.record_source_fetch!(source_id: source.fetch("id"), item_count: 0, error: error.message)
    if selected_locale_sources.any? { |candidate| candidate.fetch("id") == source.fetch("id") }
      locale_attempts << {
        batch_id: locale_batch_id, source_id: source.fetch("id"), outcome: "failed", item_count: 0,
        http_status: (error.message[/HTTP (\d{3})/, 1]&.to_i), discovery_basis: "locale_headlines", query_conditioned: false,
        analysis_policy: "exploration_only", source_config_hash: store.registry_contract_hash(sources: [source]),
        error_code: "fetch_failed", error_message: error.message
      }
    end
    warn error.message
  end
end
begin
  inserted = store.ingest_source_items!(items: items)
rescue StandardError => ingest_error
  if locale_batch
    by_source = locale_attempts.to_h { |attempt| [attempt.fetch(:source_id), attempt] }
    selected_locale_sources.each do |source|
      by_source[source.fetch("id")] = {
        batch_id: locale_batch_id, source_id: source.fetch("id"), outcome: "failed", item_count: 0,
        capture_id: nil, http_status: nil, discovery_basis: "locale_headlines", query_conditioned: false,
        analysis_policy: "exploration_only", source_config_hash: store.registry_contract_hash(sources: [source]),
        error_code: "persist_failed", error_message: ingest_error.message
      }
    end
    store.record_source_fetch_attempts!(attempts: by_source.values)
    store.freeze_collection_selection!(batch_id: locale_batch_id, version_ids: [])
    store.finalize_collection_batch!(batch_id: locale_batch_id, status: "failed")
  end
  raise
end
store.record_source_fetch_attempts!(attempts: locale_attempts) if locale_batch
selected_locale_versions = locale_batch ? store.selected_versions_for_batch(batch_id: locale_batch_id) : []
store.freeze_collection_selection!(batch_id: locale_batch_id, version_ids: selected_locale_versions.map { |version| version.fetch("version_id") }) if locale_batch
if items.empty?
  if locale_batch
    terminal_status = errors.empty? ? "published" : "failed"
    store.finalize_collection_batch!(batch_id: locale_batch_id, status: terminal_status)
    puts JSON.pretty_generate({
      "status" => errors.empty? ? "success_empty" : "failed",
      "batch_id" => locale_batch_id,
      "worker_state" => errors.empty? ? "success_empty" : "failed",
      "planned_source_count" => selected_locale_sources.length,
      "error_count" => errors.length,
      "source_errors" => errors
    })
    exit 0
  end
  abort "all source fetches failed"
end
translation_result = { "status" => "not_requested", "translated_count" => 0, "failed_count" => 0, "blocked_count" => 0 }
if ENV.fetch("LOCAL_TRANSLATE_LIVE", "0") == "1"
  translation_result = TranslationRunner.new(store: store, provider: TranslationProvider::OpenAICompatible.new).run(limit: Integer(ENV.fetch("LOCAL_TRANSLATION_LIMIT", "20")))
end
signal_batch_items = items.select { |item| item.fetch("analysis_policy", "signal_eligible").to_s == "signal_eligible" }
prior_signal_radar = signal_batch_items.empty? ? store.current_radar : nil
latest = store.latest_source_items(limit: Integer(ENV.fetch("LOCAL_RADAR_CARD_LIMIT", "8")), published_only: true, analysis_policy: "signal_eligible")
analysis_items = store.latest_source_items(limit: Integer(ENV.fetch("LOCAL_TREND_ITEM_LIMIT", "500")), published_only: true, analysis_policy: "signal_eligible")
event_analysis_items = store.event_analysis_items(limit: Integer(ENV.fetch("LOCAL_EVENT_ITEM_LIMIT", ENV.fetch("LOCAL_TREND_ITEM_LIMIT", "500"))), analysis_policy: "signal_eligible")
raw_trends = TrendAnalyzer.new(
  window_hours: Integer(ENV.fetch("LOCAL_TREND_WINDOW_HOURS", "48")),
  recent_window_hours: Integer(ENV.fetch("LOCAL_TREND_RECENT_HOURS", "12"))
).analyze(items: analysis_items)
revision = store.next_revision
snapshot_id = "rss-batch-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-r#{revision}"
watermark = store.signal_comparison_watermark(items: items)
cards = latest.each_with_index.map do |item, index|
  published = item.fetch("published_at").to_s
  display_time = begin
    Time.parse(published).getlocal("+08:00").strftime("%m月%d日 %H:%M")
  rescue ArgumentError
    "时间待确认"
  end
  {
    "card_id" => "#{snapshot_id}-card-#{index + 1}",
    "signal_type" => "新闻",
    "title" => item.fetch("display_title"),
    "summary" => item.fetch("display_summary").to_s.empty? ? "该来源未提供摘要，点击原文查看详情。" : item.fetch("display_summary"),
    "metric_label" => "发布时间",
    "metric_value" => display_time,
    "source_count" => 1,
    "stance" => "unknown",
    "action_stage" => "待观察",
    "evidence_label" => "#{item.fetch('publisher_name', item.fetch('source_name'))} · 来源条目元数据 / 短摘要版本",
    "source_name" => item.fetch("publisher_name", item.fetch("source_name")),
    "source_url" => item.fetch("source_url"),
    "source_language" => item.fetch("language"),
    "source_region" => item.fetch("region", "未标注"),
    "original_title" => item.fetch("title"),
    "original_summary" => item.fetch("summary"),
    "translation_status" => item.fetch("translation_status"),
    "translation_artifact_id" => item.fetch("translation_artifact_id", ""),
    "translated_at" => item.fetch("translated_at").to_s.empty? ? nil : item.fetch("translated_at"),
    "sort_order" => index
  }
end
trends = raw_trends.each_with_index.map do |trend, index|
  trend.merge(
    "trend_id" => "#{snapshot_id}-trend-#{Digest::SHA256.hexdigest(trend.fetch('trend_key'))[0, 12]}",
    "sort_order" => index
  )
end
raw_event_candidates = EventCandidateAnalyzer.new(
  max_age_hours: Integer(ENV.fetch("LOCAL_EVENT_MAX_AGE_HOURS", "72"))
).analyze(items: event_analysis_items, now: Time.now.utc)
event_candidates = raw_event_candidates.each_with_index.map do |candidate, index|
  candidate.merge(
    "candidate_id" => "#{snapshot_id}-event-#{Digest::SHA256.hexdigest(candidate.fetch('candidate_key'))[0, 12]}",
    "sort_order" => index
  )
end
if signal_batch_items.empty?
  # A locale-only/failed-signal batch may still publish a new exploration
  # snapshot, but it must preserve the prior signal surface byte-for-byte.
  prior_cards = Array(prior_signal_radar && prior_signal_radar.fetch("cards", []))
  abort "locale-only batch has no prior signal snapshot to preserve" if prior_cards.empty?
  cards = prior_cards.each_with_index.map do |card, index|
    card.merge("card_id" => "#{snapshot_id}-preserved-card-#{index}", "sort_order" => index,
               "translated_at" => card.fetch("translated_at", "").to_s.empty? ? nil : card.fetch("translated_at"))
  end
  trends = Array(prior_signal_radar.fetch("trends", [])).each_with_index.map do |trend, index|
    trend.merge("trend_id" => "#{snapshot_id}-preserved-trend-#{index}", "sort_order" => index,
                "growth_rate" => trend.fetch("growth_rate", "").to_s.empty? ? nil : trend.fetch("growth_rate"))
  end
  event_candidates = Array(prior_signal_radar.fetch("event_candidates", [])).each_with_index.map { |candidate, index| candidate.merge("candidate_id" => "#{snapshot_id}-preserved-event-#{index}", "sort_order" => index) }
end
exploration_memberships = selected_locale_versions.each_with_index.map do |version, index|
  {
    "version_id" => version.fetch("version_id"),
    "resolution" => version.fetch("publisher_identity_status") == "unresolved" || version.fetch("publisher_id").to_s.empty? ? "unresolved" : "resolved",
    "sort_order" => index
  }
end

snapshot_payload = lambda do |id, number, method_epoch:, rights_epoch:, projection_status:, projection_source: nil|
  {
    "snapshot_id" => id,
    "surface_id" => "public-radar",
    "revision" => number,
    "comparison_watermark" => watermark,
    "method_epoch" => method_epoch,
    "rights_epoch" => rights_epoch,
    "render_plan_hash" => "#{id}-render",
    "signal_projection_status" => projection_status,
    "signal_source_snapshot_id" => projection_source
  }
end

rekey_cards = lambda do |rows, id|
  rows.each_with_index.map { |row, index| row.merge("card_id" => "#{id}-card-#{index + 1}", "sort_order" => index) }
end
rekey_trends = lambda do |rows, id|
  rows.each_with_index.map do |row, index|
    row.merge("trend_id" => "#{id}-trend-#{Digest::SHA256.hexdigest(row.fetch('trend_key', row.fetch('topic_key')))[0, 12]}", "sort_order" => index)
  end
end
rekey_events = lambda do |rows, id|
  rows.each_with_index.map do |row, index|
    row.merge("candidate_id" => "#{id}-event-#{Digest::SHA256.hexdigest(row.fetch('candidate_key'))[0, 12]}", "sort_order" => index)
  end
end

published_snapshot_ids = []
signal_snapshot_id = nil
if locale_batch && !signal_batch_items.empty?
  # Mixed runs have two explicit publication boundaries: commit the fresh
  # signal head first, then commit a next-revision exploration snapshot that
  # reuses that exact signal surface while attaching the frozen locale batch.
  fresh_snapshot = snapshot_payload.call(snapshot_id, revision, method_epoch: "rss-batch-v2", rights_epoch: 1, projection_status: "fresh_batch")
  fresh_published = store.publish_snapshot!(snapshot: fresh_snapshot, cards: cards, trends: trends, event_candidates: event_candidates)
  signal_snapshot_id = fresh_published.dig("snapshot", "snapshot_id")
  published_snapshot_ids << signal_snapshot_id

  if selected_locale_versions.empty?
    # Empty/failed locale runs have no membership projection to publish. Keep
    # the fresh signal head and close the batch from its attempt denominator.
    locale_failed = locale_attempts.any? { |attempt| attempt.fetch(:outcome).to_s == "failed" }
    store.finalize_collection_batch!(batch_id: locale_batch_id, status: locale_failed ? "failed" : "published")
    published = store.current_radar
  else
    reused_revision = store.next_revision
    reused_snapshot_id = "rss-batch-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-r#{reused_revision}"
    # Reuse the committed source projection, not the caller's pre-persistence
    # hashes. PostgreSQL canonicalizes timestamps/numerics and the store may
    # truncate display summaries; lineage must compare against what was
    # actually published.
    reused_published = store.publish_snapshot!(
      snapshot: snapshot_payload.call(reused_snapshot_id, reused_revision, method_epoch: fresh_snapshot.fetch("method_epoch"), rights_epoch: fresh_snapshot.fetch("rights_epoch"), projection_status: "reused_previous", projection_source: signal_snapshot_id),
      cards: rekey_cards.call(fresh_published.fetch("cards", []), reused_snapshot_id),
      trends: rekey_trends.call(fresh_published.fetch("trends", []), reused_snapshot_id),
      event_candidates: rekey_events.call(fresh_published.fetch("event_candidates", []), reused_snapshot_id),
      batch_id: locale_batch_id,
      exploration_items: exploration_memberships
    )
    published = reused_published
    published_snapshot_ids << published.dig("snapshot", "snapshot_id")
  end
elsif signal_batch_items.empty?
  # Locale-only runs reuse the existing signal head and never create a fresh
  # signal projection.
  published = store.publish_snapshot!(
    snapshot: snapshot_payload.call(snapshot_id, revision, method_epoch: prior_signal_radar.dig("snapshot", "method_epoch"), rights_epoch: prior_signal_radar.dig("snapshot", "rights_epoch"), projection_status: "reused_previous", projection_source: prior_signal_radar.dig("snapshot", "snapshot_id")),
    cards: cards,
    trends: trends,
    event_candidates: event_candidates,
    batch_id: locale_batch_id,
    exploration_items: exploration_memberships
  )
  published_snapshot_ids << published.dig("snapshot", "snapshot_id")
else
  # Signal-only runs publish one fresh head with no exploration batch attached.
  published = store.publish_snapshot!(
    snapshot: snapshot_payload.call(snapshot_id, revision, method_epoch: "rss-batch-v2", rights_epoch: 1, projection_status: "fresh_batch"),
    cards: cards,
    trends: trends,
    event_candidates: event_candidates
  )
  published_snapshot_ids << published.dig("snapshot", "snapshot_id")
  signal_snapshot_id = published.dig("snapshot", "snapshot_id")
end

puts JSON.pretty_generate({
  "status" => "passed",
  "source_count" => sources.length,
  "fetched_item_count" => items.length,
  "inserted_item_count" => inserted,
  "published_snapshot_id" => published.dig("snapshot", "snapshot_id"),
  "published_snapshot_ids" => published_snapshot_ids,
  "signal_snapshot_id" => signal_snapshot_id,
  "card_count" => published.fetch("cards").length,
  "trend_count" => published.fetch("trends").length,
  "trend_topics" => published.fetch("trends").map { |trend| trend.fetch("topic") },
  "event_candidate_count" => published.fetch("event_candidates").length,
  "event_candidate_labels" => published.fetch("event_candidates").map { |candidate| candidate.fetch("label") },
  "active_source_count" => published.fetch("sources").count { |source| source.fetch("enabled") },
  "source_item_counts" => published.fetch("sources").to_h { |source| [source.fetch("source_id"), source.fetch("last_item_count")] },
  "translation" => translation_result,
  "archive" => published.fetch("archive"),
  "source_errors" => errors
})
