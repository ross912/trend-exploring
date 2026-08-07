#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/test_catalog_generator"

options = {
  phase: "M1",
  gate: "phase-exit",
  input: File.expand_path("../docs/04-acceptance-test-plan.md", __dir__),
  output: nil,
  governance_policy_version: nil
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_test_catalog.rb [options]"
  parser.on("--phase PHASE", M1::TestCatalogGenerator::PHASES) { |value| options[:phase] = value }
  parser.on("--gate GATE", M1::TestCatalogGenerator::BLOCKING) { |value| options[:gate] = value }
  parser.on("--input PATH") { |value| options[:input] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--governance-policy UUID") { |value| options[:governance_policy_version] = value }
end.parse!

rows = M1::TestCatalogGenerator.load_acceptance_plan(options[:input])
catalog = M1::TestCatalogGenerator.build(
  rows,
  target_phase: options[:phase],
  target_gate: options[:gate],
  governance_policy_version: options[:governance_policy_version]
)

if options[:output]
  File.write(options[:output], JSON.pretty_generate(catalog) + "\n")
  warn "wrote unsigned catalog: #{options[:output]}"
else
  puts JSON.pretty_generate(catalog)
end
