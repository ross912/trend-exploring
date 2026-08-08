#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/m4_readiness"

root = File.expand_path("..", __dir__)
report = M4::M4Readiness.evaluate(
  acceptance_plan: File.read(File.join(root, "docs/04-acceptance-test-plan.md")),
  coverage: JSON.parse(File.read(File.join(root, "schema/m4-phase-exit-coverage.json"))),
  root: root
)
puts JSON.pretty_generate(report)
exit 1 unless report.fetch("decision") == "ready"
