#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../lib/concept_mapping_provider"
require_relative "../../lib/concept_mapping_runner"
require_relative "../../lib/local_runtime"
require_relative "../../lib/multilingual_concept_store"

options = {
  mode: "dry_run", limit: 20, persist: false, allow_paid: false, fixture_file: nil
}
OptionParser.new do |parser|
  parser.banner = "Usage: map_concepts.rb [--mode dry_run|fixture|production] [--limit N] [--persist] [--allow-paid] [--fixture-file PATH]"
  parser.on("--mode MODE", %w[dry_run fixture production]) { |value| options[:mode] = value }
  parser.on("--limit N", Integer) { |value| options[:limit] = value }
  parser.on("--persist") { options[:persist] = true }
  parser.on("--allow-paid") { options[:allow_paid] = true }
  parser.on("--fixture-file PATH") { |value| options[:fixture_file] = value }
end.parse!

begin
  provider = case options.fetch(:mode)
             when "fixture"
               path = options.fetch(:fixture_file).to_s
               abort "--fixture-file is required in fixture mode" if path.empty?
               payload = JSON.parse(File.read(path))
               ConceptMappingProvider::Fixture.new(mappings: payload)
             when "production"
               ConceptMappingProvider::DeepSeek.new
             end
  store = MultilingualConceptStore.new
  result = ConceptMappingRunner.new(store: store, provider: provider).run(
    limit: options.fetch(:limit), mode: options.fetch(:mode), persist: options.fetch(:persist),
    allow_paid: options.fetch(:allow_paid)
  )
  puts JSON.pretty_generate(result)
rescue JSON::ParserError, Errno::ENOENT, OptionParser::ParseError, ConceptMappingRunner::Error,
       ConceptMappingProvider::Error, MultilingualConceptStore::Error, ArgumentError => error
  puts JSON.generate("status" => "failed", "error" => error.message)
  exit 1
end
