# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/canonical_schema_compiler"

class CanonicalSchemaCompilerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def compiled
    @compiled ||= M1::CanonicalSchemaCompiler.compile(
      contract_path: File.join(ROOT, "docs/05-canonical-data-and-time-contract.md"),
      object_map_path: File.join(ROOT, "schema/object-map.json")
    )
  end

  def test_compiler_is_deterministic_and_emits_executable_metadata_ddl
    second = M1::CanonicalSchemaCompiler.compile(
      contract_path: File.join(ROOT, "docs/05-canonical-data-and-time-contract.md"),
      object_map_path: File.join(ROOT, "schema/object-map.json")
    )
    assert_equal compiled, second
    assert_equal 247, compiled.fetch("objects").length
    assert_match(/CREATE TABLE canonical_contract_registry/, compiled.fetch("ddl"))
    assert_match(/CREATE UNIQUE INDEX canonical_contract_registry_profile_uq/, compiled.fetch("ddl"))
    assert_match(/event_subtype/, compiled.fetch("ddl"))
    assert_match(/\A[a-f0-9]{64}\z/, compiled.fetch("schemaHash"))
  end

  def test_global_identity_collision_is_rejected
    rows = [
      { "globalIdentityId" => "same", "identityKind" => "record", "concreteType" => "RawItem" },
      { "globalIdentityId" => "same", "identityKind" => "object", "concreteType" => "Signal" }
    ]
    error = assert_raises(M1::CanonicalSchemaCompiler::Error) do
      M1::CanonicalSchemaCompiler.validate_identity_universe!(rows)
    end
    assert_match(/global identity collision/, error.message)
  end

  def test_orphan_parent_is_rejected
    rows = [{
      "globalIdentityId" => "child",
      "identityKind" => "record",
      "concreteType" => "Child",
      "parentIdentityId" => "missing"
    }]
    error = assert_raises(M1::CanonicalSchemaCompiler::Error) do
      M1::CanonicalSchemaCompiler.validate_identity_universe!(rows)
    end
    assert_match(/orphan canonical parent/, error.message)
  end
end
