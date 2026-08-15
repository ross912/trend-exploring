# frozen_string_literal: true

require "json"
require "digest"
require "cgi"
require "open3"
require "securerandom"
require "time"
require "uri"
require_relative "event_candidate_analyzer"
require_relative "breadth_discovery_selector"
require_relative "local_runtime"

class LocalRadarStore
  class Error < StandardError; end
  SUMMARY_LIMIT = 320
  METADATA_TRANSLATION_MAX_LIMIT = 100
  METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT = 200_000
  METADATA_TRANSLATION_LEASE_SECONDS = 15 * 60
  DISCOVERY_BASES = %w[editorial_feed topic_query locale_headlines].freeze
  ANALYSIS_POLICIES = %w[signal_eligible exploration_only].freeze

  def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                 host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                 port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                 database: ENV.fetch("LOCAL_PGDATABASE", LocalRuntime.global_database),
                 user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user))
    @psql = psql
    @host = host
    @port = port
    @database = database
    @user = user
  end

  def health
    value = query("SELECT json_build_object('database', current_database(), 'server_version', current_setting('server_version'), 'status', 'ok')::text")
    JSON.parse(value.fetch(0))
  rescue StandardError => error
    raise Error, "local database health check failed: #{error.message}"
  end

  def current_radar
    snapshot_rows = query(<<~SQL)
      SELECT snapshot_id, surface_id, revision, comparison_watermark, method_epoch,
             rights_epoch, render_plan_hash, snapshot_status, created_at::text,
             #{breadth_schema_available? ? "signal_projection_status, signal_source_snapshot_id" : "'fresh_batch', NULL"}
        FROM local_radar_snapshot
       WHERE snapshot_status = 'published'
       ORDER BY revision DESC
       LIMIT 1
    SQL
    return { "snapshot" => nil, "cards" => [], "trends" => [], "event_candidates" => [], "sources" => source_summary, "discovered_publishers" => discovered_publishers, "translation" => translation_summary, "archive" => archive_summary, "coverage" => coverage, "exploration" => exploration_summary } if snapshot_rows.empty?

    snapshot_keys = %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch render_plan_hash snapshot_status created_at signal_projection_status signal_source_snapshot_id]
    snapshot = row_to_hash(snapshot_rows.fetch(0), snapshot_keys)
    snapshot["signal_source_snapshot_id"] = nil if snapshot.fetch("signal_source_snapshot_id").to_s.empty?
    cards = query(<<~SQL).map do |row|
      SELECT c.card_id, c.signal_type,
             CASE WHEN t.status='translated' THEN t.translated_title ELSE c.title END,
             CASE WHEN t.status='translated' THEN t.translated_summary ELSE c.summary END,
             c.metric_label, c.metric_value, c.source_count, c.stance, c.action_stage,
             c.evidence_label, c.source_name, c.source_url, c.source_language, c.source_region,
             COALESCE(NULLIF(c.original_title,''), c.title), COALESCE(NULLIF(c.original_summary,''), c.summary),
             CASE WHEN c.source_language LIKE 'zh%' THEN 'not_needed'
                  WHEN t.status='translated' THEN 'translated'
                  WHEN c.translation_status='failed' THEN 'failed' ELSE 'untranslated' END,
             COALESCE(t.artifact_id, c.translation_artifact_id),
             COALESCE(t.created_at, c.translated_at)::text, c.sort_order,
             c.source_item_key, c.source_version_id, c.source_content_hash
        FROM local_radar_card c
        LEFT JOIN LATERAL (
          SELECT artifact_id, translated_title, translated_summary, status, created_at
            FROM local_translation_artifact
           WHERE item_key=c.source_item_key AND original_content_hash=c.source_content_hash
             AND target_language='zh-CN' AND status='translated'
           ORDER BY created_at DESC LIMIT 1
        ) t ON TRUE
       WHERE c.snapshot_id = #{literal(snapshot.fetch("snapshot_id"))}
       ORDER BY c.sort_order ASC
    SQL
      row_to_hash(row, %w[card_id signal_type title summary metric_label metric_value source_count stance action_stage evidence_label source_name source_url source_language source_region original_title original_summary translation_status translation_artifact_id translated_at sort_order source_item_key source_version_id source_content_hash])
    end
    trends = query(<<~SQL).map do |row|
      SELECT trend_id, topic_key, topic, topic_language, topic_kind, semantic_status, topic_label, topic_explanation, signal_state, summary,
             mention_count, recent_mention_count, prior_mention_count, source_count,
             region_count, language_count, growth_rate::text, window_hours,
             recent_window_hours, window_start::text, window_end::text,
             source_names::text, regions::text, languages::text, evidence_urls::text, sort_order
        FROM local_radar_trend
       WHERE snapshot_id = #{literal(snapshot.fetch("snapshot_id"))}
       ORDER BY sort_order ASC
    SQL
      trend = row_to_hash(row, %w[trend_id topic_key topic topic_language topic_kind semantic_status topic_label topic_explanation signal_state summary mention_count recent_mention_count prior_mention_count source_count region_count language_count growth_rate window_hours recent_window_hours window_start window_end source_names regions languages evidence_urls sort_order])
      %w[source_names regions languages evidence_urls].each { |key| trend[key] = parse_json_array(trend.fetch(key)) }
      trend
    end
    event_candidates = query(<<~SQL).map do |row|
      SELECT candidate_id, candidate_key, candidate_status, label, language, matching_method, explanation,
             member_count, dedup_source_count, qualifying_source_count, query_conditioned_evidence_count,
             first_published_at::text, last_published_at::text, time_span_hours::text,
             shared_anchors::text, shared_phrases::text, evidence_items::text,
             member_item_keys::text, qualifying_item_keys::text, query_item_keys::text, sort_order
        FROM local_event_candidate
       WHERE snapshot_id = #{literal(snapshot.fetch("snapshot_id"))}
       ORDER BY sort_order ASC
    SQL
      candidate = row_to_hash(row, %w[candidate_id candidate_key candidate_status label language matching_method explanation member_count dedup_source_count qualifying_source_count query_conditioned_evidence_count first_published_at last_published_at time_span_hours shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys sort_order])
      %w[shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys].each do |key|
        candidate[key] = parse_json_value(candidate.fetch(key))
      end
      %w[member_count dedup_source_count qualifying_source_count query_conditioned_evidence_count sort_order].each { |key| candidate[key] = candidate.fetch(key).to_i }
      candidate["time_span_hours"] = candidate.fetch("time_span_hours").to_f
      candidate
    end
    { "snapshot" => snapshot, "cards" => cards, "trends" => trends, "event_candidates" => event_candidates, "sources" => source_summary, "discovered_publishers" => discovered_publishers, "translation" => translation_summary, "archive" => archive_summary, "coverage" => coverage, "exploration" => exploration_summary }
  end

  # Internal immutable signal surface for lineage-preserving republishes. The
  # public current_radar method may add late translation projections; callers
  # that claim reused_previous must copy the stored snapshot facts instead.
  def stored_signal_projection(snapshot_id: nil)
    id = snapshot_id.to_s
    if id.empty?
      rows = query("SELECT snapshot_id FROM local_radar_snapshot WHERE snapshot_status='published' ORDER BY revision DESC LIMIT 1")
      return { "snapshot" => nil, "cards" => [], "trends" => [], "event_candidates" => [] } if rows.empty?
      id = rows.fetch(0)
    end
    snapshot_rows = query("SELECT snapshot_id, surface_id, revision, comparison_watermark, method_epoch, rights_epoch, render_plan_hash, snapshot_status, created_at::text, signal_projection_status, signal_source_snapshot_id FROM local_radar_snapshot WHERE snapshot_id=#{literal(id)} AND snapshot_status='published'")
    raise Error, "stored signal snapshot is missing" if snapshot_rows.empty?
    snapshot = row_to_hash(snapshot_rows.fetch(0), %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch render_plan_hash snapshot_status created_at signal_projection_status signal_source_snapshot_id])
    cards = query("SELECT card_id, signal_type, title, summary, metric_label, metric_value, source_count, stance, action_stage, evidence_label, source_name, source_url, source_language, source_region, original_title, original_summary, translation_status, translation_artifact_id, translated_at::text, sort_order, source_item_key, source_version_id, source_content_hash FROM local_radar_card WHERE snapshot_id=#{literal(id)} ORDER BY sort_order").map { |row| row_to_hash(row, %w[card_id signal_type title summary metric_label metric_value source_count stance action_stage evidence_label source_name source_url source_language source_region original_title original_summary translation_status translation_artifact_id translated_at sort_order source_item_key source_version_id source_content_hash]) }
    public_view = current_radar
    { "snapshot" => snapshot, "cards" => cards, "trends" => public_view.fetch("trends"), "event_candidates" => public_view.fetch("event_candidates") }
  end

  def source_summary
    breadth = breadth_schema_available?
    query(<<~SQL).map do |row|
      SELECT r.source_id, r.source_name, r.source_url, r.language, r.region,
             r.publisher_region, r.publisher_id, r.region_basis, r.query_conditioned::text,
             r.source_kind, r.enabled::text, r.last_fetch_at::text,
             #{breadth ? "r.discovery_basis, r.analysis_policy, r.aggregator_id, r.locale_tag, r.market_label, r.market_label_basis, r.query_topics::text, r.verified_at::text, r.verification_status," : ""}
             r.last_item_count, r.last_error, COUNT(i.item_key)
        FROM local_source_registry r
        LEFT JOIN local_source_item i ON i.source_id = r.source_id
       GROUP BY r.source_id, r.source_name, r.source_url, r.language, r.region,
                r.publisher_region, r.publisher_id, r.region_basis, r.query_conditioned,
                r.source_kind, r.enabled, r.last_fetch_at, r.last_item_count, r.last_error#{breadth ? ", r.discovery_basis, r.analysis_policy, r.aggregator_id, r.locale_tag, r.market_label, r.market_label_basis, r.query_topics, r.verified_at, r.verification_status" : ""}
       ORDER BY r.enabled DESC, r.region ASC, r.source_name ASC
    SQL
      keys = %w[source_id source_name source_url language region publisher_region publisher_id region_basis query_conditioned source_kind enabled last_fetch_at]
      keys += %w[discovery_basis analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics verified_at verification_status] if breadth
      keys += %w[last_item_count last_error item_count]
      row_to_hash(row, keys).tap do |source|
        source["enabled"] = %w[t true].include?(source.fetch("enabled").downcase)
        source["query_conditioned"] = %w[t true].include?(source.fetch("query_conditioned").downcase)
        source["last_item_count"] = source.fetch("last_item_count").to_i
        source["item_count"] = source.fetch("item_count").to_i
        source["query_topics"] = parse_json_array(source.fetch("query_topics")) if breadth
      end
    end
  rescue LocalRadarStore::Error
    raise if breadth_schema_available?

    []
  end

  def discovered_publishers
    item_policy = breadth_schema_available? ? " AND i.analysis_policy = 'signal_eligible'" : ""
    query(<<~SQL).map do |row|
      SELECT publisher_id AS publisher_id, publisher_id AS publisher_name, 'https://' || publisher_id || '/' AS publisher_url,
             string_agg(DISTINCT language, ' / ' ORDER BY language),
             string_agg(DISTINCT region, ' / ' ORDER BY region), COUNT(*)
        FROM local_source_item i
       WHERE i.source_kind = 'discovery' AND i.publisher_identity_status = 'observed_domain' AND i.publisher_id <> ''#{item_policy}
       GROUP BY i.publisher_id
       ORDER BY COUNT(*) DESC, publisher_id ASC
       LIMIT 100
    SQL
      row_to_hash(row, %w[publisher_id publisher_name publisher_url language region item_count]).tap do |publisher|
        publisher["item_count"] = publisher.fetch("item_count").to_i
      end
    end
  rescue LocalRadarStore::Error
    []
  end

  def coverage
    breadth = breadth_schema_available?
    item_policy = breadth ? " AND i.analysis_policy = 'signal_eligible'" : ""
    values = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT
        COUNT(*) FILTER (WHERE enabled AND source_kind <> 'discovery'),
        COUNT(*) FILTER (WHERE enabled AND source_kind = 'discovery' AND query_conditioned),
        COUNT(DISTINCT publisher_id) FILTER (WHERE enabled AND source_kind <> 'discovery' AND publisher_id <> ''),
        (SELECT COUNT(DISTINCT i.publisher_id)
           FROM local_source_item i
           JOIN local_source_registry r ON r.source_id = i.source_id
          WHERE r.source_kind = 'discovery'
            AND r.query_conditioned
            AND i.publisher_identity_status = 'observed_domain'
            AND i.publisher_id <> ''#{item_policy}),
        (SELECT COUNT(*) FROM local_source_item i WHERE i.publisher_identity_status = 'unresolved'#{item_policy}),
        (SELECT COUNT(*)
           FROM local_source_item i
           JOIN local_source_registry r ON r.source_id = i.source_id
          WHERE r.source_kind = 'discovery'
            AND r.query_conditioned
            AND i.publisher_identity_status = 'unresolved'#{item_policy}),
        (EXISTS (SELECT 1
                   FROM local_source_registry
                  WHERE enabled AND source_kind = 'discovery' AND query_conditioned)
         OR EXISTS (SELECT 1
                      FROM local_source_item i
                      JOIN local_source_registry r ON r.source_id = i.source_id
                     WHERE r.source_kind = 'discovery' AND r.query_conditioned)),
        COALESCE((SELECT string_agg(DISTINCT i.language, ',' ORDER BY i.language) FROM local_source_item i WHERE i.language <> ''#{item_policy}), '')
        FROM (SELECT 1 AS keep) AS coverage_keep
        LEFT JOIN local_source_registry ON TRUE
    SQL
    editorial_count = values.fetch(0).to_i
    query_count = values.fetch(1).to_i
    configured_publishers = values.fetch(2).to_i
    observed_domains = values.fetch(3).to_i
    unresolved_items = values.fetch(4).to_i
    discovery_unresolved_items = values.fetch(5).to_i
    query_conditioned = %w[t true].include?(values.fetch(6).downcase)
    languages = values.fetch(7).split(",").reject(&:empty?)
    debts = []
    debts << "event_geography_unverified"
    language_debt = if languages.empty?
                      "no_observed_content_language"
                    elsif languages.length == 1
                      "single_content_language"
                    elsif languages.length == 2
                      "only_two_content_languages"
                    end
    debts << language_debt if language_debt
    debts << "discovery_is_topic_conditioned" if query_conditioned
    debts << "discovery_publisher_origin_unknown" if query_conditioned && (observed_domains.positive? || discovery_unresolved_items.positive?)
    base = {
      "scope" => "local_archive",
      "editorial_feed_count" => editorial_count,
      "query_feed_count" => query_count,
      "configured_publisher_count" => configured_publishers,
      "observed_publisher_domain_count" => observed_domains,
      "unresolved_publisher_item_count" => unresolved_items,
      "discovery_unresolved_publisher_item_count" => discovery_unresolved_items,
      "observed_languages" => languages,
      "event_geography_status" => "unverified",
      "query_conditioned" => query_conditioned,
      "debts" => debts
    }
    breadth = breadth_coverage
    base.merge(breadth).merge("debts" => (Array(base.fetch("debts")) + Array(breadth.fetch("debts"))).uniq)
  rescue LocalRadarStore::Error
    raise if breadth_schema_available?

    { "scope" => "local_archive", "editorial_feed_count" => 0, "query_feed_count" => 0,
      "configured_publisher_count" => 0, "observed_publisher_domain_count" => 0,
      "unresolved_publisher_item_count" => 0, "discovery_unresolved_publisher_item_count" => 0, "observed_languages" => [],
      "event_geography_status" => "unverified", "query_conditioned" => false,
      "configured_locale_headline_feed_count" => 0, "last_batch_planned_source_count" => 0,
      "last_batch_succeeded_source_count" => 0, "last_batch_empty_source_count" => 0,
      "last_batch_failed_source_count" => 0, "observed_locale_tags" => [],
      "observed_original_languages" => [], "exploration_only_item_count" => 0,
      "locale_discovery_observed_publisher_domain_count" => 0, "locale_discovery_unresolved_item_count" => 0,
      "debts" => ["event_geography_unverified", "no_observed_content_language", "locale_discovery_is_aggregator_mediated", "configured_frontier_is_not_open_world"] }
  end

  def translation_summary
    item_policy = breadth_schema_available? ? "WHERE i.analysis_policy = 'signal_eligible'" : ""
    values = query(<<~SQL).fetch(0).split("\t")
      SELECT
        COUNT(*) FILTER (WHERE i.language NOT LIKE 'zh%'),
        COUNT(DISTINCT t.item_key) FILTER (WHERE t.status = 'translated'),
        COUNT(*) FILTER (WHERE i.language NOT LIKE 'zh%' AND t.item_key IS NULL)
        FROM local_source_item i
        LEFT JOIN LATERAL (
          SELECT item_key, status
            FROM local_translation_artifact
           WHERE item_key = i.item_key AND target_language = 'zh-CN'
           ORDER BY created_at DESC
           LIMIT 1
        ) t ON TRUE
       #{item_policy}
    SQL
    { "english_items" => values.fetch(0).to_i, "translated_items" => values.fetch(1).to_i,
      "untranslated_items" => values.fetch(2).to_i, "target_language" => "zh-CN" }
  rescue LocalRadarStore::Error
    { "english_items" => 0, "translated_items" => 0, "untranslated_items" => 0, "target_language" => "zh-CN" }
  end

  def archive_summary
    fulltext = relation_exists?("local_article_archive")
    values = query(<<~SQL).fetch(0).split("\t")
      SELECT (SELECT COUNT(*) FROM local_source_capture),
             (SELECT COUNT(*) FROM local_source_item_version),
             (SELECT COUNT(DISTINCT item_key) FROM local_source_item_version),
             (SELECT COUNT(*) FROM local_source_capture WHERE storage_status = 'metadata_only'),
             #{fulltext ? "(SELECT COUNT(*) FROM local_article_archive)" : "0"},
             #{fulltext ? "(SELECT COUNT(*) FROM local_article_translation_artifact)" : "0"},
             #{fulltext ? "(SELECT COUNT(*) FROM local_source_archive_policy WHERE rights_scope='full_archive')" : "0"}
    SQL
    summary = { "capture_count" => values.fetch(0).to_i, "item_version_count" => values.fetch(1).to_i,
      "versioned_item_count" => values.fetch(2).to_i, "metadata_only_capture_count" => values.fetch(3).to_i,
      "fulltext_archive_count" => values.fetch(4).to_i, "fulltext_translation_count" => values.fetch(5).to_i,
      "full_archive_source_count" => values.fetch(6).to_i }
    return summary.merge("source_policies" => [], "archive_attempts" => {}, "translation_queue" => {}) unless fulltext

    policies = query(<<~SQL).map do |row|
      SELECT DISTINCT ON (p.source_id) p.source_id, r.source_name, p.rights_scope,
             p.permission_basis, COALESCE(p.permission_verified_at::text,''), p.effective_at::text
        FROM local_source_archive_policy p
        LEFT JOIN local_source_registry r ON r.source_id=p.source_id
       ORDER BY p.source_id, p.effective_at DESC, p.policy_id DESC
    SQL
      row_to_hash(row, %w[source_id source_name rights_scope permission_basis permission_verified_at effective_at])
    end
    attempt_counts = query("SELECT outcome, COUNT(*) FROM local_article_archive_attempt GROUP BY outcome ORDER BY outcome").to_h { |row| key, count = row.split("\t", -1); [key, count.to_i] }
    queue_counts = query("SELECT state, COUNT(*) FROM local_article_translation_run GROUP BY state ORDER BY state").to_h { |row| key, count = row.split("\t", -1); [key, count.to_i] }
    summary.merge("source_policies" => policies, "archive_attempts" => attempt_counts, "translation_queue" => queue_counts,
                  "boundary" => "full text is fetched only for verified full_archive sources; original metadata and links remain available for excerpt_only sources")
  rescue LocalRadarStore::Error
    { "capture_count" => 0, "item_version_count" => 0, "versioned_item_count" => 0, "metadata_only_capture_count" => 0,
      "fulltext_archive_count" => 0, "fulltext_translation_count" => 0, "full_archive_source_count" => 0,
      "source_policies" => [], "archive_attempts" => {}, "translation_queue" => {} }
  end

  # Additive read model for the exploration lane.  It intentionally reads the
  # immutable version/capture rows rather than copying body fields into the
  # membership table.  A legacy 011 database simply reports that the worker
  # has not been run.
  def exploration_summary
    return legacy_exploration_summary unless breadth_schema_available?

    batch_rows = query(<<~SQL)
      SELECT batch_id, started_at::text, completed_at::text, registry_hash,
             selected_count, planned_source_count, selected_set_hash, selected_order_hash, status
        FROM local_collection_batch
       ORDER BY started_at DESC, batch_id ASC
       LIMIT 1
    SQL
    return legacy_exploration_summary if batch_rows.empty?

    batch = row_to_hash(batch_rows.fetch(0), %w[batch_id started_at completed_at registry_hash selected_count planned_source_count selected_set_hash selected_order_hash status])
    manifest_row = query(<<~SQL).first
      SELECT manifest_id, manifest_version, scope_id, seed, policy_version,
             eligibility_count, eligible_count, ineligible_count,
             selection_decision_count, selected_count, delivery_status,
             not_a_signal::text, personalization, status
        FROM local_pre_detection_exploration_manifest
       WHERE batch_id = #{literal(batch.fetch("batch_id"))}
       ORDER BY created_at DESC, manifest_id ASC
       LIMIT 1
    SQL
    attempts = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT COUNT(*) FILTER (WHERE outcome = 'succeeded_with_items'),
             COUNT(*) FILTER (WHERE outcome = 'succeeded_empty'),
             COUNT(*) FILTER (WHERE outcome = 'failed'), COUNT(*)
        FROM local_source_fetch_attempt
       WHERE batch_id = #{literal(batch.fetch("batch_id"))}
    SQL
    snapshot_row = query(<<~SQL)
      SELECT s.snapshot_id
        FROM local_radar_exploration_item e
        JOIN local_radar_snapshot s ON s.snapshot_id = e.snapshot_id
       WHERE e.batch_id = #{literal(batch.fetch("batch_id"))}
         AND s.snapshot_status = 'published'
       ORDER BY s.revision DESC, s.snapshot_id ASC
       LIMIT 1
    SQL
    snapshot_id = snapshot_row.fetch(0, "")
    items = snapshot_id.empty? ? [] : exploration_items(snapshot_id: snapshot_id)
    success_with_items = attempts.fetch(0).to_i
    success_empty = attempts.fetch(1).to_i
    failed = attempts.fetch(2).to_i
    total_attempts = attempts.fetch(3).to_i
    worker_state = if total_attempts.zero?
                     "not_run"
                   elsif snapshot_id.empty? && success_with_items.positive?
                     "snapshot_no_selection"
                   elsif failed.positive? && failed < total_attempts
                     "partial_failure"
                   elsif failed == total_attempts
                     "failed"
                   elsif success_empty == total_attempts
                     "success_empty"
                   else
                     "published"
                   end
    summary = {
      "latest_batch" => {
        "batch_id" => batch.fetch("batch_id"),
        "status" => batch.fetch("status"),
        "worker_state" => worker_state,
        "started_at" => batch.fetch("started_at"),
        "completed_at" => batch.fetch("completed_at"),
        "registry_hash" => batch.fetch("registry_hash"),
        "selected_set_hash" => batch.fetch("selected_set_hash"),
        "selected_order_hash" => batch.fetch("selected_order_hash"),
        "selected_count" => batch.fetch("selected_count").to_i,
        "attempt_count" => total_attempts,
        # Keep the frozen plan as the denominator even while attempts are
        # incomplete; attempt_count is the observed worker fact.
        "planned_source_count" => batch.fetch("planned_source_count").to_i,
        "succeeded_source_count" => success_with_items,
        "empty_source_count" => success_empty,
        "failed_source_count" => failed,
        "snapshot_id" => snapshot_id.empty? ? nil : snapshot_id,
        "selection_count" => items.length,
      },
      "items" => items,
      "boundary" => exploration_boundary
    }
    unless manifest_row.nil?
      manifest = row_to_hash(manifest_row, %w[manifest_id manifest_version scope_id seed policy_version eligibility_count eligible_count ineligible_count selection_decision_count selected_count delivery_status not_a_signal personalization status])
      %w[eligibility_count eligible_count ineligible_count selection_decision_count selected_count].each { |key| manifest[key] = manifest.fetch(key).to_i }
      manifest["not_a_signal"] = truthy_value?(manifest.fetch("not_a_signal"))
      summary["latest_batch"].merge!(
        "selection_manifest_id" => manifest.fetch("manifest_id"),
        "selection_manifest_version" => manifest.fetch("manifest_version"),
        "selection_scope_id" => manifest.fetch("scope_id"),
        "selection_seed" => manifest.fetch("seed"),
        "selection_policy_version" => manifest.fetch("policy_version"),
        "eligibility_count" => manifest.fetch("eligibility_count"),
        "eligible_count" => manifest.fetch("eligible_count"),
        "ineligible_count" => manifest.fetch("ineligible_count"),
        "selection_decision_count" => manifest.fetch("selection_decision_count"),
        "selected_count" => manifest.fetch("selected_count"),
        "delivery_status" => manifest.fetch("delivery_status"),
        "not_a_signal" => manifest.fetch("not_a_signal"),
        "personalization" => manifest.fetch("personalization"),
        "selection_status" => manifest.fetch("status")
      )
    end
    summary
  end

  alias latest_exploration exploration_summary

  def exploration_items(snapshot_id:)
    return [] unless breadth_schema_available?

    query(<<~SQL).map do |row|
      SELECT e.exploration_item_id, e.snapshot_id, e.batch_id, e.version_id,
             e.lane, e.reason, e.resolution, e.sort_order,
             e.selection_manifest_id, e.exploration_decision_id,
             e.not_a_signal::text, e.delivery_status,
             v.item_key, v.source_id, v.source_name, v.language, v.title,
             v.summary, v.source_url, v.published_at::text, v.fetched_at::text,
             v.captured_at::text, v.content_hash, v.publisher_id,
             v.publisher_name, v.publisher_url, v.publisher_identity_status,
             v.source_kind, v.discovery_basis, v.query_conditioned::text,
             v.analysis_policy, v.aggregator_id, v.locale_tag, v.market_label,
             v.market_label_basis, v.query_topics::text,
             COALESCE(t.translated_title,''), COALESCE(t.translated_summary,''),
             CASE WHEN v.language LIKE 'zh%' THEN 'not_needed'
                  WHEN t.status='translated' THEN 'translated' ELSE 'untranslated' END,
             COALESCE(t.artifact_id,''), COALESCE(t.created_at::text,''),
             c.capture_id, c.source_url, c.source_kind, c.rights_scope,
             c.http_status::text, c.content_type, c.content_bytes::text,
             c.body_hash, c.storage_status, c.storage_uri
        FROM local_radar_exploration_item e
        JOIN local_source_item_version v ON v.version_id = e.version_id
        LEFT JOIN LATERAL (
          SELECT artifact_id, translated_title, translated_summary, status, created_at
            FROM local_translation_artifact
           WHERE source_version_id=v.version_id AND target_language='zh-CN' AND status='translated'
           ORDER BY created_at DESC LIMIT 1
        ) t ON TRUE
        JOIN local_source_capture c ON c.capture_id = v.capture_id
       WHERE e.snapshot_id = #{literal(snapshot_id)}
       ORDER BY e.sort_order ASC
    SQL
      item = row_to_hash(row, %w[exploration_item_id snapshot_id batch_id version_id lane reason resolution sort_order selection_manifest_id exploration_decision_id not_a_signal delivery_status item_key source_id source_name language title summary source_url published_at fetched_at captured_at content_hash publisher_id publisher_name publisher_url publisher_identity_status source_kind discovery_basis query_conditioned analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics translated_title translated_summary translation_status translation_artifact_id translated_at capture_id capture_source_url capture_source_kind rights_scope capture_http_status capture_content_type capture_content_bytes capture_body_hash capture_storage_status storage_uri])
      %w[sort_order capture_http_status capture_content_bytes].each { |key| item[key] = item.fetch(key).to_i }
      item["query_conditioned"] = truthy_value?(item.fetch("query_conditioned"))
      item["not_a_signal"] = truthy_value?(item.fetch("not_a_signal"))
      item["query_topics"] = parse_json_array(item.fetch("query_topics"))
      item["display_title"] = item.fetch("translation_status") == "translated" ? item.fetch("translated_title") : item.fetch("title")
      item["display_summary"] = item.fetch("translation_status") == "translated" ? item.fetch("translated_summary") : item.fetch("summary")
      item["raw_listing"] = {
        "title" => item.fetch("display_title"), "summary" => item.fetch("display_summary"),
        "original_title" => item.fetch("title"), "original_summary" => item.fetch("summary"),
        "source_url" => item.fetch("source_url"), "published_at" => item.fetch("published_at"),
        "language" => item.fetch("language")
      }
      item["claim_status"] = "raw_listing"
      item
    end
  end

  def legacy_exploration_summary
    { "latest_batch" => nil, "items" => [], "boundary" => exploration_boundary }
  end

  def exploration_boundary
    {
      "topic_conditioned" => false,
      "aggregator_mediated" => true,
      "event_geography_status" => "unverified",
      "signal_eligible" => false,
      "lane" => "locale_frontier",
      "discovery_basis" => "locale_headlines",
      "claims" => ["archive_and_browse_only", "not_important", "not_novelty", "not_trend", "not_early_signal"]
    }
  end

  def breadth_coverage
    return {
      "configured_locale_headline_feed_count" => 0,
      "last_batch_planned_source_count" => 0, "last_batch_succeeded_source_count" => 0,
      "last_batch_empty_source_count" => 0, "last_batch_failed_source_count" => 0,
      "observed_locale_tags" => [], "observed_original_languages" => [],
      "exploration_only_item_count" => 0, "locale_discovery_observed_publisher_domain_count" => 0,
      "locale_discovery_unresolved_item_count" => 0,
      "debts" => breadth_debts
    } unless breadth_schema_available?

    configured = query("SELECT COUNT(*) FROM local_source_registry WHERE enabled AND discovery_basis = 'locale_headlines'").fetch(0).to_i
    latest_batch_rows = query("SELECT batch_id, planned_source_count FROM local_collection_batch ORDER BY started_at DESC, batch_id ASC LIMIT 1")
    return {
      "configured_locale_headline_feed_count" => configured,
      "last_batch_planned_source_count" => 0, "last_batch_succeeded_source_count" => 0,
      "last_batch_empty_source_count" => 0, "last_batch_failed_source_count" => 0,
      "observed_locale_tags" => [], "observed_original_languages" => [],
      "exploration_only_item_count" => 0, "locale_discovery_observed_publisher_domain_count" => 0,
      "locale_discovery_unresolved_item_count" => 0, "debts" => breadth_debts
    } if latest_batch_rows.empty?

    latest = latest_batch_rows.fetch(0).split("\t", -1)
    batch_id = latest.fetch(0)
    counts = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT COUNT(*) FILTER (WHERE outcome = 'succeeded_with_items'),
             COUNT(*) FILTER (WHERE outcome = 'succeeded_empty'),
             COUNT(*) FILTER (WHERE outcome = 'failed')
        FROM local_source_fetch_attempt
       WHERE batch_id = #{literal(batch_id)}
    SQL
    locales = query(<<~SQL).fetch(0, "").to_s.split(",").reject(&:empty?)
      SELECT COALESCE(string_agg(DISTINCT v.locale_tag, ',' ORDER BY v.locale_tag), '')
        FROM local_source_item_version v
        JOIN local_source_fetch_attempt a ON a.batch_id = #{literal(batch_id)} AND a.source_id = v.source_id AND a.capture_id = v.capture_id
       WHERE a.outcome = 'succeeded_with_items' AND v.discovery_basis = 'locale_headlines'
         AND v.analysis_policy = 'exploration_only'
         AND v.locale_tag <> ''
    SQL
    languages = query(<<~SQL).fetch(0, "").to_s.split(",").reject(&:empty?)
      SELECT COALESCE(string_agg(DISTINCT v.language, ',' ORDER BY v.language), '')
        FROM local_source_item_version v
        JOIN local_source_fetch_attempt a ON a.batch_id = #{literal(batch_id)} AND a.source_id = v.source_id AND a.capture_id = v.capture_id
       WHERE a.outcome = 'succeeded_with_items' AND v.discovery_basis = 'locale_headlines'
         AND v.analysis_policy = 'exploration_only'
         AND v.language <> ''
    SQL
    exploration_counts = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT COUNT(*),
             COUNT(*) FILTER (WHERE resolution = 'resolved'),
             COUNT(*) FILTER (WHERE resolution = 'unresolved')
        FROM local_radar_exploration_item WHERE batch_id = #{literal(batch_id)}
    SQL
    {
      "configured_locale_headline_feed_count" => configured,
      # This is the frozen batch denominator: selected items are a separate
      # projection and must never inflate the number of planned feeds.
      "last_batch_planned_source_count" => latest.fetch(1).to_i,
      "last_batch_succeeded_source_count" => counts.fetch(0).to_i,
      "last_batch_empty_source_count" => counts.fetch(1).to_i,
      "last_batch_failed_source_count" => counts.fetch(2).to_i,
      "observed_locale_tags" => locales,
      "observed_original_languages" => languages,
      "exploration_only_item_count" => exploration_counts.fetch(0).to_i,
      "locale_discovery_observed_publisher_domain_count" => query("SELECT COUNT(DISTINCT v.publisher_id) FROM local_radar_exploration_item e JOIN local_source_item_version v ON v.version_id = e.version_id WHERE e.batch_id = #{literal(batch_id)} AND v.publisher_identity_status = 'observed_domain' AND v.publisher_id <> ''").fetch(0).to_i,
      "locale_discovery_unresolved_item_count" => exploration_counts.fetch(2).to_i,
      "debts" => breadth_debts
    }
  end

  def breadth_debts
    ["locale_discovery_is_aggregator_mediated", "configured_frontier_is_not_open_world", "event_geography_unverified", "unsupported_analysis_languages"]
  end

  def seed_demo!
    transaction do
      execute(<<~SQL)
        INSERT INTO local_radar_snapshot
          (snapshot_id, surface_id, revision, comparison_watermark, method_epoch, rights_epoch, render_plan_hash, snapshot_status)
        VALUES ('staging-snapshot-001', 'public-radar', 1, '2026-08-08T07:00:00Z', 'method-v1', 1, 'render-staging-001', 'published')
        ON CONFLICT (snapshot_id) DO NOTHING
      SQL
      execute(<<~SQL)
        INSERT INTO local_radar_card
          (card_id, snapshot_id, signal_type, title, summary, metric_label, metric_value, source_count, stance, action_stage, evidence_label, source_name, source_url, sort_order)
        VALUES
          ('card-001', 'staging-snapshot-001', 'diffusion', '小语种，正在扩散的足迹', '一个低总量命题正在三个本地行动者群体中出现，并且每条路径都有独立证据边。', '独立行动者', '3', 7, 'mixed', '早期采纳', '3 条本地路径 / 7 个来源版本', '演示数据', '', 0),
          ('card-002', 'staging-snapshot-001', 'emergence', '讨论先动了，数量还没有', '讨论量已经上升，但行动证据保持不变；当前更像关注增加，而不是采用增加。', '讨论增量', '+42%', 12, 'skeptical', '讨论阶段', '尚缺行动证据', '演示数据', '', 1),
          ('card-003', 'staging-snapshot-001', 'exploration', '未分类演示材料', '一个本地样本保留在探索展示区，当前没有任何检测器把它升级为候选信号。', '检测结果', '无候选', 0, 'unknown', '不适用', '仅作探索材料', '演示数据', '', 2)
        ON CONFLICT (card_id) DO NOTHING
      SQL
    end
    current_radar
  end

  def reset_demo!
    raise Error, "reset is restricted to the disposable local database" unless @database == "trend_exploring_local"
    if breadth_schema_available?
      execute("TRUNCATE local_radar_exploration_item, local_source_fetch_attempt, local_collection_batch CASCADE")
    end
    execute("TRUNCATE local_event_candidate, local_radar_trend, local_radar_card, local_radar_snapshot")
    true
  end

  def register_sources!(sources:)
    transaction do
      Array(sources).each do |source|
        contract = normalize_source_contract(source)
        publisher_region = contract.fetch("discovery_basis") == "locale_headlines" ? "" : source.fetch("publisher_region", source.fetch("region", "未标注"))
        if breadth_schema_available?
          execute(<<~SQL)
            INSERT INTO local_source_registry
              (source_id, source_name, source_url, language, region, publisher_region, publisher_id, region_basis,
               query_conditioned, source_kind, discovery_basis, analysis_policy, aggregator_id, locale_tag,
               market_label, market_label_basis, query_topics, verified_at, verification_status, enabled, updated_at)
            VALUES (#{literal(source.fetch("id"))}, #{literal(source.fetch("name"))}, #{literal(source.fetch("url"))},
                    #{literal(source.fetch("language", "zh-CN"))}, #{literal(source.fetch("region", "未标注"))},
                    #{literal(publisher_region)},
                    #{literal(source.fetch("publisher_id", ""))}, #{literal(source.fetch("region_basis", source.fetch("source_kind", "configured") == "discovery" ? "query_target_label" : "editorial_scope_label"))},
                    #{contract.fetch("query_conditioned") ? "TRUE" : "FALSE"}, #{literal(source.fetch("source_kind", "configured"))},
                    #{literal(contract.fetch("discovery_basis"))}, #{literal(contract.fetch("analysis_policy"))},
                    #{literal(contract.fetch("aggregator_id"))}, #{literal(contract.fetch("locale_tag"))},
                    #{literal(contract.fetch("market_label"))}, #{literal(contract.fetch("market_label_basis"))},
                    #{literal(JSON.generate(contract.fetch("query_topics")))}::jsonb,
                    #{source.fetch("verified_at", nil).to_s.empty? ? "NULL" : literal(source.fetch("verified_at"))},
                    #{literal(source.fetch("verification_status", "unverified"))},
                    #{source.fetch("enabled", true) ? "TRUE" : "FALSE"}, now())
            ON CONFLICT (source_id) DO UPDATE SET
              source_name = EXCLUDED.source_name, source_url = EXCLUDED.source_url,
              language = EXCLUDED.language, region = EXCLUDED.region,
              publisher_region = EXCLUDED.publisher_region, publisher_id = EXCLUDED.publisher_id,
              region_basis = EXCLUDED.region_basis, query_conditioned = EXCLUDED.query_conditioned,
              source_kind = EXCLUDED.source_kind, discovery_basis = EXCLUDED.discovery_basis,
              analysis_policy = EXCLUDED.analysis_policy, aggregator_id = EXCLUDED.aggregator_id,
              locale_tag = EXCLUDED.locale_tag, market_label = EXCLUDED.market_label,
              market_label_basis = EXCLUDED.market_label_basis, query_topics = EXCLUDED.query_topics,
              verified_at = EXCLUDED.verified_at, verification_status = EXCLUDED.verification_status,
              enabled = EXCLUDED.enabled, updated_at = now()
          SQL
        else
          execute(<<~SQL)
            INSERT INTO local_source_registry
              (source_id, source_name, source_url, language, region, publisher_region, publisher_id, region_basis,
               query_conditioned, source_kind, enabled, updated_at)
            VALUES (#{literal(source.fetch("id"))}, #{literal(source.fetch("name"))}, #{literal(source.fetch("url"))},
                    #{literal(source.fetch("language", "zh-CN"))}, #{literal(source.fetch("region", "未标注"))},
                    #{literal(publisher_region)},
                    #{literal(source.fetch("publisher_id", ""))}, #{literal(source.fetch("region_basis", source.fetch("source_kind", "configured") == "discovery" ? "query_target_label" : "editorial_scope_label"))},
                    #{contract.fetch("query_conditioned") ? "TRUE" : "FALSE"}, #{literal(source.fetch("source_kind", "configured"))},
                    #{source.fetch("enabled", true) ? "TRUE" : "FALSE"}, now())
            ON CONFLICT (source_id) DO UPDATE SET
              source_name = EXCLUDED.source_name, source_url = EXCLUDED.source_url,
              language = EXCLUDED.language, region = EXCLUDED.region,
              publisher_region = EXCLUDED.publisher_region, publisher_id = EXCLUDED.publisher_id,
              region_basis = EXCLUDED.region_basis, query_conditioned = EXCLUDED.query_conditioned,
              source_kind = EXCLUDED.source_kind, enabled = EXCLUDED.enabled, updated_at = now()
          SQL
        end
      end
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "source registry update is incomplete: #{error.message}"
  end

  def register_archive_policies!(sources:)
    return false unless relation_exists?("local_source_archive_policy")
    transaction do
      Array(sources).each do |source|
        rights_scope = source.fetch("rights_scope", "excerpt_only").to_s
        permission_basis = rights_scope == "full_archive" ? source.fetch("archive_permission_basis").to_s : ""
        permission_verified_at = rights_scope == "full_archive" ? source.fetch("archive_permission_verified_at").to_s : ""
        source_config_hash = Digest::SHA256.hexdigest(JSON.generate(source.sort.to_h))
        policy_id = Digest::SHA256.hexdigest([source.fetch("id"), source_config_hash, rights_scope].join("\0"))
        execute(<<~SQL)
          INSERT INTO local_source_archive_policy
            (policy_id, source_id, rights_scope, permission_basis, permission_verified_at, source_config_hash)
          VALUES (#{literal(policy_id)}, #{literal(source.fetch("id"))}, #{literal(rights_scope)},
                  #{literal(permission_basis)}, #{permission_verified_at.empty? ? "NULL" : literal(permission_verified_at)},
                  #{literal(source_config_hash)})
          ON CONFLICT (source_id, source_config_hash) DO NOTHING
        SQL
      end
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "source archive policy is incomplete: #{error.message}"
  end

  def record_source_fetch!(source_id:, item_count:, error: nil)
    execute(<<~SQL)
      UPDATE local_source_registry
         SET last_fetch_at = now(), last_item_count = #{Integer(item_count)},
             last_error = #{literal(error.to_s)}, updated_at = now()
       WHERE source_id = #{literal(source_id)}
    SQL
    true
  end

  def registry_contract_hash(sources: nil)
    rows = if sources
             Array(sources).map { |source| source_contract_projection(source) }
           elsif breadth_schema_available?
             query(<<~SQL).map { |row| JSON.parse(row) }
               SELECT json_build_object(
                 'source_id', source_id, 'source_url', source_url, 'source_kind', source_kind,
                 'discovery_basis', discovery_basis, 'query_conditioned', query_conditioned,
                 'analysis_policy', analysis_policy, 'aggregator_id', aggregator_id,
                 'locale_tag', locale_tag, 'market_label', market_label,
                 'market_label_basis', market_label_basis, 'query_topics', query_topics,
                 'enabled', enabled
               )::text
                 FROM local_source_registry
                WHERE enabled
                ORDER BY source_id
             SQL
           else
             query("SELECT json_build_object('source_id', source_id, 'source_url', source_url, 'source_kind', source_kind, 'query_conditioned', query_conditioned, 'enabled', enabled)::text FROM local_source_registry WHERE enabled ORDER BY source_id").map { |row| JSON.parse(row) }
           end
    Digest::SHA256.hexdigest(JSON.generate(rows.sort_by { |row| row.fetch("source_id") }))
  end

  alias source_config_hash registry_contract_hash

  def selected_set_hash(version_ids:)
    Digest::SHA256.hexdigest(Array(version_ids).map(&:to_s).uniq.sort.join("\u0000"))
  end

  def selected_order_hash(version_ids:)
    Digest::SHA256.hexdigest(Array(version_ids).map(&:to_s).join("\u0000"))
  end

  def create_collection_batch!(batch_id:, registry_hash:, planned_source_count: 0, selected_count: 0,
                               selected_set_hash: "", selected_order_hash: "", sources: [],
                               started_at: Time.now.utc.iso8601(6), status: "running")
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    raise Error, "collection batch must start in running state" unless status.to_s == "running"
    raise Error, "collection batch selected_count must start at zero" unless Integer(selected_count).zero?
    raise Error, "collection batch selected hashes must start empty" unless selected_set_hash.to_s.empty? && selected_order_hash.to_s.empty?
    sources = Array(sources).sort_by { |source| source.fetch("id").to_s }
    raise Error, "planned locale source set is incomplete" unless sources.length == Integer(planned_source_count)
    raise Error, "collection batch sources must be locale_headlines exploration sources" unless sources.all? do |source|
      contract = normalize_source_contract(source)
      contract.fetch("discovery_basis") == "locale_headlines" && contract.fetch("analysis_policy") == "exploration_only" && !contract.fetch("query_conditioned")
    end
    raise Error, "registry_hash does not match frozen source set" unless registry_contract_hash(sources: sources) == registry_hash.to_s
    source_rows = sources.map { |source| [source.fetch("id").to_s, registry_contract_hash(sources: [source])] }
    transaction do
      execute(<<~SQL)
        INSERT INTO local_collection_batch
          (batch_id, started_at, registry_hash, selected_count, planned_source_count, selected_set_hash, selected_order_hash, status)
        VALUES (#{literal(batch_id)}, #{literal(started_at)}, #{literal(registry_hash)}, #{Integer(selected_count)}, #{Integer(planned_source_count)}, #{literal(selected_set_hash)}, #{literal(selected_order_hash)}, #{literal(status)})
        ON CONFLICT (batch_id) DO NOTHING
      SQL
      row = execute("SELECT batch_id, started_at::text, completed_at::text, registry_hash, selected_count, planned_source_count, selected_set_hash, selected_order_hash, status FROM local_collection_batch WHERE batch_id = #{literal(batch_id)}").fetch(0)
      actual = row_to_hash(row, %w[batch_id started_at completed_at registry_hash selected_count planned_source_count selected_set_hash selected_order_hash status])
      expected = { "registry_hash" => registry_hash.to_s, "selected_count" => Integer(selected_count), "planned_source_count" => Integer(planned_source_count), "selected_set_hash" => selected_set_hash.to_s, "selected_order_hash" => selected_order_hash.to_s, "status" => status.to_s }
      raise Error, "collection batch immutable payload differs" unless actual.fetch("registry_hash") == expected.fetch("registry_hash") && actual.fetch("selected_count").to_i == expected.fetch("selected_count") && actual.fetch("planned_source_count").to_i == expected.fetch("planned_source_count") && actual.fetch("selected_set_hash") == expected.fetch("selected_set_hash") && actual.fetch("selected_order_hash") == expected.fetch("selected_order_hash") && actual.fetch("status") == expected.fetch("status") && timestamp_equal?(actual.fetch("started_at"), started_at)
      source_rows.each_with_index do |(source_id, source_hash), index|
        execute(<<~SQL)
          INSERT INTO local_collection_batch_source (batch_id, source_id, source_config_hash, sort_order)
          VALUES (#{literal(batch_id)}, #{literal(source_id)}, #{literal(source_hash)}, #{index})
          ON CONFLICT (batch_id, source_id) DO NOTHING
        SQL
        existing = execute("SELECT source_config_hash, sort_order FROM local_collection_batch_source WHERE batch_id = #{literal(batch_id)} AND source_id = #{literal(source_id)}").fetch(0).split("\t", -1)
        raise Error, "collection batch source immutable payload differs" unless existing.fetch(0) == source_hash && existing.fetch(1).to_i == index
      end
      planned_ids = execute("SELECT source_id FROM local_collection_batch_source WHERE batch_id = #{literal(batch_id)} ORDER BY sort_order ASC").map(&:to_s)
      raise Error, "collection batch planned source set differs" unless planned_ids == source_rows.map(&:first)
      actual.tap do |batch|
        %w[selected_count planned_source_count].each { |key| batch[key] = batch.fetch(key).to_i }
      end
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "collection batch is incomplete: #{error.message}"
  end

  alias start_collection_batch! create_collection_batch!
  alias begin_collection_batch! create_collection_batch!

  def record_source_fetch_attempt!(batch_id:, source_id:, outcome:, item_count:, capture_id: nil, http_status: nil,
                                   discovery_basis: "locale_headlines", query_conditioned: false,
                                   analysis_policy: "exploration_only", source_config_hash: "",
                                   error_code: "", error_message: "", started_at: Time.now.utc.iso8601(6),
                                   completed_at: Time.now.utc.iso8601(6))
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    outcome = outcome.to_s
    raise Error, "fetch attempt outcome is invalid" unless %w[succeeded_with_items succeeded_empty failed].include?(outcome)
    raise Error, "succeeded_with_items requires capture_id" if outcome == "succeeded_with_items" && capture_id.to_s.empty?
    raise Error, "succeeded_with_items requires positive item_count" if outcome == "succeeded_with_items" && Integer(item_count) <= 0
    raise Error, "succeeded_empty cannot carry capture_id" if outcome == "succeeded_empty" && !capture_id.to_s.empty?
    raise Error, "succeeded_empty requires zero item_count" if outcome == "succeeded_empty" && Integer(item_count) != 0
    raise Error, "failed attempt cannot carry capture_id" if outcome == "failed" && !capture_id.to_s.empty?
    raise Error, "failed attempt requires zero item_count" if outcome == "failed" && Integer(item_count) != 0
    raise Error, "failed attempt requires error code or message" if outcome == "failed" && error_code.to_s.empty? && error_message.to_s.empty?
    raise Error, "fetch attempt source_config_hash is required" if source_config_hash.to_s.empty?
    source = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT discovery_basis, query_conditioned::text, analysis_policy
        FROM local_source_registry
       WHERE source_id = #{literal(source_id)}
    SQL
    raise Error, "fetch attempt source is not registered" if source.empty?
    raise Error, "fetch attempt source contract changed" unless source.fetch(0) == discovery_basis.to_s && truthy_value?(source.fetch(1)) == !!query_conditioned && source.fetch(2) == analysis_policy.to_s
    planned = query("SELECT source_config_hash FROM local_collection_batch_source WHERE batch_id = #{literal(batch_id)} AND source_id = #{literal(source_id)}")
    raise Error, "fetch attempt source is not in frozen batch plan" if planned.empty?
    raise Error, "fetch attempt source_config_hash differs from frozen plan" unless planned.fetch(0) == source_config_hash.to_s
    execute(<<~SQL)
      INSERT INTO local_source_fetch_attempt
        (attempt_id, batch_id, source_id, outcome, item_count, capture_id, http_status,
         discovery_basis, query_conditioned, analysis_policy, source_config_hash,
         error_code, error_message, started_at, completed_at)
      VALUES (#{literal(Digest::SHA256.hexdigest([batch_id, source_id].join("\u0000")))}, #{literal(batch_id)}, #{literal(source_id)}, #{literal(outcome)}, #{Integer(item_count)},
              #{capture_id.to_s.empty? ? "NULL" : literal(capture_id)}, #{http_status.nil? ? "NULL" : Integer(http_status)},
              #{literal(discovery_basis)}, #{query_conditioned ? "TRUE" : "FALSE"}, #{literal(analysis_policy)}, #{literal(source_config_hash)},
              #{literal(error_code)}, #{literal(error_message)}, #{literal(started_at)}, #{literal(completed_at)})
      ON CONFLICT (batch_id, source_id) DO NOTHING
    SQL
    existing = execute("SELECT outcome, item_count, capture_id, http_status, discovery_basis, query_conditioned::text, analysis_policy, source_config_hash, error_code, error_message, started_at::text, completed_at::text FROM local_source_fetch_attempt WHERE batch_id = #{literal(batch_id)} AND source_id = #{literal(source_id)}").fetch(0).split("\t", -1)
    expected = [outcome, Integer(item_count).to_s, capture_id.to_s, http_status.to_s, discovery_basis.to_s, query_conditioned ? "t" : "f", analysis_policy.to_s, source_config_hash.to_s, error_code.to_s, error_message.to_s, started_at.to_s, completed_at.to_s]
    unless existing.fetch(0) == expected.fetch(0) && existing.fetch(1).to_i == Integer(item_count) && existing.fetch(2) == expected.fetch(2) && existing.fetch(3).to_s == expected.fetch(3) && existing.fetch(4, "") == expected.fetch(4) && truthy_value?(existing.fetch(5)) == !!query_conditioned && existing.fetch(6) == expected.fetch(6) && existing.fetch(7) == expected.fetch(7) && existing.fetch(8) == expected.fetch(8) && existing.fetch(9) == expected.fetch(9) && timestamp_equal?(existing.fetch(10), started_at) && timestamp_equal?(existing.fetch(11), completed_at)
      raise Error, "fetch attempt immutable payload differs"
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "fetch attempt is incomplete: #{error.message}"
  end

  alias record_fetch_attempt! record_source_fetch_attempt!

  def record_source_fetch_attempts!(attempts:)
    transaction do
      Array(attempts).each { |attempt| record_source_fetch_attempt!(**attempt) }
    end
    true
  end

  alias record_fetch_attempts! record_source_fetch_attempts!

  def collection_batch(batch_id:)
    return nil unless breadth_schema_available?
    rows = query("SELECT batch_id, started_at::text, completed_at::text, registry_hash, selected_count, planned_source_count, selected_set_hash, selected_order_hash, status FROM local_collection_batch WHERE batch_id = #{literal(batch_id)}")
    return nil if rows.empty?

    row_to_hash(rows.fetch(0), %w[batch_id started_at completed_at registry_hash selected_count planned_source_count selected_set_hash selected_order_hash status]).tap do |batch|
      %w[selected_count planned_source_count].each { |key| batch[key] = batch.fetch(key).to_i }
    end
  end

  def source_fetch_attempts(batch_id:)
    return [] unless breadth_schema_available?
    query("SELECT attempt_id, batch_id, source_id, outcome, item_count, capture_id, http_status, discovery_basis, query_conditioned::text, analysis_policy, source_config_hash, error_code, error_message, started_at::text, completed_at::text FROM local_source_fetch_attempt WHERE batch_id = #{literal(batch_id)} ORDER BY source_id ASC").map do |row|
      row_to_hash(row, %w[attempt_id batch_id source_id outcome item_count capture_id http_status discovery_basis query_conditioned analysis_policy source_config_hash error_code error_message started_at completed_at]).tap do |attempt|
        attempt["item_count"] = attempt.fetch("item_count").to_i
        attempt["http_status"] = attempt.fetch("http_status").to_i unless attempt.fetch("http_status").empty?
        attempt["query_conditioned"] = truthy_value?(attempt.fetch("query_conditioned"))
      end
    end
  end

  def freeze_collection_selection!(batch_id:, version_ids:)
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    ids = Array(version_ids).map(&:to_s)
    raise Error, "selection contains empty/duplicate version ids" if ids.any?(&:empty?) || ids.uniq.length != ids.length
    batch = collection_batch(batch_id: batch_id)
    raise Error, "collection batch is missing" unless batch
    assert_batch_attempts_complete!(batch_id: batch_id)
    manifest = selection_manifest_for_batch(batch_id: batch_id)
    canonical_ids = manifest.fetch("selected_version_ids")
    raise Error, "selection does not match canonical selector order" unless ids == canonical_ids
    raise Error, "selection exceeds frozen planned count" if batch.fetch("planned_source_count").to_i.positive? && ids.length > batch.fetch("planned_source_count").to_i * 12
    hash = selected_set_hash(version_ids: ids)
    order_hash = selected_order_hash(version_ids: ids)
    if batch.fetch("status") != "running"
      raise Error, "frozen collection selection differs" unless batch.fetch("selected_count").to_i == ids.length && batch.fetch("selected_set_hash") == hash && batch.fetch("selected_order_hash") == order_hash
      return batch
    end
    updated = transaction do
      persist_selection_manifest!(batch_id: batch_id, manifest: manifest)
      execute("UPDATE local_collection_batch SET selected_count = #{ids.length}, selected_set_hash = #{literal(hash)}, selected_order_hash = #{literal(order_hash)}, status = 'frozen' WHERE batch_id = #{literal(batch_id)} AND status = 'running' RETURNING batch_id")
    end
    if updated.empty?
      current = collection_batch(batch_id: batch_id)
      raise Error, "frozen collection selection differs" unless current.fetch("selected_count").to_i == ids.length && current.fetch("selected_set_hash") == hash && current.fetch("selected_order_hash") == order_hash
      return current
    end
    collection_batch(batch_id: batch_id)
  end

  def batch_candidate_versions(batch_id:)
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    query(<<~SQL).map do |row|
      SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name,
             v.publisher_id, v.publisher_name, v.publisher_url, v.publisher_identity_status,
             v.source_kind, v.discovery_basis, v.query_conditioned::text,
             v.analysis_policy, v.aggregator_id, v.locale_tag, v.market_label,
             v.market_label_basis, v.query_topics::text, v.title, v.summary,
             v.source_url, v.published_at::text, v.fetched_at::text, v.captured_at::text,
             v.content_hash
        FROM local_source_item_version v
        JOIN local_source_fetch_attempt a ON a.batch_id = #{literal(batch_id)}
                                         AND a.source_id = v.source_id
                                         AND a.capture_id = v.capture_id
       WHERE a.outcome = 'succeeded_with_items'
       ORDER BY v.published_at DESC NULLS LAST, v.captured_at DESC, v.version_id ASC
    SQL
      item = row_to_hash(row, %w[version_id item_key capture_id source_id source_name publisher_id publisher_name publisher_url publisher_identity_status source_kind discovery_basis query_conditioned analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics title summary source_url published_at fetched_at captured_at content_hash])
      item["query_conditioned"] = truthy_value?(item.fetch("query_conditioned"))
      item["query_topics"] = parse_json_array(item.fetch("query_topics"))
      item
    end
  end

  def selected_versions_for_batch(batch_id:, limit: 12)
    selection_manifest_for_batch(batch_id: batch_id, limit: limit).fetch("selected_items")
  end

  # Public, batch-scoped seed. It intentionally depends only on frozen batch
  # identity and registry contract, never on a user, click, or personal state.
  def selection_seed(batch_id:, registry_hash: nil)
    batch = collection_batch(batch_id: batch_id)
    frozen_registry_hash = registry_hash || batch&.fetch("registry_hash", "")
    raise Error, "collection batch is missing" if frozen_registry_hash.to_s.empty?

    "breadth-pre-detection-v1/#{batch_id}/#{frozen_registry_hash}"
  end

  def selection_manifest_for_batch(batch_id:, limit: 12, detector_results: {})
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    batch = collection_batch(batch_id: batch_id)
    raise Error, "collection batch is missing" unless batch
    seed = selection_seed(batch_id: batch_id, registry_hash: batch.fetch("registry_hash"))
    BreadthDiscoverySelector.new(limit: limit, seed: seed).selection_manifest(
      items: batch_candidate_versions(batch_id: batch_id), scope_id: "locale_frontier",
      seed: seed, detector_results: detector_results
    )
  end

  # Persist the complete detector-before universe before the batch CAS moves
  # to frozen.  Every row is inserted once and then guarded by append-only
  # triggers in 012; retries may replay identical payloads but cannot edit a
  # terminal decision.
  def persist_selection_manifest!(batch_id:, manifest:)
    execute(<<~SQL)
      INSERT INTO local_pre_detection_exploration_manifest
        (manifest_id, batch_id, scope_id, manifest_version, seed, policy_version,
         selection_limit, locale_limit, publisher_limit, eligibility_count,
         eligible_count, ineligible_count, selection_decision_count, selected_count,
         eligibility_set_hash, selected_set_hash, selected_order_hash, status,
         delivery_status, not_a_signal, personalization)
      VALUES (#{literal(manifest.fetch("manifest_id"))}, #{literal(batch_id)},
              #{literal(manifest.fetch("scope_id"))}, #{literal(manifest.fetch("manifest_version"))},
              #{literal(manifest.fetch("seed"))}, #{literal(manifest.fetch("policy_version"))},
              #{Integer(manifest.fetch("limit"))}, #{Integer(manifest.fetch("locale_limit"))},
              #{Integer(manifest.fetch("publisher_limit"))}, #{Integer(manifest.fetch("eligibility_count"))},
              #{Integer(manifest.fetch("eligible_count"))}, #{Integer(manifest.fetch("ineligible_count"))},
              #{Integer(manifest.fetch("selection_decision_count"))}, #{Integer(manifest.fetch("selected_count"))},
              #{literal(manifest.fetch("eligibility_set_hash"))}, #{literal(manifest.fetch("selected_set_hash"))},
              #{literal(manifest.fetch("selected_order_hash"))}, #{literal(manifest.fetch("status"))},
              #{literal(manifest.fetch("delivery_status"))}, TRUE, #{literal(manifest.fetch("personalization"))})
      ON CONFLICT (manifest_id) DO NOTHING
    SQL
    manifest.fetch("eligibility_units").each do |unit|
      execute(<<~SQL)
        INSERT INTO local_pre_detection_exploration_eligibility_unit
          (eligibility_unit_id, manifest_id, version_id, item_hash, input_index, policy_version, eligibility_predicate)
        VALUES (#{literal(unit.fetch("eligibility_unit_id"))}, #{literal(manifest.fetch("manifest_id"))},
                #{literal(unit.fetch("version_id"))}, #{literal(unit.fetch("item_hash"))},
                #{Integer(unit.fetch("input_index"))}, #{literal(unit.fetch("policy_version"))},
                #{literal(unit.fetch("eligibility_predicate"))})
        ON CONFLICT (eligibility_unit_id) DO NOTHING
      SQL
    end
    manifest.fetch("eligibility_decisions").each do |decision|
      execute(<<~SQL)
        INSERT INTO local_pre_detection_exploration_eligibility_decision
          (eligibility_decision_id, eligibility_unit_id, manifest_id, outcome, reason_code, terminal)
        VALUES (#{literal(decision.fetch("eligibility_decision_id"))}, #{literal(decision.fetch("eligibility_unit_id"))},
                #{literal(manifest.fetch("manifest_id"))}, #{literal(decision.fetch("outcome"))},
                #{literal(decision.fetch("reason_code"))}, TRUE)
        ON CONFLICT (eligibility_decision_id) DO NOTHING
      SQL
    end
    manifest.fetch("exploration_units").each do |unit|
      execute(<<~SQL)
        INSERT INTO local_pre_detection_exploration_unit
          (exploration_unit_id, manifest_id, eligibility_unit_id, version_id, random_key, detector_outcome, input_index)
        VALUES (#{literal(unit.fetch("exploration_unit_id"))}, #{literal(manifest.fetch("manifest_id"))},
                #{literal(unit.fetch("eligibility_unit_id"))}, #{literal(unit.fetch("version_id"))},
                #{literal(unit.fetch("random_key"))}, #{literal(unit.fetch("detector_outcome"))},
                #{Integer(unit.fetch("input_index"))})
        ON CONFLICT (exploration_unit_id) DO NOTHING
      SQL
    end
    manifest.fetch("exploration_decisions").each do |decision|
      selection_order = decision.fetch("selection_order")
      execute(<<~SQL)
        INSERT INTO local_pre_detection_exploration_decision
          (exploration_decision_id, exploration_unit_id, manifest_id, outcome, reason_code,
           sort_order, selection_order, not_a_signal, delivery_status, terminal)
        VALUES (#{literal(decision.fetch("exploration_decision_id"))}, #{literal(decision.fetch("exploration_unit_id"))},
                #{literal(manifest.fetch("manifest_id"))}, #{literal(decision.fetch("outcome"))},
                #{literal(decision.fetch("reason_code"))}, #{Integer(decision.fetch("sort_order"))},
                #{selection_order.nil? ? "NULL" : Integer(selection_order)}, TRUE, 'unmeasured', TRUE)
        ON CONFLICT (exploration_decision_id) DO NOTHING
      SQL
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "selection manifest is incomplete: #{error.message}"
  end

  def finalize_collection_batch!(batch_id:, status: "published")
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    raise Error, "invalid collection batch status" unless %w[published failed].include?(status.to_s)
    batch = collection_batch(batch_id: batch_id)
    raise Error, "collection batch is missing" unless batch
    raise Error, "published terminal status requires empty selection" if status.to_s == "published" && batch.fetch("selected_count").to_i != 0
    if batch.fetch("status") == status.to_s
      return batch
    end
    raise Error, "collection batch is not frozen" unless batch.fetch("status") == "frozen"
    assert_batch_attempts_complete!(batch_id: batch_id)
    updated = execute("UPDATE local_collection_batch SET status = #{literal(status)}, completed_at = COALESCE(completed_at, now()) WHERE batch_id = #{literal(batch_id)} AND status = 'frozen' RETURNING batch_id")
    if updated.empty?
      current = collection_batch(batch_id: batch_id)
      raise Error, "collection batch terminal state changed concurrently" unless current.fetch("status") == status.to_s
      return current
    end
    collection_batch(batch_id: batch_id)
  end

  def ingest_source_items!(items:)
    inserted = 0
    transaction do
      Array(items).each do |item|
        source_id = item.fetch("source_id")
        capture_at = item.fetch("capture_captured_at", item.fetch("fetched_at"))
        fetched_at = item.fetch("fetched_at", capture_at)
        capture_body_hash = item.fetch("capture_body_hash", "").to_s
        # Direct fixture callers predate capture metadata. Keep that API
        # compatible while ensuring HTTP Fetcher rows always carry the real
        # feed-body hash.
        capture_body_hash = Digest::SHA256.hexdigest([source_id, item.fetch("capture_source_url", item.fetch("source_url")), capture_at].join("\u0000")) if capture_body_hash.empty?
        capture_id = item.fetch("capture_id", "").to_s
        capture_id = Digest::SHA256.hexdigest([source_id, capture_body_hash, capture_at].join("\u0000")) if capture_id.empty?
        item_key = item.fetch("item_key")
        source_kind = item.fetch("source_kind", "configured")
        contract = normalize_item_contract(item, source_kind: source_kind)
        validate_item_registry_contract!(source_id: source_id, contract: contract) if breadth_schema_available?
        capture_source_url = item.fetch("capture_source_url", item.fetch("source_url"))
        rights_scope = item.fetch("rights_scope", "excerpt_only")
        capture_http_status = Integer(item.fetch("capture_http_status", 200))
        capture_content_type = item.fetch("capture_content_type", "")
        capture_content_bytes = Integer(item.fetch("capture_content_bytes", 0))
        capture_storage_status = item.fetch("capture_storage_status", "metadata_only")
        capture_storage_uri = item.fetch("capture_storage_uri", "")
        title = item.fetch("title").to_s
        summary = persisted_summary(item.fetch("summary"))
        source_url = item.fetch("source_url").to_s
        content_hash = content_hash_for(title: title, summary: summary, source_url: source_url)
        publisher_id = item.fetch("publisher_id", "").to_s
        publisher_identity_status = item.fetch("publisher_identity_status", publisher_id.empty? ? "unresolved" : "configured").to_s
        publisher_name = item.fetch("publisher_name", item.fetch("source_name", "")).to_s
        publisher_url = item.fetch("publisher_url", item.fetch("source_url", "")).to_s
        ensure_capture!(
          capture_id: capture_id, source_id: source_id, source_url: capture_source_url,
          source_kind: source_kind, rights_scope: rights_scope, captured_at: capture_at,
          http_status: capture_http_status, content_type: capture_content_type,
          content_bytes: capture_content_bytes, body_hash: capture_body_hash,
          storage_status: capture_storage_status, storage_uri: capture_storage_uri
        )
        item_insert_sql = if breadth_schema_available?
          <<~SQL
            INSERT INTO local_source_item
              (item_key, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id, publisher_identity_status, source_kind, capture_id,
               discovery_basis, analysis_policy, aggregator_id, locale_tag, market_label, market_label_basis, query_topics,
               title, summary, source_url, published_at, fetched_at, captured_at, content_hash)
            VALUES (#{literal(item_key)}, #{literal(source_id)}, #{literal(item.fetch("source_name"))},
                    #{literal(item.fetch("language"))}, #{literal(item.fetch("region", "未标注"))},
                    #{literal(publisher_name)}, #{literal(publisher_url)}, #{literal(publisher_id)}, #{literal(publisher_identity_status)},
                    #{literal(source_kind)}, #{literal(capture_id)}, #{literal(contract.fetch("discovery_basis"))},
                    #{literal(contract.fetch("analysis_policy"))}, #{literal(contract.fetch("aggregator_id"))},
                    #{literal(contract.fetch("locale_tag"))}, #{literal(contract.fetch("market_label"))},
                    #{literal(contract.fetch("market_label_basis"))}, #{literal(JSON.generate(contract.fetch("query_topics")))}::jsonb,
                    #{literal(title)}, #{literal(summary)}, #{literal(source_url)}, #{item.fetch("published_at") ? literal(item.fetch("published_at")) : "NULL"},
                    #{literal(fetched_at)}, #{literal(capture_at)}, #{literal(content_hash)})
          SQL
        else
          <<~SQL
            INSERT INTO local_source_item
              (item_key, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id, publisher_identity_status, source_kind, capture_id,
               title, summary, source_url, published_at, fetched_at, captured_at, content_hash)
            VALUES (#{literal(item_key)}, #{literal(source_id)}, #{literal(item.fetch("source_name"))},
                    #{literal(item.fetch("language"))}, #{literal(item.fetch("region", "未标注"))},
                    #{literal(publisher_name)}, #{literal(publisher_url)}, #{literal(publisher_id)}, #{literal(publisher_identity_status)},
                    #{literal(source_kind)}, #{literal(capture_id)}, #{literal(title)},
                    #{literal(summary)}, #{literal(source_url)}, #{item.fetch("published_at") ? literal(item.fetch("published_at")) : "NULL"},
                    #{literal(fetched_at)}, #{literal(capture_at)}, #{literal(content_hash)})
          SQL
        end
        rows = execute(item_insert_sql.sub(
          /ON CONFLICT.*/m,
          ""
        ) + <<~SQL)
          ON CONFLICT (item_key) DO UPDATE SET
            source_name = EXCLUDED.source_name,
            language = EXCLUDED.language,
            title = EXCLUDED.title,
            summary = EXCLUDED.summary,
            region = EXCLUDED.region,
            publisher_name = EXCLUDED.publisher_name,
            publisher_url = EXCLUDED.publisher_url,
            publisher_id = EXCLUDED.publisher_id,
            publisher_identity_status = EXCLUDED.publisher_identity_status,
            source_kind = EXCLUDED.source_kind,
            #{breadth_schema_available? ? "discovery_basis = EXCLUDED.discovery_basis, analysis_policy = EXCLUDED.analysis_policy, aggregator_id = EXCLUDED.aggregator_id, locale_tag = EXCLUDED.locale_tag, market_label = EXCLUDED.market_label, market_label_basis = EXCLUDED.market_label_basis, query_topics = EXCLUDED.query_topics," : ""}
            capture_id = EXCLUDED.capture_id,
            published_at = EXCLUDED.published_at,
            fetched_at = EXCLUDED.fetched_at,
            captured_at = EXCLUDED.captured_at,
            content_hash = EXCLUDED.content_hash
           WHERE local_source_item.capture_id IS DISTINCT FROM EXCLUDED.capture_id
             AND (EXCLUDED.captured_at > local_source_item.captured_at
              OR (EXCLUDED.captured_at = local_source_item.captured_at
                  AND EXCLUDED.fetched_at > local_source_item.fetched_at)
              OR (EXCLUDED.captured_at = local_source_item.captured_at
                  AND EXCLUDED.fetched_at = local_source_item.fetched_at
                  AND (local_source_item.capture_id IS NULL
                       OR EXCLUDED.capture_id > local_source_item.capture_id)))
          RETURNING (xmax = 0)::text
        SQL
        inserted += rows.count { |row| %w[t true].include?(row) }
        ensure_version!(
          version_id: Digest::SHA256.hexdigest([item_key, capture_id].join("\u0000")),
          item_key: item_key, capture_id: capture_id, source_id: source_id,
          source_name: item.fetch("source_name"), language: item.fetch("language"), region: item.fetch("region", "未标注"),
          publisher_name: publisher_name, publisher_url: publisher_url, publisher_id: publisher_id,
          publisher_identity_status: publisher_identity_status, source_kind: source_kind,
          query_conditioned: contract.fetch("query_conditioned"),
          discovery_basis: contract.fetch("discovery_basis"), analysis_policy: contract.fetch("analysis_policy"),
          aggregator_id: contract.fetch("aggregator_id"), locale_tag: contract.fetch("locale_tag"),
          market_label: contract.fetch("market_label"), market_label_basis: contract.fetch("market_label_basis"),
          query_topics: contract.fetch("query_topics"),
          lineage_metadata_basis: "capture_time",
          title: title, summary: summary, source_url: source_url,
          published_at: item.fetch("published_at"), fetched_at: fetched_at,
          captured_at: capture_at, content_hash: content_hash
        )
      end
    end
    inserted
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "source item ingest is incomplete: #{error.message}"
  end

  def latest_source_items(limit: 12, published_only: false, analysis_policy: "signal_eligible")
    breadth = breadth_schema_available?
    policy_clause = breadth ? " AND i.analysis_policy = #{literal(analysis_policy)}" : ""
    query(<<~SQL).map do |row|
      SELECT i.item_key, i.source_id, i.source_name, i.language, i.region, i.publisher_name, i.publisher_url,
             i.publisher_id, i.publisher_identity_status, i.source_kind, i.capture_id, i.title, i.summary, i.source_url, i.published_at::text, i.fetched_at::text, i.captured_at::text, i.content_hash,
             cv.version_id,
             #{breadth ? "i.discovery_basis, i.analysis_policy, i.aggregator_id, i.locale_tag, i.market_label, i.market_label_basis, i.query_topics::text," : ""}
             COALESCE(t.translated_title, ''), COALESCE(t.translated_summary, ''),
             CASE WHEN i.language LIKE 'zh%' THEN 'not_needed'
                  WHEN t.status = 'translated' THEN 'translated'
                  WHEN t.status = 'failed' THEN 'failed'
                  ELSE 'untranslated' END,
             COALESCE(t.artifact_id, ''), COALESCE(t.provider, ''), COALESCE(t.model, ''), COALESCE(t.created_at::text, '')
        FROM local_source_item i
        LEFT JOIN LATERAL (
          SELECT version_id FROM local_source_item_version
           WHERE item_key=i.item_key AND capture_id=i.capture_id
           ORDER BY created_at DESC, version_id ASC LIMIT 1
        ) cv ON TRUE
        LEFT JOIN LATERAL (
          SELECT artifact_id, translated_title, translated_summary, status, provider, model, created_at
            FROM local_translation_artifact
           WHERE item_key = i.item_key AND target_language = 'zh-CN' AND original_content_hash = i.content_hash
           ORDER BY created_at DESC
           LIMIT 1
        ) t ON TRUE
       WHERE 1 = 1#{published_only ? " AND i.published_at IS NOT NULL" : ""}#{policy_clause}
       ORDER BY i.published_at DESC NULLS LAST, i.fetched_at DESC, i.item_key ASC
       LIMIT #{Integer(limit)}
    SQL
      keys = %w[item_key source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind capture_id title summary source_url published_at fetched_at capture_captured_at content_hash version_id]
      keys += %w[discovery_basis analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics] if breadth
      keys += %w[translated_title translated_summary translation_status translation_artifact_id translation_provider translation_model translated_at]
      item = row_to_hash(row, keys)
      item["query_topics"] = parse_json_array(item.fetch("query_topics")) if breadth
      item["display_title"] = item.fetch("translation_status") == "translated" ? item.fetch("translated_title") : item.fetch("title")
      item["display_summary"] = item.fetch("translation_status") == "translated" ? item.fetch("translated_summary") : item.fetch("summary")
      item
    end
  end

  # Raw, enabled-registry-only input for deterministic event-candidate
  # analysis.  Deliberately does not join translation artifacts or expose
  # display_title/display_summary: the analyzer must see the original title
  # and summary that were archived.
  def event_analysis_items(limit: 500, analysis_policy: "signal_eligible")
    breadth = breadth_schema_available?
    policy_clause = breadth ? " AND v.analysis_policy = #{literal(analysis_policy)}" : ""
    query(<<~SQL).map do |row|
      SELECT v.item_key, v.source_id, v.source_name, v.language, v.region,
             v.publisher_name, v.publisher_url, v.publisher_id,
             v.publisher_identity_status, v.source_kind, v.lineage_metadata_basis, v.title, v.summary,
             v.source_url, v.published_at::text, v.fetched_at::text,
             v.captured_at::text, v.content_hash, v.version_id, v.capture_id,
             #{breadth ? "v.discovery_basis, v.analysis_policy, v.aggregator_id, v.locale_tag, v.market_label, v.market_label_basis, v.query_topics::text," : ""}
             r.enabled::text, v.query_conditioned::text
        FROM local_source_item_version v
        JOIN local_source_item i ON i.item_key = v.item_key AND i.capture_id = v.capture_id
        JOIN local_source_registry r ON r.source_id = v.source_id
       WHERE r.enabled
         #{policy_clause}
         AND v.published_at IS NOT NULL
         AND v.publisher_id <> ''
         AND v.publisher_identity_status <> 'unresolved'
       ORDER BY v.published_at DESC NULLS LAST, v.item_key ASC
       LIMIT #{Integer(limit)}
    SQL
      keys = %w[item_key source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind lineage_metadata_basis title summary source_url published_at fetched_at capture_captured_at content_hash version_id capture_id]
      keys += %w[discovery_basis analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics] if breadth
      keys += %w[registry_enabled query_conditioned]
      item = row_to_hash(row, keys)
      item["query_topics"] = parse_json_array(item.fetch("query_topics")) if breadth
      item["registry_enabled"] = %w[t true].include?(item.fetch("registry_enabled").downcase)
      item["query_conditioned"] = %w[t true].include?(item.fetch("query_conditioned").downcase)
      item
    end
  end

  alias signal_analysis_items event_analysis_items

  # Internal lineage read for audit/tests. The public radar contract continues
  # to use latest_source_items/current_radar; versions are never exposed as a
  # new HTTP endpoint.
  def source_item_versions(item_key:)
    breadth = breadth_schema_available?
    query(<<~SQL).map do |row|
      SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name, v.language, v.region,
             v.publisher_name, v.publisher_url, v.publisher_id, v.publisher_identity_status,
             v.source_kind, v.query_conditioned::text, v.lineage_metadata_basis,
             #{breadth ? "v.discovery_basis, v.analysis_policy, v.aggregator_id, v.locale_tag, v.market_label, v.market_label_basis, v.query_topics::text," : ""}
             v.title, v.summary, v.source_url, v.published_at::text, v.fetched_at::text, v.captured_at::text,
             v.content_hash, c.source_url, c.source_kind, c.rights_scope,
             c.http_status, c.content_type, c.content_bytes, c.body_hash,
             c.storage_status, c.storage_uri
        FROM local_source_item_version v
        JOIN local_source_capture c ON c.capture_id = v.capture_id
       WHERE v.item_key = #{literal(item_key)}
       ORDER BY v.captured_at DESC, v.version_id ASC
    SQL
      keys = %w[version_id item_key capture_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind query_conditioned lineage_metadata_basis]
      keys += %w[discovery_basis analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics] if breadth
      keys += %w[title summary source_url published_at fetched_at captured_at content_hash capture_source_url capture_source_kind rights_scope capture_http_status capture_content_type capture_content_bytes capture_body_hash capture_storage_status capture_storage_uri]
      row_to_hash(row, keys).tap do |version|
        version["capture_http_status"] = version.fetch("capture_http_status").to_i
        version["capture_content_bytes"] = version.fetch("capture_content_bytes").to_i
        version["query_topics"] = parse_json_array(version.fetch("query_topics")) if breadth
      end
    end
  end

  def translation_candidates(limit: 20)
    query(<<~SQL).map do |row|
      SELECT v.version_id, v.item_key, v.source_id, v.source_name, v.language, v.region, v.publisher_name, v.publisher_url,
             v.source_kind, v.title, v.summary, v.source_url, v.published_at::text, v.fetched_at::text, v.content_hash
        FROM local_source_item_version v
       WHERE v.language NOT LIKE 'zh%'
         AND NOT EXISTS (
           SELECT 1 FROM local_translation_artifact t
            WHERE t.item_key = v.item_key AND t.target_language = 'zh-CN'
              AND t.original_content_hash = v.content_hash AND t.status = 'translated'
         )
         AND v.version_id = (
           SELECT v2.version_id FROM local_source_item_version v2
            WHERE v2.item_key=v.item_key AND v2.content_hash=v.content_hash
            ORDER BY v2.created_at ASC, v2.version_id ASC LIMIT 1
         )
       ORDER BY v.created_at DESC, v.version_id ASC
       LIMIT #{Integer(limit)}
    SQL
      row_to_hash(row, %w[version_id item_key source_id source_name language region publisher_name publisher_url source_kind title summary source_url published_at fetched_at content_hash])
    end
  end

  def ensure_metadata_translation_runs!(provider: "deepseek", model: "deepseek-v4-pro",
                                        prompt_version: "metadata-translation-v1")
    return 0 unless relation_exists?("local_metadata_translation_run")
    candidates = query(<<~SQL)
      SELECT v.version_id, v.item_key, v.content_hash, char_length(v.title) + char_length(v.summary)
        FROM local_source_item_version v
       WHERE v.language NOT LIKE 'zh%'
         AND v.version_id = (
           SELECT v2.version_id FROM local_source_item_version v2
            WHERE v2.item_key=v.item_key AND v2.content_hash=v.content_hash
            ORDER BY v2.created_at ASC, v2.version_id ASC LIMIT 1
         )
       ORDER BY v.created_at DESC, v.version_id ASC
    SQL
    inserted = 0
    candidates.each do |row|
      version_id, item_key, content_hash, input_chars = row.split("\t", -1)
      run_id = Digest::SHA256.hexdigest([version_id, prompt_version, model].join("\0"))
      inserted += execute(<<~SQL).length
        INSERT INTO local_metadata_translation_run
          (run_id, source_version_id, item_key, source_content_hash, target_language,
           provider, model, prompt_version, state, input_chars)
        VALUES (#{literal(run_id)}, #{literal(version_id)}, #{literal(item_key)}, #{literal(content_hash)},
                'zh-CN', #{literal(provider)}, #{literal(model)}, #{literal(prompt_version)},
                'pending', #{Integer(input_chars)})
        ON CONFLICT (item_key, source_content_hash, target_language, provider, model, prompt_version) DO NOTHING
        RETURNING run_id
      SQL
    end
    inserted
  end

  def metadata_translation_candidates(limit: 20, daily_character_limit: 200_000)
    return translation_candidates(limit: limit) unless relation_exists?("local_metadata_translation_run")
    recover_stale_metadata_translation_runs! if metadata_translation_lease_schema_available?
    requested_limit = Integer(limit)
    raise Error, "metadata translation limit must be between 1 and #{METADATA_TRANSLATION_MAX_LIMIT}" unless requested_limit.between?(1, METADATA_TRANSLATION_MAX_LIMIT)
    configured_daily_limit = Integer(daily_character_limit)
    raise Error, "metadata translation daily character limit must be between 1 and #{METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT}" unless configured_daily_limit.between?(1, METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT)
    used = query("SELECT COALESCE(SUM(input_chars),0) FROM local_metadata_translation_run WHERE started_at >= date_trunc('day', now()) AND state IN ('running','succeeded','failed')").fetch(0).to_i
    remaining = [configured_daily_limit - used, 0].max
    return [] if remaining.zero?
    items = query(<<~SQL).map do |row|
      SELECT r.run_id, v.version_id, v.item_key, v.source_id, v.source_name, v.language,
             v.region, v.publisher_name, v.publisher_url, v.source_kind, v.title, v.summary,
             v.source_url, v.published_at::text, v.fetched_at::text, v.content_hash, r.input_chars
        FROM local_metadata_translation_run r
        JOIN local_source_item_version v ON v.version_id=r.source_version_id
       WHERE r.state IN ('pending','failed','credential_blocked','budget_blocked','interrupted')
         AND r.attempt_count < 3
         AND NOT EXISTS (
           SELECT 1 FROM local_translation_artifact t WHERE t.item_key=r.item_key
             AND t.original_content_hash=r.source_content_hash AND t.target_language='zh-CN'
             AND t.provider=r.provider AND t.model=r.model AND t.status='translated'
         )
       ORDER BY v.created_at DESC, r.run_id ASC
       LIMIT #{requested_limit}
    SQL
      row_to_hash(row, %w[translation_run_id version_id item_key source_id source_name language region publisher_name publisher_url source_kind title summary source_url published_at fetched_at content_hash input_chars]).tap { |item| item["input_chars"] = item.fetch("input_chars").to_i }
    end
    total = 0
    items.take_while { |item| total += item.fetch("input_chars"); total <= remaining }
  end

  def start_metadata_translation!(run_id:, owner: nil, lease_seconds: METADATA_TRANSLATION_LEASE_SECONDS, job_id: nil)
    owner_id = normalized_translation_owner(owner)
    seconds = Integer(lease_seconds)
    raise Error, "metadata translation lease duration must be positive" unless seconds.positive?
    if metadata_translation_lease_schema_available?
      rows = execute(<<~SQL)
        UPDATE local_metadata_translation_run
           SET state='running', attempt_count=attempt_count+1, started_at=now(),
               finished_at=NULL, error_reason='', lease_owner=#{literal(owner_id)},
               heartbeat_at=now(), lease_expires_at=now() + (#{seconds} * interval '1 second'), updated_at=now()
         WHERE run_id=#{literal(run_id)}
           AND state IN ('pending','failed','credential_blocked','budget_blocked','interrupted')
         RETURNING run_id
      SQL
      raise Error, "metadata translation run is not claimable" if rows.empty?
      record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "claimed") if job_id
    else
      rows = execute("UPDATE local_metadata_translation_run SET state='running',attempt_count=attempt_count+1,started_at=now(),finished_at=NULL,error_reason='',updated_at=now() WHERE run_id=#{literal(run_id)} AND state IN ('pending','failed','credential_blocked','budget_blocked') RETURNING run_id")
      raise Error, "metadata translation run is not claimable" if rows.empty?
    end
    true
  end

  def block_metadata_translation_for_credentials!(run_id:, reason:, owner: nil, job_id: nil)
    owner_id = normalized_translation_owner(owner)
    where = if metadata_translation_lease_schema_available?
              "run_id=#{literal(run_id)} AND state IN ('pending','failed','credential_blocked','budget_blocked','interrupted')"
            else
              "run_id=#{literal(run_id)} AND state IN ('pending','failed','credential_blocked','budget_blocked')"
            end
    rows = execute("UPDATE local_metadata_translation_run SET state='credential_blocked',error_reason=#{literal(reason.to_s[0,1000])},finished_at=now(),updated_at=now() WHERE #{where} RETURNING run_id")
    raise Error, "metadata translation run cannot be credential-blocked" if rows.empty?
    record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "blocked", error_reason: reason) if job_id
    true
  end

  def finish_metadata_translation!(run_id:, result:, artifact: nil, owner: nil, job_id: nil)
    usage = result.fetch("usage", {})
    owner_id = normalized_translation_owner(owner)
    if artifact && metadata_translation_lease_schema_available?
      transaction do
        assert_metadata_translation_owner!(run_id: run_id, owner_id: owner_id)
        save_translation_artifact!(artifact: artifact)
        rows = execute("UPDATE local_metadata_translation_run SET state='succeeded',prompt_tokens=#{Integer(usage.fetch("prompt_tokens",0))},completion_tokens=#{Integer(usage.fetch("completion_tokens",0))},finished_at=now(),heartbeat_at=now(),lease_expires_at=now(),updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running' AND lease_owner=#{literal(owner_id)} RETURNING run_id")
        raise Error, "metadata translation run is no longer owned" if rows.empty?
        record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "succeeded", input_chars: artifact_input_chars(artifact)) if job_id
      end
    else
      rows = execute("UPDATE local_metadata_translation_run SET state='succeeded',prompt_tokens=#{Integer(usage.fetch("prompt_tokens",0))},completion_tokens=#{Integer(usage.fetch("completion_tokens",0))},finished_at=now(),updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running'#{metadata_translation_lease_schema_available? ? " AND lease_owner=#{literal(owner_id)}" : ""} RETURNING run_id")
      raise Error, "metadata translation run is no longer owned" if rows.empty?
      record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "succeeded") if job_id
    end
    true
  end

  def fail_metadata_translation!(run_id:, reason:, owner: nil, job_id: nil)
    owner_id = normalized_translation_owner(owner)
    rows = execute("UPDATE local_metadata_translation_run SET state='failed',error_reason=#{literal(reason.to_s[0,1000])},finished_at=now(),heartbeat_at=now(),lease_expires_at=now(),updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running'#{metadata_translation_lease_schema_available? ? " AND lease_owner=#{literal(owner_id)}" : ""} RETURNING run_id")
    raise Error, "metadata translation run is no longer owned" if rows.empty?
    record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "failed", error_reason: reason) if job_id
    true
  end

  # A heartbeat is deliberately owner-bound.  A stale/non-expired run can be
  # observed by another process, but it cannot be renewed or completed by it.
  def heartbeat_metadata_translation!(run_id:, owner:, lease_seconds: METADATA_TRANSLATION_LEASE_SECONDS, job_id: nil)
    owner_id = normalized_translation_owner(owner)
    seconds = Integer(lease_seconds)
    rows = execute("UPDATE local_metadata_translation_run SET heartbeat_at=now(),lease_expires_at=now() + (#{seconds} * interval '1 second'),updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running' AND lease_owner=#{literal(owner_id)} RETURNING run_id")
    raise Error, "metadata translation run heartbeat is not owned" if rows.empty?
    record_translation_batch_attempt!(job_id: job_id, run_id: run_id, owner_id: owner_id, event: "heartbeat") if job_id
    true
  end

  # Reconcile a running row after a crash.  The artifact is accepted only when
  # its immutable lineage/provider fields match the run exactly.  A valid
  # artifact wins even when the lease is still fresh (the provider may have
  # committed immediately before the process died); without one, only an
  # expired lease can be interrupted/requeued.
  def recover_stale_metadata_translation_runs!(now: nil, owner: "translation-recovery")
    return [] unless metadata_translation_lease_schema_available?
    owner_id = normalized_translation_owner(owner)
    now_literal = now ? literal(now) : "now()"
    run_ids = query("SELECT run_id FROM local_metadata_translation_run WHERE state='running' ORDER BY started_at, run_id").map(&:to_s)
    run_ids.map do |run_id|
      reconcile_metadata_translation_run!(run_id: run_id, owner: owner_id, force_expired: false, now: now) ? run_id : nil
    end.compact
  end

  def reconcile_metadata_translation_run!(run_id:, owner: "translation-recovery", force_expired: false, now: nil)
    return false unless metadata_translation_lease_schema_available?
    owner_id = normalized_translation_owner(owner)
    tx_now = now ? literal(now) : "now()"
    transaction do
      row = query(<<~SQL).fetch(0, nil)
        SELECT run_id, source_version_id, item_key, source_content_hash, target_language, provider, model,
               state, lease_expires_at::text
          FROM local_metadata_translation_run
         WHERE run_id=#{literal(run_id)}
         FOR UPDATE
      SQL
      next false unless row
      values = row.split("\t", -1)
      run = row_to_hash(row, %w[run_id source_version_id item_key source_content_hash target_language provider model state lease_expires_at])
      next false unless run.fetch("state") == "running"
      artifact_rows = query(<<~SQL)
        SELECT artifact_id, source_version_id, item_key, source_language, target_language,
               original_content_hash, provider, model, status
          FROM local_translation_artifact
         WHERE source_version_id=#{literal(run.fetch("source_version_id"))}
           AND item_key=#{literal(run.fetch("item_key"))}
           AND original_content_hash=#{literal(run.fetch("source_content_hash"))}
           AND target_language=#{literal(run.fetch("target_language"))}
           AND provider=#{literal(run.fetch("provider"))}
           AND model=#{literal(run.fetch("model"))}
           AND status='translated'
         ORDER BY created_at DESC, artifact_id ASC
         LIMIT 2
         FOR SHARE
      SQL
      artifact_valid = artifact_rows.any? do |artifact_row|
        artifact = row_to_hash(artifact_row, %w[artifact_id source_version_id item_key source_language target_language original_content_hash provider model status])
        artifact.fetch("source_version_id") == run.fetch("source_version_id") &&
          artifact.fetch("item_key") == run.fetch("item_key") &&
          artifact.fetch("original_content_hash") == run.fetch("source_content_hash") &&
          artifact.fetch("target_language") == run.fetch("target_language") &&
          artifact.fetch("provider") == run.fetch("provider") &&
          artifact.fetch("model") == run.fetch("model") && artifact.fetch("status") == "translated"
      end
      if artifact_valid
        execute("UPDATE local_metadata_translation_run SET state='succeeded',error_reason='',finished_at=#{tx_now},heartbeat_at=#{tx_now},lease_expires_at=#{tx_now},updated_at=#{tx_now} WHERE run_id=#{literal(run_id)} AND state='running'")
        record_translation_batch_attempt_for_run!(run_id: run_id, owner_id: owner_id, event: "reconciled")
        next true
      end
      expired = force_expired || query("SELECT lease_expires_at < #{tx_now} FROM local_metadata_translation_run WHERE run_id=#{literal(run_id)}").fetch(0) == "t"
      next false unless expired
      execute("UPDATE local_metadata_translation_run SET state='interrupted',error_reason='worker lease expired before artifact commit',finished_at=#{tx_now},heartbeat_at=#{tx_now},lease_expires_at=#{tx_now},updated_at=#{tx_now} WHERE run_id=#{literal(run_id)} AND state='running'")
      record_translation_batch_attempt_for_run!(run_id: run_id, owner_id: owner_id, event: "interrupted", error_reason: "worker lease expired before artifact commit")
      true
    end
  end

  # Public queue/budget view used by both the API and the CLI.  It intentionally
  # reports no provider credential values or prompt content.
  def translation_status(daily_character_limit: METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT)
    return { "status" => "not_available" } unless relation_exists?("local_metadata_translation_run")
    limit = Integer(daily_character_limit)
    limit = METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT if limit > METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT
    recover_stale_metadata_translation_runs! if metadata_translation_lease_schema_available?
    queue = query("SELECT state, COUNT(*) FROM local_metadata_translation_run GROUP BY state ORDER BY state").to_h do |row|
      state, count = row.split("\t", -1)
      [state, count.to_i]
    end
    eligible = query(<<~SQL).fetch(0).split("\t", -1)
      SELECT COUNT(*), COALESCE(SUM(input_chars),0)
        FROM local_metadata_translation_run
       WHERE state IN ('pending','failed','budget_blocked','credential_blocked','interrupted')
         AND attempt_count < 3
    SQL
    pending_only = query("SELECT COUNT(*), COALESCE(SUM(input_chars),0) FROM local_metadata_translation_run WHERE state='pending' AND attempt_count < 3").fetch(0).split("\t", -1)
    budget = query("SELECT COALESCE(SUM(input_chars),0) FROM local_metadata_translation_run WHERE started_at >= date_trunc('day', now()) AND state IN ('running','succeeded','failed')").fetch(0).to_i
    active = active_translation_batch_job
    last_update_sql = if metadata_translation_lease_schema_available?
                        "SELECT GREATEST(COALESCE((SELECT MAX(updated_at) FROM local_metadata_translation_run), now()), COALESCE((SELECT MAX(updated_at) FROM local_translation_batch_job), now()))::text"
                      else
                        "SELECT COALESCE(MAX(updated_at), now())::text FROM local_metadata_translation_run"
                      end
    last_update = query(last_update_sql).fetch(0)
    {
      "status" => active ? "running" : (queue.fetch("pending", 0).positive? ? "pending" : "idle"),
      "queue" => queue,
      "eligible_pending" => { "count" => eligible.fetch(0).to_i, "input_chars" => eligible.fetch(1).to_i },
      "eligible_pending_count" => eligible.fetch(0).to_i,
      "eligible_pending_chars" => eligible.fetch(1).to_i,
      "pending" => { "count" => pending_only.fetch(0).to_i, "input_chars" => pending_only.fetch(1).to_i },
      "pending_count" => pending_only.fetch(0).to_i,
      "pending_input_chars" => pending_only.fetch(1).to_i,
      "active_job" => active,
      "daily_budget" => { "limit" => limit, "used" => budget, "remaining" => [limit - budget, 0].max },
      "daily_budget_used" => budget,
      "daily_budget_remaining" => [limit - budget, 0].max,
      "last_updated_at" => last_update,
      "last_update" => last_update,
      "fulltext_boundary" => "metadata-only title and short summary translation; full text remains rights-gated in local_article_archive"
    }
  rescue LocalRadarStore::Error
    raise
  rescue StandardError => error
    raise Error, "translation status failed: #{error.message}"
  end

  def active_translation_batch_job
    return nil unless relation_exists?("local_translation_batch_job")
    recover_stale_translation_batch_jobs!
    rows = query(<<~SQL)
      SELECT job_id, singleton_key, owner_id, state, requested_limit, daily_character_limit,
             queued_count, examined_count, translated_count, failed_count, blocked_count,
             input_chars, error_reason, started_at::text, heartbeat_at::text,
             lease_expires_at::text, finished_at::text, updated_at::text
        FROM local_translation_batch_job
       WHERE singleton_key='metadata' AND state='running'
       ORDER BY started_at DESC, job_id DESC
       LIMIT 1
    SQL
    return nil if rows.empty?
    row_to_hash(rows.fetch(0), %w[job_id singleton_key owner_id state requested_limit daily_character_limit queued_count examined_count translated_count failed_count blocked_count input_chars error_reason started_at heartbeat_at lease_expires_at finished_at updated_at]).tap do |job|
      %w[requested_limit daily_character_limit queued_count examined_count translated_count failed_count blocked_count input_chars].each { |key| job[key] = job.fetch(key).to_i }
    end
  end

  def recover_stale_translation_batch_jobs!(now: nil)
    return [] unless relation_exists?("local_translation_batch_job")
    now_literal = now ? literal(now) : "now()"
    rows = execute(<<~SQL)
      UPDATE local_translation_batch_job
         SET state='interrupted', error_reason='worker lease expired before batch completion',
             finished_at=#{now_literal}, heartbeat_at=#{now_literal}, lease_expires_at=#{now_literal}, updated_at=#{now_literal}
       WHERE singleton_key='metadata' AND state='running' AND lease_expires_at < #{now_literal}
       RETURNING job_id
    SQL
    rows
  end

  def start_translation_batch_job!(limit:, daily_character_limit:, owner: nil, job_id: nil)
    requested_limit = Integer(limit)
    raise Error, "metadata translation limit must be between 1 and #{METADATA_TRANSLATION_MAX_LIMIT}" unless requested_limit.between?(1, METADATA_TRANSLATION_MAX_LIMIT)
    budget = Integer(daily_character_limit)
    raise Error, "metadata translation daily character limit must be between 1 and #{METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT}" unless budget.between?(1, METADATA_TRANSLATION_DAILY_CHARACTER_LIMIT)
    owner_id = normalized_translation_owner(owner)
    id = job_id.to_s.empty? ? "metadata-translation-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-#{SecureRandom.hex(6)}" : job_id.to_s
    recover_stale_translation_batch_jobs!
    # Reconcile expired item leases before attempting the singleton insert;
    # the partial unique index still protects against races.
    recover_stale_metadata_translation_runs!(owner: owner_id)
    transaction do
      rows = execute(<<~SQL)
        INSERT INTO local_translation_batch_job
          (job_id, singleton_key, owner_id, state, requested_limit, daily_character_limit)
        VALUES (#{literal(id)}, 'metadata', #{literal(owner_id)}, 'running', #{requested_limit}, #{budget})
        RETURNING job_id
      SQL
      raise Error, "translation batch job is already active" if rows.empty?
      id
    end
  rescue LocalRadarStore::Error => error
    raise unless error.message.include?("duplicate key") || error.message.include?("already active")
    raise Error, "translation batch job is already active"
  end

  def heartbeat_translation_batch_job!(job_id:, owner:, lease_seconds: METADATA_TRANSLATION_LEASE_SECONDS)
    owner_id = normalized_translation_owner(owner)
    seconds = Integer(lease_seconds)
    rows = execute("UPDATE local_translation_batch_job SET heartbeat_at=now(),lease_expires_at=now() + (#{seconds} * interval '1 second'),updated_at=now() WHERE job_id=#{literal(job_id)} AND state='running' AND owner_id=#{literal(owner_id)} RETURNING job_id")
    raise Error, "translation batch job heartbeat is not owned" if rows.empty?
    true
  end

  def update_translation_batch_job!(job_id:, owner:, counters: {})
    owner_id = normalized_translation_owner(owner)
    allowed = %w[queued_count examined_count translated_count failed_count blocked_count input_chars]
    assignments = allowed.select { |key| counters.key?(key) }.map { |key| "#{key}=#{Integer(counters.fetch(key))}" }
    assignments << "updated_at=now()"
    rows = execute("UPDATE local_translation_batch_job SET #{assignments.join(', ')} WHERE job_id=#{literal(job_id)} AND state='running' AND owner_id=#{literal(owner_id)} RETURNING job_id")
    raise Error, "translation batch job update is not owned" if rows.empty?
    true
  end

  def finish_translation_batch_job!(job_id:, owner:, state: "succeeded", counters: {}, error_reason: "")
    raise Error, "invalid translation batch job terminal state" unless %w[succeeded failed blocked interrupted].include?(state.to_s)
    owner_id = normalized_translation_owner(owner)
    allowed = %w[queued_count examined_count translated_count failed_count blocked_count input_chars]
    assignments = allowed.select { |key| counters.key?(key) }.map { |key| "#{key}=#{Integer(counters.fetch(key))}" }
    assignments += ["state=#{literal(state)}", "error_reason=#{literal(error_reason.to_s[0, 1000])}", "finished_at=now()", "heartbeat_at=now()", "lease_expires_at=now()", "updated_at=now()"]
    rows = execute("UPDATE local_translation_batch_job SET #{assignments.join(', ')} WHERE job_id=#{literal(job_id)} AND state='running' AND owner_id=#{literal(owner_id)} RETURNING job_id")
    raise Error, "translation batch job finish is not owned" if rows.empty?
    true
  end

  def fail_translation_batch_job!(job_id:, owner:, reason:)
    finish_translation_batch_job!(job_id: job_id, owner: owner, state: "failed", error_reason: reason)
  end

  def save_translation_artifact!(artifact:)
    required = %w[artifact_id source_version_id item_key source_language target_language original_content_hash provider model translated_title translated_summary validation_status status]
    missing = required.reject { |key| artifact.key?(key) && !artifact.fetch(key).to_s.empty? }
    raise Error, "translation artifact fields missing: #{missing.join(',')}" unless missing.empty?
    execute(<<~SQL)
      INSERT INTO local_translation_artifact
        (artifact_id, source_version_id, item_key, source_language, target_language, original_content_hash, provider, model,
         translated_title, translated_summary, validation_status, status, error_reason, created_at)
      VALUES (#{literal(artifact.fetch("artifact_id"))}, #{literal(artifact.fetch("source_version_id"))}, #{literal(artifact.fetch("item_key"))}, #{literal(artifact.fetch("source_language"))},
              #{literal(artifact.fetch("target_language"))}, #{literal(artifact.fetch("original_content_hash"))}, #{literal(artifact.fetch("provider"))},
              #{literal(artifact.fetch("model"))}, #{literal(artifact.fetch("translated_title"))}, #{literal(artifact.fetch("translated_summary"))},
              #{literal(artifact.fetch("validation_status"))}, #{literal(artifact.fetch("status"))}, #{literal(artifact.fetch("error_reason", ""))}, now())
      ON CONFLICT (item_key, target_language, original_content_hash, provider, model) DO NOTHING
    SQL
    rows = query("SELECT artifact_id, source_version_id, translated_title, translated_summary, validation_status, status, error_reason FROM local_translation_artifact WHERE item_key=#{literal(artifact.fetch("item_key"))} AND target_language=#{literal(artifact.fetch("target_language"))} AND original_content_hash=#{literal(artifact.fetch("original_content_hash"))} AND provider=#{literal(artifact.fetch("provider"))} AND model=#{literal(artifact.fetch("model"))}")
    raise Error, "translation artifact was not persisted" if rows.empty?
    actual = rows.fetch(0).split("\t", -1)
    expected = %w[artifact_id source_version_id translated_title translated_summary validation_status status].map { |key| artifact.fetch(key).to_s } + [artifact.fetch("error_reason", "").to_s]
    raise Error, "translation artifact immutable payload differs" unless actual == expected
    artifact
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "translation artifact save is incomplete: #{error.message}"
  end

  def article_archive_candidates(limit: 20, include_terminal: false)
    return [] unless relation_exists?("local_article_archive_attempt")
    terminal_clause = include_terminal ? "" : " AND a.source_version_id IS NULL"
    query(<<~SQL).map do |row|
      SELECT v.version_id, v.item_key, v.source_id, v.source_name, v.language,
             v.title, v.summary, v.source_url, v.content_hash, v.published_at::text,
             c.rights_scope,
             CASE WHEN c.rights_scope = 'full_archive' THEN 'full_archive'
                  WHEN c.rights_scope IN ('excerpt_only', 'metadata_short_summary_link') THEN 'excerpt_only'
                  ELSE 'link_only' END
        FROM local_source_item_version v
        JOIN local_source_capture c ON c.capture_id = v.capture_id
        LEFT JOIN local_article_archive_attempt a ON a.source_version_id = v.version_id
          AND a.rights_scope = CASE WHEN c.rights_scope = 'full_archive' THEN 'full_archive'
                                    WHEN c.rights_scope IN ('excerpt_only', 'metadata_short_summary_link') THEN 'excerpt_only'
                                    ELSE 'link_only' END
       WHERE 1 = 1#{terminal_clause}
       ORDER BY v.created_at DESC, v.version_id ASC
       LIMIT #{Integer(limit)}
    SQL
      row_to_hash(row, %w[version_id item_key source_id source_name language title summary source_url content_hash published_at rights_scope archive_rights_scope])
    end
  end

  def save_article_archive_result!(attempt:, archive: nil)
    required = %w[attempt_id source_version_id rights_scope outcome fetched_at final_url content_type response_bytes error_reason]
    missing = required.reject { |key| attempt.key?(key) }
    raise Error, "article archive attempt fields missing: #{missing.join(',')}" unless missing.empty?
    transaction do
      execute(<<~SQL)
        INSERT INTO local_article_archive_attempt
          (attempt_id, source_version_id, rights_scope, outcome, http_status, fetched_at,
           final_url, content_type, response_bytes, error_reason)
        VALUES (#{literal(attempt.fetch("attempt_id"))}, #{literal(attempt.fetch("source_version_id"))},
                #{literal(attempt.fetch("rights_scope"))}, #{literal(attempt.fetch("outcome"))},
                #{attempt.fetch("http_status").nil? ? "NULL" : Integer(attempt.fetch("http_status"))},
                #{literal(attempt.fetch("fetched_at"))}, #{literal(attempt.fetch("final_url"))},
                #{literal(attempt.fetch("content_type"))}, #{Integer(attempt.fetch("response_bytes"))},
                #{literal(attempt.fetch("error_reason"))})
        ON CONFLICT (source_version_id, rights_scope) DO NOTHING
      SQL
      if archive
        archive_required = %w[archive_id attempt_id source_version_id source_url final_url source_language title body_text image_captions extraction_method extractor_version body_hash body_chars archived_at]
        archive_missing = archive_required.reject { |key| archive.key?(key) }
        raise Error, "article archive fields missing: #{archive_missing.join(',')}" unless archive_missing.empty?
        execute(<<~SQL)
          INSERT INTO local_article_archive
            (archive_id, attempt_id, source_version_id, source_url, final_url, source_language,
             title, body_text, image_captions, extraction_method, extractor_version,
             body_hash, body_chars, archived_at)
          VALUES (#{literal(archive.fetch("archive_id"))}, #{literal(archive.fetch("attempt_id"))},
                  #{literal(archive.fetch("source_version_id"))}, #{literal(archive.fetch("source_url"))},
                  #{literal(archive.fetch("final_url"))}, #{literal(archive.fetch("source_language"))},
                  #{literal(archive.fetch("title"))}, #{literal(archive.fetch("body_text"))},
                  #{literal(JSON.generate(archive.fetch("image_captions")))}::jsonb,
                  #{literal(archive.fetch("extraction_method"))}, #{literal(archive.fetch("extractor_version"))},
                  #{literal(archive.fetch("body_hash"))}, #{Integer(archive.fetch("body_chars"))},
                  #{literal(archive.fetch("archived_at"))})
          ON CONFLICT (source_version_id) DO NOTHING
        SQL
      end
    end
    archive || attempt
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "article archive save is incomplete: #{error.message}"
  end

  def ensure_article_translation_runs!(provider: "deepseek", model: "deepseek-v4-pro",
                                       prompt_version: "full-article-translation-v1")
    return 0 unless relation_exists?("local_article_archive")
    archives = query("SELECT archive_id, body_hash FROM local_article_archive ORDER BY created_at ASC, archive_id ASC")
    rows = []
    archives.each do |row|
      archive_id, body_hash = row.split("\t", -1)
      run_id = Digest::SHA256.hexdigest([archive_id, prompt_version, model].join("\0"))
      rows.concat(execute(<<~SQL))
      INSERT INTO local_article_translation_run
        (run_id, archive_id, target_language, provider, model, prompt_version,
         source_body_hash, state, input_chars)
      SELECT #{literal(run_id)}, a.archive_id, 'zh-CN', #{literal(provider)}, #{literal(model)},
             #{literal(prompt_version)}, a.body_hash, 'pending', a.body_chars
        FROM local_article_archive a
       WHERE a.archive_id = #{literal(archive_id)} AND a.body_hash = #{literal(body_hash)}
      RETURNING run_id
    SQL
    end
    rows.length
  end

  def article_translation_candidates(limit: 10, daily_character_limit: 200_000)
    return [] unless relation_exists?("local_article_translation_run")
    used = execute("SELECT COALESCE(SUM(input_chars),0) FROM local_article_translation_run WHERE started_at >= date_trunc('day', now()) AND state IN ('running','succeeded','failed')").fetch(0).to_i
    remaining = [Integer(daily_character_limit) - used, 0].max
    return [] if remaining.zero?
    candidates = query(<<~SQL).map do |row|
      SELECT r.run_id, r.archive_id, r.source_body_hash, r.input_chars,
             a.source_version_id, a.source_language, a.title, v.summary,
             a.body_text, a.image_captions::text
        FROM local_article_translation_run r
        JOIN local_article_archive a ON a.archive_id = r.archive_id
        JOIN local_source_item_version v ON v.version_id = a.source_version_id
       WHERE r.state IN ('pending', 'failed', 'credential_blocked', 'budget_blocked')
         AND r.attempt_count < 3
       ORDER BY r.created_at ASC, r.run_id ASC
       LIMIT #{Integer(limit)}
    SQL
      row_to_hash(row, %w[run_id archive_id source_body_hash input_chars source_version_id source_language title summary body_text image_captions]).tap do |item|
        item["input_chars"] = item.fetch("input_chars").to_i
        item["image_captions"] = JSON.parse(item.fetch("image_captions"))
      end
    end
    total = 0
    candidates.take_while { |item| total += item.fetch("input_chars"); total <= remaining }
  end

  def start_article_translation!(run_id:)
    rows = execute("UPDATE local_article_translation_run SET state='running', attempt_count=attempt_count+1, started_at=now(), finished_at=NULL, error_reason='', updated_at=now() WHERE run_id=#{literal(run_id)} AND state IN ('pending','failed','credential_blocked','budget_blocked') RETURNING run_id")
    raise Error, "article translation run is not claimable" if rows.empty?
    true
  end

  def finish_article_translation!(run_id:, result:, validation_status:)
    artifact_id = Digest::SHA256.hexdigest([run_id, result.fetch("translated_body")].join("\0"))
    output_hash = Digest::SHA256.hexdigest(JSON.generate(result.slice("translated_title", "translated_summary", "translated_body", "translated_image_captions")))
    transaction do
      execute(<<~SQL)
        INSERT INTO local_article_translation_artifact
          (artifact_id, run_id, archive_id, source_body_hash, target_language, provider, model,
           prompt_version, translated_title, translated_summary, translated_body,
           translated_image_captions, output_hash, validation_status)
        SELECT #{literal(artifact_id)}, r.run_id, r.archive_id, r.source_body_hash, r.target_language,
               r.provider, r.model, r.prompt_version, #{literal(result.fetch("translated_title"))},
               #{literal(result.fetch("translated_summary"))}, #{literal(result.fetch("translated_body"))},
               #{literal(JSON.generate(result.fetch("translated_image_captions")))}::jsonb,
               #{literal(output_hash)}, #{literal(validation_status)}
          FROM local_article_translation_run r WHERE r.run_id = #{literal(run_id)}
        ON CONFLICT (run_id) DO NOTHING
      SQL
      usage = result.fetch("usage", {})
      execute("UPDATE local_article_translation_run SET state='succeeded', prompt_tokens=#{Integer(usage.fetch("prompt_tokens", 0))}, completion_tokens=#{Integer(usage.fetch("completion_tokens", 0))}, finished_at=now(), updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running'")
    end
    artifact_id
  end

  def fail_article_translation!(run_id:, state:, reason:)
    raise Error, "article translation failure state is invalid" unless %w[failed credential_blocked budget_blocked].include?(state.to_s)
    execute("UPDATE local_article_translation_run SET state=#{literal(state)}, error_reason=#{literal(reason.to_s[0, 1000])}, finished_at=now(), updated_at=now() WHERE run_id=#{literal(run_id)} AND state='running'")
    true
  end

  def block_article_translation_for_credentials!(run_id:, reason:)
    rows = execute("UPDATE local_article_translation_run SET state='credential_blocked', error_reason=#{literal(reason.to_s[0, 1000])}, finished_at=now(), updated_at=now() WHERE run_id=#{literal(run_id)} AND state IN ('pending','failed','credential_blocked','budget_blocked') RETURNING run_id")
    raise Error, "article translation run cannot be credential-blocked" if rows.empty?
    true
  end

  def next_revision(surface_id: "public-radar")
    query("SELECT COALESCE(MAX(revision), 0) + 1 FROM local_radar_snapshot WHERE surface_id = #{literal(surface_id)}").fetch(0).to_i
  end

  # Comparison watermarks belong to the signal lane.  Locale exploration
  # captures are deliberately ignored; when a locale-only batch is published
  # the prior signal watermark is retained, or an explicit non-time sentinel
  # is returned before the first signal snapshot exists.
  def signal_comparison_watermark(items:)
    signal_times = Array(items).select { |item| item.fetch("analysis_policy", "signal_eligible").to_s == "signal_eligible" }
      .map { |item| item.fetch("capture_captured_at", item.fetch("captured_at", "")).to_s }
      .reject(&:empty?)
    return signal_times.min unless signal_times.empty?

    prior = query(<<~SQL).fetch(0, "").to_s
      SELECT comparison_watermark
        FROM local_radar_snapshot
       WHERE snapshot_status = 'published'
       ORDER BY revision DESC
       LIMIT 1
    SQL
    prior.empty? ? "no_signal_eligible_capture" : prior
  end

  def publish_snapshot!(snapshot:, cards:, trends: [], event_candidates: [], exploration_items: [], batch_id: nil)
    required = %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch render_plan_hash]
    missing = required.reject { |key| snapshot.key?(key) && !snapshot.fetch(key).to_s.empty? }
    raise Error, "snapshot fields missing: #{missing.join(',')}" unless missing.empty?
    breadth = breadth_schema_available?
    projection_status = snapshot.fetch("signal_projection_status", "fresh_batch").to_s
    projection_source = snapshot.fetch("signal_source_snapshot_id", nil)
    if breadth
      raise Error, "signal projection status is invalid" unless %w[fresh_batch reused_previous].include?(projection_status)
      if projection_status == "fresh_batch"
        raise Error, "fresh signal projection cannot name a prior snapshot" unless projection_source.nil? || projection_source.to_s.empty?
        projection_source = nil
      else
        raise Error, "reused signal projection requires a prior snapshot" if projection_source.to_s.empty?
      end
    else
      projection_status = "fresh_batch"
      projection_source = nil
    end
    rows = Array(cards)
    raise Error, "at least one radar card is required" if rows.empty?

    transaction do
      validate_batch_projection_mode!(batch_id: batch_id, projection_status: projection_status) if breadth && batch_id
      if breadth && projection_status == "reused_previous"
        validate_reused_signal_projection!(source_snapshot_id: projection_source, snapshot: snapshot, cards: rows, trends: trends, event_candidates: event_candidates)
      end
      execute(<<~SQL)
        INSERT INTO local_radar_snapshot
          (snapshot_id, surface_id, revision, comparison_watermark, method_epoch, rights_epoch, render_plan_hash, snapshot_status#{breadth ? ", signal_projection_status, signal_source_snapshot_id" : ""})
        VALUES (#{literal(snapshot.fetch("snapshot_id"))}, #{literal(snapshot.fetch("surface_id"))}, #{Integer(snapshot.fetch("revision"))},
                #{literal(snapshot.fetch("comparison_watermark"))}, #{literal(snapshot.fetch("method_epoch"))}, #{Integer(snapshot.fetch("rights_epoch"))},
                #{literal(snapshot.fetch("render_plan_hash"))}, 'published'#{breadth ? ", #{literal(projection_status)}, #{projection_source.nil? ? "NULL" : literal(projection_source)}" : ""})
      SQL
      rows.each do |card|
        execute(<<~SQL)
          INSERT INTO local_radar_card
            (card_id, snapshot_id, signal_type, title, summary, metric_label, metric_value, source_count, stance, action_stage,
             evidence_label, source_name, source_url, source_language, source_region, original_title, original_summary,
             translation_status, translation_artifact_id, translated_at, source_item_key, source_version_id, source_content_hash, sort_order)
          VALUES (#{literal(card.fetch("card_id"))}, #{literal(snapshot.fetch("snapshot_id"))}, #{literal(card.fetch("signal_type"))},
                  #{literal(card.fetch("title"))}, #{literal(card.fetch("summary"))}, #{literal(card.fetch("metric_label"))}, #{literal(card.fetch("metric_value"))},
                  #{Integer(card.fetch("source_count"))}, #{literal(card.fetch("stance"))}, #{literal(card.fetch("action_stage"))},
                  #{literal(card.fetch("evidence_label"))}, #{literal(card.fetch("source_name", ""))}, #{literal(card.fetch("source_url", ""))},
                  #{literal(card.fetch("source_language", ""))}, #{literal(card.fetch("source_region", ""))},
                  #{literal(card.fetch("original_title", ""))}, #{literal(card.fetch("original_summary", ""))},
                  #{literal(card.fetch("translation_status", "not_needed"))}, #{literal(card.fetch("translation_artifact_id", ""))},
                  #{card.fetch("translated_at", nil).to_s.empty? ? "NULL" : literal(card.fetch("translated_at"))},
                  #{card.fetch("source_item_key", nil).to_s.empty? ? "NULL" : literal(card.fetch("source_item_key"))},
                  #{card.fetch("source_version_id", nil).to_s.empty? ? "NULL" : literal(card.fetch("source_version_id"))},
                  #{literal(card.fetch("source_content_hash", ""))}, #{Integer(card.fetch("sort_order"))})
        SQL
      end
      Array(trends).each do |trend|
        execute(<<~SQL)
          INSERT INTO local_radar_trend
            (trend_id, snapshot_id, topic_key, topic, topic_language, topic_kind, semantic_status, topic_label, topic_explanation, signal_state, summary,
             mention_count, recent_mention_count, prior_mention_count, source_count,
             region_count, language_count, growth_rate, window_hours, recent_window_hours,
             window_start, window_end, source_names, regions, languages, evidence_urls, sort_order)
          VALUES (#{literal(trend.fetch("trend_id"))}, #{literal(snapshot.fetch("snapshot_id"))}, #{literal(trend.fetch("topic_key"))},
                  #{literal(trend.fetch("topic"))}, #{literal(trend.fetch("topic_language"))}, #{literal(trend.fetch("topic_kind", "term"))},
                  #{literal(trend.fetch("semantic_status", "statistical_candidate"))}, #{literal(trend.fetch("topic_label", ""))}, #{literal(trend.fetch("topic_explanation", ""))},
                  #{literal(trend.fetch("signal_state"))},
                  #{literal(trend.fetch("summary"))}, #{Integer(trend.fetch("mention_count"))}, #{Integer(trend.fetch("recent_mention_count"))},
                  #{Integer(trend.fetch("prior_mention_count"))}, #{Integer(trend.fetch("source_count"))}, #{Integer(trend.fetch("region_count"))},
                  #{Integer(trend.fetch("language_count"))}, #{trend.fetch("growth_rate", nil).to_s.empty? ? "NULL" : Float(trend.fetch("growth_rate"))},
                  #{Integer(trend.fetch("window_hours"))}, #{Integer(trend.fetch("recent_window_hours"))},
                  #{literal(trend.fetch("window_start"))}, #{literal(trend.fetch("window_end"))},
                  #{literal(JSON.generate(Array(trend.fetch("source_names", []))))}::jsonb,
                  #{literal(JSON.generate(Array(trend.fetch("regions", []))))}::jsonb,
                  #{literal(JSON.generate(Array(trend.fetch("languages", []))))}::jsonb,
                  #{literal(JSON.generate(Array(trend.fetch("evidence_urls", []))))}::jsonb,
                  #{Integer(trend.fetch("sort_order"))})
        SQL
      end
      Array(event_candidates).each_with_index do |candidate, index|
        validate_event_candidate!(candidate)
        candidate_id = candidate.fetch("candidate_id", "#{snapshot.fetch("snapshot_id")}-event-candidate-#{Digest::SHA256.hexdigest(candidate.fetch("candidate_key"))[0, 12]}")
        qualifying_source_count = Integer(candidate.fetch("qualifying_source_count"))
        raise Error, "event candidate requires at least two qualifying publishers" if qualifying_source_count < 2
        execute(<<~SQL)
          INSERT INTO local_event_candidate
            (candidate_id, snapshot_id, candidate_key, candidate_status, label, language, matching_method, explanation,
             member_count, dedup_source_count, qualifying_source_count, query_conditioned_evidence_count,
             first_published_at, last_published_at, time_span_hours,
             shared_anchors, shared_phrases, evidence_items, member_item_keys, qualifying_item_keys, query_item_keys, sort_order)
          VALUES (#{literal(candidate_id)}, #{literal(snapshot.fetch("snapshot_id"))}, #{literal(candidate.fetch("candidate_key"))},
                  #{literal(candidate.fetch("candidate_status"))}, #{literal(candidate.fetch("label"))}, #{literal(candidate.fetch("language"))},
                  #{literal(candidate.fetch("matching_method", "deterministic_anchor_similarity_v1"))}, #{literal(candidate.fetch("explanation", ""))},
                  #{Integer(candidate.fetch("member_count"))}, #{Integer(candidate.fetch("dedup_source_count"))}, #{qualifying_source_count}, #{Integer(candidate.fetch("query_conditioned_evidence_count"))},
                  #{literal(candidate.fetch("first_published_at"))},
                  #{literal(candidate.fetch("last_published_at"))}, #{candidate.fetch("time_span_hours").to_f},
                  #{literal(JSON.generate(Array(candidate.fetch("shared_anchors", []))))}::jsonb,
                  #{literal(JSON.generate(Array(candidate.fetch("shared_phrases", []))))}::jsonb,
                  #{literal(JSON.generate(Array(candidate.fetch("evidence_items", []))))}::jsonb,
                  #{literal(JSON.generate(Array(candidate.fetch("member_item_keys", []))))}::jsonb,
                  #{literal(JSON.generate(Array(candidate.fetch("qualifying_item_keys", []))))}::jsonb,
                  #{literal(JSON.generate(Array(candidate.fetch("query_item_keys", []))))}::jsonb,
                  #{Integer(candidate.fetch("sort_order", index))})
        SQL
      end
      if batch_id
        raise Error, "exploration membership requires batch_id" if batch_id.to_s.empty?
        publish_exploration_memberships!(snapshot_id: snapshot.fetch("snapshot_id"), batch_id: batch_id, memberships: exploration_items)
      end
    end
    current_radar
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "snapshot publish is incomplete: #{error.message}"
  end

  private

  # A batch with planned locale-frontier sources is an exploration-only
  # publication. It must carry an explicit reused_previous signal projection;
  # no timestamp proximity or unrelated signal version can authorize a fresh
  # projection. The source-set contract is locked in the same transaction as
  # the snapshot insert to avoid a registry TOCTOU window.
  def validate_batch_projection_mode!(batch_id:, projection_status:)
    rows = query(<<~SQL)
      SELECT r.discovery_basis, r.query_conditioned::text, r.analysis_policy
        FROM local_collection_batch_source bs
        JOIN local_source_registry r ON r.source_id = bs.source_id
       WHERE bs.batch_id = #{literal(batch_id)}
       ORDER BY bs.sort_order ASC
       FOR SHARE
    SQL
    return if rows.empty?

    contracts = rows.map { |row| row.split("\t", -1) }
    locale_batch = contracts.all? { |basis, query, policy| basis == "locale_headlines" && !truthy_value?(query) && policy == "exploration_only" }
    raise Error, "collection batch contains non-locale source contract" unless locale_batch
    raise Error, "locale exploration batch requires reused_previous signal projection" unless projection_status == "reused_previous"
  end

  # Reused signal projections are a lineage claim, not a caller-controlled
  # label.  Lock the current head and compare every signal semantic field;
  # only record IDs and the destination snapshot ID may change.
  def validate_reused_signal_projection!(source_snapshot_id:, snapshot:, cards:, trends:, event_candidates:)
    source_rows = query(<<~SQL)
      SELECT snapshot_id, surface_id, revision, comparison_watermark, method_epoch, rights_epoch
        FROM local_radar_snapshot
       WHERE snapshot_id = #{literal(source_snapshot_id)}
         AND snapshot_status = 'published'
       FOR SHARE
    SQL
    raise Error, "reused signal projection source is not published" if source_rows.empty?
    source = row_to_hash(source_rows.fetch(0), %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch])
    head_rows = query(<<~SQL)
      SELECT snapshot_id, revision
        FROM local_radar_snapshot
       WHERE surface_id = #{literal(snapshot.fetch("surface_id"))}
         AND snapshot_status = 'published'
       ORDER BY revision DESC, snapshot_id ASC
       LIMIT 1
       FOR SHARE
    SQL
    raise Error, "reused signal projection head is missing" if head_rows.empty?
    head = row_to_hash(head_rows.fetch(0), %w[snapshot_id revision])
    raise Error, "reused signal projection source is not current head" unless head.fetch("snapshot_id") == source.fetch("snapshot_id")
    raise Error, "reused signal projection revision is not the next head" unless Integer(snapshot.fetch("revision")) == source.fetch("revision").to_i + 1
    %w[surface_id comparison_watermark method_epoch rights_epoch].each do |field|
      raise Error, "reused signal projection #{field} differs from source" unless snapshot.fetch(field).to_s == source.fetch(field).to_s
    end

    prior_cards = query(<<~SQL).map do |row|
      SELECT signal_type, title, summary, metric_label, metric_value, source_count, stance, action_stage,
             evidence_label, source_name, source_url, source_language, source_region, original_title,
             original_summary, translation_status, translation_artifact_id, translated_at::text, sort_order,
             source_item_key, source_version_id, source_content_hash
        FROM local_radar_card
       WHERE snapshot_id = #{literal(source_snapshot_id)}
       ORDER BY sort_order ASC
    SQL
      row_to_hash(row, %w[signal_type title summary metric_label metric_value source_count stance action_stage evidence_label source_name source_url source_language source_region original_title original_summary translation_status translation_artifact_id translated_at sort_order source_item_key source_version_id source_content_hash])
    end
    prior_trends = query(<<~SQL).map do |row|
      SELECT topic_key, topic, topic_language, topic_kind, semantic_status, topic_label, topic_explanation, signal_state,
             summary, mention_count, recent_mention_count, prior_mention_count, source_count, region_count, language_count,
             growth_rate::text, window_hours, recent_window_hours, window_start::text, window_end::text,
             source_names::text, regions::text, languages::text, evidence_urls::text, sort_order
        FROM local_radar_trend
       WHERE snapshot_id = #{literal(source_snapshot_id)}
       ORDER BY sort_order ASC
    SQL
      row_to_hash(row, %w[topic_key topic topic_language topic_kind semantic_status topic_label topic_explanation signal_state summary mention_count recent_mention_count prior_mention_count source_count region_count language_count growth_rate window_hours recent_window_hours window_start window_end source_names regions languages evidence_urls sort_order])
    end
    prior_events = query(<<~SQL).map do |row|
      SELECT candidate_status, label, language, matching_method, explanation, member_count, dedup_source_count,
             qualifying_source_count, query_conditioned_evidence_count, first_published_at::text, last_published_at::text,
             time_span_hours::text, shared_anchors::text, shared_phrases::text, evidence_items::text,
             member_item_keys::text, qualifying_item_keys::text, query_item_keys::text, sort_order
        FROM local_event_candidate
       WHERE snapshot_id = #{literal(source_snapshot_id)}
       ORDER BY sort_order ASC
    SQL
      row_to_hash(row, %w[candidate_status label language matching_method explanation member_count dedup_source_count qualifying_source_count query_conditioned_evidence_count first_published_at last_published_at time_span_hours shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys sort_order])
    end
    unless normalize_signal_cards(cards) == normalize_signal_cards(prior_cards) &&
           normalize_signal_trends(trends) == normalize_signal_trends(prior_trends) &&
           normalize_signal_events(event_candidates) == normalize_signal_events(prior_events)
      raise Error, "reused signal projection differs from source snapshot"
    end
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "reused signal projection is incomplete: #{error.message}"
  end

  def normalize_signal_cards(rows)
    keys = %w[signal_type title summary metric_label metric_value source_count stance action_stage evidence_label source_name source_url source_language source_region original_title original_summary translation_status translation_artifact_id translated_at sort_order source_item_key source_version_id source_content_hash]
    Array(rows).map do |row|
      values = keys.each_with_object({}) { |key, result| result[key] = row.fetch(key, "") }
      values["translation_status"] = "not_needed" if values.fetch("translation_status").to_s.empty?
      values["source_count"] = Integer(values.fetch("source_count"))
      values["sort_order"] = Integer(values.fetch("sort_order"))
      values["translated_at"] = nil if values.fetch("translated_at").to_s.empty?
      values["translated_at"] = Time.parse(values.fetch("translated_at").to_s).utc.iso8601(6) if values["translated_at"]
      values
    end.sort_by { |row| row.fetch("sort_order") }
  end

  def normalize_signal_trends(rows)
    keys = %w[topic_key topic topic_language topic_kind semantic_status topic_label topic_explanation signal_state summary mention_count recent_mention_count prior_mention_count source_count region_count language_count growth_rate window_hours recent_window_hours window_start window_end source_names regions languages evidence_urls sort_order]
    int_keys = %w[mention_count recent_mention_count prior_mention_count source_count region_count language_count window_hours recent_window_hours sort_order]
    json_keys = %w[source_names regions languages evidence_urls]
    Array(rows).map do |row|
      values = keys.each_with_object({}) { |key, result| result[key] = row.fetch(key, "") }
      values["topic_kind"] = "term" if values.fetch("topic_kind").to_s.empty?
      values["semantic_status"] = "statistical_candidate" if values.fetch("semantic_status").to_s.empty?
      int_keys.each { |key| values[key] = Integer(values.fetch(key)) }
      values["growth_rate"] = nil if values.fetch("growth_rate").to_s.empty?
      %w[window_start window_end].each do |key|
        values[key] = values.fetch(key).to_s.empty? ? nil : Time.parse(values.fetch(key).to_s).utc.iso8601(6)
      end
      json_keys.each { |key| values[key] = values.fetch(key).is_a?(String) ? parse_json_array(values.fetch(key)) : Array(values.fetch(key)) }
      values
    end.sort_by { |row| row.fetch("sort_order") }
  end

  def normalize_signal_events(rows)
    keys = %w[candidate_status label language matching_method explanation member_count dedup_source_count qualifying_source_count query_conditioned_evidence_count first_published_at last_published_at time_span_hours shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys sort_order]
    int_keys = %w[member_count dedup_source_count qualifying_source_count query_conditioned_evidence_count sort_order]
    json_keys = %w[shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys]
    Array(rows).map do |row|
      values = keys.each_with_object({}) { |key, result| result[key] = row.fetch(key, "") }
      int_keys.each { |key| values[key] = Integer(values.fetch(key)) }
      values["time_span_hours"] = Float(values.fetch("time_span_hours"))
      %w[first_published_at last_published_at].each do |key|
        values[key] = values.fetch(key).to_s.empty? ? nil : Time.parse(values.fetch(key).to_s).utc.iso8601(6)
      end
      json_keys.each { |key| values[key] = values.fetch(key).is_a?(String) ? parse_json_value(values.fetch(key)) : values.fetch(key) }
      values
    end.sort_by { |row| row.fetch("sort_order") }
  end

  def normalize_source_contract(source)
    inferred_query = truthy_value?(source.fetch("query_conditioned", false))
    source_kind = source.fetch("source_kind", inferred_query ? "discovery" : "configured").to_s
    basis = source.fetch("discovery_basis", truthy_value?(source.fetch("query_conditioned", false)) ? "topic_query" : "editorial_feed").to_s
    policy = source.fetch("analysis_policy", basis == "locale_headlines" ? "exploration_only" : "signal_eligible").to_s
    query_conditioned = truthy_value?(source.fetch("query_conditioned", basis == "topic_query"))
    topics = source.fetch("query_topics", [])
    raise Error, "source query_topics must be an array" unless topics.is_a?(Array)
    raise Error, "source discovery_basis is invalid" unless DISCOVERY_BASES.include?(basis)
    raise Error, "source analysis_policy is invalid" unless ANALYSIS_POLICIES.include?(policy)
    if basis == "locale_headlines"
      raise Error, "locale_headlines source contract is invalid" unless source_kind == "discovery" && !query_conditioned && policy == "exploration_only"
      raise Error, "locale_headlines source contract is incomplete" if %w[aggregator_id locale_tag market_label].any? { |key| source.fetch(key, "").to_s.strip.empty? }
      raise Error, "locale_headlines market label basis is invalid" unless source.fetch("market_label_basis", "") == "aggregator_locale_label"
      raise Error, "locale_headlines region basis is invalid" unless source.fetch("region_basis", "aggregator_locale_label") == "aggregator_locale_label"
      raise Error, "locale_headlines publisher_region must be empty" unless source.fetch("publisher_region", "").to_s.empty?
      raise Error, "locale_headlines registry publisher_id must be empty" unless source.fetch("publisher_id", "").to_s.empty?
      raise Error, "locale_headlines query_topics must be empty" unless topics.empty?
      validate_locale_url!(source.fetch("url"), aggregator_id: source.fetch("aggregator_id", "").to_s)
    elsif basis == "topic_query"
      raise Error, "topic query source contract is invalid" unless source_kind == "discovery" && query_conditioned
      raise Error, "topic query source has no configured topics" if source.key?("discovery_basis") && topics.empty?
    elsif policy == "exploration_only"
      raise Error, "only locale_headlines may be exploration_only"
    end
    default_market_label_basis = basis == "locale_headlines" ? "aggregator_locale_label" : "editorial_scope_label"
    market_label_basis = source.fetch("market_label_basis", "").to_s
    market_label_basis = default_market_label_basis if market_label_basis.empty?
    {
      "discovery_basis" => basis, "analysis_policy" => policy,
      "query_conditioned" => query_conditioned,
      "aggregator_id" => source.fetch("aggregator_id", "").to_s,
      "locale_tag" => source.fetch("locale_tag", "").to_s,
      "market_label" => source.fetch("market_label", "").to_s,
      "market_label_basis" => market_label_basis,
      "query_topics" => topics.map(&:to_s)
    }
  rescue KeyError, TypeError => error
    raise Error, "source contract is incomplete: #{error.message}"
  end

  def source_contract_projection(source)
    contract = normalize_source_contract(source)
    {
      "source_id" => source.fetch("id").to_s,
      "source_url" => source.fetch("url").to_s,
      "source_kind" => source.fetch("source_kind", "configured").to_s,
      "discovery_basis" => contract.fetch("discovery_basis"),
      "query_conditioned" => contract.fetch("query_conditioned"),
      "analysis_policy" => contract.fetch("analysis_policy"),
      "aggregator_id" => contract.fetch("aggregator_id"),
      "locale_tag" => contract.fetch("locale_tag"),
      "market_label" => contract.fetch("market_label"),
      "market_label_basis" => contract.fetch("market_label_basis"),
      "query_topics" => contract.fetch("query_topics"),
      "enabled" => source.fetch("enabled", true)
    }
  end

  def validate_item_registry_contract!(source_id:, contract:)
    rows = query("SELECT discovery_basis, analysis_policy, aggregator_id, locale_tag, market_label, market_label_basis, query_topics::text, query_conditioned::text FROM local_source_registry WHERE source_id = #{literal(source_id)}")
    raise Error, "item source is not registered" if rows.empty?
    values = rows.fetch(0).split("\t", -1)
    expected = [contract.fetch("discovery_basis"), contract.fetch("analysis_policy"), contract.fetch("aggregator_id"), contract.fetch("locale_tag"), contract.fetch("market_label"), contract.fetch("market_label_basis")]
    actual = values[0, 6]
    raise Error, "item immutable discovery contract differs from registry" unless actual == expected && parse_json_array(values.fetch(6)) == contract.fetch("query_topics") && truthy_value?(values.fetch(7)) == contract.fetch("query_conditioned")
  end

  def assert_batch_attempts_complete!(batch_id:)
    rows = query(<<~SQL)
      SELECT
        (SELECT COUNT(*) FROM local_collection_batch_source WHERE batch_id = #{literal(batch_id)}),
        (SELECT COUNT(*) FROM local_source_fetch_attempt WHERE batch_id = #{literal(batch_id)}),
        (SELECT COUNT(*) FROM local_collection_batch_source s
          WHERE s.batch_id = #{literal(batch_id)}
            AND NOT EXISTS (SELECT 1 FROM local_source_fetch_attempt a WHERE a.batch_id = s.batch_id AND a.source_id = s.source_id))
    SQL
    values = rows.fetch(0).split("\t", -1)
    planned = values.fetch(0).to_i
    attempts = values.fetch(1).to_i
    missing = values.fetch(2).to_i
    batch = collection_batch(batch_id: batch_id)
    raise Error, "collection batch planned source count is incomplete" unless batch && planned == batch.fetch("planned_source_count").to_i && missing.zero? && attempts == planned
    true
  end

  # Insert membership only after re-reading every immutable version, capture,
  # registry contract and batch attempt.  Caller-supplied titles/summaries are
  # ignored; the API read model later joins the version rows.
  def publish_exploration_memberships!(snapshot_id:, batch_id:, memberships:)
    raise Error, "breadth schema is not installed" unless breadth_schema_available?
    batch_rows = query("SELECT batch_id, selected_count, planned_source_count, selected_set_hash, selected_order_hash, status FROM local_collection_batch WHERE batch_id = #{literal(batch_id)}")
    raise Error, "exploration batch is missing" if batch_rows.empty?
    batch = row_to_hash(batch_rows.fetch(0), %w[batch_id selected_count planned_source_count selected_set_hash selected_order_hash status])
    manifest_row = query(<<~SQL).first
      SELECT manifest_id, selected_count, delivery_status, not_a_signal::text
        FROM local_pre_detection_exploration_manifest
       WHERE batch_id = #{literal(batch_id)}
       ORDER BY created_at DESC, manifest_id ASC
       LIMIT 1
    SQL
    raise Error, "exploration selection manifest is missing" if manifest_row.nil?
    manifest = row_to_hash(manifest_row, %w[manifest_id selected_count delivery_status not_a_signal])
    raise Error, "exploration selection manifest is not unmeasured" unless manifest.fetch("delivery_status") == "unmeasured" && truthy_value?(manifest.fetch("not_a_signal"))
    selection_rows = query(<<~SQL)
      SELECT d.exploration_decision_id, d.outcome, d.selection_order, u.version_id
        FROM local_pre_detection_exploration_decision d
        JOIN local_pre_detection_exploration_unit u ON u.exploration_unit_id = d.exploration_unit_id
       WHERE d.manifest_id = #{literal(manifest.fetch("manifest_id"))}
       ORDER BY d.selection_order NULLS LAST, d.sort_order ASC
    SQL
    selections_by_version = selection_rows.to_h do |row|
      values = row.split("\t", -1)
      [values.fetch(3), { "exploration_decision_id" => values.fetch(0), "outcome" => values.fetch(1), "selection_order" => values.fetch(2) }]
    end
    entries = Array(memberships)
    allowed_membership_keys = %w[exploration_item_id version_id sort_order resolution lane reason]
    # Validate the caller envelope before deriving any hashes.  The frozen
    # order is sort_order (not the incidental array order), so a caller cannot
    # preserve the old order hash while swapping sort_order values.
    normalized_entries = entries.map do |entry|
      raise Error, "exploration membership must be an object" unless entry.is_a?(Hash)
      unexpected_keys = entry.keys.map(&:to_s) - allowed_membership_keys
      raise Error, "exploration membership contains untrusted body/lineage fields" unless unexpected_keys.empty?
      version_id = entry.fetch("version_id").to_s
      raise Error, "exploration membership version id is empty" if version_id.empty?
      sort_order = Integer(entry.fetch("sort_order"))
      raise Error, "exploration membership sort order is negative" if sort_order.negative?
      entry.merge("version_id" => version_id, "sort_order" => sort_order)
    rescue KeyError, ArgumentError, TypeError => error
      raise Error, "exploration membership is incomplete: #{error.message}"
    end
    ordered_entries = normalized_entries.sort_by { |entry| [entry.fetch("sort_order"), entry.fetch("version_id")] }
    raise Error, "exploration membership sort order is not contiguous or duplicated" unless ordered_entries.each_with_index.all? { |entry, index| entry.fetch("sort_order") == index }
    ids = ordered_entries.map { |entry| entry.fetch("version_id") }
    raise Error, "exploration membership version ids are empty or duplicated" if ids.uniq.length != ids.length
    raise Error, "exploration membership requires frozen selection" unless batch.fetch("status") == "frozen"
    assert_batch_attempts_complete!(batch_id: batch_id)
    if !batch.fetch("selected_set_hash").to_s.empty? && selected_set_hash(version_ids: ids) != batch.fetch("selected_set_hash")
      raise Error, "exploration membership set differs from frozen batch selection"
    end
    raise Error, "exploration membership order differs from frozen batch selection" unless selected_order_hash(version_ids: ids) == batch.fetch("selected_order_hash")
    raise Error, "exploration membership count differs from frozen batch" if batch.fetch("selected_count").to_i.positive? && ids.length != batch.fetch("selected_count").to_i
    if entries.empty?
      raise Error, "empty exploration membership differs from frozen selection" unless batch.fetch("selected_count").to_i.zero?
      updated = execute("UPDATE local_collection_batch SET status = 'published', completed_at = COALESCE(completed_at, now()) WHERE batch_id = #{literal(batch_id)} AND status = 'frozen' RETURNING batch_id")
      raise Error, "collection batch was finalized concurrently" if updated.empty?
      return true
    end

    ordered_entries.each_with_index do |entry, index|
      version_id = entry.fetch("version_id")
      raise Error, "exploration membership lane is invalid" unless entry.fetch("lane", "locale_frontier") == "locale_frontier"
      raise Error, "exploration membership reason is invalid" unless entry.fetch("reason", "topic_unconditioned_locale_sample") == "topic_unconditioned_locale_sample"
      raise Error, "exploration membership sort order is not contiguous" unless Integer(entry.fetch("sort_order")) == index
      row = query(<<~SQL)
        SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name,
               v.publisher_id, v.publisher_name, v.publisher_url, v.publisher_identity_status,
               v.source_kind, v.discovery_basis, v.query_conditioned::text,
               v.analysis_policy, v.aggregator_id, v.locale_tag, v.market_label,
               v.market_label_basis, v.query_topics::text,
               c.capture_id, a.outcome, a.capture_id, a.discovery_basis,
               a.query_conditioned::text, a.analysis_policy, a.source_config_hash,
               bs.source_config_hash,
               r.discovery_basis, r.query_conditioned::text, r.analysis_policy,
               r.aggregator_id, r.locale_tag, r.market_label, r.market_label_basis,
               r.query_topics::text, r.enabled::text, r.source_url, r.source_kind
          FROM local_source_item_version v
          JOIN local_source_capture c ON c.capture_id = v.capture_id
          JOIN local_source_fetch_attempt a ON a.batch_id = #{literal(batch_id)}
                                           AND a.source_id = v.source_id
                                           AND a.capture_id = v.capture_id
          JOIN local_collection_batch_source bs ON bs.batch_id = #{literal(batch_id)}
                                               AND bs.source_id = v.source_id
          JOIN local_source_registry r ON r.source_id = v.source_id
         WHERE v.version_id = #{literal(version_id)}
      SQL
      raise Error, "exploration membership version/capture/attempt lineage missing" unless row.length == 1
      values = row.fetch(0).split("\t", -1)
      version = row_to_hash(values[0, 18].join("\t"), %w[version_id item_key capture_id source_id source_name publisher_id publisher_name publisher_url publisher_identity_status source_kind discovery_basis query_conditioned analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics])
      # The remaining columns are intentionally positional to keep SQL output
      # free of body copies while checking every frozen contract field.
      attempt_outcome = values.fetch(19)
      attempt_capture_id = values.fetch(20)
      attempt_basis = values.fetch(21)
      attempt_query = values.fetch(22)
      attempt_policy = values.fetch(23)
      attempt_hash = values.fetch(24)
      planned_hash = values.fetch(25)
      registry_basis = values.fetch(26)
      registry_query = values.fetch(27)
      registry_policy = values.fetch(28)
      registry_aggregator = values.fetch(29)
      registry_locale = values.fetch(30)
      registry_market = values.fetch(31)
      registry_market_basis = values.fetch(32)
      registry_topics = values.fetch(33)
      registry_enabled = values.fetch(34)
      registry_source_url = values.fetch(35)
      registry_source_kind = values.fetch(36)
      raise Error, "exploration attempt did not succeed_with_items" unless attempt_outcome == "succeeded_with_items" && attempt_capture_id == version.fetch("capture_id")
      raise Error, "exploration version is not locale exploration contract" unless version.fetch("source_kind") == "discovery" && version.fetch("discovery_basis") == "locale_headlines" && !truthy_value?(version.fetch("query_conditioned")) && version.fetch("analysis_policy") == "exploration_only"
      raise Error, "exploration version locale contract is incomplete" if [version.fetch("aggregator_id"), version.fetch("locale_tag"), version.fetch("market_label")].any?(&:empty?) || version.fetch("market_label_basis") != "aggregator_locale_label" || parse_json_array(version.fetch("query_topics")).any?
      raise Error, "exploration registry/version contract differs" unless [registry_basis, registry_query, registry_policy, registry_aggregator, registry_locale, registry_market, registry_market_basis] == [version.fetch("discovery_basis"), version.fetch("query_conditioned"), version.fetch("analysis_policy"), version.fetch("aggregator_id"), version.fetch("locale_tag"), version.fetch("market_label"), version.fetch("market_label_basis")]
      raise Error, "exploration registry/version topics differ" unless parse_json_array(registry_topics) == parse_json_array(version.fetch("query_topics"))
      raise Error, "exploration source is disabled" unless truthy_value?(registry_enabled)
      raise Error, "exploration attempt contract differs" unless attempt_basis == version.fetch("discovery_basis") && truthy_value?(attempt_query) == truthy_value?(version.fetch("query_conditioned")) && attempt_policy == version.fetch("analysis_policy") && !attempt_hash.to_s.empty? && attempt_hash == planned_hash
      registry_source = {
        "id" => version.fetch("source_id"), "url" => registry_source_url, "source_kind" => registry_source_kind,
        "discovery_basis" => registry_basis, "query_conditioned" => truthy_value?(registry_query),
        "analysis_policy" => registry_policy, "aggregator_id" => registry_aggregator,
        "locale_tag" => registry_locale, "market_label" => registry_market,
        "market_label_basis" => registry_market_basis, "query_topics" => parse_json_array(registry_topics),
        "enabled" => truthy_value?(registry_enabled)
      }
      raise Error, "exploration registry source config differs from frozen batch" unless registry_contract_hash(sources: [registry_source]) == planned_hash

      resolution = version.fetch("publisher_identity_status") == "unresolved" || version.fetch("publisher_id").empty? ? "unresolved" : "resolved"
      body_resolution = entry.fetch("resolution", resolution).to_s
      raise Error, "exploration membership resolution is forged" unless body_resolution == resolution
      selection = selections_by_version.fetch(version_id) { raise Error, "exploration membership is outside frozen selection manifest" }
      raise Error, "exploration membership decision is not selected" unless selection.fetch("outcome") == "selected"
      execute(<<~SQL)
        INSERT INTO local_radar_exploration_item
          (exploration_item_id, snapshot_id, batch_id, version_id, lane, reason, resolution, sort_order,
           selection_manifest_id, exploration_decision_id, not_a_signal, delivery_status)
        VALUES (#{literal(entry.fetch("exploration_item_id", "#{snapshot_id}-exploration-#{index}"))}, #{literal(snapshot_id)}, #{literal(batch_id)}, #{literal(version_id)}, 'locale_frontier', 'topic_unconditioned_locale_sample', #{literal(resolution)}, #{index}, #{literal(manifest.fetch("manifest_id"))}, #{literal(selection.fetch("exploration_decision_id"))}, TRUE, 'unmeasured')
      SQL
    end
    stored_ids = execute("SELECT version_id FROM local_radar_exploration_item WHERE batch_id = #{literal(batch_id)} AND snapshot_id = #{literal(snapshot_id)} ORDER BY sort_order ASC").map(&:to_s)
    raise Error, "exploration membership stored order differs" unless stored_ids == ids
    updated = execute("UPDATE local_collection_batch SET status = 'published', completed_at = COALESCE(completed_at, now()) WHERE batch_id = #{literal(batch_id)} AND status = 'frozen' RETURNING batch_id")
    raise Error, "collection batch was finalized concurrently" if updated.empty?
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "exploration membership is incomplete: #{error.message}"
  end

  def normalize_item_contract(item, source_kind:)
    source = item
    basis = source.fetch("discovery_basis", truthy_value?(source.fetch("query_conditioned", false)) ? "topic_query" : "editorial_feed").to_s
    policy = source.fetch("analysis_policy", basis == "locale_headlines" ? "exploration_only" : "signal_eligible").to_s
    query_conditioned = truthy_value?(source.fetch("query_conditioned", basis == "topic_query"))
    topics = source.fetch("query_topics", [])
    raise Error, "item query_topics must be an array" unless topics.is_a?(Array)
    raise Error, "item discovery_basis is invalid" unless DISCOVERY_BASES.include?(basis)
    raise Error, "item analysis_policy is invalid" unless ANALYSIS_POLICIES.include?(policy)
    if basis == "locale_headlines"
      raise Error, "item locale_headlines contract is invalid" unless source_kind.to_s == "discovery" && !query_conditioned && policy == "exploration_only"
      raise Error, "item locale_headlines contract is incomplete" if %w[aggregator_id locale_tag market_label].any? { |key| source.fetch(key, "").to_s.strip.empty? }
      raise Error, "item locale_headlines market label basis is invalid" unless source.fetch("market_label_basis", "") == "aggregator_locale_label"
      raise Error, "item locale_headlines query_topics must be empty" unless topics.empty?
      publisher_status = source.fetch("publisher_identity_status", source.fetch("publisher_id", "").to_s.empty? ? "unresolved" : "observed_domain").to_s
      publisher_id = source.fetch("publisher_id", "").to_s
      raise Error, "item locale_headlines publisher identity status is invalid" unless %w[observed_domain unresolved].include?(publisher_status)
      raise Error, "unresolved locale item cannot carry publisher id" if publisher_status == "unresolved" && !publisher_id.empty?
      raise Error, "observed locale item requires publisher id" if publisher_status == "observed_domain" && publisher_id.empty?
    elsif basis == "topic_query"
      raise Error, "item topic query contract is invalid" unless source_kind.to_s == "discovery" && query_conditioned
    elsif policy == "exploration_only"
      raise Error, "only locale_headlines may be exploration_only"
    end
    default_market_label_basis = basis == "locale_headlines" ? "aggregator_locale_label" : "editorial_scope_label"
    market_label_basis = source.fetch("market_label_basis", "").to_s
    market_label_basis = default_market_label_basis if market_label_basis.empty?
    {
      "discovery_basis" => basis, "analysis_policy" => policy,
      "query_conditioned" => query_conditioned,
      "aggregator_id" => source.fetch("aggregator_id", "").to_s,
      "locale_tag" => source.fetch("locale_tag", "").to_s,
      "market_label" => source.fetch("market_label", "").to_s,
      "market_label_basis" => market_label_basis,
      "query_topics" => topics.map(&:to_s)
    }
  rescue KeyError, TypeError => error
    raise Error, "item contract is incomplete: #{error.message}"
  end

  def validate_locale_url!(value, aggregator_id: "")
    uri = URI.parse(value.to_s)
    raise Error, "locale_headlines URL must use HTTPS" unless uri.scheme == "https" && !uri.host.to_s.empty?
    if aggregator_id == "google-news"
      raise Error, "google-news locale URL host/path is invalid" unless uri.host.to_s.downcase == "news.google.com" && uri.path == "/rss"
    end
    return if uri.query.to_s.empty?

    keys = uri.query.to_s.split("&").reject(&:empty?).map { |pair| CGI.unescape(pair.split("=", 2).first.to_s).downcase }
    raise Error, "locale_headlines URL cannot contain topic/query parameters" unless (keys & %w[q query search topic keyword keywords category section]).empty?
    raise Error, "locale_headlines URL cannot repeat query parameters" unless keys.uniq.length == keys.length
    if aggregator_id == "google-news"
      raise Error, "google-news locale URL has unsupported query parameters" unless (keys - %w[hl gl ceid]).empty?
    else
      raise Error, "locale_headlines URL query parameters require a registered aggregator validator"
    end
  rescue URI::InvalidURIError => error
    raise Error, "locale_headlines URL is invalid: #{error.message}"
  end

  def validate_event_candidate!(candidate)
    raise Error, "event candidate must be an object" unless candidate.is_a?(Hash)

    required = %w[candidate_key candidate_status label language matching_method explanation member_count
                  dedup_source_count qualifying_source_count query_conditioned_evidence_count
                  first_published_at last_published_at time_span_hours shared_anchors shared_phrases
                  evidence_items member_item_keys qualifying_item_keys query_item_keys]
    missing = required.reject { |key| candidate.key?(key) }
    raise Error, "event candidate fields missing: #{missing.join(',')}" unless missing.empty?
    raise Error, "event candidate status is invalid" unless candidate.fetch("candidate_status") == "event_candidate"

    member_keys = validate_key_array!(candidate.fetch("member_item_keys"), "member_item_keys")
    qualifying_keys = validate_key_array!(candidate.fetch("qualifying_item_keys"), "qualifying_item_keys")
    query_keys = validate_key_array!(candidate.fetch("query_item_keys"), "query_item_keys")
    raise Error, "event candidate key sets overlap" unless (qualifying_keys & query_keys).empty?
    raise Error, "event candidate member keys do not match qualifying/query keys" unless member_keys.sort == (qualifying_keys + query_keys).sort

    member_count = Integer(candidate.fetch("member_count"))
    dedup_source_count = Integer(candidate.fetch("dedup_source_count"))
    qualifying_source_count = Integer(candidate.fetch("qualifying_source_count"))
    query_count = Integer(candidate.fetch("query_conditioned_evidence_count"))
    raise Error, "event candidate member count is inconsistent" unless member_count == member_keys.length
    raise Error, "event candidate qualifying count is inconsistent" unless qualifying_source_count == qualifying_keys.length
    raise Error, "event candidate query count is inconsistent" unless query_count == query_keys.length
    raise Error, "event candidate requires at least two qualifying members" if qualifying_source_count < 2

    evidence = candidate.fetch("evidence_items")
    raise Error, "event candidate evidence_items must be an array" unless evidence.is_a?(Array) && evidence.length == member_keys.length
    evidence_by_key = {}
    evidence.each do |entry|
      raise Error, "event candidate evidence item must be an object" unless entry.is_a?(Hash)
      key = entry.fetch("item_key", "").to_s
      raise Error, "event candidate evidence item key is missing or duplicated" if key.empty? || evidence_by_key.key?(key)
      evidence_by_key[key] = entry
    end
    raise Error, "event candidate evidence keys do not match members" unless evidence_by_key.keys.sort == member_keys.sort

    language = candidate.fetch("language").to_s
    raise Error, "event candidate language is empty" if language.empty?
    qualifying_publishers = []
    publishers = []
    evidence_by_key.each do |key, entry|
      entry_language = entry.fetch("language", "").to_s
      raise Error, "event candidate evidence language is inconsistent" unless entry_language.downcase == language.downcase
      publisher_id = entry.fetch("publisher_id", "").to_s
      raise Error, "event candidate evidence publisher_id is missing" if publisher_id.empty?
      raise Error, "event candidate publisher is repeated" if publishers.include?(publisher_id)
      publishers << publisher_id
      role = entry.fetch("lineage_role", "").to_s
      query_conditioned = truthy_value?(entry.fetch("query_conditioned", false))
      if qualifying_keys.include?(key)
        raise Error, "event candidate qualifying role is invalid" unless role == "qualifying_non_query" && !query_conditioned
        qualifying_publishers << publisher_id
      elsif query_keys.include?(key)
        raise Error, "event candidate query role is invalid" unless role == "query_conditioned_support" && query_conditioned
      else
        raise Error, "event candidate evidence key is not a member"
      end
    end
    raise Error, "event candidate dedup source count is inconsistent" unless dedup_source_count == publishers.uniq.length
    raise Error, "event candidate qualifying source count is inconsistent" unless qualifying_source_count == qualifying_publishers.uniq.length

    validate_event_lineage!(evidence_by_key.values)
    core_times = qualifying_keys.map { |key| parse_event_time!(evidence_by_key.fetch(key).fetch("published_at")) }
    first_time = parse_event_time!(candidate.fetch("first_published_at"))
    last_time = parse_event_time!(candidate.fetch("last_published_at"))
    minimum = core_times.min
    maximum = core_times.max
    raise Error, "event candidate first/last timestamps are inconsistent" unless first_time == minimum && last_time == maximum && first_time <= last_time
    span_hours = (maximum - minimum) / 3600.0
    raise Error, "event candidate time span is inconsistent" unless (span_hours - Float(candidate.fetch("time_span_hours"))).abs <= 0.001

    validate_event_anchors!(candidate.fetch("shared_anchors"), qualifying_source_count)
    validate_event_phrases!(candidate.fetch("shared_phrases"))
    validate_event_candidate_semantics!(candidate, evidence_by_key.values, last_time)
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "event candidate validation failed: #{error.message}"
  end

  def validate_key_array!(value, name)
    raise Error, "event candidate #{name} must be an array" unless value.is_a?(Array)
    keys = value.map { |entry| entry.to_s }
    raise Error, "event candidate #{name} contains an empty or duplicate key" if keys.any?(&:empty?) || keys.uniq.length != keys.length
    keys
  end

  def validate_event_anchors!(anchors, qualifying_source_count)
    raise Error, "event candidate shared_anchors must be an array" unless anchors.is_a?(Array)
    seen = {}
    anchors.each do |anchor|
      raise Error, "event candidate anchor must be an object" unless anchor.is_a?(Hash)
      kind = anchor.fetch("kind", "").to_s
      value = anchor.fetch("value", "").to_s
      strength = anchor.fetch("strength", "").to_s
      support = Integer(anchor.fetch("supporting_qualifying_source_count"))
      valid_kind = %w[number numeric number_unit trigram name_candidate abbreviation long_shingle quoted_phrase token bigram].include?(kind)
      raise Error, "event candidate anchor shape is invalid" unless valid_kind && !value.empty? && %w[strong supporting].include?(strength)
      raise Error, "event candidate anchor support is inconsistent" unless support == qualifying_source_count
      identity = [kind, value]
      raise Error, "event candidate anchors contain duplicates" if seen.key?(identity)
      seen[identity] = true
    end
  end

  def validate_event_phrases!(phrases)
    raise Error, "event candidate shared_phrases must be an array" unless phrases.is_a?(Array)
    values = phrases.map { |phrase| phrase.to_s }
    raise Error, "event candidate shared_phrases contain an empty or duplicate value" if values.any?(&:empty?) || values.uniq.length != values.length
  end

  def validate_event_lineage!(evidence)
    breadth = breadth_schema_available?
    evidence.each do |entry|
      item_key = entry.fetch("item_key", "").to_s
      version_id = entry.fetch("version_id", "").to_s
      capture_id = entry.fetch("capture_id", "").to_s
      content_hash = entry.fetch("content_hash", "").to_s
      raise Error, "event candidate evidence lineage is incomplete" if item_key.empty? || version_id.empty? || capture_id.empty? || content_hash.empty?
      rows = query(<<~SQL)
        SELECT v.version_id, v.item_key, v.capture_id, v.source_id, v.source_name, v.language, v.region,
               v.publisher_name, v.publisher_url, v.publisher_id, v.publisher_identity_status, v.source_kind,
               v.lineage_metadata_basis,
               #{breadth ? "v.analysis_policy," : ""}
               v.query_conditioned::text, v.title, v.summary, v.source_url, v.published_at::text, v.content_hash,
               r.enabled::text
          FROM local_source_item_version v
          JOIN local_source_registry r ON r.source_id = v.source_id
         WHERE v.version_id = #{literal(version_id)}
           AND v.item_key = #{literal(item_key)}
           AND v.capture_id = #{literal(capture_id)}
      SQL
      raise Error, "event candidate evidence version is missing" unless rows.length == 1
      stored_keys = %w[version_id item_key capture_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind lineage_metadata_basis]
      stored_keys << "analysis_policy" if breadth
      stored_keys += %w[query_conditioned title summary source_url published_at content_hash registry_enabled]
      stored = row_to_hash(rows.fetch(0), stored_keys)
      raise Error, "event candidate evidence source is disabled" unless truthy_value?(stored.fetch("registry_enabled"))
      raise Error, "exploration-only evidence cannot enter event candidates" if breadth && stored.fetch("analysis_policy") != "signal_eligible"
      lineage_fields = %w[version_id item_key capture_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind title summary source_url content_hash]
      lineage_fields << "lineage_metadata_basis" unless entry.fetch("lineage_metadata_basis", "").to_s.empty?
      lineage_fields.each do |field|
        raise Error, "event candidate evidence version #{field} does not match" unless entry.fetch(field, "").to_s == stored.fetch(field).to_s
      end
      raise Error, "event candidate evidence version query_conditioned does not match" unless truthy_value?(entry.fetch("query_conditioned", false)) == truthy_value?(stored.fetch("query_conditioned"))
      raise Error, "event candidate evidence version published_at does not match" unless parse_event_time!(entry.fetch("published_at")) == parse_event_time!(stored.fetch("published_at"))
    end
  end

  def parse_event_time!(value)
    value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
  rescue ArgumentError, TypeError
    raise Error, "event candidate timestamp is invalid"
  end

  def truthy_value?(value)
    value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def validate_event_candidate_semantics!(candidate, evidence, now)
    analyzer_items = evidence.map do |entry|
      {
        "item_key" => entry.fetch("item_key"),
        "source_id" => entry.fetch("source_id", ""),
        "source_name" => entry.fetch("source_name", entry.fetch("publisher_name", "")),
        "region" => entry.fetch("region", "未标注"),
        "publisher_name" => entry.fetch("publisher_name", ""),
        "publisher_url" => entry.fetch("publisher_url", ""),
        "publisher_id" => entry.fetch("publisher_id"),
        "version_id" => entry.fetch("version_id"),
        "capture_id" => entry.fetch("capture_id"),
        "content_hash" => entry.fetch("content_hash"),
        "publisher_identity_status" => entry.fetch("publisher_identity_status", "configured"),
        "source_kind" => entry.fetch("source_kind", "configured"),
        "lineage_metadata_basis" => entry.fetch("lineage_metadata_basis", ""),
        "language" => entry.fetch("language"),
        "title" => entry.fetch("title", ""),
        "summary" => entry.fetch("summary", ""),
        "source_url" => entry.fetch("source_url", ""),
        "published_at" => entry.fetch("published_at"),
        "query_conditioned" => truthy_value?(entry.fetch("query_conditioned", false)),
        "registry_enabled" => true
      }
    end
    # Recompute against the full evidence horizon. A query-conditioned item
    # may sit outside the core qualifying span while remaining pair-compatible;
    # using the core `last_published_at` as `now` would incorrectly drop it as
    # a future row during validation.
    analysis_now = analyzer_items.map { |item| Time.parse(item.fetch("published_at").to_s).utc }.max || now
    canonical = EventCandidateAnalyzer.new(max_age_hours: [EventCandidateAnalyzer::DEFAULT_MAX_AGE_HOURS, 72].max)
      .analyze(items: analyzer_items, now: analysis_now)
    raise Error, "event candidate does not reproduce one canonical candidate" unless canonical.length == 1
    expected = canonical.fetch(0)
    fields = %w[candidate_key candidate_status label language matching_method explanation member_count dedup_source_count
                 qualifying_source_count query_conditioned_evidence_count first_published_at last_published_at
                 time_span_hours shared_anchors shared_phrases evidence_items member_item_keys qualifying_item_keys query_item_keys]
    fields.each do |field|
      actual_value = candidate.fetch(field)
      expected_value = expected.fetch(field)
      if %w[first_published_at last_published_at].include?(field)
        raise Error, "event candidate #{field} differs from canonical analysis" unless parse_event_time!(actual_value) == parse_event_time!(expected_value)
      elsif field == "time_span_hours"
        raise Error, "event candidate time span differs from canonical analysis" unless (Float(actual_value) - Float(expected_value)).abs <= 0.001
      elsif field == "evidence_items"
        raise Error, "event candidate evidence differs from canonical analysis" unless normalize_event_evidence_times(actual_value) == normalize_event_evidence_times(expected_value)
      else
        raise Error, "event candidate #{field} differs from canonical analysis" unless actual_value == expected_value
      end
    end
  end

  def normalize_event_evidence_times(value)
    Array(value).map do |entry|
      hash = entry.dup
      hash["published_at"] = parse_event_time!(hash.fetch("published_at")).iso8601
      hash
    end
  end

  def ensure_capture!(capture_id:, source_id:, source_url:, source_kind:, rights_scope:, captured_at:,
                      http_status:, content_type:, content_bytes:, body_hash:, storage_status:, storage_uri:)
    execute(<<~SQL)
      INSERT INTO local_source_capture
        (capture_id, source_id, source_url, source_kind, rights_scope, captured_at, http_status,
         content_type, content_bytes, body_hash, storage_status, storage_uri)
      VALUES (#{literal(capture_id)}, #{literal(source_id)}, #{literal(source_url)}, #{literal(source_kind)},
              #{literal(rights_scope)}, #{literal(captured_at)}, #{Integer(http_status)}, #{literal(content_type)},
              #{Integer(content_bytes)}, #{literal(body_hash)}, #{literal(storage_status)}, #{literal(storage_uri)})
      ON CONFLICT (capture_id) DO NOTHING
    SQL
    row = execute(<<~SQL).fetch(0)
      SELECT source_id, source_url, source_kind, rights_scope, captured_at::text,
             http_status::text, content_type, content_bytes::text, body_hash,
             storage_status, storage_uri
        FROM local_source_capture
       WHERE capture_id = #{literal(capture_id)}
    SQL
    actual = row_to_hash(row, %w[source_id source_url source_kind rights_scope captured_at http_status content_type content_bytes body_hash storage_status storage_uri])
    expected = {
      "source_id" => source_id.to_s, "source_url" => source_url.to_s, "source_kind" => source_kind.to_s,
      "rights_scope" => rights_scope.to_s, "captured_at" => captured_at.to_s,
      "http_status" => Integer(http_status), "content_type" => content_type.to_s,
      "content_bytes" => Integer(content_bytes), "body_hash" => body_hash.to_s,
      "storage_status" => storage_status.to_s, "storage_uri" => storage_uri.to_s
    }
    matches = actual.fetch("source_id") == expected.fetch("source_id") &&
      actual.fetch("source_url") == expected.fetch("source_url") &&
      actual.fetch("source_kind") == expected.fetch("source_kind") &&
      actual.fetch("rights_scope") == expected.fetch("rights_scope") &&
      timestamp_equal?(actual.fetch("captured_at"), expected.fetch("captured_at")) &&
      actual.fetch("http_status").to_i == expected.fetch("http_status") &&
      actual.fetch("content_type") == expected.fetch("content_type") &&
      actual.fetch("content_bytes").to_i == expected.fetch("content_bytes") &&
      actual.fetch("body_hash") == expected.fetch("body_hash") &&
      actual.fetch("storage_status") == expected.fetch("storage_status") &&
      actual.fetch("storage_uri") == expected.fetch("storage_uri")
    raise Error, "capture_id conflict: immutable capture payload differs for #{capture_id}" unless matches
  rescue IndexError
    raise Error, "capture_id conflict: capture #{capture_id} disappeared during ingest"
  end

  def ensure_version!(version_id:, item_key:, capture_id:, source_id:, source_name:, language:, region:, publisher_name:, publisher_url:, publisher_id:, publisher_identity_status:, source_kind:, query_conditioned:, discovery_basis: "editorial_feed", analysis_policy: "signal_eligible", aggregator_id: "", locale_tag: "", market_label: "", market_label_basis: "", query_topics: [], lineage_metadata_basis: "capture_time", title:, summary:, source_url:,
                      published_at:, fetched_at:, captured_at:, content_hash:)
    breadth = breadth_schema_available?
    insert_sql = if breadth
      <<~SQL
        INSERT INTO local_source_item_version
          (version_id, item_key, capture_id, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id, publisher_identity_status, source_kind, query_conditioned, discovery_basis, analysis_policy, aggregator_id, locale_tag, market_label, market_label_basis, query_topics, lineage_metadata_basis, title, summary, source_url, published_at, fetched_at, captured_at, content_hash)
        VALUES (#{literal(version_id)}, #{literal(item_key)}, #{literal(capture_id)}, #{literal(source_id)}, #{literal(source_name)}, #{literal(language)}, #{literal(region)}, #{literal(publisher_name)}, #{literal(publisher_url)}, #{literal(publisher_id)}, #{literal(publisher_identity_status)}, #{literal(source_kind)}, #{query_conditioned ? "TRUE" : "FALSE"}, #{literal(discovery_basis)}, #{literal(analysis_policy)}, #{literal(aggregator_id)}, #{literal(locale_tag)}, #{literal(market_label)}, #{literal(market_label_basis)}, #{literal(JSON.generate(Array(query_topics)))}::jsonb, #{literal(lineage_metadata_basis)}, #{literal(title)},
                #{literal(summary)}, #{literal(source_url)}, #{published_at.nil? ? "NULL" : literal(published_at)},
                #{literal(fetched_at)}, #{literal(captured_at)}, #{literal(content_hash)})
      SQL
    else
      <<~SQL
        INSERT INTO local_source_item_version
          (version_id, item_key, capture_id, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id, publisher_identity_status, source_kind, query_conditioned, lineage_metadata_basis, title, summary, source_url, published_at, fetched_at, captured_at, content_hash)
        VALUES (#{literal(version_id)}, #{literal(item_key)}, #{literal(capture_id)}, #{literal(source_id)}, #{literal(source_name)}, #{literal(language)}, #{literal(region)}, #{literal(publisher_name)}, #{literal(publisher_url)}, #{literal(publisher_id)}, #{literal(publisher_identity_status)}, #{literal(source_kind)}, #{query_conditioned ? "TRUE" : "FALSE"}, #{literal(lineage_metadata_basis)}, #{literal(title)},
                #{literal(summary)}, #{literal(source_url)}, #{published_at.nil? ? "NULL" : literal(published_at)},
                #{literal(fetched_at)}, #{literal(captured_at)}, #{literal(content_hash)})
      SQL
    end
    execute(insert_sql + <<~SQL)
      ON CONFLICT (item_key, capture_id) DO NOTHING
    SQL
    row = execute(<<~SQL).fetch(0)
      SELECT version_id, source_id, source_name, language, region, publisher_name, publisher_url, publisher_id, publisher_identity_status, source_kind, query_conditioned::text, lineage_metadata_basis,
        #{breadth ? "discovery_basis, analysis_policy, aggregator_id, locale_tag, market_label, market_label_basis, query_topics::text," : ""}
        title, summary, source_url, published_at::text,
        fetched_at::text, captured_at::text, content_hash
        FROM local_source_item_version
       WHERE item_key = #{literal(item_key)} AND capture_id = #{literal(capture_id)}
    SQL
    keys = %w[version_id source_id source_name language region publisher_name publisher_url publisher_id publisher_identity_status source_kind query_conditioned lineage_metadata_basis]
    keys += %w[discovery_basis analysis_policy aggregator_id locale_tag market_label market_label_basis query_topics] if breadth
    keys += %w[title summary source_url published_at fetched_at captured_at content_hash]
    actual = row_to_hash(row, keys)
    actual["query_topics"] = parse_json_array(actual.fetch("query_topics")) if breadth
    matches = actual.fetch("version_id") == version_id.to_s &&
      actual.fetch("source_id") == source_id.to_s &&
      actual.fetch("source_name") == source_name.to_s &&
      actual.fetch("language") == language.to_s &&
      actual.fetch("region") == region.to_s &&
      actual.fetch("publisher_name") == publisher_name.to_s &&
      actual.fetch("publisher_url") == publisher_url.to_s &&
      actual.fetch("publisher_id") == publisher_id.to_s &&
      actual.fetch("publisher_identity_status") == publisher_identity_status.to_s &&
      actual.fetch("source_kind") == source_kind.to_s &&
      (%w[t true].include?(actual.fetch("query_conditioned").downcase) == !!query_conditioned) &&
      actual.fetch("lineage_metadata_basis") == lineage_metadata_basis.to_s &&
      (!breadth || (actual.fetch("discovery_basis") == discovery_basis.to_s && actual.fetch("analysis_policy") == analysis_policy.to_s && actual.fetch("aggregator_id") == aggregator_id.to_s && actual.fetch("locale_tag") == locale_tag.to_s && actual.fetch("market_label") == market_label.to_s && actual.fetch("market_label_basis") == market_label_basis.to_s && actual.fetch("query_topics") == Array(query_topics))) &&
      actual.fetch("title") == title.to_s &&
      actual.fetch("summary") == summary.to_s &&
      actual.fetch("source_url") == source_url.to_s &&
      timestamp_equal?(actual.fetch("published_at"), published_at) &&
      timestamp_equal?(actual.fetch("fetched_at"), fetched_at) &&
      timestamp_equal?(actual.fetch("captured_at"), captured_at) &&
      actual.fetch("content_hash") == content_hash.to_s
    raise Error, "item_key/capture_id conflict: immutable item version differs for #{item_key}/#{capture_id}" unless matches
  rescue IndexError
    raise Error, "item_key/capture_id conflict: version #{item_key}/#{capture_id} disappeared during ingest"
  end

  def timestamp_equal?(left, right)
    left_value = left.to_s
    right_value = right.to_s
    return left_value.empty? && right.nil? if left_value.empty?
    return false if right.nil? || right.to_s.empty?

    Time.parse(left_value).utc == Time.parse(right.to_s).utc
  rescue ArgumentError
    left_value == right.to_s
  end

  def transaction
    raise Error, "nested local database transaction is not supported" if @transaction_io

    open_transaction
    transaction_query("BEGIN")
    result = yield
    transaction_query("COMMIT")
    result
  rescue StandardError
    begin
      transaction_query("ROLLBACK") if @transaction_io
    rescue StandardError
      nil
    end
    raise
  ensure
    close_transaction
  end

  def execute(sql)
    query(sql)
  end

  def query(sql)
    return transaction_query(sql) if @transaction_io

    args = psql_args + ["-c", sql]
    stdout, stderr, status = Open3.capture3(*args)
    raise Error, stderr.strip unless status.success?
    stdout.lines(chomp: true).reject(&:empty?)
  end

  def psql_args
    [@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end

  # Keep every statement in a transaction on one backend connection. The
  # previous implementation launched a fresh psql process for each statement,
  # which made BEGIN/COMMIT ineffective across capture, version, and projection
  # writes.
  def open_transaction
    @transaction_io = Open3.popen3(*psql_args)
    @transaction_stdin, @transaction_stdout, @transaction_stderr, @transaction_wait_thread = @transaction_io
    @transaction_stdin.sync = true
    @transaction_stdout.sync = true
  end

  def transaction_query(sql)
    raise Error, "local database transaction is not open" unless @transaction_io

    marker = "__local_radar_txn_marker_#{SecureRandom.hex(12)}__"
    command = sql.to_s.strip
    command = "#{command};" unless command.end_with?(";")
    @transaction_stdin.write("#{command}\nSELECT #{literal(marker)};\n")
    @transaction_stdin.flush
    rows = []
    loop do
      line = @transaction_stdout.gets
      if line.nil?
        error = @transaction_stderr.read.to_s.strip
        raise Error, error.empty? ? "local database transaction connection closed" : error
      end
      value = line.chomp
      break if value == marker
      rows << value unless value.empty?
    end
    rows
  end

  def close_transaction
    return unless @transaction_io

    begin
      @transaction_stdin.close unless @transaction_stdin.closed?
    rescue IOError
      nil
    end
    begin
      @transaction_wait_thread.value
    rescue StandardError
      nil
    end
    [@transaction_stdout, @transaction_stderr].each do |io|
      begin
        io.close unless io.closed?
      rescue IOError
        nil
      end
    end
  ensure
    @transaction_io = nil
    @transaction_stdin = nil
    @transaction_stdout = nil
    @transaction_stderr = nil
    @transaction_wait_thread = nil
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def persisted_summary(value)
    value.to_s[0, SUMMARY_LIMIT]
  end

  def content_hash_for(title:, summary:, source_url:)
    Digest::SHA256.hexdigest([title.to_s, persisted_summary(summary), source_url.to_s].join("\u0000"))
  end

  def row_to_hash(row, keys)
    values = row.split("\t", -1)
    keys.each_with_index.each_with_object({}) { |(key, index), result| result[key] = values[index] }
  end

  def parse_json_array(value)
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  def parse_json_value(value)
    JSON.parse(value.to_s)
  rescue JSON::ParserError
    []
  end

  def breadth_schema_available?
    return true if @breadth_schema_available == true

    # A legacy 011 database has none of the 012-only relations/columns.  Once
    # migration has started, however, a missing relation is schema corruption,
    # not a legacy database; silently switching to zero/legacy coverage would
    # make a broken installation look like a worker that has not run.  Probe the
    # complete relation set and a 012-only column marker so partial drops fail
    # closed and database errors propagate to the HTTP 503 handler.
    relation_count = query("SELECT COUNT(*) FROM pg_class WHERE relkind = 'r' AND relname IN ('local_collection_batch', 'local_collection_batch_source', 'local_source_fetch_attempt', 'local_radar_exploration_item')").fetch(0, "0").to_i
    marker_count = query(<<~SQL).fetch(0, "0").to_i
      SELECT COUNT(*)
        FROM information_schema.columns
       WHERE (table_name = 'local_source_registry' AND column_name = 'discovery_basis')
          OR (table_name = 'local_radar_snapshot' AND column_name = 'signal_projection_status')
    SQL
    if relation_count.zero?
      raise Error, "breadth schema is incomplete: 012 marker exists but discovery relations are missing" if marker_count.positive?
      @breadth_schema_available = false
    elsif relation_count < 4
      raise Error, "breadth schema is incomplete: expected all 012 discovery relations"
    else
      @breadth_schema_available = true
    end
  end

  def relation_exists?(name)
    query("SELECT to_regclass(#{literal(name)}) IS NOT NULL").fetch(0, "f") == "t"
  end

  def metadata_translation_lease_schema_available?
    return true if @metadata_translation_lease_schema_available == true
    required = query(<<~SQL).fetch(0, "0").to_i
      SELECT COUNT(*)
        FROM information_schema.columns
       WHERE table_name='local_metadata_translation_run'
         AND column_name IN ('lease_owner','heartbeat_at','lease_expires_at')
    SQL
    @metadata_translation_lease_schema_available = required == 3 && relation_exists?("local_translation_batch_job")
  rescue LocalRadarStore::Error
    false
  end

  def normalized_translation_owner(owner)
    value = owner.to_s.strip
    value = "translation-worker-#{Process.pid}" if value.empty?
    raise Error, "translation owner is invalid" unless value.match?(/\A[A-Za-z0-9_.:-]{1,160}\z/)
    value
  end

  def assert_metadata_translation_owner!(run_id:, owner_id:)
    rows = query("SELECT run_id FROM local_metadata_translation_run WHERE run_id=#{literal(run_id)} AND state='running' AND lease_owner=#{literal(owner_id)} FOR UPDATE")
    raise Error, "metadata translation run is no longer owned" if rows.empty?
    true
  end

  def artifact_input_chars(artifact)
    Integer(artifact.fetch("input_chars", 0))
  rescue KeyError, ArgumentError, TypeError
    0
  end

  def record_translation_batch_attempt!(job_id:, run_id:, owner_id:, event:, error_reason: "", input_chars: 0)
    execute(<<~SQL)
      INSERT INTO local_translation_batch_attempt
        (attempt_id, job_id, run_id, owner_id, event, error_reason, input_chars)
      VALUES (#{literal("#{job_id}-#{run_id}-#{event}-#{SecureRandom.hex(5)}")}, #{literal(job_id)}, #{literal(run_id)},
              #{literal(owner_id)}, #{literal(event)}, #{literal(error_reason.to_s[0, 1000])}, #{Integer(input_chars)})
    SQL
  end

  def record_translation_batch_attempt_for_run!(run_id:, owner_id:, event:, error_reason: "")
    job = query("SELECT job_id FROM local_translation_batch_job WHERE state='running' ORDER BY started_at DESC, job_id DESC LIMIT 1").fetch(0, nil)
    job_literal = job ? literal(job) : "NULL"
    execute(<<~SQL)
      INSERT INTO local_translation_batch_attempt
        (attempt_id, job_id, run_id, owner_id, event, error_reason)
      VALUES (#{literal("reconcile-#{run_id}-#{event}-#{SecureRandom.hex(5)}")}, #{job_literal}, #{literal(run_id)},
              #{literal(owner_id)}, #{literal(event)}, #{literal(error_reason.to_s[0, 1000])})
    SQL
  end
end
