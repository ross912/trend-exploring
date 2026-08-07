# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "canonical_contract"
require_relative "test_catalog_generator"

module M1
  module ManifestCompiler
    class Error < StandardError; end

    FIELD_TYPES = {
      "CollectionPlanManifest" => {
        "planned_poll_cadence" => :string, "opportunity_id_rule" => :string,
        "time_zone" => :string, "schedule_rule" => :hash
      },
      "SourceDiscoveryProgramManifest" => {
        "programKey" => :string, "frameOpportunityCount" => :positive_integer,
        "coverageStrata" => :nonempty_array, "cadence" => :string, "baseline" => :hash
      },
      "SourceDiscoveryFrameManifest" => {
        "frameKey" => :string, "sourceUniverse" => :hash,
        "expectedOpportunityCount" => :positive_integer, "anchorDeadline" => :timestamp,
        "receipts" => :nonempty_array
      },
      "SnapshotMembershipProfile" => {
        "snapshotType" => :string, "canonicalScopeKey" => :string,
        "roles" => :nonempty_array, "projectionOracle" => :string
      },
      "ClockPolicyManifest" => {
        "allowed_sources" => :nonempty_array, "quorum" => :positive_integer,
        "max_skew_ms" => :nonnegative_integer, "health_ttl_seconds" => :positive_integer,
        "recovery_rule" => :hash
      },
      "EventTypeRegistryManifest" => { "eventTypes" => :nonempty_array },
      "CoveragePolicyManifest" => {
        "strata" => :nonempty_array, "allocation_lanes" => :nonempty_array,
        "random_seed" => :integer
      },
      "DetectorManifest" => {
        "detectors" => :nonempty_array, "required_version" => :string
      },
      "CandidateEmissionPolicy" => {
        "policyVersion" => :string, "candidateKinds" => :nonempty_array,
        "emissionRules" => :hash, "dedupeKey" => :string
      },
      "SequentialTestingUniverseManifest" => {
        "universeKey" => :string, "strata" => :nonempty_array,
        "randomSeed" => :integer, "windowRule" => :hash, "comparisonKeys" => :nonempty_array
      },
      "SequentialHypothesisFamilyManifest" => {
        "familyKey" => :string, "alphaSpending" => :hash,
        "onlineFdr" => :hash, "resetRule" => :string, "ledgerRule" => :hash
      },
      "RankingRuleManifest" => {
        "requiredComparisonKeys" => :nonempty_array, "baseline" => :hash,
        "tieBreak" => :string, "rankingFeatures" => :nonempty_array
      },
      "AttentionBudgetManifest" => {
        "budgetByChannel" => :hash, "priorityRule" => :string,
        "fairnessStrata" => :nonempty_array, "randomSeed" => :integer
      },
      "AttentionDeliveryFrameManifest" => {
        "deliveryFrameKey" => :string, "opportunityRule" => :hash,
        "eligibility" => :hash, "terminalOutcomes" => :nonempty_array
      },
      "ReportScheduleManifest" => {
        "cadence" => :string, "timeZone" => :string, "slots" => :nonempty_array,
        "anchorDeadline" => :timestamp, "graceMinutes" => :nonnegative_integer
      },
      "ReportPipelineManifest" => {
        "requiredStages" => :nonempty_array, "comparisonKeys" => :nonempty_array,
        "provenanceRule" => :hash, "watermarkRule" => :hash
      },
      "RadarPipelineManifest" => {
        "headScope" => :string, "dominanceRule" => :hash,
        "revocationEpoch" => :nonnegative_integer, "projectionAsOf" => :timestamp,
        "freshnessSlo" => :hash
      },
      "PresentationTemplateManifest" => {
        "claimSlotSchema" => :hash, "renderChannels" => :nonempty_array,
        "locales" => :nonempty_array
      },
      "UiBundleManifest" => {
        "bundleVersion" => :string, "assetHash" => :sha256,
        "renderChannels" => :nonempty_array, "locales" => :nonempty_array,
        "accessibility" => :hash
      },
      "DeliveryPolicyManifest" => {
        "channels" => :nonempty_array, "retryPolicy" => :hash,
        "egressPolicy" => :hash, "safetyGates" => :nonempty_array
      },
      "PresentationSinkPolicyManifest" => {
        "sinkKind" => :string, "allowedContentKinds" => :nonempty_array,
        "redactionRule" => :hash, "headerPolicy" => :hash
      },
      "TokenUsePolicyManifest" => {
        "tokenType" => :string, "actions" => :nonempty_array,
        "useMode" => :string, "maxUses" => :positive_integer,
        "cursorRule" => :hash, "revocationEpoch" => :nonnegative_integer
      },
      "ModelTaskManifest" => {
        "provider" => :string, "model" => :string, "purpose" => :string,
        "egress_policy" => :hash, "output_schema" => :hash
      },
      "ProviderResponseModeProfile" => {
        "mode" => :string, "requiredRequestProof" => :nonempty_array,
        "requiredResponseProof" => :nonempty_array, "terminalRule" => :hash,
        "schema" => :hash
      },
      "ProviderResponseSetProfile" => {
        "responseMode" => :string, "memberKind" => :string,
        "minimumMembers" => :positive_integer, "continuationRequired" => :boolean,
        "schemaVersion" => :string, "schemaHash" => :sha256
      },
      "SLOConfig" => {
        "sloVersion" => :string, "plannedSlotDenominator" => :positive_integer,
        "windowDays" => :positive_integer, "timeZone" => :string,
        "p95Method" => :string, "onTimeRateMin" => :ratio
      },
      "EvaluationProtocolVersion" => {
        "protocolVersion" => :string, "outcomeFrame" => :hash,
        "cutoffRule" => :hash, "comparison" => :hash, "randomSeed" => :integer
      },
      "EvaluationArmManifest" => {
        "armKey" => :string, "scopeSnapshot" => :string,
        "k" => :positive_integer, "outcomeFrame" => :hash,
        "cutoffAt" => :timestamp, "randomSeed" => :integer
      },
      "OutcomeFrameManifest" => {
        "frameKey" => :string, "outcomeDefinition" => :hash,
        "window" => :hash, "censoringRule" => :hash, "comparison" => :hash
      },
      "CapabilityClaimFamilyManifest" => {
        "claimFamily" => :string, "denominator" => :hash,
        "thresholds" => :hash, "evidenceFloor" => :string, "promotionRule" => :hash
      },
      "AnnotationProtocolVersion" => {
        "protocolVersion" => :string, "labelSchema" => :hash,
        "adjudicationRule" => :hash, "sampleSize" => :positive_integer,
        "agreementMetric" => :string
      },
      "PreservationPolicyManifest" => {
        "retention" => :hash, "fixity" => :hash, "restore" => :hash
      },
      "ComplianceCheckpointAuthorityManifest" => {
        "authorityKey" => :string, "epochRule" => :hash,
        "checkpointCadence" => :string, "quorum" => :positive_integer,
        "recoveryFence" => :hash
      },
      "TestCatalogManifest" => {
        "targetPhase" => :string, "targetGate" => :string,
        "definitions" => :nonempty_array, "members" => :nonempty_array,
        "definitionsUniverseHash" => :sha256
      },
      "TestGovernancePolicy" => {
        "policyRevision" => :positive_integer, "schemaHash" => :sha256,
        "effectiveFrom" => :timestamp
      },
      "SigningKeyVersion" => {
        "keyPurpose" => :string, "keyFingerprint" => :string,
        "keyState" => :string, "effectiveFrom" => :timestamp,
        "expiresAt" => :timestamp, "authorizedManifestKinds" => :nonempty_array
      }
    }.freeze

    REQUIRED_FIELDS = FIELD_TYPES.transform_values(&:keys).freeze

    module_function

    def compile(manifest_type:, schema_version:, owner:, effective_from:, payload:, contract_path:, signature_status: "unsigned", manifest_signature: nil, input_record_ids: [])
      registry = validate_contract!(contract_path)
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

      canonical_payload = canonicalize(payload)
      validate_payload!(manifest_type, canonical_payload)
      missing = REQUIRED_FIELDS.fetch(manifest_type, []).reject { |field| canonical_payload.key?(field) }
      raise Error, "#{manifest_type} missing required fields: #{missing.join(',')}" unless missing.empty?

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

    def validate_contract!(contract_path)
      registry = CanonicalContract.list_registry(File.read(contract_path), "immutable_manifest")
      missing = registry - FIELD_TYPES.keys
      extra = FIELD_TYPES.keys - registry
      unless missing.empty? && extra.empty?
        raise Error, "manifest compiler schema coverage mismatch (missing=#{missing.join(',')}; extra=#{extra.join(',')})"
      end
      registry
    rescue KeyError, Errno::ENOENT => e
      raise Error, "manifest compiler contract is invalid: #{e.message}"
    end

    def validate_payload!(manifest_type, payload)
      schema = FIELD_TYPES.fetch(manifest_type)
      missing = schema.keys.reject { |field| payload.key?(field) }
      raise Error, "#{manifest_type} missing required fields: #{missing.join(',')}" unless missing.empty?

      schema.each do |field, type|
        validate_field_type!(manifest_type, field, payload.fetch(field), type)
      end

      case manifest_type
      when "EventTypeRegistryManifest"
        validate_hash_entries!(manifest_type, payload.fetch("eventTypes"), %w[eventType stateSemantics aggregateKind aggregateConcreteType payloadSchemaHash])
      when "DetectorManifest"
        validate_hash_entries!(manifest_type, payload.fetch("detectors"), %w[detectorKey])
      when "TestCatalogManifest"
        unless %w[M0 M1 M2 M3 M4 M5].include?(payload.fetch("targetPhase"))
          raise Error, "TestCatalogManifest targetPhase is invalid"
        end
        unless %w[phase-exit normal-edition service-claim release capability-claim version-promotion none].include?(payload.fetch("targetGate"))
          raise Error, "TestCatalogManifest targetGate is invalid"
        end
        validate_hash_entries!(manifest_type, payload.fetch("definitions"), %w[testCode])
        validate_hash_entries!(manifest_type, payload.fetch("members"), %w[testDefinitionVersionId membership])
      when "TokenUsePolicyManifest"
        unless %w[single_use multi_use].include?(payload.fetch("useMode"))
          raise Error, "TokenUsePolicyManifest useMode is invalid"
        end
        if payload.fetch("useMode") == "single_use" && payload.fetch("maxUses") != 1
          raise Error, "TokenUsePolicyManifest single_use maxUses must be 1"
        end
        if payload.fetch("useMode") == "multi_use" && payload.fetch("maxUses") <= 1
          raise Error, "TokenUsePolicyManifest multi_use maxUses must exceed 1"
        end
      when "ProviderResponseModeProfile"
        unless %w[synchronous callback poll download].include?(payload.fetch("mode"))
          raise Error, "ProviderResponseModeProfile mode is invalid"
        end
      when "SLOConfig"
        unless payload.fetch("p95Method") == "nearest-rank"
          raise Error, "SLOConfig p95Method must be nearest-rank"
        end
      when "SigningKeyVersion"
        unless %w[active revoked compromised expired].include?(payload.fetch("keyState"))
          raise Error, "SigningKeyVersion keyState is invalid"
        end
        if Time.iso8601(payload.fetch("expiresAt")) <= Time.iso8601(payload.fetch("effectiveFrom"))
          raise Error, "SigningKeyVersion expiresAt must be after effectiveFrom"
        end
      end
      true
    rescue KeyError => e
      raise Error, "#{manifest_type} field is invalid: #{e.message}"
    end

    def validate_field_type!(manifest_type, field, value, type)
      valid = case type
      when :string
        value.is_a?(String) && !value.strip.empty?
      when :positive_integer
        value.is_a?(Integer) && value.positive?
      when :nonnegative_integer
        value.is_a?(Integer) && value >= 0
      when :integer
        value.is_a?(Integer)
      when :boolean
        value == true || value == false
      when :hash
        value.is_a?(Hash)
      when :nonempty_array
        value.is_a?(Array) && !value.empty?
      when :timestamp
        value.is_a?(String) && !value.strip.empty? && timestamp?(value)
      when :sha256
        value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
      when :ratio
        value.is_a?(Numeric) && value >= 0 && value <= 1
      else
        false
      end
      return if valid

      raise Error, "#{manifest_type}.#{field} has invalid type or value"
    end

    def validate_hash_entries!(manifest_type, entries, required_fields)
      unless entries.all? do |entry|
        entry.is_a?(Hash) && required_fields.all? { |field| entry.key?(field) && !entry.fetch(field).to_s.strip.empty? }
      end
        raise Error, "#{manifest_type} contains an incomplete typed entry"
      end
    end

    def timestamp?(value)
      Time.iso8601(value)
      true
    rescue ArgumentError
      false
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
