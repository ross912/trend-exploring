#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/rss_ingest"

root = File.expand_path("../..", __dir__)
config_path = ENV.fetch("LOCAL_SOURCES_CONFIG", File.join(root, "config/sources.json"))
config = JSON.parse(File.read(config_path))
selected_ids = ENV["LOCAL_SOURCE_IDS"]&.split(",")&.map(&:strip)
sources = Array(config.fetch("sources")).select { |source| selected_ids.nil? || selected_ids.include?(source.fetch("id")) }
abort "no configured sources selected" if sources.empty?

fetcher = RSSIngest::Fetcher.new
store = LocalRadarStore.new
items = []
errors = []
sources.each do |source|
  begin
    fetched = fetcher.fetch(source)
    items.concat(fetched)
    puts "fetched #{source.fetch('id')}: #{fetched.length} items"
  rescue RSSIngest::Error => error
    errors << { "source_id" => source.fetch("id"), "error" => error.message }
    warn error.message
  end
end
abort "all source fetches failed" if items.empty?

inserted = store.ingest_source_items!(items: items)
latest = store.latest_source_items(limit: Integer(ENV.fetch("LOCAL_RADAR_CARD_LIMIT", "8")))
revision = store.next_revision
snapshot_id = "live-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-r#{revision}"
watermark = latest.map { |item| item.fetch("published_at") }.compact.min || Time.now.utc.iso8601
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
    "title" => item.fetch("title"),
    "summary" => item.fetch("summary").to_s.empty? ? "该来源未提供摘要，点击原文查看详情。" : item.fetch("summary"),
    "metric_label" => "发布时间",
    "metric_value" => display_time,
    "source_count" => 1,
    "stance" => "unknown",
    "action_stage" => "待观察",
    "evidence_label" => "#{item.fetch('source_name')} · 原文版本",
    "source_name" => item.fetch("source_name"),
    "source_url" => item.fetch("source_url"),
    "sort_order" => index
  }
end

published = store.publish_snapshot!(
  snapshot: {
    "snapshot_id" => snapshot_id,
    "surface_id" => "public-radar",
    "revision" => revision,
    "comparison_watermark" => watermark,
    "method_epoch" => "rss-live-v1",
    "rights_epoch" => 1,
    "render_plan_hash" => "#{snapshot_id}-render"
  },
  cards: cards
)

puts JSON.pretty_generate({
  "status" => "passed",
  "source_count" => sources.length,
  "fetched_item_count" => items.length,
  "inserted_item_count" => inserted,
  "published_snapshot_id" => published.dig("snapshot", "snapshot_id"),
  "card_count" => published.fetch("cards").length,
  "source_errors" => errors
})
