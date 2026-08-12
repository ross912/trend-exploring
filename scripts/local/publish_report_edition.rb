#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require_relative "../../lib/local_report_ledger"

begin
options = {
  slot_id: ENV["LOCAL_REPORT_SLOT_ID"], kind: ENV["LOCAL_REPORT_KIND"], scheduled_at: ENV["LOCAL_REPORT_SCHEDULED_AT"],
  idempotency_key: ENV["LOCAL_REPORT_IDEMPOTENCY_KEY"],
  processing_frontier: ENV["LOCAL_REPORT_PROCESSING_FRONTIER"],
  selection_completeness_frontier: ENV["LOCAL_REPORT_SELECTION_FRONTIER"],
  configured_data_cutoff: ENV["LOCAL_REPORT_CONFIGURED_DATA_CUTOFF"], data_cutoff: ENV["LOCAL_REPORT_DATA_CUTOFF"],
  comparison_watermark: ENV["LOCAL_REPORT_COMPARISON_WATERMARK"], edition_status: ENV.fetch("LOCAL_REPORT_EDITION_STATUS", "normal"),
  reason_codes: ENV.fetch("LOCAL_REPORT_REASON_CODES", "").split(",").map(&:strip).reject(&:empty?)
}
OptionParser.new do |parser|
  parser.on("--slot-id ID") { |value| options[:slot_id] = value }
  parser.on("--kind KIND") { |value| options[:kind] = value }
  parser.on("--scheduled-at TIME") { |value| options[:scheduled_at] = value }
  parser.on("--idempotency-key KEY") { |value| options[:idempotency_key] = value }
  parser.on("--processing-frontier TIME") { |value| options[:processing_frontier] = value }
  parser.on("--selection-frontier TIME") { |value| options[:selection_completeness_frontier] = value }
  parser.on("--configured-data-cutoff TIME") { |value| options[:configured_data_cutoff] = value }
  parser.on("--data-cutoff TIME") { |value| options[:data_cutoff] = value }
  parser.on("--comparison-watermark TIME") { |value| options[:comparison_watermark] = value }
  parser.on("--edition-status STATUS") { |value| options[:edition_status] = value }
  parser.on("--reason-codes LIST") { |value| options[:reason_codes] = value.split(",").map(&:strip).reject(&:empty?) }
end.parse!(ARGV)

raise ArgumentError, "--slot-id or --kind/--scheduled-at is required" if options[:slot_id].to_s.empty? && (options[:kind].to_s.empty? || options[:scheduled_at].to_s.empty?)
raise ArgumentError, "--processing-frontier is required" if options[:processing_frontier].to_s.empty?
raise ArgumentError, "--selection-frontier is required" if options[:selection_completeness_frontier].to_s.empty?
raise ArgumentError, "--comparison-watermark is required" if options[:comparison_watermark].to_s.empty?

options[:idempotency_key] = "report-publish-#{Digest::SHA256.hexdigest(JSON.generate(options.reject { |key, _| key == :idempotency_key }))[0, 32]}" if options[:idempotency_key].to_s.empty?
ledger = LocalReportLedger.new
edition = ledger.publish_slot!(**options)
puts JSON.generate({ "status" => "published", "edition" => edition })
rescue LocalReportLedger::Error, ArgumentError, OptionParser::ParseError => error
  warn error.message
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
