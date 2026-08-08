#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/m2_readiness"

root = File.expand_path("..", __dir__)
options = { output: nil, test_code: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/report_m2_readiness.rb [--output PATH] [--test-code CODE]"
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--test-code CODE") { |value| options[:test_code] = value }
end.parse!

report = M2::M2Readiness.evaluate(
  acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
  coverage: JSON.parse(File.read(File.join(root, "schema/m2-phase-exit-coverage.json"))),
  root: root
)
if options[:test_code]
  entry = report.fetch("entries").find { |candidate| candidate.fetch("testCode") == options[:test_code] }
  report = {
    "decision" => entry && entry.fetch("effectiveStatus") == "fixture_passed" ? "ready" : "blocked",
    "testCode" => options[:test_code],
    "entry" => entry,
    "summary" => report.fetch("summary")
  }
end
json = JSON.pretty_generate(report) + "\n"
if options[:output]
  File.write(options.fetch(:output), json)
else
  puts json
end
exit 1 unless report.fetch("decision") == "ready"
