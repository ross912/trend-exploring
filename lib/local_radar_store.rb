# frozen_string_literal: true

require "json"
require "open3"

class LocalRadarStore
  class Error < StandardError; end

  def initialize(psql: ENV.fetch("LOCAL_PSQL", "/private/tmp/pg15-build-20260808/install/bin/psql"),
                 host: ENV.fetch("LOCAL_PGHOST", "/private/tmp/m1-pg-socket-20260808"),
                 port: ENV.fetch("LOCAL_PGPORT", "55432"),
                 database: ENV.fetch("LOCAL_PGDATABASE", "trend_exploring_local"),
                 user: ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres")))
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
             rights_epoch, render_plan_hash, snapshot_status, created_at::text
        FROM local_radar_snapshot
       WHERE snapshot_status = 'published'
       ORDER BY revision DESC
       LIMIT 1
    SQL
    return { "snapshot" => nil, "cards" => [] } if snapshot_rows.empty?

    snapshot = row_to_hash(snapshot_rows.fetch(0), %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch render_plan_hash snapshot_status created_at])
    cards = query(<<~SQL).map do |row|
      SELECT card_id, signal_type, title, summary, metric_label, metric_value,
             source_count, stance, action_stage, evidence_label, source_name, source_url, sort_order
        FROM local_radar_card
       WHERE snapshot_id = #{literal(snapshot.fetch("snapshot_id"))}
       ORDER BY sort_order ASC
    SQL
      row_to_hash(row, %w[card_id signal_type title summary metric_label metric_value source_count stance action_stage evidence_label source_name source_url sort_order])
    end
    { "snapshot" => snapshot, "cards" => cards }
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
          ('card-003', 'staging-snapshot-001', 'exploration', '未知地带', '一个开放世界样本通过了探索资格，但没有任何检测器把它升级为候选信号。', '检测结果', '无候选', 0, 'unknown', '不适用', '仅作探索材料', '演示数据', '', 2)
        ON CONFLICT (card_id) DO NOTHING
      SQL
    end
    current_radar
  end

  def reset_demo!
    raise Error, "reset is restricted to the disposable local database" unless @database == "trend_exploring_local"
    execute("TRUNCATE local_radar_card, local_radar_snapshot")
    true
  end

  def ingest_source_items!(items:)
    inserted = 0
    transaction do
      Array(items).each do |item|
        rows = execute(<<~SQL)
          INSERT INTO local_source_item
            (item_key, source_id, source_name, language, title, summary, source_url, published_at, fetched_at, content_hash)
          VALUES (#{literal(item.fetch("item_key"))}, #{literal(item.fetch("source_id"))}, #{literal(item.fetch("source_name"))},
                  #{literal(item.fetch("language"))}, #{literal(item.fetch("title"))}, #{literal(item.fetch("summary").to_s[0, 320])},
                  #{literal(item.fetch("source_url"))}, #{item.fetch("published_at") ? literal(item.fetch("published_at")) : "NULL"},
                  #{literal(item.fetch("fetched_at"))}, #{literal(item.fetch("content_hash"))})
          ON CONFLICT (item_key) DO UPDATE SET
            title = EXCLUDED.title,
            summary = EXCLUDED.summary,
            fetched_at = EXCLUDED.fetched_at,
            content_hash = EXCLUDED.content_hash
          RETURNING (xmax = 0)::text
        SQL
        inserted += rows.count { |row| %w[t true].include?(row) }
      end
    end
    inserted
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "source item ingest is incomplete: #{error.message}"
  end

  def latest_source_items(limit: 12)
    query(<<~SQL).map do |row|
      SELECT item_key, source_id, source_name, language, title, summary, source_url,
             published_at::text, fetched_at::text
        FROM local_source_item
       ORDER BY COALESCE(published_at, fetched_at) DESC, item_key ASC
       LIMIT #{Integer(limit)}
    SQL
      row_to_hash(row, %w[item_key source_id source_name language title summary source_url published_at fetched_at])
    end
  end

  def next_revision(surface_id: "public-radar")
    query("SELECT COALESCE(MAX(revision), 0) + 1 FROM local_radar_snapshot WHERE surface_id = #{literal(surface_id)}").fetch(0).to_i
  end

  def publish_snapshot!(snapshot:, cards:)
    required = %w[snapshot_id surface_id revision comparison_watermark method_epoch rights_epoch render_plan_hash]
    missing = required.reject { |key| snapshot.key?(key) && !snapshot.fetch(key).to_s.empty? }
    raise Error, "snapshot fields missing: #{missing.join(',')}" unless missing.empty?
    rows = Array(cards)
    raise Error, "at least one radar card is required" if rows.empty?

    transaction do
      execute(<<~SQL)
        INSERT INTO local_radar_snapshot
          (snapshot_id, surface_id, revision, comparison_watermark, method_epoch, rights_epoch, render_plan_hash, snapshot_status)
        VALUES (#{literal(snapshot.fetch("snapshot_id"))}, #{literal(snapshot.fetch("surface_id"))}, #{Integer(snapshot.fetch("revision"))},
                #{literal(snapshot.fetch("comparison_watermark"))}, #{literal(snapshot.fetch("method_epoch"))}, #{Integer(snapshot.fetch("rights_epoch"))},
                #{literal(snapshot.fetch("render_plan_hash"))}, 'published')
      SQL
      rows.each do |card|
        execute(<<~SQL)
          INSERT INTO local_radar_card
            (card_id, snapshot_id, signal_type, title, summary, metric_label, metric_value, source_count, stance, action_stage, evidence_label, source_name, source_url, sort_order)
          VALUES (#{literal(card.fetch("card_id"))}, #{literal(snapshot.fetch("snapshot_id"))}, #{literal(card.fetch("signal_type"))},
                  #{literal(card.fetch("title"))}, #{literal(card.fetch("summary"))}, #{literal(card.fetch("metric_label"))}, #{literal(card.fetch("metric_value"))},
                  #{Integer(card.fetch("source_count"))}, #{literal(card.fetch("stance"))}, #{literal(card.fetch("action_stage"))},
                  #{literal(card.fetch("evidence_label"))}, #{literal(card.fetch("source_name", ""))}, #{literal(card.fetch("source_url", ""))}, #{Integer(card.fetch("sort_order"))})
        SQL
      end
    end
    current_radar
  rescue KeyError, ArgumentError, TypeError => error
    raise Error, "snapshot publish is incomplete: #{error.message}"
  end

  private

  def transaction
    execute("BEGIN")
    yield
    execute("COMMIT")
  rescue StandardError
    begin
      execute("ROLLBACK")
    rescue StandardError
      nil
    end
    raise
  end

  def execute(sql)
    query(sql)
  end

  def query(sql)
    args = [@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database, "-c", sql]
    stdout, stderr, status = Open3.capture3(*args)
    raise Error, stderr.strip unless status.success?
    stdout.lines(chomp: true).reject(&:empty?)
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def row_to_hash(row, keys)
    values = row.split("\t", -1)
    keys.each_with_index.each_with_object({}) { |(key, index), result| result[key] = values[index] }
  end
end
