#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"

root = File.expand_path("..", __dir__)
options = {
  root: root,
  result: nil,
  runtime_name: nil,
  runtime_version: nil,
  test_paths: []
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/record_m1_readiness_evidence.rb --code CODE --command COMMAND --test-path PATH --artifact PATH [options]"
  parser.on("--code CODE", "Stable acceptance test code") { |value| options[:code] = value }
  parser.on("--command COMMAND", "Exact command to execute or record") { |value| options[:command] = value }
  parser.on("--test-path PATH", "Fixture/test path; may be repeated", Array) { |value| options[:test_paths].concat(Array(value)) }
  parser.on("--artifact PATH", "Repository-relative artifact JSON path") { |value| options[:artifact] = value }
  parser.on("--stdout PATH", "Repository-relative combined stdout/stderr path") { |value| options[:stdout] = value }
  parser.on("--root PATH", "Repository root") { |value| options[:root] = File.expand_path(value) }
  parser.on("--result RESULT", "not_run, passed, failed, environment_blocked, or external_blocked") { |value| options[:result] = value }
  parser.on("--blocker-reason REASON", "Required for blocked/not-run records") { |value| options[:blocker_reason] = value }
  parser.on("--runtime-name NAME", "Runtime name, e.g. postgresql") { |value| options[:runtime_name] = value }
  parser.on("--runtime-version VERSION", "Runtime version, e.g. 15.18") { |value| options[:runtime_version] = value }
end.parse!

required = %i[code command artifact]
missing = required.select { |key| options[key].to_s.strip.empty? }
missing << :test_paths if options[:test_paths].empty?
abort "missing options: #{missing.join(", ")}" unless missing.empty?

allowed_results = %w[not_run passed failed environment_blocked external_blocked]
if options[:result] && !allowed_results.include?(options[:result])
  abort "unknown result: #{options[:result]}"
end
if %w[not_run environment_blocked external_blocked].include?(options[:result]) && options[:blocker_reason].to_s.strip.empty?
  abort "--blocker-reason is required for #{options[:result]}"
end

def relative_path(root, path)
  raise "path must be repository-relative: #{path}" unless path.is_a?(String) && !path.empty? && !path.start_with?("/")

  root_path = File.expand_path(root)
  candidate = File.expand_path(path, root_path)
  prefix = "#{root_path}#{File::SEPARATOR}"
  raise "path escapes repository: #{path}" unless candidate.start_with?(prefix)

  candidate
end

options[:test_paths].each do |path|
  abort "fixture/test path does not exist: #{path}" unless File.file?(relative_path(options[:root], path))
end

runtime = if options[:runtime_name] || options[:runtime_version]
  abort "both --runtime-name and --runtime-version are required" unless options[:runtime_name] && options[:runtime_version]

  { "name" => options[:runtime_name], "version" => options[:runtime_version] }
end
result = options[:result]
command_exit_status = nil
output = ""

unless %w[not_run environment_blocked external_blocked].include?(result)
  stdout, stderr, status = Open3.capture3("sh", "-lc", options.fetch(:command), chdir: options.fetch(:root))
  output = stdout.to_s + stderr.to_s
  command_exit_status = status.exitstatus
  result = status.success? ? "passed" : "failed"
else
  output = "#{result}: #{options.fetch(:blocker_reason)}\n"
end

verified_at = Time.now.utc.iso8601
stdout_path = options[:stdout] || options[:artifact].sub(/\.json\z/, ".stdout.log")
stdout_file = relative_path(options.fetch(:root), stdout_path)
artifact_file = relative_path(options.fetch(:root), options.fetch(:artifact))
FileUtils.mkdir_p(File.dirname(stdout_file))
FileUtils.mkdir_p(File.dirname(artifact_file))
File.write(stdout_file, output)

artifact = {
  "schemaVersion" => "m1.readiness-artifact.v1",
  "testCode" => options.fetch(:code),
  "command" => options.fetch(:command),
  "result" => result,
  "verified" => true,
  "verifiedAt" => verified_at,
  "runtime" => runtime,
  "testPaths" => options.fetch(:test_paths),
  "stdoutPath" => stdout_path,
  "stdoutSha256" => Digest::SHA256.file(stdout_file).hexdigest,
  "commandExitStatus" => command_exit_status,
  "runner" => "scripts/record_m1_readiness_evidence.rb"
}
File.write(artifact_file, JSON.pretty_generate(artifact) + "\n")
puts JSON.pretty_generate(artifact)
