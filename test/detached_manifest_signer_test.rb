# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require_relative "../lib/detached_manifest_signer"
require_relative "../lib/m1_gate_evaluator"
require_relative "../lib/test_catalog_generator"

class DetachedManifestSignerTest < Minitest::Test
  def setup
    @key = OpenSSL::PKey::RSA.new(2048)
    @manifest = {
      "owner" => "fixture-owner",
      "payloadHash" => "a" * 64,
      "payload" => { "z" => 1, "a" => ["x", { "b" => true }] },
      "signatureStatus" => "unsigned",
      "manifestSignature" => nil
    }
  end

  def test_sign_and_verify_detached_canonical_payload
    signed = M1::DetachedManifestSigner.sign(
      @manifest, private_key_pem: @key.to_pem, signing_key_version_id: "key-v1"
    )
    assert_equal "signed", signed.fetch("signatureStatus")
    assert_equal "key-v1", signed.fetch("signingKeyVersionId")
    assert M1::DetachedManifestSigner.verify(signed, public_key_pem: @key.public_key.to_pem)
  end

  def test_signature_does_not_cover_mutated_payload
    signed = M1::DetachedManifestSigner.sign(
      @manifest, private_key_pem: @key.to_pem, signing_key_version_id: "key-v1"
    )
    signed.fetch("payload")["z"] = 2
    refute M1::DetachedManifestSigner.verify(signed, public_key_pem: @key.public_key.to_pem)
  end

  def test_public_key_cannot_sign
    error = assert_raises(M1::DetachedManifestSigner::Error) do
      M1::DetachedManifestSigner.sign(
        @manifest, private_key_pem: @key.public_key.to_pem, signing_key_version_id: "key-v1"
      )
    end
    assert_match(/private signing key is required/, error.message)
  end

  def test_already_signed_manifest_is_not_resigned
    signed = M1::DetachedManifestSigner.sign(
      @manifest, private_key_pem: @key.to_pem, signing_key_version_id: "key-v1"
    )
    error = assert_raises(M1::DetachedManifestSigner::Error) do
      M1::DetachedManifestSigner.sign(
        signed, private_key_pem: @key.to_pem, signing_key_version_id: "key-v2"
      )
    end
    assert_match(/already signed/, error.message)
  end

  def test_signed_catalog_is_accepted_by_phase_exit_gate
    rows = M1::TestCatalogGenerator.load_acceptance_plan(
      File.expand_path("../docs/04-acceptance-test-plan.md", __dir__)
    )
    catalog = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
    signed = M1::DetachedManifestSigner.sign(
      catalog, private_key_pem: @key.to_pem, signing_key_version_id: "key-v1"
    )
    phase_exit_ids = signed.fetch("definitions").select { |definition| definition.fetch("blocking") == "phase-exit" }
      .map { |definition| definition.fetch("testDefinitionVersionId") }
    required_ids = signed.fetch("members").select { |member| member.fetch("membership") == "applicable" }
      .map { |member| member.fetch("testDefinitionVersionId") } & phase_exit_ids
    results = required_ids.to_h { |definition_id| [definition_id, "pass"] }
    report = M1::M1GateEvaluator.evaluate(catalog: signed, results: results)
    assert_equal "pass", report.fetch("decision")

    signed.fetch("definitions").first["oracleSpec"] = "tampered"
    refute M1::DetachedManifestSigner.verify(signed, public_key_pem: @key.public_key.to_pem)
  end
end
