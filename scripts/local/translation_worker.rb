#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone metadata translation worker.  It translates only non-Chinese
# title/short-summary metadata; article/full-text work stays in the rights-aware
# archive pipeline.  The worker owns the same DB batch lease used by ingest and
# the HTTP manual trigger, so duplicate launches are harmless.
require "json"
require "optparse"
require "fileutils"
require_relative "../../lib/local_radar_store"
require_relative "../../lib/local_runtime"
require_relative "../../lib/translation_provider"
require_relative "../../lib/translation_runner"

MAX_LIMIT = 100
MAX_DAILY_CHARS = 200_000

options = {
  limit: Integer(ENV.fetch("LOCAL_TRANSLATION_LIMIT", "100")),
  daily_character_limit: Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", MAX_DAILY_CHARS.to_s))
}
configured_limit = [Integer(ENV.fetch("LOCAL_TRANSLATION_LIMIT", MAX_LIMIT.to_s)), MAX_LIMIT].min
configured_daily_limit = [Integer(ENV.fetch("LOCAL_DEEPSEEK_DAILY_CHARACTER_LIMIT", MAX_DAILY_CHARS.to_s)), MAX_DAILY_CHARS].min
OptionParser.new do |parser|
  parser.banner = "Usage: translation_worker.rb [--limit N] [--daily-character-limit N]"
  parser.on("--limit N", Integer, "metadata item limit (1..100)") { |value| options[:limit] = value }
  parser.on("--daily-character-limit N", Integer, "daily input-character budget (1..200000)") { |value| options[:daily_character_limit] = value }
end.parse!(ARGV)

options[:limit] = [options.fetch(:limit), MAX_LIMIT].min
options[:daily_character_limit] = [options.fetch(:daily_character_limit), MAX_DAILY_CHARS].min
abort "translation worker limit must be between 1 and #{configured_limit}" unless options.fetch(:limit).between?(1, configured_limit)
abort "translation worker daily character limit must be between 1 and #{configured_daily_limit}" unless options.fetch(:daily_character_limit).between?(1, configured_daily_limit)

state_dir = ENV.fetch("LOCAL_STATE_DIR", LocalRuntime.state_dir)
lock_root = File.join(state_dir, "locks")
lock_dir = File.join(lock_root, "translation.lock")
FileUtils.mkdir_p(lock_root, mode: 0o700)
if File.exist?(File.join(state_dir, "deploy.lock"))
  warn "translation worker refused: deployment lock is active"
  exit 75
end
unless Dir.mkdir(lock_dir, 0o700)
  warn "translation worker refused: another translation worker is active"
  exit 75
end
pid_path = File.join(lock_dir, "pid")
File.write(pid_path, "#{Process.pid}\n", mode: "w", perm: 0o600)
cleanup_owned_lock = lambda do
  begin
    owner_pid = File.read(pid_path).to_s.strip.to_i if File.file?(pid_path)
    FileUtils.rm_rf(lock_dir) if owner_pid == Process.pid
  rescue StandardError
    # Never mask the worker's actual exit status with cleanup diagnostics.
    nil
  end
end
at_exit { cleanup_owned_lock.call }
Signal.trap("TERM") { exit 143 }
Signal.trap("INT") { exit 130 }

begin
  store = LocalRadarStore.new
  provider = TranslationProvider::DeepSeek.new
  result = TranslationRunner.new(store: store, provider: provider).run(
    limit: options.fetch(:limit), daily_character_limit: options.fetch(:daily_character_limit)
  )
  puts JSON.pretty_generate(result.merge(
    "worker" => "metadata-translation",
    "limit" => options.fetch(:limit),
    "daily_character_limit" => options.fetch(:daily_character_limit),
    "fulltext_boundary" => "full text remains rights-gated; this worker handles title and short summary metadata only"
  ))
  exit(result.fetch("status") == "active" ? 75 : 0)
rescue TranslationProvider::Error, LocalRadarStore::Error, ArgumentError => error
  puts JSON.generate({ "status" => "failed", "worker" => "metadata-translation", "error" => error.message })
  exit 1
end
