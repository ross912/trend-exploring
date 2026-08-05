# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "../lib/provider_response_set"

ROOT = File.expand_path("..", __dir__)
DOC_GLOB = File.join(ROOT, "docs/*.md")
ACCEPTANCE_PATH = File.join(ROOT, "docs/04-acceptance-test-plan.md")
CONTRACT_PATH = File.join(ROOT, "docs/05-canonical-data-and-time-contract.md")
OBJECT_MAP_PATH = File.join(ROOT, "schema/object-map.json")
JSON_SCHEMA_PATH = File.join(ROOT, "schema/json/provider-response-set.schema.json")
M1_VALIDATOR_PATH = File.join(ROOT, "scripts/validate_m1.rb")
PROJECT_TEST_GLOB = File.join(ROOT, "test/*_test.rb")

M0_BASELINE_COUNTS = {
  "acceptance tests" => 233,
  "stable_identity" => 41,
  "immutable_record" => 169,
  "immutable_manifest" => 36
}.freeze

VALID_PHASES = %w[M0 M1 M2 M3 M4 M5].freeze
VALID_SEVERITIES = %w[P0 P1].freeze
VALID_BLOCKING = %w[
  phase-exit normal-edition service-claim release capability-claim
  version-promotion none
].freeze

def listed_objects(markdown, registry_name)
  line = markdown.lines.find { |candidate| candidate.start_with?("| `#{registry_name}` |") }
  return nil unless line

  line.split("|", -1).fetch(2).split("、").map do |name|
    name.delete("`").strip
  end.reject(&:empty?)
end

def duplicates(values)
  values.group_by { |value| value }
        .select { |_value, occurrences| occurrences.length > 1 }
        .keys
end

def validate_markdown(path, content, errors)
  fence_open = false
  table_width = nil

  content.lines.each_with_index do |line, index|
    line_number = index + 1
    if line.start_with?("```")
      fence_open = !fence_open
      table_width = nil
      next
    end

    next if fence_open

    if line.start_with?("|")
      width = line.scan(/(?<!\\)\|/).length
      table_width ||= width
      if width != table_width
        errors << "#{path}:#{line_number} markdown table width #{width}, expected #{table_width}"
      end
    else
      table_width = nil
    end
  end

  errors << "#{path}: unclosed code fence" if fence_open
end

errors = []
documents = Dir[DOC_GLOB].sort.each_with_object({}) do |path, memo|
  memo[path] = File.read(path)
end

documents.each do |path, content|
  validate_markdown(path, content, errors)
end

json_blocks = []
documents.each do |path, content|
  content.scan(/^```json\s*$\n(.*?)^```\s*$/m).each_with_index do |match, index|
    begin
      JSON.parse(match.first)
      json_blocks << [path, index]
    rescue JSON::ParserError => e
      errors << "#{path}: JSON block #{index + 1} is invalid: #{e.message}"
    end
  end
end
errors << "docs/02 must retain exactly 6 JSON examples" unless json_blocks.count { |path, _index| path.end_with?("02-weak-signal-specification.md") } == 6

acceptance = File.read(ACCEPTANCE_PATH)
acceptance_rows = acceptance.lines.each_with_index.map do |line, index|
  next unless line.match?(/^\| [A-Z][A-Z0-9]*-[0-9]/)

  cells = line.split("|", -1).map(&:strip)
  errors << "#{ACCEPTANCE_PATH}:#{index + 1} acceptance row must have 6 columns" unless cells.length == 8
  {
    "line" => index + 1,
    "id" => cells[1],
    "phase" => cells[2],
    "severity" => cells[3],
    "blocking" => cells[4]
  }
end.compact

acceptance_ids = acceptance_rows.map { |row| row["id"] }
errors << "acceptance baseline count changed: #{acceptance_ids.length}" unless acceptance_ids.length == M0_BASELINE_COUNTS["acceptance tests"]
duplicates(acceptance_ids).each { |id| errors << "duplicate acceptance ID: #{id}" }
acceptance_rows.each do |row|
  location = "#{ACCEPTANCE_PATH}:#{row['line']}"
  errors << "#{location} malformed acceptance ID: #{row['id']}" unless row["id"].match?(/\A[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\z/)
  errors << "#{location} unknown phase: #{row['phase']}" unless VALID_PHASES.include?(row["phase"])
  errors << "#{location} unknown severity: #{row['severity']}" unless VALID_SEVERITIES.include?(row["severity"])
  errors << "#{location} unknown blocking mode: #{row['blocking']}" unless VALID_BLOCKING.include?(row["blocking"])
end

referenced_ids = documents.reject { |path, _content| path == ACCEPTANCE_PATH }
                          .values
                          .flat_map { |content| content.scan(/\b[A-Z][A-Z0-9]*-[0-9]{3}[A-Z]?\b/) }
                          .uniq
(referenced_ids - acceptance_ids).each do |id|
  errors << "documentation references unknown acceptance ID: #{id}"
end

contract = File.read(CONTRACT_PATH)
registries = {}
%w[stable_identity immutable_record immutable_manifest].each do |registry_name|
  objects = listed_objects(contract, registry_name)
  if objects.nil?
    errors << "missing canonical registry: #{registry_name}"
    next
  end
  registries[registry_name] = objects
  expected_count = M0_BASELINE_COUNTS.fetch(registry_name)
  errors << "#{registry_name} baseline count changed: #{objects.length}" unless objects.length == expected_count
  duplicates(objects).each { |name| errors << "duplicate #{registry_name} object: #{name}" }
end

registered_objects = registries.values.flatten
duplicates(registered_objects).each do |name|
  errors << "canonical object appears in multiple archetypes: #{name}"
end

record_time_profiles = {}
%w[
  raw_item_version_time bitemporal_version_time standalone_snapshot_time
  derived_record_time operational_record_time
].each do |profile|
  objects = listed_objects(contract, profile)
  if objects.nil?
    errors << "missing time profile registry: #{profile}"
    next
  end
  objects.each do |object_name|
    if record_time_profiles.key?(object_name)
      errors << "record appears in multiple time profiles: #{object_name}"
    end
    record_time_profiles[object_name] = profile
  end
end

immutable_records = registries.fetch("immutable_record", [])
(immutable_records - record_time_profiles.keys).each do |name|
  errors << "immutable record missing time profile: #{name}"
end
(record_time_profiles.keys - immutable_records).each do |name|
  errors << "time profile contains non-record object: #{name}"
end

begin
  object_map = JSON.parse(File.read(OBJECT_MAP_PATH))
  object_map.fetch("mappings").each do |mapping|
    object_name = mapping.fetch("canonicalObject")
    role = mapping.fetch("role")
    profile = mapping.fetch("timeProfile")
    case role
    when "identity"
      errors << "#{object_name} is not a stable identity" unless registries.fetch("stable_identity", []).include?(object_name)
      errors << "#{object_name} identity must use identity_time" unless profile == "identity_time"
    when "manifest"
      errors << "#{object_name} is not an immutable manifest" unless registries.fetch("immutable_manifest", []).include?(object_name)
      errors << "#{object_name} manifest must use manifest_time" unless profile == "manifest_time"
    when "record"
      errors << "#{object_name} is not an immutable record" unless immutable_records.include?(object_name)
      expected_profile = record_time_profiles[object_name]
      errors << "#{object_name} uses #{profile}, expected #{expected_profile}" unless profile == expected_profile
    when "event"
      errors << "#{object_name} event must use event_time" unless profile == "event_time"
      errors << "event API object is absent from canonical contract: #{object_name}" unless contract.include?("`#{object_name}`")
    when "child"
      errors << "#{object_name} child must inherit parent time" unless profile == "inherits_parent"
      errors << "child parent is absent from canonical contract: #{object_name}" unless registered_objects.include?(object_name)
    else
      errors << "unknown object-map role: #{role}"
    end
  end
rescue JSON::ParserError, KeyError => e
  errors << "object map validation error: #{e.message}"
end

begin
  schema = JSON.parse(File.read(JSON_SCHEMA_PATH))
  schema_key_contracts = {
    "responseSet" => ["responseSet", M1::ProviderResponseSet::RESPONSE_SET_KEYS],
    "memberUnit" => ["expectedMembers", M1::ProviderResponseSet::MEMBER_KEYS],
    "memberDecision" => ["decisions", M1::ProviderResponseSet::DECISION_KEYS],
    "receipt" => ["receipts", M1::ProviderResponseSet::RECEIPT_KEYS],
    "output" => ["outputs", M1::ProviderResponseSet::OUTPUT_KEYS]
  }
  errors << "JSON Schema top-level keys diverge from Ruby" unless schema.fetch("properties").keys.sort == M1::ProviderResponseSet::TOP_LEVEL_KEYS.sort
  schema_key_contracts.each do |definition, (label, ruby_keys)|
    schema_keys = schema.fetch("$defs").fetch(definition).fetch("properties").keys
    errors << "JSON Schema #{label} keys diverge from Ruby" unless schema_keys.sort == ruby_keys.sort
  end
rescue JSON::ParserError, KeyError => e
  errors << "JSON Schema/Ruby contract error: #{e.message}"
end

status_contracts = {
  File.join(ROOT, "docs/00-requirements-and-implementation-roadmap.md") => "M0 有条件冻结的需求基线；M1 实施中",
  File.join(ROOT, "docs/03-design-review-log.md") => "M0 有条件冻结；M1 实施中（历史审查记录封存）",
  ACCEPTANCE_PATH => "M0 有条件冻结的可执行验收基线；M1 继续物化测试",
  CONTRACT_PATH => "M0 有条件冻结的语义权威；M1 机器 schema 化中"
}
status_contracts.each do |path, status|
  errors << "#{path} has stale M0/M1 status" unless File.read(path).lines.first(8).join.include?(status)
end

m1_stdout, m1_stderr, m1_status = Open3.capture3(RbConfig.ruby, M1_VALIDATOR_PATH)
errors << "M1 validator failed: #{m1_stderr.strip}" unless m1_status.success?

test_loader = "Dir[#{PROJECT_TEST_GLOB.inspect}].sort.each { |path| require File.expand_path(path) }"
test_stdout, test_stderr, test_status = Open3.capture3(
  RbConfig.ruby,
  "-I#{File.join(ROOT, 'lib')}",
  "-e",
  test_loader
)
errors << "project tests failed: #{test_stderr.strip}\n#{test_stdout.strip}" unless test_status.success?

if errors.empty?
  puts "M0+M1 VALIDATION PASSED"
  puts "  acceptance tests: #{acceptance_ids.length} unique"
  puts "  canonical objects: #{registries.fetch('stable_identity').length} identities, #{immutable_records.length} records, #{registries.fetch('immutable_manifest').length} manifests"
  puts "  embedded JSON examples: #{json_blocks.length}"
  puts "  markdown documents: #{documents.length}"
  puts "  M1 validator: passed"
  summary = test_stdout.lines.find { |line| line.include?("runs,") }
  puts "  project tests: #{summary.to_s.strip}"
else
  warn "M0+M1 VALIDATION FAILED"
  errors.each { |error| warn "  - #{error}" }
  exit 1
end
