#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/translation_provider"
require_relative "../../lib/translation_runner"

store = LocalRadarStore.new
provider = TranslationProvider::OpenAICompatible.new
result = TranslationRunner.new(store: store, provider: provider).run(limit: Integer(ENV.fetch("LOCAL_TRANSLATION_LIMIT", "20")))
puts JSON.pretty_generate(result)
exit 0
