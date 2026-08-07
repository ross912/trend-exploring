#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/detached_manifest_signer"

options = { manifest: nil, public_key: nil, owner: nil, signing_key: nil,
            signed_at: nil, effective_from: nil, system_available_at: nil, output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/prepare_manifest_import.rb --manifest SIGNED_JSON --public-key PEM --owner UUID --signing-key UUID --signed-at ISO8601 --effective-from ISO8601 --system-available-at ISO8601"
  parser.on("--manifest PATH") { |value| options[:manifest] = value }
  parser.on("--public-key PATH") { |value| options[:public_key] = value }
  parser.on("--owner UUID") { |value| options[:owner] = value }
  parser.on("--signing-key UUID") { |value| options[:signing_key] = value }
  parser.on("--signed-at ISO8601") { |value| options[:signed_at] = value }
  parser.on("--effective-from ISO8601") { |value| options[:effective_from] = value }
  parser.on("--system-available-at ISO8601") { |value| options[:system_available_at] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

missing = options.select { |key, value| key != :output && value.to_s.empty? }.keys
abort "missing required options: #{missing.join(', ')}" unless missing.empty?

manifest = JSON.parse(File.read(options.fetch(:manifest)))
abort "manifest must be signed" unless manifest["signatureStatus"] == "signed"
unless M1::DetachedManifestSigner.verify(
  manifest, public_key_pem: File.read(options.fetch(:public_key))
)
  abort "manifest signature verification failed"
end

function_name = case manifest["manifestType"] || manifest["type"]
                when "EventTypeRegistryManifest", "EventRegistryManifest" then "import_event_registry_manifest"
                when "TestCatalogManifest" then "import_test_catalog_manifest"
                else abort "unsupported manifest type for PostgreSQL import"
                end

envelope = {
  "function" => function_name,
  "manifest" => manifest,
  "ownerServicePrincipalId" => options.fetch(:owner),
  "signingKeyVersionId" => options.fetch(:signing_key),
  "signedAt" => options.fetch(:signed_at),
  "effectiveFrom" => options.fetch(:effective_from),
  "systemAvailableAt" => options.fetch(:system_available_at),
  "signatureVerified" => true
}
json = JSON.pretty_generate(envelope) + "\n"
if options[:output]
  File.write(options[:output], json)
else
  puts json
end
