# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/bitemporal_query"

class BitemporalQueryTest < Minitest::Test
  def test_templates_require_both_system_and_valid_as_of_for_versions
    query = M1::BitemporalQuery.bitemporal_version_as_known(table: "test_definition_version")
    assert_includes query, "system_from <= :query_system_as_of"
    assert_includes query, "valid_from <= :valid_time_as_of"
    refute_match(/MAX\s*\(|current_/i, query)
  end

  def test_unsafe_identifier_is_rejected
    assert_raises(M1::BitemporalQuery::Error) do
      M1::BitemporalQuery.operational_record_as_known(table: "test_runs; DROP TABLE test_result")
    end
  end

  def test_all_templates_validate
    assert M1::BitemporalQuery.validate!
  end
end
