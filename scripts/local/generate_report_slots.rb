#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"
require "optparse"
require_relative "../../lib/local_report_ledger"

begin
options = {
  from: ENV["LOCAL_REPORT_DATE"], to: ENV["LOCAL_REPORT_DATE"],
  kinds: ENV.fetch("LOCAL_REPORT_KINDS", "morning,evening").split(",").map(&:strip).reject(&:empty?),
  configured_data_cutoff: ENV["LOCAL_REPORT_CONFIGURED_DATA_CUTOFF"]
}
OptionParser.new do |parser|
  parser.on("--date DATE", "local Asia/Shanghai date") { |value| options[:from] = value; options[:to] = value }
  parser.on("--from DATE", "first local date, inclusive") { |value| options[:from] = value }
  parser.on("--to DATE", "last local date, inclusive") { |value| options[:to] = value }
  parser.on("--kinds LIST", "morning,evening") { |value| options[:kinds] = value.split(",").map(&:strip) }
  parser.on("--configured-data-cutoff TIME", "immutable slot cutoff") { |value| options[:configured_data_cutoff] = value }
end.parse!(ARGV)

today = Time.now.getlocal("+08:00").to_date
from = Date.iso8601(options[:from].to_s.empty? ? today.iso8601 : options[:from].to_s)
to = Date.iso8601(options[:to].to_s.empty? ? from.iso8601 : options[:to].to_s)
raise ArgumentError, "--to must not precede --from" if to < from

ledger = LocalReportLedger.new
slots = []
(from..to).each do |date|
  slots.concat(ledger.generate_slots!(date: date, kinds: options[:kinds], configured_data_cutoff: options[:configured_data_cutoff]))
end
puts JSON.generate({ "status" => "ok", "timezone" => LocalReportLedger::TIMEZONE, "slots" => slots })
rescue LocalReportLedger::Error, ArgumentError, OptionParser::ParseError => error
  warn error.message
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
