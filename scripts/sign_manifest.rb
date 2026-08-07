#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lib/detached_manifest_signer"

options = { input: nil, key: nil, key_version: nil, output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/sign_manifest.rb --input MANIFEST --key PRIVATE_PEM --key-version ID --output SIGNED"
  parser.on("--input PATH") { |value| options[:input] = value }
  parser.on("--key PATH") { |value| options[:key] = value }
  parser.on("--key-version ID") { |value| options[:key_version] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

missing = %i[input key key_version output].select { |name| options[name].to_s.empty? }
abort "missing required options: #{missing.join(', ')}" unless missing.empty?

manifest = JSON.parse(File.read(options[:input]))
signed = M1::DetachedManifestSigner.sign(
  manifest,
  private_key_pem: File.read(options[:key]),
  signing_key_version_id: options[:key_version]
)
File.write(options[:output], JSON.pretty_generate(signed) + "\n")
warn "wrote signed manifest: #{options[:output]}"
