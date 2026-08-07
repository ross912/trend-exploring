# frozen_string_literal: true

module M1
  module CanonicalContract
    class Error < StandardError; end
    ARCHETYPES = %w[stable_identity immutable_record immutable_manifest].freeze
    TIME_PROFILES = %w[
      raw_item_version_time bitemporal_version_time standalone_snapshot_time
      derived_record_time operational_record_time
    ].freeze

    module_function

    def list_registry(markdown, registry_name)
      line = markdown.lines.find { |candidate| candidate.start_with?("| `#{registry_name}` |") }
      return [] unless line

      line.split("|", -1).fetch(2).split("、").map { |name| name.delete("`").strip }.reject(&:empty?)
    end

    def validate(archetypes:, time_profiles:)
      errors = []
      archetype_values = ARCHETYPES.flat_map { |name| archetypes.fetch(name, []) }
      duplicates(archetype_values).each { |name| errors << "object appears in multiple archetypes: #{name}" }

      profile_values = TIME_PROFILES.flat_map { |name| time_profiles.fetch(name, []) }
      duplicates(profile_values).each { |name| errors << "object appears in multiple time profiles: #{name}" }
      immutable_records = archetypes.fetch("immutable_record", [])
      errors.concat((immutable_records - profile_values).map { |name| "immutable record missing time profile: #{name}" })
      errors.concat((profile_values - immutable_records).map { |name| "time profile contains non-record object: #{name}" })
      errors
    rescue KeyError => e
      ["canonical registry missing: #{e.message}"]
    end

    def repository_report(contract_path)
      markdown = File.read(contract_path)
      archetypes = ARCHETYPES.to_h { |name| [name, list_registry(markdown, name)] }
      time_profiles = TIME_PROFILES.to_h { |name| [name, list_registry(markdown, name)] }
      {
        "errors" => validate(archetypes: archetypes, time_profiles: time_profiles),
        "archetypes" => archetypes.transform_values(&:length),
        "timeProfiles" => time_profiles.transform_values(&:length)
      }
    end

    def duplicates(values)
      values.group_by { |value| value }.select { |_value, rows| rows.length > 1 }.keys
    end
  end
end
