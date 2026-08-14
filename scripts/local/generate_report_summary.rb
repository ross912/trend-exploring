#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../lib/local_report_ledger"
require_relative "../../lib/report_summary_provider"
require_relative "../../lib/report_summary_runner"

begin
options = {
  "edition_id" => ENV["REPORT_SUMMARY_EDITION_ID"],
  "kind" => ENV["REPORT_SUMMARY_KIND"],
  "idempotency_key" => ENV["REPORT_SUMMARY_IDEMPOTENCY_KEY"]
}
OptionParser.new do |parser|
  parser.on("--edition-id ID") { |value| options["edition_id"] = value }
  parser.on("--kind KIND") { |value| options["kind"] = value }
  parser.on("--idempotency-key KEY") { |value| options["idempotency_key"] = value }
end.parse!(ARGV)

ledger = LocalReportLedger.new
edition_id = options["edition_id"].to_s
if edition_id.empty?
  kind = options["kind"].to_s
  raise ArgumentError, "--edition-id or --kind is required" unless %w[morning evening].include?(kind)

  report = ledger.latest_report(kind: kind)
  edition_id = report.dig("edition", "edition_id").to_s
  raise ArgumentError, "no published edition for kind #{kind}" if edition_id.empty?
end
key = options["idempotency_key"].to_s
if key.empty?
  ledger.recover_stale_summary_runs!(edition_id: edition_id, recovery_owner: "summary-cli-#{Process.pid}")
  key = ledger.next_summary_idempotency_key(edition_id: edition_id, base_key: "report-summary-#{edition_id}",
                                            max_attempts: LocalReportLedger::SUMMARY_MAX_ATTEMPTS)
  if key.nil?
    puts JSON.generate({ "status" => "attempts_exhausted", "edition_id" => edition_id,
                         "attempt_limit" => LocalReportLedger::SUMMARY_MAX_ATTEMPTS })
    exit 0
  end
end

result = ReportSummaryRunner.new(ledger: ledger).run(edition_id: edition_id, idempotency_key: key)
puts JSON.generate(result)
rescue LocalReportLedger::Error, ReportSummaryProvider::Error, ReportSummaryRunner::Error, ArgumentError, OptionParser::ParseError => error
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
