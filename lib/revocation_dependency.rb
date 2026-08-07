# frozen_string_literal: true

require "digest"
require "json"

module M1
  module RevocationDependency
    class Error < StandardError; end
    REQUIRED_DOMAINS = %w[personal global rights].freeze

    module_function

    def snapshot(domains:, epochs:)
      missing = REQUIRED_DOMAINS - domains.keys.map(&:to_s)
      raise Error, "revocation dependency domains missing: #{missing.join(', ')}" unless missing.empty?

      canonical = canonicalize(REQUIRED_DOMAINS.to_h { |domain| [domain, domains.fetch(domain) { domains.fetch(domain.to_sym) }] })
      {
        "domains" => canonical,
        "epochs" => canonicalize(epochs),
        "setHash" => Digest::SHA256.hexdigest(JSON.generate(canonical.merge("epochs" => canonicalize(epochs))))
      }
    end

    def matches?(snapshot, domains:, epochs:)
      expected = snapshot(domains: domains, epochs: epochs)
      snapshot.fetch("setHash") == expected.fetch("setHash")
    rescue KeyError, Error
      false
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source_key = value.key?(key) ? key : key.to_sym
          result[key] = canonicalize(value.fetch(source_key))
        end
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end
    private_class_method :canonicalize
  end
end
