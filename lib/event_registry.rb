# frozen_string_literal: true

require "json"
require "digest"

module M1
  module EventRegistry
    SEMANTICS = {
      "SUPERSESSION" => ["conflict_tolerant_closure", "RECORD_SUPERSESSION"],
      "AGGREGATE_MERGE_SPLIT" => ["conflict_tolerant_closure", "AGGREGATE_TOPOLOGY"],
      "SIGNAL_STATE" => ["exclusive_transition", "SIGNAL_LIFECYCLE"],
      "COLLECTION_OPPORTUNITY_STATE" => ["exclusive_transition", "COLLECTION_OPPORTUNITY_LIFECYCLE"],
      "REPORT_SLOT_STATE" => ["exclusive_transition", "REPORT_SLOT_LIFECYCLE"],
      "PUBLICATION" => ["exclusive_transition", "REPORT_SLOT_LIFECYCLE"],
      "REPORT_AMENDMENT" => ["exclusive_transition", "REPORT_AMENDMENT_CHAIN"],
      "RADAR_PUBLICATION" => ["exclusive_transition", "RADAR_SURFACE_HEAD"],
      "REVOCATION_EPOCH" => ["exclusive_transition", "REVOCATION_DOMAIN_HEAD"],
      "PROVIDER_CALLBACK_KEY_STATE" => ["exclusive_transition", "PROVIDER_CALLBACK_KEY_LIFECYCLE"],
      "SERVICE_PRINCIPAL_CREDENTIAL_STATE" => ["exclusive_transition", "SERVICE_PRINCIPAL_CREDENTIAL_LIFECYCLE"],
      "RIGHTS_GRANT_STATE" => ["exclusive_transition", "RIGHTS_GRANT_LIFECYCLE"],
      "BINDING_REVOCATION" => ["exclusive_transition", "ARTIFACT_BLOB_BINDING_LIFECYCLE"],
      "BLOB_DELETION" => ["exclusive_transition", "STORAGE_BLOB_LIFECYCLE"],
      "COVERAGE_DEBT_STATE" => ["exclusive_transition", "COVERAGE_DEBT_LIFECYCLE"],
      "WATERMARK_GAP_STATE" => ["exclusive_transition", "WATERMARK_GAP_LIFECYCLE"],
      "MEMORY_CANDIDATE_DECISION" => ["exclusive_transition", "MEMORY_CANDIDATE_LIFECYCLE"],
      "CORRECTION_PROPOSAL_DECISION" => ["exclusive_transition", "CORRECTION_PROPOSAL_LIFECYCLE"],
      "SIGNING_KEY_STATE" => ["exclusive_transition", "SIGNING_KEY_LIFECYCLE"],
      "CANDIDATE_TRIGGER" => ["append_observation", nil],
      "EXTERNAL_POINTER_CHECK" => ["append_observation", nil],
      "FIXITY_CHECK" => ["append_observation", nil],
      "REPAIR" => ["append_observation", nil],
      "CHECKSUM_MIGRATION" => ["append_observation", nil],
      "KEY_ROTATION" => ["append_observation", nil],
      "RESTORE_TEST" => ["append_observation", nil],
      "FORMAT_MIGRATION" => ["append_observation", nil],
      "CORRECTION" => ["immutable_fact", nil],
      "DELETION" => ["immutable_fact", nil]
    }.freeze

    AGGREGATES = {
      "SUPERSESSION" => ["record", "Supersession"],
      "AGGREGATE_MERGE_SPLIT" => ["record", "AggregateTopology"],
      "SIGNAL_STATE" => ["object", "Signal"],
      "COLLECTION_OPPORTUNITY_STATE" => ["record", "CollectionOpportunity"],
      "REPORT_SLOT_STATE" => ["record", "ReportSlot"],
      "PUBLICATION" => ["record", "ReportSlot"],
      "REPORT_AMENDMENT" => ["record", "ReportEdition"],
      "RADAR_PUBLICATION" => ["record", "RadarSurface"],
      "REVOCATION_EPOCH" => ["record", "RevocationDomain"],
      "PROVIDER_CALLBACK_KEY_STATE" => ["record", "ProviderCallbackSigningKeyVersion"],
      "SERVICE_PRINCIPAL_CREDENTIAL_STATE" => ["record", "ServicePrincipalCredentialVersion"],
      "RIGHTS_GRANT_STATE" => ["record", "RightsGrantVersion"],
      "BINDING_REVOCATION" => ["record", "ArtifactBlobBindingVersion"],
      "BLOB_DELETION" => ["record", "StorageBlob"],
      "COVERAGE_DEBT_STATE" => ["record", "CoverageDebt"],
      "WATERMARK_GAP_STATE" => ["record", "WatermarkGap"],
      "MEMORY_CANDIDATE_DECISION" => ["object", "MemoryCandidate"],
      "CORRECTION_PROPOSAL_DECISION" => ["record", "CorrectionProposal"],
      "SIGNING_KEY_STATE" => ["record", "SigningKeyVersion"],
      "CANDIDATE_TRIGGER" => ["object", "SignalCandidate"],
      "EXTERNAL_POINTER_CHECK" => ["record", "ExternalPointer"],
      "FIXITY_CHECK" => ["record", "StorageBlob"],
      "REPAIR" => ["record", "StorageBlob"],
      "CHECKSUM_MIGRATION" => ["record", "RawArtifact"],
      "KEY_ROTATION" => ["record", "SigningKeyVersion"],
      "RESTORE_TEST" => ["record", "PreservationManifestVersion"],
      "FORMAT_MIGRATION" => ["record", "RawArtifact"],
      "CORRECTION" => ["record", "CorrectionProposal"],
      "DELETION" => ["record", "RawArtifact"]
    }.freeze

    STATE_MACHINES = {
      "SIGNAL_STATE" => {
        "initial" => "candidate",
        "states" => %w[candidate watch active established fading falsified archived reactivated],
        "transitions" => %w[
          candidate>watch candidate>falsified watch>active watch>fading watch>falsified
          active>established active>fading active>falsified established>fading established>falsified
          fading>archived fading>reactivated fading>falsified falsified>archived archived>reactivated
          reactivated>active reactivated>fading reactivated>falsified
        ]
      },
      "COLLECTION_OPPORTUNITY_STATE" => {
        "initial" => "scheduled",
        "states" => %w[scheduled succeeded failed excluded],
        "transitions" => %w[scheduled>succeeded scheduled>failed scheduled>excluded]
      },
      "REPORT_SLOT_STATE" => {
        "initial" => "scheduled",
        "states" => %w[scheduled failed cancelled published],
        "transitions" => %w[scheduled>failed scheduled>cancelled]
      },
      "PUBLICATION" => {
        "initial" => "scheduled",
        "states" => %w[scheduled published],
        "transitions" => %w[scheduled>published]
      },
      "REPORT_AMENDMENT" => {
        "initial" => "published",
        "states" => %w[published amended],
        "transitions" => %w[published>amended amended>amended]
      },
      "RADAR_PUBLICATION" => {
        "initial" => "unpublished",
        "states" => %w[unpublished published],
        "transitions" => %w[unpublished>published published>published]
      },
      "REVOCATION_EPOCH" => {
        "initial" => "epoch",
        "states" => ["epoch"],
        "transitions" => ["epoch>epoch"]
      },
      "PROVIDER_CALLBACK_KEY_STATE" => {
        "initial" => "active",
        "states" => %w[active revoked compromised],
        "transitions" => %w[active>revoked active>compromised]
      },
      "SERVICE_PRINCIPAL_CREDENTIAL_STATE" => {
        "initial" => "active",
        "states" => %w[active revoked compromised],
        "transitions" => %w[active>revoked active>compromised]
      },
      "RIGHTS_GRANT_STATE" => {
        "initial" => "active",
        "states" => %w[active revoked],
        "transitions" => ["active>revoked"]
      },
      "BINDING_REVOCATION" => {
        "initial" => "active",
        "states" => %w[active revoked],
        "transitions" => ["active>revoked"]
      },
      "BLOB_DELETION" => {
        "initial" => "retained",
        "states" => %w[retained deleted],
        "transitions" => ["retained>deleted"]
      },
      "COVERAGE_DEBT_STATE" => {
        "initial" => "open",
        "states" => %w[open repaid waived],
        "transitions" => %w[open>repaid open>waived]
      },
      "WATERMARK_GAP_STATE" => {
        "initial" => "open",
        "states" => %w[open closed superseded],
        "transitions" => %w[open>closed open>superseded]
      },
      "MEMORY_CANDIDATE_DECISION" => {
        "initial" => "pending",
        "states" => %w[pending accepted rejected revoked],
        "transitions" => %w[pending>accepted pending>rejected rejected>accepted accepted>revoked]
      },
      "CORRECTION_PROPOSAL_DECISION" => {
        "initial" => "pending",
        "states" => %w[pending accepted rejected withdrawn],
        "transitions" => %w[pending>accepted pending>rejected pending>withdrawn]
      },
      "SIGNING_KEY_STATE" => {
        "initial" => "active",
        "states" => %w[active revoked compromised],
        "transitions" => %w[active>revoked active>compromised]
      }
    }.freeze

    class Error < StandardError; end

    module_function

    def build(registry_version: "m1.event-registry.v1")
      event_types = SEMANTICS.keys.sort.map do |event_type|
        semantics, family = SEMANTICS.fetch(event_type)
        machine = STATE_MACHINES[event_type]
        definition = {
          "eventType" => event_type,
          "stateSemantics" => semantics,
          "stateMachineFamily" => family,
          "aggregateKind" => AGGREGATES.fetch(event_type).fetch(0),
          "aggregateConcreteType" => AGGREGATES.fetch(event_type).fetch(1),
          "payloadSchemaHash" => Digest::SHA256.hexdigest("event-payload:#{event_type}"),
          "typedApiAliasSharesEventId" => true,
          "typedPayloadRequired" => true
        }
        if machine
          definition["initialState"] = machine.fetch("initial")
          definition["states"] = machine.fetch("states").map do |state|
            { "stateKey" => state, "isInitialState" => state == machine.fetch("initial") }
          end
          definition["transitions"] = machine.fetch("transitions").sort.map do |transition|
            from_state, to_state = transition.split(">", 2)
            {
              "fromState" => from_state,
              "toState" => to_state,
              "isInitialTransition" => from_state == machine.fetch("initial") && to_state == machine.fetch("initial"),
              "typedGuardRequired" => true
            }
          end
        end
        definition
      end

      validate_event_types!(event_types)
      {
        "schemaVersion" => registry_version,
        "schemaHash" => Digest::SHA256.hexdigest("event-registry-schema:#{registry_version}"),
        "signatureStatus" => "unsigned",
        "manifestSignature" => nil,
        "eventTypes" => event_types,
        "governance" => {
          "signatureRequiredBeforeActivation" => true,
          "reason" => "registry output is deterministic but not a governance signature"
        }
      }
    end

    def validate_event_types!(event_types)
      names = event_types.map { |definition| definition.fetch("eventType") }
      raise Error, "duplicate event type" unless names.uniq == names

      event_types.each do |definition|
        semantics = definition.fetch("stateSemantics")
        machine_fields = %w[initialState states transitions]
        if semantics == "exclusive_transition"
          missing = machine_fields.reject { |field| definition.key?(field) }
          raise Error, "exclusive event missing #{missing.join(',')}: #{definition.fetch('eventType')}" unless missing.empty?
          states = definition.fetch("states").map { |state| state.fetch("stateKey") }
          raise Error, "initial state is not unique: #{definition.fetch('eventType')}" unless states.count(definition.fetch("initialState")) == 1
          definition.fetch("transitions").each do |transition|
            unless states.include?(transition.fetch("fromState")) && states.include?(transition.fetch("toState"))
              raise Error, "transition references unknown state: #{definition.fetch('eventType')}"
            end
          end
        elsif machine_fields.any? { |field| definition.key?(field) }
          raise Error, "non-exclusive event has state machine: #{definition.fetch('eventType')}"
        end
      end
      true
    end
  end
end
