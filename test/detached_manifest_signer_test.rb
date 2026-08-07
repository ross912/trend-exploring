# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require_relative "../lib/detached_manifest_signer"

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
end
