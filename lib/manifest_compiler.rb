# frozen_string_literal: true

require "digest"
require "json"
require_relative "canonical_contract"
require_relative "test_catalog_generator"

module M1
  module ManifestCompiler
    class Error < StandardError; end

    REQUIRED_FIELDS = {
      "CollectionPlanManifest" => %w[planned_poll_cadence opportunity_id_rule time_zone schedule_rule],
      "ClockPolicyManifest" => %w[allowed_sources quorum max_skew_ms health_ttl_seconds recovery_rule],
      "EventTypeRegistryManifest" => %w[eventTypes],
      "CoveragePolicyManifest" => %w[strata allocation_lanes random_seed],
      "DetectorManifest" => %w[detectors required_version],
      "ModelTaskManifest" => %w[provider model purpose egress_policy output_schema],
      "SnapshotMembershipProfile" => %w[snapshotType canonicalScopeKey roles projectionOracle],
      "PresentationTemplateManifest" => %w[claimSlotSchema renderChannels locales],
      "PreservationPolicyManifest" => %w[retention fixity restore],
      "TestCatalogManifest" => %w[targetPhase targetGate definitions members definitionsUniverseHash],
      "TestGovernancePolicy" => %w[policyRevision schemaHash effectiveFrom]
    }.freeze

    module_function

    def compile(manifest_type:, schema_version:, owner:, effective_from:, payload:, contract_path:, signature_status: "unsigned", manifest_signature: nil, input_record_ids: [])
      registry = CanonicalContract.list_registry(File.read(contract_path), "immutable_manifest")
      raise Error, "unknown manifest type #{manifest_type}" unless registry.include?(manifest_type)
      raise Error, "manifest schema version is empty" if schema_version.to_s.strip.empty?
      raise Error, "manifest owner is empty" if owner.to_s.strip.empty?
      raise Error, "manifest effective_from is empty" if effective_from.to_s.strip.empty?
      raise Error, "manifest payload must be an object" unless payload.is_a?(Hash)
      unless %w[unsigned signed].include?(signature_status)
        raise Error, "unknown manifest signature status #{signature_status}"
      end
      if signature_status == "signed" && manifest_signature.to_s.strip.empty?
        raise Error, "signed manifest requires a signature"
      end

      missing = REQUIRED_FIELDS.fetch(manifest_type, []).reject { |field| payload.key?(field) }
      raise Error, "#{manifest_type} missing required fields: #{missing.join(',')}" unless missing.empty?

      canonical_payload = canonicalize(payload)
      payload_hash = Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
      manifest_id = TestCatalogGenerator.uuid5("manifest:#{manifest_type}:#{schema_version}:#{payload_hash}")
      {
        "manifestType" => manifest_type,
        "manifestId" => manifest_id,
        "schemaVersion" => schema_version,
        "schemaHash" => Digest::SHA256.hexdigest("manifest-schema:#{schema_version}"),
        "payloadHash" => payload_hash,
        "payload" => canonical_payload,
        "owner" => owner,
        "effectiveFrom" => effective_from,
        "inputRecordIds" => input_record_ids,
        "signatureStatus" => signature_status,
        "manifestSignature" => manifest_signature,
        "governance" => {
          "signatureRequiredBeforeActivation" => true,
          "activationStatus" => "pending_signature"
        }
      }
    rescue KeyError, Errno::ENOENT => e
      raise Error, "manifest compiler input is invalid: #{e.message}"
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonicalize(value.fetch(original_key))
        end
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end
  end
end
