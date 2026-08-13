#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/fulltext_pipeline"

begin
  store = LocalRadarStore.new
  pipeline = FulltextPipeline.new(store: store)
  archive = pipeline.archive(limit: Integer(ENV.fetch("LOCAL_ARTICLE_ARCHIVE_LIMIT", "20")))
  translation = pipeline.translate(
    limit: Integer(ENV.fetch("LOCAL_FULLTEXT_TRANSLATION_LIMIT", "5")),
    daily_character_limit: Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", "200000"))
  )
  puts JSON.generate({ "status" => "passed", "archive" => archive, "translation" => translation })
rescue ArticleArchive::Error, TranslationProvider::Error, LocalRadarStore::Error, ArgumentError => error
  puts JSON.generate({ "status" => "failed", "error" => error.message })
  exit 1
end
