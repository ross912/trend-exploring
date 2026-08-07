#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/canonical_schema_compiler"

root = File.expand_path("..", __dir__)
options = { output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_canonical_schema.rb [options]"
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

compiled = M1::CanonicalSchemaCompiler.compile(
  contract_path: File.join(root, "docs/05-canonical-data-and-time-contract.md"),
  object_map_path: File.join(root, "schema/object-map.json")
)
json = JSON.pretty_generate(compiled) + "\n"
if options[:output]
  File.write(options[:output], json)
  warn "wrote unsigned canonical schema contract: #{options[:output]}"
else
  puts json
end
