# frozen_string_literal: true

require "json"
require_relative "../lib/provider_response_set"
require_relative "../lib/test_catalog_generator"
require_relative "../lib/event_registry"
require_relative "../lib/m1_gate_evaluator"
require_relative "../lib/m1_readiness"
require_relative "../lib/canonical_contract"

ROOT = File.expand_path("..", __dir__)
SQL_PATH = File.join(ROOT, "schema/postgres/001_m1_core.sql")
EVENT_SQL_PATH = File.join(ROOT, "schema/postgres/002_event_base.sql")
IMPORT_SQL_PATH = File.join(ROOT, "schema/postgres/003_manifest_import.sql")
EVENT_MAP_PATH = File.join(ROOT, "schema/event-infrastructure-map.json")
SOURCE_SQL_PATH = File.join(ROOT, "schema/postgres/004_m1_source_archive.sql")
SOURCE_MAP_PATH = File.join(ROOT, "schema/m1-source-map.json")
GATE_REPORT_SQL_PATH = File.join(ROOT, "schema/postgres/005_m1_gate_report.sql")
COVERAGE_PATH = File.join(ROOT, "schema/m1-phase-exit-coverage.json")
GOVERNANCE_SQL_PATH = File.join(ROOT, "schema/postgres/006_governance_quorum.sql")
GOVERNANCE_MAP_PATH = File.join(ROOT, "schema/governance-quorum-map.json")
ACCEPTANCE_PATH = File.join(ROOT, "docs/04-acceptance-test-plan.md")
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
  test_definition
  test_governance_policy
  test_definition_version
  test_catalog_manifest
  test_catalog_definition_member
  test_run
  test_result
  gate_decision
  approval_decision
  test_waiver
  gate_evaluation_unit
  gate_run_attempt_membership
  gate_evaluation_closure_decision
  gate_run_selection_decision
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
  "credential usability gate" => /assert_service_principal_credential_usable/,
  "test catalog closure" => /validate_test_catalog_closure/,
  "test result catalog membership" => /validate_test_result_membership/,
  "gate decision closure" => /validate_gate_decision_closure/,
  "P0 test applicability floor" => /severity <> 'P0' OR \(applicability_predicate = 'always' AND NOT waiver_allowed\)/,
  "waiver approval floor" => /validate_test_waiver/,
  "gate attempt catalog binding" => /validate_gate_run_attempt_membership/,
  "gate evaluation closure" => /validate_gate_evaluation_closure/,
  "gate run selection closure" => /validate_gate_run_selection/
}.freeze

TIME_PROFILE_FIELDS = {
  "identity_time" => %w[identity_created_at system_available_at],
  "operational_record_time" => %w[recorded_at system_available_at],
  "derived_record_time" => %w[recorded_at system_available_at as_of run_mode input_record_ids],
  "standalone_snapshot_time" => %w[snapshot_frozen_at system_available_at as_of input_record_ids],
  "bitemporal_version_time" => %w[valid_from system_from system_available_at as_of run_mode input_record_ids],
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

begin
  canonical_report = M1::CanonicalContract.repository_report(CANONICAL_CONTRACT_PATH)
  errors.concat(canonical_report.fetch("errors"))
rescue StandardError => e
  errors << "canonical contract validator error: #{e.class}: #{e.message}"
end

begin
  governance_sql = File.read(GOVERNANCE_SQL_PATH)
  governance_map = JSON.parse(File.read(GOVERNANCE_MAP_PATH)).fetch("mappings")
  governance_tables = governance_sql.scan(/^CREATE TABLE\s+(\w+)/).flatten
  mapped_governance_tables = governance_map.map { |mapping| mapping.fetch("table") }
  errors << "governance quorum tables missing mappings: #{(governance_tables - mapped_governance_tables).join(',')}" unless (governance_tables - mapped_governance_tables).empty?
  errors << "governance quorum map has unknown tables: #{(mapped_governance_tables - governance_tables).join(',')}" unless (mapped_governance_tables - governance_tables).empty?
  errors << "governance quorum migration must be transactional" unless governance_sql.include?("BEGIN;") && governance_sql.rstrip.end_with?("COMMIT;")
  errors << "approval quorum trigger is missing" unless governance_sql.include?("approval_decision_quorum_guard")
rescue JSON::ParserError, Errno::ENOENT, KeyError => e
  errors << "governance quorum contract error: #{e.message}"
end

begin
  readiness = M1::M1Readiness.evaluate(
    acceptance_plan: File.read(ACCEPTANCE_PATH),
    coverage: JSON.parse(File.read(COVERAGE_PATH))
  )
  errors << "M1 coverage matrix has missing/extra IDs" unless readiness.fetch("missingTestCodes").empty? && readiness.fetch("extraTestCodes").empty?
  errors << "M1 coverage matrix must remain blocked while partial/not-implemented evidence exists" unless readiness.fetch("decision") == "blocked" && readiness.fetch("blockedTestCodes").length > 0
rescue JSON::ParserError, Errno::ENOENT, KeyError, M1::M1Readiness::Error => e
  errors << "M1 readiness contract error: #{e.message}"
end

begin
  gate_report_sql = File.read(GATE_REPORT_SQL_PATH)
  errors << "M1 gate report migration must be transactional" unless gate_report_sql.include?("BEGIN;") && gate_report_sql.rstrip.end_with?("COMMIT;")
  errors << "M1 gate report function is missing" unless gate_report_sql.match?(/CREATE OR REPLACE FUNCTION\s+evaluate_m1_phase_exit_gate\b/i)
  errors << "M1 gate report must block missing results" unless gate_report_sql.include?("missing_count") && gate_report_sql.include?("blocking_count")
rescue Errno::ENOENT => e
  errors << "M1 gate report contract error: #{e.message}"
end

begin
  source_sql = File.read(SOURCE_SQL_PATH)
  source_map = JSON.parse(File.read(SOURCE_MAP_PATH)).fetch("mappings")
  source_tables = source_sql.scan(/^CREATE TABLE\s+(\w+)/).flatten
  mapped_source_tables = source_map.map { |mapping| mapping.fetch("table") }
  errors << "M1 source tables missing mappings: #{(source_tables - mapped_source_tables).join(',')}" unless (source_tables - mapped_source_tables).empty?
  errors << "M1 source map has unknown tables: #{(mapped_source_tables - source_tables).join(',')}" unless (mapped_source_tables - source_tables).empty?
  errors << "M1 source migration must be transactional" unless source_sql.include?("BEGIN;") && source_sql.rstrip.end_with?("COMMIT;")
  source_guarded = source_sql[/FOREACH immutable_table IN ARRAY ARRAY\[(.*?)\]\s*LOOP/m, 1].to_s.scan(/'([^']+)'/).flatten
  errors << "M1 source tables without append-only guards: #{(source_tables - source_guarded).join(',')}" unless (source_tables - source_guarded).empty?
  errors << "M1 source slice must define purpose gate" unless source_sql.include?("assert_purpose_authorized")
rescue JSON::ParserError, Errno::ENOENT, KeyError => e
  errors << "M1 source contract error: #{e.message}"
end

begin
  event_sql = File.read(EVENT_SQL_PATH)
  import_sql = File.read(IMPORT_SQL_PATH)
  event_tables = event_sql.scan(/^CREATE TABLE\s+(\w+)/).flatten
  event_map = JSON.parse(File.read(EVENT_MAP_PATH)).fetch("mappings")
  mapped_event_tables = event_map.map { |mapping| mapping.fetch("table") }
  errors << "event infrastructure tables missing mappings: #{(event_tables - mapped_event_tables).join(',')}" unless (event_tables - mapped_event_tables).empty?
  errors << "event infrastructure map has unknown tables: #{(mapped_event_tables - event_tables).join(',')}" unless (mapped_event_tables - event_tables).empty?
  errors << "EventBase migration must be transactional" unless event_sql.include?("BEGIN;") && event_sql.rstrip.end_with?("COMMIT;")
  errors << "manifest import migration must be transactional" unless import_sql.include?("BEGIN;") && import_sql.rstrip.end_with?("COMMIT;")
  %w[global_identity_registry event_type_registry_manifest event_type_definition event_base event_causal_parent].each do |object_name|
    errors << "missing EventBase SQL object: #{object_name}" unless event_sql.match?(/CREATE\s+TABLE\s+#{Regexp.escape(object_name)}\b/i)
  end
  %w[import_event_registry_manifest import_test_catalog_manifest].each do |function_name|
    errors << "missing manifest import function: #{function_name}" unless import_sql.match?(/CREATE OR REPLACE FUNCTION\s+#{function_name}\b/i)
  end
  errors << "manifest import must require signature verification" unless import_sql.include?("p_signature_verified") && import_sql.include?("signature is not verified")
rescue JSON::ParserError, Errno::ENOENT, KeyError => e
  errors << "EventBase/import contract error: #{e.message}"
end

begin
  rows = M1::TestCatalogGenerator.load_acceptance_plan(ACCEPTANCE_PATH)
  catalog = M1::TestCatalogGenerator.build(rows, target_phase: "M1", target_gate: "phase-exit")
  errors << "TestCatalog generator schema hash is invalid" unless catalog.fetch("schemaHash").match?(/\A[a-f0-9]{64}\z/)
  errors << "TestCatalog generator manifest ID is invalid" unless catalog.fetch("catalogManifestId").match?(/\A[0-9a-f-]{36}\z/)
  errors << "TestCatalog generator emitted unsigned catalog without governance marker" unless catalog.fetch("signatureStatus") == "unsigned" && catalog.fetch("governance").fetch("signatureRequiredBeforeActivation")
  errors << "TestCatalog members lack applicability evidence" unless catalog.fetch("members").all? { |member| member.fetch("applicabilityEvidence").to_s != "" }

  registry = M1::EventRegistry.build
  errors << "EventRegistry schema hash is invalid" unless registry.fetch("schemaHash").match?(/\A[a-f0-9]{64}\z/)
  errors << "EventRegistry definitions lack aggregate binding" unless registry.fetch("eventTypes").all? do |definition|
    definition.fetch("aggregateKind") && definition.fetch("aggregateConcreteType") && definition.fetch("payloadSchemaHash").match?(/\A[a-f0-9]{64}\z/)
  end
  gate_report = M1::M1GateEvaluator.evaluate(catalog: catalog, results: {})
  errors << "unsigned TestCatalog must block phase-exit" unless gate_report.fetch("decision") == "blocked" && gate_report.fetch("reasonCodes").include?("CATALOG_SIGNATURE_UNVERIFIED")
rescue StandardError => e
  errors << "generator/import contract error: #{e.class}: #{e.message}"
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
  puts "  EventBase infrastructure: 8 tables; signed import functions: 2"
  puts "  M1 source/archive slice: 15 tables"
  puts "  M1 phase-exit report: database function and positive/negative fixture"
  puts "  Governance quorum: 2 tables and deferred approval trigger"
  puts "  M1 phase-exit coverage: 30 required IDs; readiness intentionally blocked until all are fixture_passed"
  puts "  JSON Schema: #{SCHEMA_PATH}"
  puts "  valid fixture: accepted"
  puts "  omitted-member fixture: blocked"
else
  warn "M1 VALIDATION FAILED"
  errors.each { |error| warn "  - #{error}" }
  exit 1
end
