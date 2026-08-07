#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/event_registry"

options = { output: nil, version: "m1.event-registry.v1" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_event_registry.rb [options]"
  parser.on("--version VERSION") { |value| options[:version] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

registry = M1::EventRegistry.build(registry_version: options[:version])
json = JSON.pretty_generate(registry) + "\n"
if options[:output]
  File.write(options[:output], json)
  warn "wrote unsigned event registry: #{options[:output]}"
else
  puts json
end
