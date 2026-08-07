#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/manifest_compiler"
require_relative "../lib/test_catalog_generator"

root = File.expand_path("..", __dir__)
options = { output: nil, type: "TestCatalogManifest" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/compile_manifest.rb [options]"
  parser.on("--type TYPE") { |value| options[:type] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

rows = M1::TestCatalogGenerator.load_acceptance_plan(File.join(root, "docs/04-acceptance-test-plan.md"))
catalog = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
manifest = M1::ManifestCompiler.compile(
  manifest_type: options[:type],
  schema_version: catalog.fetch("schemaVersion"),
  owner: "m1-governance-compiler",
  effective_from: "2026-08-07T00:00:00Z",
  payload: catalog,
  contract_path: File.join(root, "docs/05-canonical-data-and-time-contract.md")
)
json = JSON.pretty_generate(manifest) + "\n"
if options[:output]
  File.write(options[:output], json)
  warn "wrote unsigned manifest: #{options[:output]}"
else
  puts json
end
