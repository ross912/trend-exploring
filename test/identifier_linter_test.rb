# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/identifier_linter"

class IdentifierLinterTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_repository_identifiers_pass
    assert_empty M1::IdentifierLinter.lint(root: ROOT)
  end

  def test_unknown_acceptance_id_is_rejected
    assert_raises(M1::IdentifierLinter::Error) do
      M1::IdentifierLinter.lint_text_references("see XYZ-999", known_ids: ["ABC-001"])
    end
  end

  def test_duplicate_identifier_is_reported
    assert_includes M1::IdentifierLinter.duplicate_errors(%w[A-001 A-001], "acceptance ID"), "duplicate acceptance ID: A-001"
  end
end
