#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/permission_matrix"

options = { output: nil, version: "m1.permission-matrix.v1" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_permission_matrix.rb [options]"
  parser.on("--version VERSION") { |value| options[:version] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

json = JSON.pretty_generate(M1::PermissionMatrix.build(matrix_version: options[:version])) + "\n"
if options[:output]
  File.write(options[:output], json)
  warn "wrote unsigned permission matrix: #{options[:output]}"
else
  puts json
end
