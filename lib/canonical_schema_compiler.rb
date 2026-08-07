# frozen_string_literal: true

require "digest"
require "json"
require "set"
require_relative "canonical_contract"

module M1
  module CanonicalSchemaCompiler
    class Error < StandardError; end

    ARCHETYPE_BY_REGISTRY = {
      "stable_identity" => "stable_identity",
      "immutable_record" => "immutable_record",
      "immutable_manifest" => "immutable_manifest"
    }.freeze

    module_function

    def compile(contract_path:, object_map_path:)
      contract = File.read(contract_path)
      report = CanonicalContract.repository_report(contract_path)
      raise Error, "canonical contract has errors: #{report.fetch('errors').join('; ')}" if report.fetch("errors").any?

      registries = ARCHETYPE_BY_REGISTRY.keys.to_h do |registry_name|
        [registry_name, CanonicalContract.list_registry(contract, registry_name)]
      end
      time_profiles = CanonicalContract::TIME_PROFILES.to_h do |profile|
        [profile, CanonicalContract.list_registry(contract, profile)]
      end
      object_map = JSON.parse(File.read(object_map_path)).fetch("mappings")

      objects = registries.flat_map do |registry_name, names|
        names.map do |name|
          {
            "canonicalObject" => name,
            "archetype" => ARCHETYPE_BY_REGISTRY.fetch(registry_name),
            "timeProfile" => time_profiles.find { |_profile, values| values.include?(name) }&.first
          }
        end
      end
      event_objects = object_map.select { |mapping| mapping.fetch("role") == "event" }.map do |mapping|
        {
          "canonicalObject" => mapping.fetch("canonicalObject"),
          "archetype" => "event_subtype",
          "timeProfile" => mapping.fetch("timeProfile")
        }
      end
      objects = (objects + event_objects).uniq { |object| object.fetch("canonicalObject") }
      validate_object_map!(objects, object_map)

      ddl = metadata_ddl(objects)
      {
        "schemaVersion" => "m1.canonical-registry.v1",
        "schemaHash" => Digest::SHA256.hexdigest(ddl),
        "signatureStatus" => "unsigned",
        "objects" => objects,
        "timeProfiles" => time_profiles,
        "ddl" => ddl
      }
    rescue JSON::ParserError, Errno::ENOENT, KeyError => e
      raise Error, "canonical schema compiler input is invalid: #{e.message}"
    end

    def validate_identity_universe!(rows)
      rows = rows.map { |row| row.transform_keys(&:to_s) }
      missing = rows.select { |row| row["globalIdentityId"].to_s.empty? || row["identityKind"].to_s.empty? }
      raise Error, "global identity row is incomplete" unless missing.empty?

      collisions = rows.group_by { |row| row.fetch("globalIdentityId") }
                       .select { |_id, values| values.map { |row| [row.fetch("identityKind"), row.fetch("concreteType")] }.uniq.length > 1 }
      unless collisions.empty?
        raise Error, "global identity collision #{collisions.keys.join(',')}"
      end

      known_ids = rows.map { |row| row.fetch("globalIdentityId") }.to_set
      orphan_parents = rows.each_with_object([]) do |row, values|
        parent_id = row["parentIdentityId"]
        values << parent_id unless parent_id.nil? || known_ids.include?(parent_id)
      end
      raise Error, "orphan canonical parent #{orphan_parents.uniq.join(',')}" unless orphan_parents.empty?
      true
    end

    def validate_object_map!(objects, object_map)
      by_name = objects.to_h { |object| [object.fetch("canonicalObject"), object] }
      object_map.each do |mapping|
        name = mapping.fetch("canonicalObject")
        object = by_name[name]
        raise Error, "object map references unknown canonical object #{name}" unless object
        if mapping.fetch("role") == "identity" && object.fetch("archetype") != "stable_identity"
          raise Error, "#{name} identity archetype mismatch"
        end
        if mapping.fetch("role") == "manifest" && object.fetch("archetype") != "immutable_manifest"
          raise Error, "#{name} manifest archetype mismatch"
        end
        if mapping.fetch("role") == "record" && object.fetch("archetype") != "immutable_record"
          raise Error, "#{name} record archetype mismatch"
        end
        expected_profile = object.fetch("timeProfile")
        if mapping.fetch("role") != "child" && expected_profile && mapping.fetch("timeProfile") != expected_profile
          raise Error, "#{name} time profile mismatch: #{mapping.fetch('timeProfile')} != #{expected_profile}"
        end
      end
      true
    end

    def metadata_ddl(objects)
      rows = objects.sort_by { |object| object.fetch("canonicalObject") }.map do |object|
        "(#{sql_quote(object.fetch('canonicalObject'))}, #{sql_quote(object.fetch('archetype'))}, #{sql_quote(object.fetch('timeProfile').to_s)})"
      end
      <<~SQL
        CREATE TABLE canonical_contract_registry (
          canonical_object text PRIMARY KEY,
          archetype text NOT NULL CHECK (archetype IN ('stable_identity', 'immutable_record', 'immutable_manifest')),
          time_profile text NOT NULL
        );
        INSERT INTO canonical_contract_registry (canonical_object, archetype, time_profile)
        VALUES #{rows.join(",\n")};
        CREATE UNIQUE INDEX canonical_contract_registry_profile_uq
          ON canonical_contract_registry (canonical_object, archetype, time_profile);
      SQL
    end

    def sql_quote(value)
      "'#{value.gsub("'", "''")}'"
    end
  end
end
