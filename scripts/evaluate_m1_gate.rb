#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/m1_gate_evaluator"

options = { catalog: nil, results: nil, output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/evaluate_m1_gate.rb --catalog PATH [--results PATH]"
  parser.on("--catalog PATH") { |value| options[:catalog] = value }
  parser.on("--results PATH") { |value| options[:results] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

abort "--catalog is required" unless options[:catalog]
catalog = JSON.parse(File.read(options.fetch(:catalog)))
results = options[:results] ? JSON.parse(File.read(options.fetch(:results))) : {}
results = results.each_with_object({}) do |entry, memo|
  memo[entry.fetch("testDefinitionVersionId")] = entry.fetch("result")
end if results.is_a?(Array)
report = M1::M1GateEvaluator.evaluate(catalog: catalog, results: results)
json = JSON.pretty_generate(report) + "\n"
if options[:output]
  File.write(options.fetch(:output), json)
else
  puts json
end
exit 1 unless report.fetch("decision") == "pass"
