#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/bitemporal_query"

options = { output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_bitemporal_queries.rb [options]"
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

M1::BitemporalQuery.validate!
text = M1::BitemporalQuery.templates.map do |name, query|
  "-- #{name}\n#{query}"
end.join("\n")
text += "\n"
if options[:output]
  File.write(options[:output], text)
  warn "wrote bitemporal query templates: #{options[:output]}"
else
  puts text
end
