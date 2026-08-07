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
end
