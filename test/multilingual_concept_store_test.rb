# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "securerandom"
require_relative "../lib/multilingual_concept_store"
require_relative "../lib/multilingual_concept_linker"

class MultilingualConceptStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREFIX = "multilingual_concept_store_test_#{Process.pid}_"

  def setup
    @database = "#{PREFIX}#{SecureRandom.hex(4)}"
    run!([pgbin("createdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database])
    %w[011_local_radar.sql 012_breadth_discovery.sql 017_raw_archive_immutability.sql 018_multilingual_concepts.sql].each do |file|
      run!([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", file)])
    end
    @store = MultilingualConceptStore.new(psql: pgbin("psql"), host: pg_host, port: pg_port, database: @database, user: pg_user)
    seed_sources
  end

  def teardown
    run!([pgbin("dropdb"), "-h", pg_host, "-p", pg_port, "-U", pg_user, @database]) if @database
  end

  def test_append_only_lineage_and_direct_sql_counterexamples
    linker = MultilingualConceptLinker.new
    source_items = [source("v-en", "en", "pub-en"), source("v-zh", "zh-CN", "pub-zh")]
    mappings = [mapping("m-en", "v-en", "en"), mapping("m-zh", "v-zh", "zh-CN")]
    linkage = linker.link(source_items: source_items, mappings: mappings)
    candidates = @store.save_linkage!(linkage: linkage)
    assert_equal 1, candidates.length
    assert_equal 2, candidates.fetch(0).fetch("source_language_count")

    assert_raises(MultilingualConceptStore::Error) { @store.send(:execute, "UPDATE local_source_item_version SET title = 'rewritten' WHERE version_id = 'v-en'") }
    assert_raises(MultilingualConceptStore::Error) { @store.send(:execute, "UPDATE local_multilingual_concept_mapping SET target_canonical_label = '伪造' WHERE mapping_id = 'm-en'") }
    assert_raises(MultilingualConceptStore::Error) { @store.send(:execute, "DELETE FROM local_multilingual_participation_candidate") }
    assert_raises(MultilingualConceptStore::Error) { @store.send(:execute, "TRUNCATE local_multilingual_translation_input") }
  end

  def test_candidate_direct_sql_rejects_one_language_and_one_publisher
    linker = MultilingualConceptLinker.new
    linkage = linker.link(source_items: [source("v-en", "en", "pub-en"), source("v-zh", "zh-CN", "pub-zh")], mappings: [mapping("m-en", "v-en", "en"), mapping("m-zh", "v-zh", "zh-CN")])
    @store.save_linkage!(linkage: linkage)
    candidate = linkage.fetch("participation_candidates").fetch(0)
    broken = candidate.merge("publisher_count" => 1, "publishers" => ["pub-en"])
    assert_raises(MultilingualConceptStore::Error) { @store.send(:execute, candidate_sql_for(broken)) }
  end

  def test_migration_is_clean_rerunnable
    run!([pgbin("psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", @database, "-f", File.join(ROOT, "schema/postgres", "018_multilingual_concepts.sql")])
    assert_equal "018_multilingual_concepts_v1", @store.send(:query, "SELECT schema_version FROM local_multilingual_concept_schema_meta").fetch(0)
  end

  private

  def seed_sources
    now = "2026-08-13T00:00:00Z"
    [["s-en", "en", "pub-en"], ["s-zh", "zh-CN", "pub-zh"]].each do |source_id, language, publisher_id|
      @store.send(:execute, <<~SQL)
        INSERT INTO local_source_registry(source_id, source_name, source_url, language, region, publisher_id, discovery_basis, analysis_policy, query_topics, market_label_basis)
        VALUES ('#{source_id}', '#{source_id}', 'https://#{source_id}.example', '#{language}', 'fixture', '#{publisher_id}', 'editorial_feed', 'signal_eligible', '[]'::jsonb, 'editorial_scope_label')
      SQL
      @store.send(:execute, <<~SQL)
        INSERT INTO local_source_capture(capture_id, source_id, source_url, captured_at, http_status, content_bytes, body_hash, storage_status)
        VALUES ('c-#{source_id}', '#{source_id}', 'https://#{source_id}.example/item', '#{now}', 200, 1, 'body-#{source_id}', 'metadata_only')
      SQL
      @store.send(:execute, <<~SQL)
        INSERT INTO local_source_item(item_key, source_id, source_name, language, region, publisher_id, publisher_identity_status, title, summary, source_url, fetched_at, captured_at, content_hash, capture_id)
        VALUES ('i-#{source_id}', '#{source_id}', '#{source_id}', '#{language}', 'fixture', '#{publisher_id}', 'configured', 'title', 'summary', 'https://#{source_id}.example/item', '#{now}', '#{now}', 'hash-v-#{language == "en" ? "en" : "zh"}', 'c-#{source_id}')
      SQL
      @store.send(:execute, <<~SQL)
        INSERT INTO local_source_item_version(version_id, item_key, capture_id, source_id, source_name, language, region, publisher_id, publisher_identity_status, source_kind, query_conditioned, lineage_metadata_basis, title, summary, source_url, fetched_at, captured_at, content_hash, published_at, discovery_basis, analysis_policy, query_topics, market_label_basis)
        VALUES ('v-#{language == "en" ? "en" : "zh"}', 'i-#{source_id}', 'c-#{source_id}', '#{source_id}', '#{source_id}', '#{language}', 'fixture', '#{publisher_id}', 'configured', 'configured', false, 'capture_time', 'title', 'summary', 'https://#{source_id}.example/item', '#{now}', '#{now}', 'hash-v-#{language == "en" ? "en" : "zh"}', '#{now}', 'editorial_feed', 'signal_eligible', '[]'::jsonb, 'editorial_scope_label')
      SQL
    end
  end

  def source(version_id, language, publisher_id)
    { "version_id" => version_id, "item_key" => "i-#{language == "en" ? "s-en" : "s-zh"}", "content_hash" => "hash-v-#{language == "en" ? "en" : "zh"}", "language" => language, "publisher_id" => publisher_id, "analysis_policy" => "signal_eligible" }
  end

  def mapping(mapping_id, version_id, language)
    { "mapping_id" => mapping_id, "source_version_id" => version_id, "source_content_hash" => "hash-v-#{language == "en" ? "en" : "zh"}", "source_language" => language, "target_language" => "zh-CN", "target_canonical_label" => "台风", "relation" => "translation_equivalent", "provider" => "fixture", "model" => "concept-v1", "prompt_version" => "prompt-v1", "input_hash" => "input-#{mapping_id}", "output_hash" => "output-#{mapping_id}" }
  end

  def candidate_sql_for(candidate)
    json = lambda { |key| "'#{JSON.generate(candidate.fetch(key)).gsub("'", "''")}'::jsonb" }
    <<~SQL
      INSERT INTO local_multilingual_participation_candidate
        (candidate_id,candidate_status,candidate_kind,canonical_concept_key,target_language,target_canonical_label,relation_set,member_mapping_ids,member_version_ids,languages,publishers,source_language_count,publisher_count,member_count,query_conditioned_version_ids,exploration_only_version_ids,signal_eligible_version_ids,query_conditioned_count,exploration_only_count,signal_eligible_count,evidence,merge_policy,event_merge_allowed,claim_merge_allowed)
      VALUES ('#{candidate.fetch("candidate_id")}', 'cross_language_participation', 'concept_participation', '#{candidate.fetch("canonical_concept_key")}', 'zh-CN', '台风', #{json.call("relation_set")}, #{json.call("member_mapping_ids")}, #{json.call("member_version_ids")}, #{json.call("languages")}, #{json.call("publishers")}, 2, 1, 2, #{json.call("query_conditioned_version_ids")}, #{json.call("exploration_only_version_ids")}, #{json.call("signal_eligible_version_ids")}, 0, 0, 2, #{json.call("evidence")}, 'participation_only', FALSE, FALSE)
    SQL
  end

  def pgbin(name); "/private/tmp/trend-exploring-postgres15-runtime/bin/#{name}"; end
  def pg_host; "/private/tmp/trend-exploring-pg-socket"; end
  def pg_port; "55433"; end
  def pg_user; ENV.fetch("USER", "postgres"); end
  def run!(args); stdout, stderr, status = Open3.capture3(*args); raise stderr unless status.success?; stdout; end
end
