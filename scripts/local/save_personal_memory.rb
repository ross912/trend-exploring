#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../lib/personal_memory_store"

options = {
  database: ENV.fetch("PERSONAL_PGDATABASE", PersonalMemoryStore::DEFAULT_DATABASE),
  subject_key: ENV["PERSONAL_SUBJECT_KEY"],
  memory_entry_id: ENV["PERSONAL_MEMORY_ENTRY_ID"],
  memory_kind: ENV["PERSONAL_MEMORY_KIND"],
  text: ENV["PERSONAL_MEMORY_TEXT"],
  source: ENV.fetch("PERSONAL_MEMORY_SOURCE", "manual_import"),
  status: ENV.fetch("PERSONAL_MEMORY_STATUS", "active"),
  supersedes_entry_id: ENV["PERSONAL_MEMORY_SUPERSEDES_ENTRY_ID"],
  evidence_version_ids: ENV.fetch("PERSONAL_MEMORY_EVIDENCE_VERSION_IDS", "[]")
}
begin
OptionParser.new do |parser|
  parser.on("--database NAME") { |value| options[:database] = value }
  parser.on("--subject-key KEY") { |value| options[:subject_key] = value }
  parser.on("--memory-entry-id ID") { |value| options[:memory_entry_id] = value }
  parser.on("--kind KIND") { |value| options[:memory_kind] = value }
  parser.on("--text TEXT") { |value| options[:text] = value }
  parser.on("--source SOURCE") { |value| options[:source] = value }
  parser.on("--status STATUS") { |value| options[:status] = value }
  parser.on("--supersedes-entry-id ID") { |value| options[:supersedes_entry_id] = value }
  parser.on("--evidence-version-ids JSON") { |value| options[:evidence_version_ids] = value }
end.parse!(ARGV)

refs = JSON.parse(options.fetch(:evidence_version_ids))
raise ArgumentError, "evidence-version-ids must be a JSON array" unless refs.is_a?(Array)
store = PersonalMemoryStore.new(database: options.fetch(:database))
entry = store.append!(memory_entry_id: options.fetch(:memory_entry_id), subject_key: options.fetch(:subject_key),
                      memory_kind: options.fetch(:memory_kind), text: options.fetch(:text),
                      source: options.fetch(:source), status: options.fetch(:status),
                      supersedes_entry_id: options.fetch(:supersedes_entry_id), evidence_version_ids: refs)
puts JSON.generate({ "status" => "saved", "entry" => entry })
rescue PersonalMemoryStore::Error, ArgumentError, JSON::ParserError, OptionParser::ParseError => error
  warn error.message
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
