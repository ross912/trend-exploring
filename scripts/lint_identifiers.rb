#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/identifier_linter"

options = { root: File.expand_path("..", __dir__) }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/lint_identifiers.rb [--root PATH]"
  parser.on("--root PATH") { |value| options[:root] = File.expand_path(value) }
end.parse!

errors = M1::IdentifierLinter.lint(root: options[:root])
if errors.empty?
  puts JSON.pretty_generate({ "status" => "passed", "errors" => [] })
else
  puts JSON.pretty_generate({ "status" => "failed", "errors" => errors })
  exit 1
end
