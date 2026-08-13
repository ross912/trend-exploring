#!/usr/bin/env ruby
# frozen_string_literal: true

# One bounded, idempotent local cycle.  This is deliberately clock-driven:
# collection may run at any time. Report publication never occurs before its
# 08:00/19:00 boundary, but a delayed launch may catch up until the next
# boundary. The immutable slot and idempotency key still guarantee one edition.
require "json"
require "optparse"
require "open3"
require "time"
require "date"
require "rbconfig"
require_relative "../../lib/local_report_ledger"
require_relative "../../lib/local_runtime"
require_relative "../../lib/weak_signal_store"

ROOT = File.expand_path("../..", __dir__)
LOCAL_ZONE = "+08:00"

options = { now: Time.now.getlocal(LOCAL_ZONE), ingest: ENV.fetch("LOCAL_CYCLE_INGEST", "1") == "1" }
OptionParser.new do |parser|
  parser.banner = "Usage: run_scheduled_cycle.rb [--now ISO8601] [--skip-ingest]"
  parser.on("--now TIME", "controlled Asia/Shanghai clock for tests") { |value| options[:now] = Time.iso8601(value).getlocal(LOCAL_ZONE) }
  parser.on("--skip-ingest", "skip collection and process the existing archive") { options[:ingest] = false }
end.parse!(ARGV)

def command_json!(command, env: {})
  stdout, stderr, status = Open3.capture3(env, *command)
  raise "#{command.join(' ')} failed: #{stderr.strip}" unless status.success?

  JSON.parse(stdout)
rescue JSON::ParserError => error
  raise "#{command.join(' ')} returned invalid JSON: #{error.message}"
end

def run_command(command, env: {})
  stdout, stderr, status = Open3.capture3(env, *command)
  { "status" => status.success? ? "passed" : "failed", "stdout" => stdout, "stderr" => stderr, "exit_code" => status.exitstatus }
end

def tail_output(value, limit = 4000)
  text = value.to_s
  text.length > limit ? text[-limit, limit] : text
end

def local_date_for(now)
  now.getlocal(LOCAL_ZONE).to_date
end

def slot_kind_for(now)
  hour = now.getlocal(LOCAL_ZONE).hour
  return "morning" if hour >= 8 && hour < 19
  return "evening" if hour >= 19

  nil
end

now = options.fetch(:now).getlocal(LOCAL_ZONE)
kind = slot_kind_for(now)
date = local_date_for(now)
env = {
  "LOCAL_REPORT_DATE" => date.iso8601,
  "LOCAL_CYCLE_NOW" => now.iso8601(6)
}
result = {
  "status" => "passed", "cycle_now" => now.iso8601(6), "timezone" => "Asia/Shanghai",
  "scheduled_kind" => kind, "collection" => nil, "report" => nil,
  "weak_signal" => nil, "world_change" => nil, "summary" => nil
}

if options.fetch(:ingest)
  collection = run_command([RbConfig.ruby, File.join(ROOT, "scripts/local/ingest_sources.rb")], env: env)
  result["collection"] = collection.reject { |key, _| key == "stdout" }.merge("output" => tail_output(collection["stdout"]))
  unless collection.fetch("status") == "passed"
    result["status"] = "degraded"
    result["collection"]["degraded"] = true
  end
end

collection_payload = begin
  JSON.parse(result.dig("collection", "output").to_s)
rescue JSON::ParserError
  {}
end
collection_degraded = result.dig("collection", "status") == "failed" || Array(collection_payload["source_errors"]).any?
result["collection"]["degraded"] = true if result["collection"] && collection_degraded
result["status"] = "degraded" if collection_degraded

ledger = LocalReportLedger.new
ledger.generate_slots!(date: date, kinds: LocalReportLedger::KINDS)
if kind
  scheduled_at = Time.new(date.year, date.month, date.day, kind == "morning" ? 8 : 19, 0, 0, LOCAL_ZONE)
  # A cycle can never publish before the immutable scheduled boundary.  The
  # report cutoff is therefore the scheduled boundary itself: the 07:55/18:55
  # pre-collection has time to land before this publication transaction.
  frontier = scheduled_at.utc.iso8601(6)
  begin
    published = ledger.publish_slot!(kind: kind, scheduled_at: scheduled_at.iso8601,
                                     idempotency_key: "scheduled-cycle-#{kind}-#{date.strftime('%Y%m%d')}",
                                     processing_frontier: frontier, selection_completeness_frontier: frontier,
                                     comparison_watermark: frontier,
                                     edition_status: collection_degraded ? "degraded" : "normal",
                                     reason_codes: collection_degraded ? ["DEGRADED_COVERAGE"] : [])
    result["report"] = { "status" => "published", "edition_id" => published.fetch("edition_id"), "item_count" => published.fetch("item_count") }
  rescue LocalReportLedger::Error => error
    result["status"] = "degraded"
    result["report"] = { "status" => "failed", "error" => error.message }
  end
else
  result["report"] = { "status" => "not_due", "reason" => "no report boundary has elapsed for the local date" }
end

if kind
  scheduled_at = Time.new(date.year, date.month, date.day, kind == "morning" ? 8 : 19, 0, 0, LOCAL_ZONE)
  weak_as_of = scheduled_at.utc.iso8601(6)
  weak_run_id = "scheduled-weak-#{kind}-#{date.strftime('%Y%m%d')}"
  begin
    weak = command_json!([RbConfig.ruby, File.join(ROOT, "scripts/local/detect_weak_signals.rb"), "--as-of", weak_as_of, "--run-id", weak_run_id])
    result["weak_signal"] = weak
  rescue StandardError => error
    result["status"] = "degraded"
    result["weak_signal"] = { "status" => "failed", "error" => error.message }
  end
else
  result["weak_signal"] = { "status" => "not_due", "reason" => "no report boundary has elapsed for the local date" }
end

# World-change analysis is deliberately downstream of the weak-signal run. It
# has its own immutable run id and degrades independently so raw reports still
# publish when a detector or lifecycle database is unavailable.
if kind
  world_as_of = scheduled_at.utc.iso8601(6)
  world_run_id = "scheduled-world-change-#{kind}-#{date.strftime('%Y%m%d')}"
  begin
    world = command_json!([RbConfig.ruby, File.join(ROOT, "scripts/local/detect_world_changes.rb"), "--as-of", world_as_of, "--run-id", world_run_id])
    result["world_change"] = world
  rescue StandardError => error
    result["status"] = "degraded"
    result["world_change"] = { "status" => "failed", "run_id" => world_run_id, "error" => error.message, "candidate_count" => 0 }
  end
else
  result["world_change"] = { "status" => "not_due", "reason" => "no report boundary has elapsed for the local date" }
end

if result.dig("report", "status") == "published"
  edition_id = result.dig("report", "edition_id")
  summary = run_command([RbConfig.ruby, File.join(ROOT, "scripts/local/generate_report_summary.rb"), "--edition-id", edition_id,
                         "--idempotency-key", "scheduled-summary-#{edition_id}"], env: env)
  result["summary"] = summary.reject { |key, _| key == "stdout" }.merge("output" => tail_output(summary["stdout"]))
  result["status"] = "degraded" if summary.fetch("status") == "failed"
else
  result["summary"] = { "status" => "not_run", "reason" => "no edition published in this cycle" }
end

puts JSON.pretty_generate(result)
