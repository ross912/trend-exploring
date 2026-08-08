# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/manifest_compiler"

class ManifestCompilerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONTRACT_PATH = File.join(ROOT, "docs/05-canonical-data-and-time-contract.md")

  def compile_test_catalog
    rows = M1::TestCatalogGenerator.load_acceptance_plan(File.join(ROOT, "docs/04-acceptance-test-plan.md"))
    M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
  end

  def test_catalog_envelope_is_deterministic_and_unsigned_until_activation
    first = M1::ManifestCompiler.compile(
      manifest_type: "TestCatalogManifest", schema_version: "m1.test-catalog.v1",
      owner: "fixture-owner", effective_from: "2026-08-07T00:00:00Z",
      payload: compile_test_catalog, contract_path: CONTRACT_PATH
    )
    second = M1::ManifestCompiler.compile(
      manifest_type: "TestCatalogManifest", schema_version: "m1.test-catalog.v1",
      owner: "fixture-owner", effective_from: "2026-08-07T00:00:00Z",
      payload: compile_test_catalog, contract_path: CONTRACT_PATH
    )
    assert_equal first, second
    assert_equal "unsigned", first.fetch("signatureStatus")
    assert first.fetch("governance").fetch("signatureRequiredBeforeActivation")
    assert_match(/\A[a-f0-9]{64}\z/, first.fetch("payloadHash"))
  end

  def test_unknown_type_and_missing_fields_fail_closed
    error = assert_raises(M1::ManifestCompiler::Error) do
      M1::ManifestCompiler.compile(
        manifest_type: "NotARealManifest", schema_version: "v1", owner: "owner",
        effective_from: "2026-08-07T00:00:00Z", payload: {}, contract_path: CONTRACT_PATH
      )
    end
    assert_match(/unknown manifest type/, error.message)

    error = assert_raises(M1::ManifestCompiler::Error) do
      M1::ManifestCompiler.compile(
        manifest_type: "ClockPolicyManifest", schema_version: "v1", owner: "owner",
        effective_from: "2026-08-07T00:00:00Z", payload: { "quorum" => 3 }, contract_path: CONTRACT_PATH
      )
    end
    assert_match(/missing required fields/, error.message)
  end

  def test_signed_manifest_requires_signature
    error = assert_raises(M1::ManifestCompiler::Error) do
      M1::ManifestCompiler.compile(
        manifest_type: "TestGovernancePolicy", schema_version: "v1", owner: "owner",
        effective_from: "2026-08-07T00:00:00Z",
        payload: { "policyRevision" => 1, "schemaHash" => "a", "effectiveFrom" => "2026-08-07T00:00:00Z" },
        contract_path: CONTRACT_PATH, signature_status: "signed"
      )
    end
    assert_match(/requires a signature/, error.message)
  end

  def test_every_canonical_manifest_type_has_a_typed_compiler_schema
    types = M1::ManifestCompiler.validate_contract!(CONTRACT_PATH)
    assert_equal types.sort, M1::ManifestCompiler::FIELD_TYPES.keys.sort

    types.each do |manifest_type|
      payload = M1::ManifestCompiler::FIELD_TYPES.fetch(manifest_type).each_with_object({}) do |(field, type), result|
        result[field] = case type
        when :string then "value"
        when :positive_integer then 1
        when :nonnegative_integer then 0
        when :integer then 7
        when :boolean then true
        when :hash then {}
        when :nonempty_array then ["value"]
        when :timestamp then "2026-08-07T00:00:00Z"
        when :sha256 then "a" * 64
        when :ratio then 0.99
        end
      end
      payload["targetPhase"] = "M1" if manifest_type == "TestCatalogManifest"
      payload["targetGate"] = "phase-exit" if manifest_type == "TestCatalogManifest"
      payload["definitions"] = [{ "testCode" => "CTR-001", "testDefinitionVersionId" => "fixture-definition" }] if manifest_type == "TestCatalogManifest"
      payload["members"] = [{ "testDefinitionVersionId" => "fixture-definition", "membership" => "applicable" }] if manifest_type == "TestCatalogManifest"
      payload["definitionsUniverseHash"] = "a" * 64 if manifest_type == "TestCatalogManifest"
      payload["eventTypes"] = [{
        "eventType" => "FIXTURE_EVENT", "stateSemantics" => "append_observation",
        "aggregateKind" => "object", "aggregateConcreteType" => "SignalCandidate",
        "payloadSchemaHash" => "a" * 64
      }] if manifest_type == "EventTypeRegistryManifest"
      payload["detectors"] = [{ "detectorKey" => "fixture-detector" }] if manifest_type == "DetectorManifest"
      payload["useMode"] = "single_use" if manifest_type == "TokenUsePolicyManifest"
      payload["mode"] = "synchronous" if manifest_type == "ProviderResponseModeProfile"
      payload["requiredResponseProof"] = ["captured_exchange_id", "authenticated_peer"] if manifest_type == "ProviderResponseModeProfile"
      payload["p95Method"] = "nearest-rank" if manifest_type == "SLOConfig"
      payload["keyState"] = "active" if manifest_type == "SigningKeyVersion"
      payload["expiresAt"] = "2027-08-07T00:00:00Z" if manifest_type == "SigningKeyVersion"

      compiled = M1::ManifestCompiler.compile(
        manifest_type: manifest_type, schema_version: "m1.#{manifest_type}.v1",
        owner: "fixture-owner", effective_from: "2026-08-07T00:00:00Z",
        payload: payload, contract_path: CONTRACT_PATH
      )
      assert_equal manifest_type, compiled.fetch("manifestType")
      assert_match(/\A[a-f0-9]{64}\z/, compiled.fetch("payloadHash"))
    end
  end

  def test_typed_manifest_semantics_fail_closed
    payload = {
      "allowed_sources" => ["clock-a"], "quorum" => "3",
      "max_skew_ms" => 100, "health_ttl_seconds" => 60,
      "recovery_rule" => {}
    }
    error = assert_raises(M1::ManifestCompiler::Error) do
      M1::ManifestCompiler.compile(
        manifest_type: "ClockPolicyManifest", schema_version: "v1", owner: "owner",
        effective_from: "2026-08-07T00:00:00Z", payload: payload,
        contract_path: CONTRACT_PATH
      )
    end
    assert_match(/quorum has invalid type/, error.message)

    error = assert_raises(M1::ManifestCompiler::Error) do
      M1::ManifestCompiler.compile(
        manifest_type: "SLOConfig", schema_version: "v1", owner: "owner",
        effective_from: "2026-08-07T00:00:00Z",
        payload: {
          "sloVersion" => "v1", "plannedSlotDenominator" => 60,
          "windowDays" => 30, "timeZone" => "UTC", "p95Method" => "linear",
          "onTimeRateMin" => 0.99
        }, contract_path: CONTRACT_PATH
      )
    end
    assert_match(/p95Method must be nearest-rank/, error.message)
  end
end
