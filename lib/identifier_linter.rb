# frozen_string_literal: true

require "json"
require_relative "event_registry"

module M1
  module IdentifierLinter
    class Error < StandardError; end
    VALID_ROLES = %w[identity manifest record event child].freeze
    VALID_PROFILES = %w[
      identity_time operational_record_time derived_record_time
      standalone_snapshot_time bitemporal_version_time manifest_time
      manifest_child_time event_time inherits_parent
    ].freeze

    module_function

    def lint(root:)
      errors = []
      acceptance_path = File.join(root, "docs/04-acceptance-test-plan.md")
      acceptance = File.read(acceptance_path)
      acceptance_ids = acceptance.scan(/^\| ([A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?) \|/).flatten
      errors.concat(duplicate_errors(acceptance_ids, "acceptance ID"))
      Dir[File.join(root, "docs/*.md")].sort.each do |path|
        next if path == acceptance_path

        ids = File.read(path).scan(/\b[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\b/).uniq
        (ids - acceptance_ids).each { |id| errors << "#{path}: unknown acceptance ID #{id}" }
      end

      object_map = JSON.parse(File.read(File.join(root, "schema/object-map.json")))
      mappings = object_map.fetch("mappings")
      tables = mappings.map { |mapping| mapping.fetch("table") }
      errors.concat(duplicate_errors(tables, "object-map table"))
      mappings.each do |mapping|
        role = mapping.fetch("role")
        profile = mapping.fetch("timeProfile")
        errors << "invalid object-map role: #{role}" unless VALID_ROLES.include?(role)
        errors << "invalid object-map time profile: #{profile}" unless VALID_PROFILES.include?(profile)
        errors << "blank canonical object" if mapping.fetch("canonicalObject").to_s.strip.empty?
      end

      infrastructure_map = JSON.parse(File.read(File.join(root, "schema/event-infrastructure-map.json")))
      infrastructure_mappings = infrastructure_map.fetch("mappings")
      infrastructure_tables = infrastructure_mappings.map { |mapping| mapping.fetch("table") }
      sql = File.read(File.join(root, "schema/postgres/002_event_base.sql"))
      sql_tables = sql.scan(/^CREATE TABLE\s+(\w+)/).flatten
      errors << "event infrastructure tables are not mapped: #{(sql_tables - infrastructure_tables).join(', ')}" unless (sql_tables - infrastructure_tables).empty?
      errors << "event infrastructure map has unknown tables: #{(infrastructure_tables - sql_tables).join(', ')}" unless (infrastructure_tables - sql_tables).empty?
      errors.concat(duplicate_errors(infrastructure_tables, "event infrastructure table"))
      infrastructure_mappings.each do |mapping|
        errors << "event infrastructure role must be infrastructure" unless mapping.fetch("role") == "infrastructure"
        errors << "invalid event infrastructure time profile: #{mapping.fetch('timeProfile')}" unless VALID_PROFILES.include?(mapping.fetch("timeProfile"))
      end

      event_types = M1::EventRegistry.build.fetch("eventTypes").map { |definition| definition.fetch("eventType") }
      errors.concat(duplicate_errors(event_types, "event type"))
      errors << "event registry is not sorted" unless event_types == event_types.sort
      errors
    rescue JSON::ParserError, KeyError, Errno::ENOENT => e
      ["identifier linter input error: #{e.message}"]
    end

    def lint_text_references(text, known_ids:)
      referenced = text.scan(/\b[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\b/).uniq
      unknown = referenced - known_ids
      raise Error, "unknown acceptance ID(s): #{unknown.join(', ')}" unless unknown.empty?

      true
    end

    def duplicate_errors(values, label)
      values.group_by { |value| value }.select { |_value, rows| rows.length > 1 }.keys.map do |value|
        "duplicate #{label}: #{value}"
      end
    end
  end
end
