# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module M1
  module DetachedManifestSigner
    class Error < StandardError; end

    SIGNATURE_FIELDS = %w[signatureStatus manifestSignature signingKeyVersionId].freeze

    module_function

    def canonical_payload(manifest)
      raise Error, "manifest must be a Hash" unless manifest.is_a?(Hash)

      canonicalize(manifest.reject { |key, _| SIGNATURE_FIELDS.include?(key.to_s) })
    end

    def sign(manifest, private_key_pem:, signing_key_version_id:)
      raise Error, "signing key version id is required" if signing_key_version_id.to_s.empty?
      if manifest["signatureStatus"] == "signed" || !manifest["manifestSignature"].to_s.empty?
        raise Error, "manifest is already signed"
      end
      key = OpenSSL::PKey.read(private_key_pem)
      raise Error, "private signing key is required" unless key.private?

      payload = JSON.generate(canonical_payload(manifest))
      signature = key.sign(OpenSSL::Digest::SHA256.new, payload)
      signed = JSON.parse(JSON.generate(manifest))
      signed["signatureStatus"] = "signed"
      signed["manifestSignature"] = "rsa-sha256:#{Base64.strict_encode64(signature)}"
      signed["signingKeyVersionId"] = signing_key_version_id
      signed
    rescue OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError => error
      raise Error, "manifest signing failed: #{error.message}"
    end

    def verify(manifest, public_key_pem:)
      key = OpenSSL::PKey.read(public_key_pem)
      signature = manifest.fetch("manifestSignature").sub("rsa-sha256:", "")
      key.verify(
        OpenSSL::Digest::SHA256.new,
        Base64.strict_decode64(signature),
        JSON.generate(canonical_payload(manifest))
      )
    rescue KeyError, ArgumentError, OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
      false
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end
    private_class_method :canonicalize
  end
end
