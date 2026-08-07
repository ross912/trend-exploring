#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/data_boundary"

path = File.expand_path("../schema/data-domain-boundary.json", __dir__)
M1::DataBoundary.validate!(M1::DataBoundary.load(path))
puts({ "status" => "passed", "contract" => path, "runtimeEnforcement" => "pending" }.to_json)
