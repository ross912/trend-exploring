# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/concept_mapping_provider"
require_relative "../lib/concept_mapping_runner"
require_relative "../lib/multilingual_concept_store"

class ConceptMappingStoreIntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "concept_mapping_e2e_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(4)}"
    run!([bin("createdb"), "-h", host, "-p", port, "-U", user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 016_local_fulltext_translation.sql 017_raw_archive_immutability.sql 018_multilingual_concepts.sql 018_multilingual_concepts.sql].each do |file|
      run!([bin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = MultilingualConceptStore.new(psql: bin("psql"), host: host, port: port, database: @database, user: user)
    seed_sources_and_translations
  end

  def teardown
    run!([bin("dropdb"), "-h", host, "-p", port, "-U", user, @database]) if @database
  end

  def test_fixture_runner_reads_successful_artifacts_and_persists_append_only_linkage
    inputs = @store.translation_mapping_inputs(limit: 10)
    assert_equal 2, inputs.length
    provider = ConceptMappingProvider::Fixture.new(mappings: {
      inputs.fetch(0).fetch("source_version_id") => { "canonical_concept_key" => "concept:storm", "target_canonical_label" => "风暴", "relation" => "translation_equivalent" },
      inputs.fetch(1).fetch("source_version_id") => { "canonical_concept_key" => "concept:storm", "target_canonical_label" => "风暴", "relation" => "translation_equivalent" }
    })
    runner = ConceptMappingRunner.new(store: @store, provider: provider)
    result = runner.run(mode: "fixture", limit: 10, persist: true)
    assert_equal "passed", result.fetch("status")
    assert_equal 1, result.fetch("candidate_count")
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_multilingual_participation_candidate")
    assert_equal 2, scalar("SELECT COUNT(*) FROM local_multilingual_translation_input")
    assert_equal 2, scalar("SELECT COUNT(*) FROM local_multilingual_concept_mapping")

    retry_result = runner.run(mode: "fixture", limit: 10, persist: true)
    assert_equal "passed", retry_result.fetch("status")
    assert_equal 2, scalar("SELECT COUNT(*) FROM local_multilingual_concept_mapping")
    assert_equal 1, scalar("SELECT COUNT(*) FROM local_multilingual_participation_candidate")

    conflicting = Marshal.load(Marshal.dump(retry_result.fetch("linkage")))
    conflicting.fetch("mappings").first["target_canonical_label"] = "伪造标签"
    assert_raises(MultilingualConceptStore::Error) { @store.save_linkage!(linkage: conflicting) }
  end

  def test_translation_mapping_excludes_runs_with_mismatched_item_or_source_hash
    sql!(<<~SQL)
      UPDATE local_metadata_translation_run
         SET source_content_hash = 'wrong-run-hash'
       WHERE run_id = 'run-en';
      UPDATE local_metadata_translation_run
         SET item_key = 'i-s-en'
       WHERE run_id = 'run-ar';
    SQL

    assert_empty @store.translation_mapping_inputs(limit: 10)
  end

  private

  def seed_sources_and_translations
    now = "2026-08-13T00:00:00Z"
    [%w[s-en en pub-en], %w[s-ar ar pub-ar]].each do |source_id, language, publisher_id|
      sql!(<<~SQL)
        INSERT INTO local_source_registry(source_id, source_name, source_url, language, region, publisher_id, discovery_basis, analysis_policy, query_topics, market_label_basis)
        VALUES ('#{source_id}', '#{source_id}', 'https://#{source_id}.example', '#{language}', 'global', '#{publisher_id}', 'editorial_feed', 'signal_eligible', '[]'::jsonb, 'editorial_scope_label');
        INSERT INTO local_source_capture(capture_id, source_id, source_url, captured_at, http_status, content_bytes, body_hash, storage_status)
        VALUES ('c-#{source_id}', '#{source_id}', 'https://#{source_id}.example/item', '#{now}', 200, 1, 'body-#{source_id}', 'metadata_only');
        INSERT INTO local_source_item(item_key, source_id, source_name, language, region, publisher_id, publisher_identity_status, title, summary, source_url, fetched_at, captured_at, content_hash, capture_id)
        VALUES ('i-#{source_id}', '#{source_id}', '#{source_id}', '#{language}', 'global', '#{publisher_id}', 'configured', 'Storm event', 'Independent report', 'https://#{source_id}.example/item', '#{now}', '#{now}', 'hash-#{language}', 'c-#{source_id}');
        INSERT INTO local_source_item_version(version_id, item_key, capture_id, source_id, source_name, language, region, publisher_id, publisher_identity_status, source_kind, query_conditioned, lineage_metadata_basis, title, summary, source_url, fetched_at, captured_at, content_hash, published_at, discovery_basis, analysis_policy, query_topics, market_label_basis)
        VALUES ('v-#{language}', 'i-#{source_id}', 'c-#{source_id}', '#{source_id}', '#{source_id}', '#{language}', 'global', '#{publisher_id}', 'configured', 'configured', false, 'capture_time', 'Storm event', 'Independent report', 'https://#{source_id}.example/item', '#{now}', '#{now}', 'hash-#{language}', '#{now}', 'editorial_feed', 'signal_eligible', '[]'::jsonb, 'editorial_scope_label');
      SQL
      artifact_id = "tr-#{language}"
      run_id = "run-#{language}"
      sql!(<<~SQL)
        INSERT INTO local_metadata_translation_run(run_id, source_version_id, item_key, source_content_hash, target_language, provider, model, prompt_version, state, input_chars, started_at, finished_at)
        VALUES ('#{run_id}', 'v-#{language}', 'i-#{source_id}', 'hash-#{language}', 'zh-CN', 'deepseek', 'deepseek-v4-pro', 'metadata-translation-v1', 'succeeded', 20, '#{now}', '#{now}');
        INSERT INTO local_translation_artifact(artifact_id, source_version_id, item_key, source_language, target_language, original_content_hash, provider, model, translated_title, translated_summary, validation_status, status, error_reason)
        VALUES ('#{artifact_id}', 'v-#{language}', 'i-#{source_id}', '#{language}', 'zh-CN', 'hash-#{language}', 'deepseek', 'deepseek-v4-pro', '风暴事件', '独立报告', 'mechanical_pass', 'translated', '');
      SQL
    end
  end

  def host; ENV.fetch("LOCAL_PGHOST", "/private/tmp/trend-exploring-pg-socket"); end
  def port; ENV.fetch("LOCAL_PGPORT", "55433"); end
  def user; ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")); end
  def bin(name); File.join(ENV.fetch("PG_BIN", "/private/tmp/trend-exploring-postgres15-runtime/bin"), name); end
  def run!(args); out, err, status = Open3.capture3(*args); raise "#{err}\n#{out}" unless status.success?; out; end
  def sql!(sql); run!([bin("psql"), "-XAtq", "-v", "ON_ERROR_STOP=1", "-h", host, "-p", port, "-U", user, "-d", @database, "-c", sql]); end
  def scalar(sql); sql!(sql).strip.to_i; end
end
