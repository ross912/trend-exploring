# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/revocation_dependency"

class RevocationDependencyTest < Minitest::Test
  def domains
    { "rights" => { "epoch" => 11 }, "global" => { "epoch" => 3 }, "personal" => { "epoch" => 7 } }
  end

  def test_snapshot_hash_is_order_independent_and_matches
    first = M1::RevocationDependency.snapshot(domains: domains, epochs: { "rights" => 11, "global" => 3, "personal" => 7 })
    second = M1::RevocationDependency.snapshot(domains: domains.reverse_each.to_h, epochs: { personal: 7, global: 3, rights: 11 })
    assert_equal first.fetch("setHash"), second.fetch("setHash")
    assert M1::RevocationDependency.matches?(first, domains: domains, epochs: { rights: 11, global: 3, personal: 7 })
  end

  def test_epoch_change_fails_closed
    snapshot = M1::RevocationDependency.snapshot(domains: domains, epochs: { rights: 11, global: 3, personal: 7 })
    refute M1::RevocationDependency.matches?(snapshot, domains: domains, epochs: { rights: 12, global: 3, personal: 7 })
  end

  def test_missing_domain_is_rejected
    error = assert_raises(M1::RevocationDependency::Error) do
      M1::RevocationDependency.snapshot(domains: { rights: 1 }, epochs: {})
    end
    assert_match(/domains missing/, error.message)
  end
end
