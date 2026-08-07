# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/data_boundary"

class DataBoundaryTest < Minitest::Test
  SPEC_PATH = File.expand_path("../schema/data-domain-boundary.json", __dir__)

  def spec
    @spec ||= M1::DataBoundary.load(SPEC_PATH)
  end

  def test_global_boundary_is_fail_closed
    assert M1::DataBoundary.validate!(spec)
  end

  def test_private_class_cannot_be_persisted_in_global_path
    malformed = JSON.parse(JSON.generate(spec))
    malformed.fetch("paths").first.fetch("dataClasses") << "conversation_turn"
    assert_raises(M1::DataBoundary::Error) { M1::DataBoundary.validate!(malformed) }
  end

  def test_personal_to_global_long_term_path_is_rejected
    malformed = JSON.parse(JSON.generate(spec))
    malformed.fetch("paths") << {
      "name" => "private-cache-leak",
      "fromDomain" => "personal",
      "toDomain" => "global",
      "dataClasses" => ["memory_candidate"],
      "persistence" => "long_term",
      "allowed" => true
    }
    assert_raises(M1::DataBoundary::Error) { M1::DataBoundary.validate!(malformed) }
  end
end
