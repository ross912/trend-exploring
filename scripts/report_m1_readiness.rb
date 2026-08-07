#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/m1_readiness"

root = File.expand_path("..", __dir__)
options = { output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/report_m1_readiness.rb [--output PATH]"
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

report = M1::M1Readiness.evaluate(
  acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
  coverage: JSON.parse(File.read(File.join(root, "schema/m1-phase-exit-coverage.json")))
)
json = JSON.pretty_generate(report) + "\n"
if options[:output]
  File.write(options.fetch(:output), json)
else
  puts json
end
exit 1 unless report.fetch("decision") == "ready"
