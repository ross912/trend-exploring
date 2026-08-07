# frozen_string_literal: true

require "digest"
require "json"

module M1
  module TestCatalogGenerator
    PHASES = %w[M0 M1 M2 M3 M4 M5].freeze
    SEVERITIES = %w[P0 P1].freeze
    BLOCKING = %w[
      phase-exit normal-edition service-claim release capability-claim
      version-promotion none
    ].freeze
    UUID_NAMESPACE = "d5f2e6cf-66b6-5f34-9af4-507b3f31f6a0"
    CATALOG_SCHEMA_VERSION = "m1.test-catalog.v1"

    class Error < StandardError; end

    module_function

    def load_acceptance_plan(path)
      parse(File.read(path), source: path)
    end

    def parse(markdown, source: "acceptance-plan")
      rows = []
      markdown.each_line.with_index(1) do |line, line_number|
        next unless line.match?(/^\| [A-Z][A-Z0-9]*-[0-9]/)

        cells = line.split("|", -1).map(&:strip)
        unless cells.length == 8
          raise Error, "#{source}:#{line_number}: acceptance row must have 6 columns"
        end

        id, phase, severity, blocking, fixture, oracle = cells[1..6]
        validate_row!(id, phase, severity, blocking, fixture, oracle, source, line_number)
        rows << {
          "testCode" => id,
          "introducedPhase" => phase,
          "severity" => severity,
          "blocking" => blocking,
          "fixtureContract" => fixture,
          "oracleSpec" => oracle
        }
      end

      raise Error, "#{source}: no acceptance rows found" if rows.empty?

      duplicate_ids = rows.group_by { |row| row.fetch("testCode") }
                         .select { |_id, values| values.length > 1 }
                         .keys
      raise Error, "#{source}: duplicate test IDs: #{duplicate_ids.join(',')}" unless duplicate_ids.empty?

      rows.freeze
    end

    def build(rows, target_phase:, target_gate: "phase-exit", governance_policy_version: nil)
      validate_target!(target_phase, target_gate)
      selected = rows.select { |row| PHASES.index(row.fetch("introducedPhase")) <= PHASES.index(target_phase) }
      definitions = selected.map { |row| compile_definition(row) }
      definition_ids = definitions.map { |definition| definition.fetch("testDefinitionVersionId") }.sort
      members = definition_ids.map { |id| { "testDefinitionVersionId" => id, "membership" => "applicable" } }

      {
        "schemaVersion" => CATALOG_SCHEMA_VERSION,
        "targetPhase" => target_phase,
        "targetGate" => target_gate,
        "testGovernancePolicyVersion" => governance_policy_version,
        "signatureStatus" => "unsigned",
        "manifestSignature" => nil,
        "definitionsUniverseHash" => digest_members(members),
        "definitions" => definitions,
        "members" => members,
        "governance" => {
          "signatureRequiredBeforeActivation" => true,
          "reason" => "generator output is deterministic but not a governance signature"
        }
      }
    end

    def write_catalog(rows, target_phase:, target_gate:, output:, governance_policy_version: nil)
      catalog = build(
        rows,
        target_phase: target_phase,
        target_gate: target_gate,
        governance_policy_version: governance_policy_version
      )
      File.write(output, JSON.pretty_generate(catalog) + "\n")
      catalog
    end

    def compile_definition(row)
      test_code = row.fetch("testCode")
      severity = row.fetch("severity")
      canonical = {
        "testCode" => test_code,
        "definitionRevision" => 1,
        "introducedPhase" => row.fetch("introducedPhase"),
        "runOnOrAfter" => row.fetch("introducedPhase"),
        "applicabilityPredicate" => "always",
        "waiverAllowed" => severity == "P1",
        "severity" => severity,
        "blocking" => row.fetch("blocking"),
        "fixtureContract" => row.fetch("fixtureContract"),
        "configContract" => "acceptance-plan-v0.2-m0-baseline",
        "oracleSpec" => row.fetch("oracleSpec")
      }

      canonical.merge(
        "testId" => uuid5(test_code),
        "testDefinitionVersionId" => uuid5("#{test_code}:v1"),
        "definitionHash" => Digest::SHA256.hexdigest(JSON.generate(canonical)),
        "manifestSignature" => nil
      )
    end

    def digest_members(members)
      canonical = members.sort_by { |member| member.fetch("testDefinitionVersionId") }
                         .map { |member| "#{member.fetch('testDefinitionVersionId')}|#{member.fetch('membership')}" }
                         .join("\n")
      Digest::SHA256.hexdigest(canonical)
    end

    def uuid5(name)
      namespace_bytes = [UUID_NAMESPACE.delete("-")].pack("H*")
      digest = Digest::SHA1.digest(namespace_bytes + name.encode("UTF-8"))[0, 16].bytes
      digest[6] = (digest[6] & 0x0f) | 0x50
      digest[8] = (digest[8] & 0x3f) | 0x80
      hex = digest.pack("C*").unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def validate_row!(id, phase, severity, blocking, fixture, oracle, source, line_number)
      errors = []
      errors << "malformed test ID" unless id.match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/)
      errors << "unknown phase #{phase}" unless PHASES.include?(phase)
      errors << "unknown severity #{severity}" unless SEVERITIES.include?(severity)
      errors << "unknown blocking #{blocking}" unless BLOCKING.include?(blocking)
      errors << "empty fixture contract" if fixture.empty?
      errors << "empty oracle spec" if oracle.empty?
      raise Error, "#{source}:#{line_number}: #{errors.join('; ')}" unless errors.empty?
    end

    def validate_target!(target_phase, target_gate)
      raise Error, "unknown target phase #{target_phase}" unless PHASES.include?(target_phase)
      raise Error, "unknown target gate #{target_gate}" unless BLOCKING.include?(target_gate)
    end
  end
end
