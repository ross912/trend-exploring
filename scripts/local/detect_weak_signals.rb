#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "optparse"
require_relative "../../lib/weak_signal_detector"
require_relative "../../lib/weak_signal_store"

options = { as_of: nil, run_id: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: detect_weak_signals.rb --as-of ISO8601 [--run-id ID]"
  parser.on("--as-of TIME", "required controlled analysis cutoff") { |value| options[:as_of] = value }
  parser.on("--run-id ID", "optional deterministic run id") { |value| options[:run_id] = value }
end.parse!

abort "--as-of is required" if options[:as_of].to_s.empty?

begin
  as_of = Time.iso8601(options[:as_of]).utc
  store = WeakSignalStore.new
  items = store.input_items(as_of: as_of)
  result = WeakSignalDetector.new.analyze(items: items, as_of: as_of)
  run_id = options[:run_id].to_s
  run_id = "weak-signal-#{Digest::SHA256.hexdigest(JSON.generate(result.slice("as_of", "input_hash", "detector_version")))[0, 24]}" if run_id.empty?
  run = result.slice("as_of", "input_cutoff", "input_hash", "detector_version", "status", "recent_window_hours", "prior_window_days", "prior_bucket_count")
  run["run_id"] = run_id
  published = store.publish!(run: run, candidates: result.fetch("candidates"))
  puts JSON.generate(published)
rescue WeakSignalDetector::Error, WeakSignalStore::Error, ArgumentError => error
  warn error.message
  exit 1
end
