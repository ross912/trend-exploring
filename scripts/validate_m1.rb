# frozen_string_literal: true

require "json"
require_relative "../lib/provider_response_set"

ROOT = File.expand_path("..", __dir__)
SQL_PATH = File.join(ROOT, "schema/postgres/001_m1_core.sql")
SCHEMA_PATH = File.join(ROOT, "schema/json/provider-response-set.schema.json")
OBJECT_MAP_PATH = File.join(ROOT, "schema/object-map.json")
CANONICAL_CONTRACT_PATH = File.join(ROOT, "docs/05-canonical-data-and-time-contract.md")
VALID_FIXTURE = File.join(ROOT, "schema/fixtures/provider-response-set.valid.json")
INVALID_FIXTURE = File.join(
  ROOT,
  "schema/fixtures/provider-response-set.omitted-member.invalid.json"
)

REQUIRED_SQL_OBJECTS = %w[
  manifest_series
  manifest_activation_decision
  service_principal_credential_state_event
  model_invocation
  provider_response_set_profile
  provider_response_set_closure
  provider_response_member_unit
  provider_response_member_decision
  provider_response_receipt
  model_output_artifact
  provider_response_set
  token_use_policy_manifest
  token_use_unit
  token_use_decision
  token_use_ledger_checkpoint
  evaluation_arm_manifest
  evaluation_arm_generation_unit
  evaluation_arm_generation_decision
  evaluation_obligation
  evaluation_snapshot_decision
  evaluation_result
  evaluation_arm_output_snapshot
].freeze

REQUIRED_SQL_GUARDS = {
  "pgcrypto member hash" => /CREATE EXTENSION IF NOT EXISTS pgcrypto;/,
  "database member-set hash recomputation" => /calculated_member_set_hash/,
  "pre-invocation response plan" => /validate_response_plan_timing/,
  "post-closure append guard" => /prevent_response_append_after_closure/,
  "append path parent-row serialization" => /prevent_response_append_after_closure\(\).*?FOR UPDATE;/m,
  "closure path parent-row serialization" => /lock_response_set_for_closure\(\).*?FOR UPDATE;/m,
  "append-only mutation guard" => /reject_row_mutation/,
  "credential predecessor binding" => /predecessor_revision = aggregate_revision - 1/,
  "token policy composite binding" => /FOREIGN KEY \(token_use_policy_manifest_id, token_type, action\)/,
  "token scope generated binding" => /scope_binding_hash text GENERATED ALWAYS AS/,
  "token epoch enforcement" => /token use epoch is stale or unavailable/,
  "evaluation output closure" => /validate_evaluation_arm_closure/,
  "evaluation closure trigger" => /evaluation_arm_output_closure_guard/,
  "credential parent-row serialization" => /lock_credential_version_for_state_event\(\).*?FOR UPDATE;/m,
  "credential usability gate" => /assert_service_principal_credential_usable/
}.freeze

TIME_PROFILE_FIELDS = {
  "identity_time" => %w[identity_created_at system_available_at],
  "operational_record_time" => %w[recorded_at system_available_at],
  "derived_record_time" => %w[recorded_at system_available_at as_of run_mode input_record_ids],
  "standalone_snapshot_time" => %w[snapshot_frozen_at system_available_at as_of input_record_ids],
  "manifest_time" => %w[
    system_available_at effective_from schema_version schema_hash
    manifest_signature owner_service_principal_id input_record_ids
  ],
  "event_time" => %w[event_system_available_at valid_at ingest_domain_id ingest_sequence],
  "inherits_parent" => %w[system_available_at]
}.freeze

errors = []

begin
  schema = JSON.parse(File.read(SCHEMA_PATH))
  errors << "JSON Schema draft must be 2020-12" unless schema["$schema"].to_s.include?("2020-12")
  errors << "JSON Schema must declare semantic invariants" unless schema["x-m1-invariants"].is_a?(Array)
rescue JSON::ParserError => e
  errors << "JSON Schema parse error: #{e.message}"
end

sql = File.read(SQL_PATH)
sql_tables = sql.scan(/^CREATE TABLE\s+(\w+)/).flatten
table_blocks = sql.scan(/^CREATE TABLE\s+(\w+)\s+\((.*?)^\);/m).to_h
errors << "could not parse every CREATE TABLE block" unless table_blocks.keys.sort == sql_tables.sort
REQUIRED_SQL_OBJECTS.each do |object_name|
  pattern = /CREATE\s+(?:TABLE|VIEW)\s+#{Regexp.escape(object_name)}\b/i
  errors << "missing SQL object: #{object_name}" unless sql.match?(pattern)
end
REQUIRED_SQL_GUARDS.each do |guard_name, pattern|
  errors << "missing SQL guard: #{guard_name}" unless sql.match?(pattern)
end
transactional = sql.include?("BEGIN;") && sql.rstrip.end_with?("COMMIT;")
errors << "SQL migration must be transactional" unless transactional
errors << "SQL migration contains unresolved TODO" if sql.match?(/\bTODO\b/)
errors << "SQL dollar quotes are unbalanced" unless sql.scan("$$").length.even?

immutable_block = sql[/FOREACH immutable_table IN ARRAY ARRAY\[(.*?)\]\s*LOOP/m, 1]
if immutable_block
  guarded_tables = immutable_block.scan(/'([^']+)'/).flatten
  missing_guards = sql_tables - guarded_tables
  unknown_guards = guarded_tables - sql_tables
  duplicate_guards = guarded_tables.group_by { |table| table }
                                   .select { |_table, rows| rows.length > 1 }
                                   .keys
  errors << "SQL tables without append-only guard: #{missing_guards.join(',')}" unless missing_guards.empty?
  errors << "append-only guards for unknown tables: #{unknown_guards.join(',')}" unless unknown_guards.empty?
  errors << "duplicate append-only guards: #{duplicate_guards.join(',')}" unless duplicate_guards.empty?
else
  errors << "append-only table registry is missing"
end

begin
  object_map = JSON.parse(File.read(OBJECT_MAP_PATH))
  mappings = object_map.fetch("mappings")
  mapped_tables = mappings.map { |mapping| mapping.fetch("table") }
  duplicate_mappings = mapped_tables.group_by { |table| table }
                                    .select { |_table, rows| rows.length > 1 }
                                    .keys
  errors << "SQL tables missing object mappings: #{(sql_tables - mapped_tables).join(',')}" unless (sql_tables - mapped_tables).empty?
  errors << "object mappings for unknown SQL tables: #{(mapped_tables - sql_tables).join(',')}" unless (mapped_tables - sql_tables).empty?
  errors << "duplicate object mappings: #{duplicate_mappings.join(',')}" unless duplicate_mappings.empty?

  canonical_contract = File.read(CANONICAL_CONTRACT_PATH)
  mappings.each do |mapping|
    canonical_name = mapping.fetch("canonicalObject")
    unless canonical_contract.include?("`#{canonical_name}`")
      errors << "canonical object missing from 05 contract: #{canonical_name}"
    end

    time_profile = mapping.fetch("timeProfile")
    required_fields = TIME_PROFILE_FIELDS[time_profile]
    if required_fields.nil?
      errors << "unknown time profile in object map: #{time_profile}"
      next
    end
    block = table_blocks[mapping.fetch("table")].to_s
    missing_fields = required_fields.reject { |field| block.match?(/\b#{Regexp.escape(field)}\b/) }
    unless missing_fields.empty?
      errors << "#{mapping.fetch('table')} missing #{time_profile} fields: #{missing_fields.join(',')}"
    end
  end
rescue JSON::ParserError, KeyError => e
  errors << "object map error: #{e.message}"
end

begin
  M1::ProviderResponseSet.load(VALID_FIXTURE).validate!
rescue StandardError => e
  errors << "valid fixture was rejected: #{e.message}"
end

begin
  M1::ProviderResponseSet.load(INVALID_FIXTURE).validate!
  errors << "omitted-member fixture was incorrectly accepted"
rescue M1::ClosureError
  # Expected: the semantic validator must reject selective member omission.
rescue StandardError => e
  errors << "invalid fixture failed for the wrong reason: #{e.class}: #{e.message}"
end

if errors.empty?
  puts "M1 VALIDATION PASSED"
  puts "  SQL objects: #{REQUIRED_SQL_OBJECTS.length}"
  puts "  SQL guards: #{REQUIRED_SQL_GUARDS.length}"
  puts "  SQL table mappings: #{sql_tables.length}"
  puts "  JSON Schema: #{SCHEMA_PATH}"
  puts "  valid fixture: accepted"
  puts "  omitted-member fixture: blocked"
else
  warn "M1 VALIDATION FAILED"
  errors.each { |error| warn "  - #{error}" }
  exit 1
end
