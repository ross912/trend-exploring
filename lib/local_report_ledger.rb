# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "time"
require "date"
require_relative "report_window_contract"
require_relative "local_runtime"

# A small, append-oriented fact ledger for the two local report slots.  The
# class intentionally reads the existing local source archive, but does not
# generate summaries, claims, trends, or event classifications.
class LocalReportLedger
  class Error < StandardError; end

  TIMEZONE = "Asia/Shanghai"
  MORNING = "morning"
  EVENING = "evening"
  KINDS = [MORNING, EVENING].freeze
  ARRIVAL_KINDS = %w[first_seen content_update].freeze

  attr_reader :psql, :host, :port, :database, :user

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
    @transaction_io = nil
  end

  # Generate deterministic Asia/Shanghai slots for one local calendar date.
  # The morning slot is [previous day 19:00, date 08:00), and the evening
  # slot is [date 08:00, date 19:00).  Existing rows are checked rather than
  # rewritten, making repeated generation idempotent.
  def generate_slots!(date:, kinds: KINDS, configured_data_cutoff: nil, config_hash: "report-ledger-v1")
    local_date = parse_local_date(date)
    selected = Array(kinds).map(&:to_s)
    unknown = selected - KINDS
    raise Error, "unknown report slot kind: #{unknown.join(', ')}" unless unknown.empty?
    raise Error, "at least one report slot kind is required" if selected.empty?

    generated = selected.uniq.map do |kind|
      slot = slot_definition(local_date, kind, configured_data_cutoff: configured_data_cutoff, config_hash: config_hash)
      upsert_slot!(slot)
    end
    generated.sort_by { |row| [row.fetch("scheduled_at"), row.fetch("kind")] }
  rescue ArgumentError, TypeError => error
    raise Error, "invalid report slot date/configuration: #{error.message}"
  end

  alias ensure_slots! generate_slots!
  alias generate_daily_slots! generate_slots!

  def slot!(slot_id: nil, kind: nil, scheduled_at: nil)
    if slot_id
      rows = query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE slot_id = #{literal(slot_id)}")
      raise Error, "report slot not found: #{slot_id}" if rows.empty?
      return canonicalize_timestamps(row_to_hash(rows.fetch(0), SLOT_KEYS))
    end
    raise Error, "kind and scheduled_at are required" if kind.to_s.empty? || scheduled_at.to_s.empty?

    parsed = parse_time(scheduled_at)
    rows = query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE kind = #{literal(kind)} AND scheduled_at = #{literal(parsed.utc.iso8601)}")
    raise Error, "report slot not found: #{kind}/#{scheduled_at}" if rows.empty?
    canonicalize_timestamps(row_to_hash(rows.fetch(0), SLOT_KEYS))
  end

  def slots(kind: nil, from: nil, to: nil)
    clauses = []
    clauses << "kind = #{literal(kind)}" unless kind.to_s.empty?
    clauses << "scheduled_at >= #{literal(parse_time(from).utc.iso8601)}" if from
    clauses << "scheduled_at < #{literal(parse_time(to).utc.iso8601)}" if to
    sql = "SELECT #{slot_columns} FROM local_report_schedule_slot"
    sql += " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
    sql += " ORDER BY scheduled_at ASC, kind ASC"
    query(sql).map { |row| canonicalize_timestamps(row_to_hash(row, SLOT_KEYS)) }
  end

  # Materialize all immutable versions strictly before a controlled frontier,
  # ordered by (created_at, version_id).  The full scan is intentional: a
  # caller cannot choose a late version first and accidentally turn an older
  # version into a second first_seen arrival.
  def materialize_arrivals_through!(frontier:)
    cutoff = parse_time(frontier)
    attempts = 0
    begin
      transaction do
        materialize_versions_before!(cutoff.utc.iso8601)
      end
    rescue Error => error
      attempts += 1
      retry if attempts < 3 && serialization_conflict?(error)
      raise
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)

    raise Error, error.message
  end

  # Compatibility entry point.  Version ids are only used to derive a
  # frontier; all versions in the archive up to that frontier are processed.
  def materialize_arrivals!(version_ids: nil, version_id: nil, frontier: nil)
    if frontier
      return materialize_arrivals_through!(frontier: frontier)
    end
    ids = Array(version_ids || version_id).map(&:to_s).reject(&:empty?)
    raise Error, "frontier or at least one version_id is required" if ids.empty?
    rows = query("SELECT MAX(created_at)::text FROM local_source_item_version WHERE version_id IN (#{ids.map { |id| literal(id) }.join(', ')})")
    raise Error, "source item version not found" if rows.empty? || rows.fetch(0).to_s.empty?
    materialize_arrivals_through!(frontier: (parse_time(rows.fetch(0)) + 0.000001).utc.iso8601)
  end

  alias materialize_arrival! materialize_arrivals!
  alias ingest_arrivals! materialize_arrivals!

  def reportable_arrivals(limit: nil, include_placed: true)
    sql = <<~SQL
      SELECT a.arrival_id, a.version_id, a.item_key, a.capture_id, a.content_hash,
             a.information_arrival_at::text, a.nominal_slot_id, a.arrival_kind,
             a.created_at::text, a.updated_at::text,
             (p.placement_id IS NOT NULL)::text AS placed
        FROM local_reportable_arrival a
        LEFT JOIN local_report_item_placement p ON p.arrival_id = a.arrival_id
    SQL
    sql += " WHERE p.placement_id IS NULL" unless include_placed
    sql += " ORDER BY a.information_arrival_at ASC, a.arrival_id ASC"
    sql += " LIMIT #{Integer(limit)}" if limit
    query(sql).map do |row|
      row_to_hash(row, ARRIVAL_KEYS + ["placed"]).tap { |value| value["placed"] = truthy?(value.fetch("placed")) }
    end
  end

  # Publish at most one immutable edition for a scheduled slot.  A running
  # attempt is retained independently so failures remain auditable.  The
  # successful transaction locks the slot and writes edition, placements,
  # attempt, and state together.
  def publish_slot!(slot_id: nil, kind: nil, scheduled_at: nil, idempotency_key:, processing_frontier: nil,
                    selection_completeness_frontier: nil, configured_data_cutoff: nil, data_cutoff: nil,
                    comparison_watermark: "", edition_status: "normal", reason_codes: [])
    raise Error, "idempotency_key is required" if idempotency_key.to_s.empty?
    slot = slot!(slot_id: slot_id, kind: kind, scheduled_at: scheduled_at)
    reasons = Array(reason_codes).map(&:to_s).sort
    status = edition_status.to_s
    raise Error, "edition_status must be normal or degraded" unless %w[normal degraded].include?(status)
    allowed_reasons = %w[DEGRADED_COVERAGE DEGRADED_PROCESSING]
    if status == "normal" && !reasons.empty?
      raise Error, "normal edition cannot carry degraded reason codes"
    end
    if status == "degraded" && (reasons.empty? || (reasons - allowed_reasons).any?)
      raise Error, "degraded edition requires controlled reason codes"
    end
    # Parse and canonicalize equivalent timezone spellings before deriving the
    # idempotency payload.  Missing/ill-formed inputs fail before an attempt is
    # created; a semantic cutoff lag is handled below as a retained failed
    # attempt.
    begin
      frontiers = resolve_frontiers(slot, processing_frontier: processing_frontier,
                                    selection_completeness_frontier: selection_completeness_frontier,
                                    configured_data_cutoff: configured_data_cutoff, data_cutoff: data_cutoff,
                                    enforce_lag: false)
      watermark = normalize_comparison_watermark(comparison_watermark, frontiers.fetch("data_cutoff"), slot.fetch("scheduled_at"))
    rescue Error => error
      # The request never reached a publishable frontier, but retain a failed
      # attempt for operational audit (e.g. a missing explicit frontier).
      provisional = {
        "slot_id" => slot.fetch("slot_id"), "processing_frontier" => processing_frontier.to_s,
        "selection_completeness_frontier" => selection_completeness_frontier.to_s,
        "configured_data_cutoff" => configured_data_cutoff.to_s, "data_cutoff" => data_cutoff.to_s,
        "comparison_watermark" => comparison_watermark.to_s, "edition_status" => status, "reason_codes" => reasons
      }
      provisional_hash = Digest::SHA256.hexdigest(JSON.generate(provisional))
      attempt = append_running_attempt!(slot: slot, idempotency_key: idempotency_key.to_s, payload_hash: provisional_hash)
      mark_attempt_failed!(attempt_id: attempt.fetch("attempt_id"), reason: error.message) if attempt.fetch("state") == "running"
      raise
    end
    canonical_payload = {
      "slot_id" => slot.fetch("slot_id"), "configured_data_cutoff" => frontiers.fetch("configured_data_cutoff"),
      "processing_frontier" => frontiers.fetch("processing_frontier"),
      "selection_completeness_frontier" => frontiers.fetch("selection_completeness_frontier"),
      "data_cutoff" => frontiers.fetch("data_cutoff"), "comparison_watermark" => watermark,
      "edition_status" => status, "reason_codes" => reasons
    }
    payload_hash = Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
    attempt = append_running_attempt!(slot: slot, idempotency_key: idempotency_key.to_s, payload_hash: payload_hash)
    if attempt.fetch("state") == "published"
      return edition_for_attempt(attempt.fetch("attempt_id"))
    end
    if attempt.fetch("state") == "failed"
      raise Error, "idempotency key already failed: #{idempotency_key}"
    end

    begin
      if frontiers.fetch("lag_seconds") > 3600
        raise Error, "data_cutoff lag exceeds 60 minutes"
      end
      result = transaction do
        locked_slot = locked_slot!(slot.fetch("slot_id"))
        if locked_slot.fetch("state") == "published"
          existing = edition_for_slot_in_transaction(locked_slot.fetch("slot_id"))
          if existing && existing.fetch("attempt_id") == attempt.fetch("attempt_id") && existing.fetch("payload_hash") == payload_hash
            existing
          else
            raise Error, "report slot already published with a different payload"
          end
        elsif locked_slot.fetch("state") == "failed"
          raise Error, "report slot is failed and cannot be published"
        else
          # A completeness frontier is a claim about the source archive, so
          # materialize every immutable version before the cutoff in this same
          # serializable transaction before selecting placements.
          materialize_versions_before!(frontiers.fetch("data_cutoff"))
          selected = unplaced_arrivals_before(frontiers.fetch("data_cutoff"))
          edition_id = deterministic_edition_id(locked_slot.fetch("slot_id"), payload_hash)
          insert_edition!(edition_id: edition_id, slot: locked_slot, attempt_id: attempt.fetch("attempt_id"),
                          frontiers: frontiers, comparison_watermark: watermark, edition_status: status,
                          reason_codes: reasons, payload_hash: payload_hash, item_count: selected.length)
          selected.each_with_index do |arrival, index|
            backfill = arrival.fetch("nominal_slot_id") != locked_slot.fetch("slot_id")
            insert_placement!(edition_id: edition_id, arrival: arrival, sort_order: index,
                              placement_kind: backfill ? "PROCESSING_BACKFILL" : "normal",
                              reason_codes: backfill ? ["PROCESSING_BACKFILL"] : [])
          end
          transaction_query("UPDATE local_report_schedule_slot SET state = 'published' WHERE slot_id = #{literal(locked_slot.fetch('slot_id'))}")
          mark_attempt_published_in_transaction!(attempt.fetch("attempt_id"))
          edition_for_slot_in_transaction(locked_slot.fetch("slot_id"))
        end
      end
      result
    rescue StandardError => error
      begin
        mark_attempt_failed!(attempt_id: attempt.fetch("attempt_id"), reason: error.message)
      rescue StandardError
        nil
      end
      raise error if error.is_a?(Error)

      raise Error, error.message
    end
  end

  alias publish_edition! publish_slot!

  # A deadline/operations action may close a slot without producing an
  # edition.  Ordinary failed attempts deliberately do not call this method,
  # so a later attempt during the grace period can still publish.
  def mark_slot_failed!(slot_id: nil, kind: nil, scheduled_at: nil, reason:)
    slot = slot!(slot_id: slot_id, kind: kind, scheduled_at: scheduled_at)
    raise Error, "slot failure reason is required" if reason.to_s.strip.empty?
    transaction do
      locked = locked_slot!(slot.fetch("slot_id"))
      raise Error, "published report slot is immutable" if locked.fetch("state") == "published"
      if locked.fetch("state") == "failed"
        locked
      else
        transaction_query("UPDATE local_report_schedule_slot SET state = 'failed', failure_reason = #{literal(reason.to_s[0, 1000])} WHERE slot_id = #{literal(locked.fetch('slot_id'))} AND state = 'scheduled'")
        canonicalize_timestamps(row_to_hash(transaction_query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE slot_id = #{literal(locked.fetch('slot_id'))}").fetch(0), SLOT_KEYS))
      end
    end
  end

  alias fail_slot! mark_slot_failed!

  # Return the immutable, edition-bound metadata that is safe to send to a
  # summary provider.  The query is deliberately ordered by placement order
  # and reads archived version fields rather than the mutable current item
  # projection.  No URL or source authority field is included in this input.
  def report_summary_context(edition_id:)
    edition_rows = query(<<~SQL)
      SELECT edition_id, nominal_window_start::text, nominal_window_end::text,
             configured_data_cutoff::text, processing_frontier::text,
             selection_completeness_frontier::text, data_cutoff::text,
             comparison_watermark
        FROM local_report_edition
       WHERE edition_id = #{literal(edition_id)}
    SQL
    raise Error, "report edition not found: #{edition_id}" if edition_rows.empty?

    edition = row_to_hash(edition_rows.fetch(0), %w[edition_id nominal_window_start nominal_window_end configured_data_cutoff processing_frontier selection_completeness_frontier data_cutoff comparison_watermark])
    placements = query(<<~SQL).map do |row|
      SELECT p.sort_order, a.version_id, v.content_hash, v.title, v.summary,
             v.publisher_name, v.language
        FROM local_report_item_placement p
        JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
        JOIN local_source_item_version v ON v.version_id = a.version_id
       WHERE p.edition_id = #{literal(edition_id)}
       ORDER BY p.sort_order ASC
    SQL
      row_to_hash(row, %w[sort_order version_id content_hash title summary publisher language]).tap do |item|
        item["sort_order"] = item.fetch("sort_order").to_i
      end
    end
    {
      "edition_id" => edition.fetch("edition_id"),
      "boundary" => {
        "nominal_window_start" => canonicalize_timestamps(edition).fetch("nominal_window_start"),
        "nominal_window_end" => canonicalize_timestamps(edition).fetch("nominal_window_end"),
        "configured_data_cutoff" => canonicalize_timestamps(edition).fetch("configured_data_cutoff"),
        "processing_frontier" => canonicalize_timestamps(edition).fetch("processing_frontier"),
        "selection_completeness_frontier" => canonicalize_timestamps(edition).fetch("selection_completeness_frontier"),
        "data_cutoff" => canonicalize_timestamps(edition).fetch("data_cutoff"),
        "comparison_watermark" => canonicalize_timestamps(edition).fetch("comparison_watermark")
      },
      "placements" => placements
    }
  end

  # Append a summary attempt.  The idempotency key is the only key used to
  # locate a prior run; every other input is checked on replay so a key can
  # never silently point at a different edition or provider contract.
  def append_summary_run!(edition_id:, idempotency_key:, input_hash:, provider:, model:, prompt_version:)
    raise Error, "summary idempotency_key is required" if idempotency_key.to_s.empty?
    expected_input_hash = Digest::SHA256.hexdigest(JSON.generate(report_summary_context(edition_id: edition_id)))
    raise Error, "summary input_hash does not match server recomputation" unless input_hash.to_s == expected_input_hash
    retries = 0
    begin
      transaction do
        rows = transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE idempotency_key = #{literal(idempotency_key)} FOR UPDATE")
        if rows.empty?
          run_id = "summary-run-#{Digest::SHA256.hexdigest(idempotency_key.to_s)[0, 32]}"
          transaction_query(<<~SQL)
            INSERT INTO local_report_summary_run
              (run_id, edition_id, idempotency_key, input_hash, provider, model, prompt_version, state)
            VALUES (#{literal(run_id)}, #{literal(edition_id)}, #{literal(idempotency_key)}, #{literal(input_hash)},
                    #{literal(provider)}, #{literal(model)}, #{literal(prompt_version)}, 'running')
            ON CONFLICT (idempotency_key) DO NOTHING
          SQL
          rows = transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE idempotency_key = #{literal(idempotency_key)} FOR UPDATE")
        end
        run = normalize_summary_run(row_to_hash(rows.fetch(0), SUMMARY_RUN_KEYS))
        expected = {
          "edition_id" => edition_id.to_s, "input_hash" => input_hash.to_s,
          "provider" => provider.to_s, "model" => model.to_s,
          "prompt_version" => prompt_version.to_s
        }
        expected.each do |key, value|
          raise Error, "summary idempotency key payload differs (#{key})" unless run.fetch(key).to_s == value
        end
        run
      end
    rescue Error => error
      retries += 1
      retry if retries < 3 && serialization_conflict?(error)
      raise
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)

    raise Error, error.message
  end

  def finish_summary_failed!(run_id:, state:, reason:)
    normalized_state = state.to_s
    raise Error, "summary terminal state must be failed or blocked" unless %w[failed blocked].include?(normalized_state)
    raise Error, "summary failure reason is required" if reason.to_s.strip.empty?
    safe_reason = reason.to_s.gsub(/[\r\n\t]+/, " ").gsub(/\s+/, " ").strip[0, 2000]
    transaction do
      rows = transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE run_id = #{literal(run_id)} FOR UPDATE")
      raise Error, "summary run not found: #{run_id}" if rows.empty?
      run = normalize_summary_run(row_to_hash(rows.fetch(0), SUMMARY_RUN_KEYS))
      if run.fetch("state") == "running"
        transaction_query("UPDATE local_report_summary_run SET state = #{literal(normalized_state)}, finished_at = now(), error_reason = #{literal(safe_reason)} WHERE run_id = #{literal(run_id)}")
        run = normalize_summary_run(row_to_hash(transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE run_id = #{literal(run_id)}").fetch(0), SUMMARY_RUN_KEYS))
      elsif run.fetch("state") != normalized_state
        raise Error, "summary run is already terminal: #{run.fetch('state')}"
      end
      run
    end
  end

  # Atomically insert the immutable artifact and transition its run to
  # succeeded.  Deferrable database constraints enforce one artifact/run and
  # prevent a terminal non-success run from acquiring an artifact.
  def finish_summary_success!(run_id:, artifact:)
    transaction do
      rows = transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE run_id = #{literal(run_id)} FOR UPDATE")
      raise Error, "summary run not found: #{run_id}" if rows.empty?
      run = normalize_summary_run(row_to_hash(rows.fetch(0), SUMMARY_RUN_KEYS))
      if run.fetch("state") == "succeeded"
        { "run" => run, "artifact" => summary_artifact_for_run_in_transaction(run_id) }
      else
        raise Error, "summary run is already terminal: #{run.fetch('state')}" unless run.fetch("state") == "running"
        transaction_query(<<~SQL)
          INSERT INTO local_report_summary_artifact
            (artifact_id, run_id, edition_id, input_hash, provider, model, prompt_version,
             overview, key_changes, uncertainties, output_hash)
          VALUES (#{literal(artifact.fetch('artifact_id'))}, #{literal(run_id)}, #{literal(artifact.fetch('edition_id'))},
                  #{literal(artifact.fetch('input_hash'))}, #{literal(artifact.fetch('provider'))}, #{literal(artifact.fetch('model'))},
                  #{literal(artifact.fetch('prompt_version'))}, #{literal(JSON.generate(artifact.fetch('overview')))}::jsonb,
                  #{literal(JSON.generate(artifact.fetch('key_changes')))}::jsonb, #{literal(JSON.generate(artifact.fetch('uncertainties')))}::jsonb,
                  #{literal(artifact.fetch('output_hash'))})
        SQL
        transaction_query("UPDATE local_report_summary_run SET state = 'succeeded', finished_at = now(), error_reason = '' WHERE run_id = #{literal(run_id)}")
        terminal = normalize_summary_run(row_to_hash(transaction_query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE run_id = #{literal(run_id)}").fetch(0), SUMMARY_RUN_KEYS))
        { "run" => terminal, "artifact" => summary_artifact_for_run_in_transaction(run_id) }
      end
    end
  end

  def summary_runs_for_edition(edition_id:)
    query("SELECT #{summary_run_columns} FROM local_report_summary_run WHERE edition_id = #{literal(edition_id)} ORDER BY created_at ASC, run_id ASC").map do |row|
      normalize_summary_run(row_to_hash(row, SUMMARY_RUN_KEYS))
    end
  end

  def summary_artifact_for_run(run_id:)
    rows = query("SELECT #{summary_artifact_columns} FROM local_report_summary_artifact WHERE run_id = #{literal(run_id)}")
    return nil if rows.empty?

    normalize_summary_artifact(row_to_hash(rows.fetch(0), SUMMARY_ARTIFACT_KEYS))
  end

  def latest_summary_for_edition(edition_id:)
    return { "status" => "not_generated", "artifact" => nil, "runs" => [] } unless summary_tables_available?

    runs = summary_runs_for_edition(edition_id: edition_id)
    succeeded = query("SELECT #{summary_artifact_columns} FROM local_report_summary_artifact WHERE edition_id = #{literal(edition_id)} ORDER BY created_at DESC, run_id DESC LIMIT 1")
    if succeeded.empty?
      latest = runs.last
      state = latest ? latest.fetch("state") : "not_generated"
      state = "failed" if state == "running"
      return { "status" => state, "artifact" => nil, "runs" => runs }
    end
    artifact = normalize_summary_artifact(row_to_hash(succeeded.fetch(0), SUMMARY_ARTIFACT_KEYS))
    evidence = summary_evidence_for(edition_id: edition_id, artifact: artifact)
    artifact["evidence"] = evidence
    { "status" => "succeeded", "artifact" => artifact, "evidence" => evidence, "runs" => runs }
  end

  def summary_tables_available?
    query("SELECT to_regclass('local_report_summary_run') IS NOT NULL AND to_regclass('local_report_summary_artifact') IS NOT NULL").fetch(0) == "t"
  rescue Error
    false
  end

  # Summary is an additive projection.  A malformed or unavailable summary
  # row must never turn the raw edition read into an HTTP 5xx.
  def safe_latest_summary_for_edition(edition_id:)
    latest_summary_for_edition(edition_id: edition_id)
  rescue StandardError => error
    { "status" => "failed", "artifact" => nil, "runs" => [], "error" => error.message.to_s[0, 1000] }
  end

  def latest_report(kind:)
    normalized = kind.to_s
    raise Error, "kind must be morning or evening" unless KINDS.include?(normalized)
    slots = query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE kind = #{literal(normalized)} ORDER BY scheduled_at DESC LIMIT 1")
    editions = query(<<~SQL)
      SELECT e.edition_id, e.slot_id, e.attempt_id, e.nominal_window_start::text,
             e.nominal_window_end::text, e.configured_data_cutoff::text,
             e.processing_frontier::text, e.selection_completeness_frontier::text,
             e.data_cutoff::text, e.comparison_watermark,
             e.publication_committed_at::text, e.edition_status,
             e.reason_codes::text, e.summary_status, e.payload_hash,
             e.item_count, e.created_at::text, e.updated_at::text,
             s.kind, s.timezone, s.scheduled_at::text, s.state, s.failure_reason
        FROM local_report_edition e
        JOIN local_report_schedule_slot s ON s.slot_id = e.slot_id
       WHERE s.slot_id = #{literal(slots.empty? ? "__missing__" : row_to_hash(slots.fetch(0), SLOT_KEYS).fetch("slot_id"))}
    SQL
    summary = { "status" => "not_generated", "artifact" => nil, "runs" => [] }
    boundary = {
      "coverage" => "local source archive only; not global coverage",
      "summary_status" => summary.fetch("status"),
      "raw_listing_only" => true,
      "ai_summary_generated" => summary.fetch("status") == "succeeded"
    }
    if slots.empty?
      return { "status" => "not_run", "kind" => normalized, "edition" => nil, "items" => [], "summary" => { "status" => "not_generated", "artifact" => nil, "runs" => [] }, "boundary" => boundary }
    end
    slot = canonicalize_timestamps(row_to_hash(slots.fetch(0), SLOT_KEYS))
    if slot.fetch("state") == "failed"
      return { "status" => "failed", "kind" => normalized, "slot" => slot, "edition" => nil, "items" => [], "summary" => { "status" => "not_generated", "artifact" => nil, "runs" => [] }, "boundary" => boundary }
    end
    if editions.empty?
      return { "status" => "scheduled", "kind" => normalized, "slot" => slot, "edition" => nil, "items" => [], "summary" => { "status" => "not_generated", "artifact" => nil, "runs" => [] }, "boundary" => boundary }
    end
    raise Error, "published report slot has no edition" unless slot.fetch("state") == "published"

    edition = normalize_edition_row(row_to_hash(editions.fetch(0), EDITION_KEYS + %w[kind timezone scheduled_at slot_state slot_failure_reason]))
    summary = safe_latest_summary_for_edition(edition_id: edition.fetch("edition_id")) if summary_tables_available?
    boundary["summary_status"] = summary.fetch("status")
    boundary["ai_summary_generated"] = summary.fetch("status") == "succeeded"
    items = query(<<~SQL).map do |row|
      SELECT p.placement_id, p.sort_order, p.placement_kind, p.reason_codes::text,
             a.arrival_id, a.version_id, a.item_key, a.capture_id, a.content_hash,
             a.information_arrival_at::text, a.nominal_slot_id, a.arrival_kind,
             v.source_id, v.source_name, v.language,
             CASE WHEN t.status='translated' THEN t.translated_title ELSE v.title END,
             CASE WHEN t.status='translated' THEN t.translated_summary ELSE v.summary END,
             v.source_url, v.published_at::text, v.fetched_at::text, v.captured_at::text,
             v.publisher_name, v.publisher_url, v.publisher_id,
             v.publisher_identity_status, v.source_kind,
             v.title, v.summary,
             CASE WHEN v.language LIKE 'zh%' THEN 'not_needed'
                  WHEN t.status='translated' THEN 'translated' ELSE 'untranslated' END,
             COALESCE(t.artifact_id,''), COALESCE(t.created_at::text,'')
        FROM local_report_item_placement p
        JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
        JOIN local_source_item_version v ON v.version_id = a.version_id
        LEFT JOIN LATERAL (
          SELECT artifact_id, translated_title, translated_summary, status, created_at
            FROM local_translation_artifact
           WHERE item_key=v.item_key AND original_content_hash=v.content_hash
             AND target_language='zh-CN' AND status='translated'
           ORDER BY created_at DESC LIMIT 1
        ) t ON TRUE
       WHERE p.edition_id = #{literal(edition.fetch('edition_id'))}
       ORDER BY p.sort_order ASC
    SQL
      item = row_to_hash(row, PLACED_ITEM_KEYS)
      item["reason_codes"] = parse_json(item.fetch("reason_codes"))
      item
    end
    { "status" => "published", "kind" => normalized, "slot" => slot, "edition" => edition, "items" => items, "summary" => summary, "boundary" => boundary }
  end

  alias latest latest_report

  def health
    value = query("SELECT json_build_object('database', current_database(), 'server_version', current_setting('server_version'), 'status', 'ok')::text")
    JSON.parse(value.fetch(0))
  rescue StandardError => error
    raise Error, "local report ledger health check failed: #{error.message}"
  end

  private

  SLOT_KEYS = %w[slot_id kind timezone window_start window_end scheduled_at configured_data_cutoff config_hash state failure_reason created_at updated_at].freeze
  ARRIVAL_KEYS = %w[arrival_id version_id item_key capture_id content_hash information_arrival_at nominal_slot_id arrival_kind created_at updated_at].freeze
  ATTEMPT_KEYS = %w[attempt_id slot_id idempotency_key payload_hash state started_at finished_at failure_reason created_at updated_at].freeze
  EDITION_KEYS = %w[edition_id slot_id attempt_id nominal_window_start nominal_window_end configured_data_cutoff processing_frontier selection_completeness_frontier data_cutoff comparison_watermark publication_committed_at edition_status reason_codes summary_status payload_hash item_count created_at updated_at].freeze
  PLACED_ITEM_KEYS = %w[placement_id sort_order placement_kind reason_codes arrival_id version_id item_key capture_id content_hash information_arrival_at nominal_slot_id arrival_kind source_id source_name language title summary source_url published_at fetched_at captured_at publisher_name publisher_url publisher_id publisher_identity_status source_kind original_title original_summary translation_status translation_artifact_id translated_at].freeze
  SUMMARY_RUN_KEYS = %w[run_id edition_id idempotency_key input_hash provider model prompt_version state started_at finished_at error_reason created_at updated_at].freeze
  SUMMARY_ARTIFACT_KEYS = %w[artifact_id run_id edition_id input_hash provider model prompt_version overview key_changes uncertainties output_hash created_at].freeze
  TIMESTAMP_KEYS = %w[window_start window_end scheduled_at configured_data_cutoff created_at updated_at information_arrival_at started_at finished_at nominal_window_start nominal_window_end processing_frontier selection_completeness_frontier data_cutoff publication_committed_at published_at fetched_at captured_at comparison_watermark].freeze

  def slot_columns
    "slot_id, kind, timezone, window_start::text, window_end::text, scheduled_at::text, configured_data_cutoff::text, config_hash, state, failure_reason, created_at::text, updated_at::text"
  end

  def slot_definition(local_date, kind, configured_data_cutoff:, config_hash:)
    if kind == MORNING
      scheduled = local_time(local_date, 8)
      window_start = local_time(local_date - 1, 19)
    else
      scheduled = local_time(local_date, 19)
      window_start = local_time(local_date, 8)
    end
    cutoff = configured_data_cutoff ? parse_time(configured_data_cutoff) : scheduled
    raise Error, "configured_data_cutoff must not exceed scheduled_at" if cutoff > scheduled
    {
      "slot_id" => "report-#{kind}-#{local_date.strftime('%Y%m%d')}",
      "kind" => kind, "timezone" => TIMEZONE,
      "window_start" => window_start.utc.iso8601, "window_end" => scheduled.utc.iso8601,
      "scheduled_at" => scheduled.utc.iso8601, "configured_data_cutoff" => cutoff.utc.iso8601,
      "config_hash" => config_hash.to_s, "state" => "scheduled", "failure_reason" => ""
    }
  end

  def upsert_slot!(slot)
    retries = 0
    begin
      transaction do
        rows = transaction_query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE slot_id = #{literal(slot.fetch('slot_id'))} FOR UPDATE")
        if rows.empty?
          transaction_query(<<~SQL)
            INSERT INTO local_report_schedule_slot
              (slot_id, kind, timezone, window_start, window_end, scheduled_at, configured_data_cutoff, config_hash, state, failure_reason)
            VALUES (#{literal(slot.fetch('slot_id'))}, #{literal(slot.fetch('kind'))}, #{literal(slot.fetch('timezone'))},
                    #{literal(slot.fetch('window_start'))}, #{literal(slot.fetch('window_end'))}, #{literal(slot.fetch('scheduled_at'))},
                    #{literal(slot.fetch('configured_data_cutoff'))}, #{literal(slot.fetch('config_hash'))}, 'scheduled', '')
          SQL
          rows = transaction_query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE slot_id = #{literal(slot.fetch('slot_id'))}")
        end
        existing = canonicalize_timestamps(row_to_hash(rows.fetch(0), SLOT_KEYS))
        %w[kind timezone window_start window_end scheduled_at configured_data_cutoff config_hash].each do |key|
          raise Error, "report slot #{slot.fetch('slot_id')} immutable configuration differs" unless same_value?(existing.fetch(key), slot.fetch(key), timestamp: %w[window_start window_end scheduled_at configured_data_cutoff].include?(key))
        end
        existing
      end
    rescue Error => error
      retries += 1
      retry if retries < 3 && serialization_conflict?(error)
      raise
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)

    raise Error, error.message
  end

  def materialize_arrival_in_transaction!(version_id)
    rows = transaction_query(<<~SQL)
      SELECT version_id, item_key, capture_id, source_id, content_hash, created_at::text
        FROM local_source_item_version
       WHERE version_id = #{literal(version_id)}
       FOR SHARE
    SQL
    raise Error, "source item version not found: #{version_id}" if rows.empty?
    version = row_to_hash(rows.fetch(0), %w[version_id item_key capture_id source_id content_hash created_at])
    existing = transaction_query("SELECT #{arrival_columns} FROM local_reportable_arrival WHERE version_id = #{literal(version_id)}")
    return row_to_hash(existing.fetch(0), ARRIVAL_KEYS) unless existing.empty?

    previous_rows = transaction_query(<<~SQL)
      SELECT #{arrival_columns}
        FROM local_reportable_arrival
       WHERE item_key = #{literal(version.fetch('item_key'))}
         AND information_arrival_at <= #{literal(version.fetch('created_at'))}
       ORDER BY information_arrival_at DESC, created_at DESC, arrival_id DESC
       LIMIT 1
       FOR SHARE
    SQL
    previous = previous_rows.empty? ? nil : row_to_hash(previous_rows.fetch(0), ARRIVAL_KEYS)
    if previous && previous.fetch("content_hash") == version.fetch("content_hash")
      return previous.merge("reused" => true)
    end
    slot = nominal_slot_for(version.fetch("created_at"))
    arrival_kind = previous ? "content_update" : "first_seen"
    arrival_id = "arrival-#{version.fetch('version_id')}"
    transaction_query(<<~SQL)
      INSERT INTO local_reportable_arrival
        (arrival_id, version_id, item_key, capture_id, content_hash, information_arrival_at, nominal_slot_id, arrival_kind)
      VALUES (#{literal(arrival_id)}, #{literal(version.fetch('version_id'))}, #{literal(version.fetch('item_key'))},
              #{literal(version.fetch('capture_id'))}, #{literal(version.fetch('content_hash'))}, #{literal(version.fetch('created_at'))},
              #{literal(slot.fetch('slot_id'))}, #{literal(arrival_kind)})
      ON CONFLICT (version_id) DO NOTHING
    SQL
    stored = transaction_query("SELECT #{arrival_columns} FROM local_reportable_arrival WHERE version_id = #{literal(version_id)}")
    raise Error, "arrival disappeared during materialization: #{version_id}" if stored.empty?
    row_to_hash(stored.fetch(0), ARRIVAL_KEYS)
  end

  def materialize_versions_before!(cutoff)
    rows = transaction_query(<<~SQL)
      SELECT version_id, item_key, created_at::text
        FROM local_source_item_version
       WHERE created_at < #{literal(cutoff)}
       ORDER BY created_at ASC, version_id ASC
       FOR SHARE
    SQL
    rows.map do |row|
      version = row_to_hash(row, %w[version_id item_key created_at])
      # Row-level locking on the stable item identity serializes first_seen
      # and content_update decisions for concurrent publishers.
      transaction_query("SELECT item_key FROM local_source_item WHERE item_key = #{literal(version.fetch('item_key'))} FOR UPDATE")
      materialize_arrival_in_transaction!(version.fetch("version_id"))
    end
  end

  def arrival_columns
    "arrival_id, version_id, item_key, capture_id, content_hash, information_arrival_at::text, nominal_slot_id, arrival_kind, created_at::text, updated_at::text"
  end

  def nominal_slot_for(created_at)
    rows = transaction_query(<<~SQL)
      SELECT #{slot_columns} FROM local_report_schedule_slot
       WHERE window_start <= #{literal(created_at)} AND window_end > #{literal(created_at)}
       ORDER BY window_start DESC LIMIT 1
    SQL
    raise Error, "no nominal report slot covers source version created_at #{created_at}" if rows.empty?
    canonicalize_timestamps(row_to_hash(rows.fetch(0), SLOT_KEYS))
  end

  def resolve_frontiers(slot, processing_frontier:, selection_completeness_frontier:, configured_data_cutoff:, data_cutoff:, enforce_lag: true)
    scheduled = parse_time(slot.fetch("scheduled_at"))
    configured = parse_time(slot.fetch("configured_data_cutoff"))
    if configured_data_cutoff && parse_time(configured_data_cutoff).utc != configured.utc
      raise Error, "configured_data_cutoff differs from immutable slot configuration"
    end
    raise Error, "processing_frontier is required" if processing_frontier.to_s.empty?
    raise Error, "selection_completeness_frontier is required" if selection_completeness_frontier.to_s.empty?
    processing = parse_time(processing_frontier)
    selection = parse_time(selection_completeness_frontier)
    raise Error, "configured_data_cutoff must not exceed scheduled_at" if configured > scheduled
    cutoff = [configured, processing, selection].min
    if data_cutoff
      supplied = parse_time(data_cutoff)
      raise Error, "data_cutoff must equal the minimum of configured cutoff/frontiers" unless supplied == cutoff
    end
    previous = query("SELECT COALESCE(MAX(data_cutoff)::text, '__none__') FROM local_report_edition").fetch(0)
    if previous != '__none__' && cutoff < parse_time(previous)
      raise Error, "data_cutoff cannot move backwards"
    end
    lag_seconds = scheduled - cutoff
    raise Error, "data_cutoff lag exceeds 60 minutes" if enforce_lag && lag_seconds > 3600
    {
      "configured_data_cutoff" => configured.utc.iso8601,
      "processing_frontier" => processing.utc.iso8601,
      "selection_completeness_frontier" => selection.utc.iso8601,
      "data_cutoff" => cutoff.utc.iso8601,
      "lag_seconds" => lag_seconds
    }
  rescue ArgumentError => error
    raise Error, "invalid report frontier: #{error.message}"
  end

  def normalize_comparison_watermark(value, cutoff, scheduled)
    raise Error, "comparison_watermark is required" if value.to_s.empty?
    watermark = parse_time(value)
    raise Error, "comparison_watermark must not exceed data_cutoff" if watermark > parse_time(cutoff)
    raise Error, "comparison_watermark must not exceed scheduled_at" if watermark > parse_time(scheduled)
    watermark.utc.iso8601
  end

  def append_running_attempt!(slot:, idempotency_key:, payload_hash:)
    retries = 0
    begin
      transaction do
        rows = transaction_query("SELECT #{attempt_columns} FROM local_report_publication_attempt WHERE idempotency_key = #{literal(idempotency_key)} FOR UPDATE")
        if rows.empty?
          attempt_id = "attempt-#{Digest::SHA256.hexdigest(idempotency_key)[0, 24]}"
          transaction_query(<<~SQL)
            INSERT INTO local_report_publication_attempt
              (attempt_id, slot_id, idempotency_key, payload_hash, state)
            VALUES (#{literal(attempt_id)}, #{literal(slot.fetch('slot_id'))}, #{literal(idempotency_key)}, #{literal(payload_hash)}, 'running')
          SQL
          rows = transaction_query("SELECT #{attempt_columns} FROM local_report_publication_attempt WHERE idempotency_key = #{literal(idempotency_key)} FOR UPDATE")
        end
        attempt = row_to_hash(rows.fetch(0), ATTEMPT_KEYS)
        raise Error, "idempotency key payload differs" unless attempt.fetch("payload_hash") == payload_hash
        raise Error, "idempotency key belongs to a different slot" unless attempt.fetch("slot_id") == slot.fetch("slot_id")
        attempt
      end
    rescue Error => error
      retries += 1
      retry if retries < 3 && serialization_conflict?(error)
      raise
    end
  rescue StandardError => error
    raise error if error.is_a?(Error)

    raise Error, error.message
  end

  def attempt_columns
    "attempt_id, slot_id, idempotency_key, payload_hash, state, started_at::text, finished_at::text, failure_reason, created_at::text, updated_at::text"
  end

  def locked_slot!(slot_id)
    rows = transaction_query("SELECT #{slot_columns} FROM local_report_schedule_slot WHERE slot_id = #{literal(slot_id)} FOR UPDATE")
    raise Error, "report slot not found: #{slot_id}" if rows.empty?
    canonicalize_timestamps(row_to_hash(rows.fetch(0), SLOT_KEYS))
  end

  def unplaced_arrivals_before(cutoff)
    transaction_query(<<~SQL).map { |row| row_to_hash(row, ARRIVAL_KEYS) }
      SELECT #{arrival_columns}
        FROM local_reportable_arrival a
       WHERE a.information_arrival_at < #{literal(cutoff)}
         AND NOT EXISTS (SELECT 1 FROM local_report_item_placement p WHERE p.arrival_id = a.arrival_id)
       ORDER BY a.information_arrival_at ASC, a.arrival_id ASC
    SQL
  end

  def insert_edition!(edition_id:, slot:, attempt_id:, frontiers:, comparison_watermark:, edition_status:, reason_codes:, payload_hash:, item_count:)
    transaction_query(<<~SQL)
      INSERT INTO local_report_edition
        (edition_id, slot_id, attempt_id, nominal_window_start, nominal_window_end,
         configured_data_cutoff, processing_frontier, selection_completeness_frontier,
         data_cutoff, comparison_watermark, edition_status, reason_codes, summary_status,
         payload_hash, item_count)
      VALUES (#{literal(edition_id)}, #{literal(slot.fetch('slot_id'))}, #{literal(attempt_id)},
              #{literal(slot.fetch('window_start'))}, #{literal(slot.fetch('window_end'))},
              #{literal(frontiers.fetch('configured_data_cutoff'))}, #{literal(frontiers.fetch('processing_frontier'))},
              #{literal(frontiers.fetch('selection_completeness_frontier'))}, #{literal(frontiers.fetch('data_cutoff'))},
              #{literal(comparison_watermark.to_s)}, #{literal(edition_status)}, #{literal(JSON.generate(reason_codes))}::jsonb,
              'not_generated', #{literal(payload_hash)}, #{Integer(item_count)})
    SQL
  end

  def insert_placement!(edition_id:, arrival:, sort_order:, placement_kind:, reason_codes:)
    placement_id = "placement-#{Digest::SHA256.hexdigest([edition_id, arrival.fetch('arrival_id')].join(':'))[0, 28]}"
    transaction_query(<<~SQL)
      INSERT INTO local_report_item_placement
        (placement_id, edition_id, arrival_id, nominal_slot_id, sort_order, placement_kind, reason_codes)
      VALUES (#{literal(placement_id)}, #{literal(edition_id)}, #{literal(arrival.fetch('arrival_id'))}, #{literal(arrival.fetch('nominal_slot_id'))},
              #{Integer(sort_order)}, #{literal(placement_kind)}, #{literal(JSON.generate(reason_codes))}::jsonb)
    SQL
  end

  def mark_attempt_published_in_transaction!(attempt_id)
    transaction_query("UPDATE local_report_publication_attempt SET state = 'published', finished_at = now(), failure_reason = '' WHERE attempt_id = #{literal(attempt_id)} AND state = 'running'")
  end

  def mark_attempt_failed!(attempt_id:, reason:)
    transaction do
      transaction_query("UPDATE local_report_publication_attempt SET state = 'failed', finished_at = now(), failure_reason = #{literal(reason.to_s[0, 1000])} WHERE attempt_id = #{literal(attempt_id)} AND state = 'running'")
    end
  end

  def edition_for_slot_in_transaction(slot_id)
    rows = transaction_query(<<~SQL)
      SELECT #{edition_columns}
        FROM local_report_edition WHERE slot_id = #{literal(slot_id)}
    SQL
    return nil if rows.empty?

    normalize_edition_row(row_to_hash(rows.fetch(0), EDITION_KEYS))
  end

  def edition_for_attempt(attempt_id)
    rows = query("SELECT #{edition_columns} FROM local_report_edition WHERE attempt_id = #{literal(attempt_id)}")
    raise Error, "published report attempt has no edition" if rows.empty?
    normalize_edition_row(row_to_hash(rows.fetch(0), EDITION_KEYS))
  end

  def edition_columns
    "edition_id, slot_id, attempt_id, nominal_window_start::text, nominal_window_end::text, configured_data_cutoff::text, processing_frontier::text, selection_completeness_frontier::text, data_cutoff::text, comparison_watermark, publication_committed_at::text, edition_status, reason_codes::text, summary_status, payload_hash, item_count, created_at::text, updated_at::text"
  end

  def summary_run_columns
    "run_id, edition_id, idempotency_key, input_hash, provider, model, prompt_version, state, started_at::text, finished_at::text, regexp_replace(error_reason, E'[\\n\\r\\t]+', ' ', 'g'), created_at::text, updated_at::text"
  end

  def summary_artifact_columns
    "artifact_id, run_id, edition_id, input_hash, provider, model, prompt_version, overview::text, key_changes::text, uncertainties::text, output_hash, created_at::text"
  end

  def normalize_summary_run(row)
    canonicalize_timestamps(row)
  end

  def normalize_summary_artifact(row)
    normalized = canonicalize_timestamps(row)
    %w[overview key_changes uncertainties].each { |key| normalized[key] = parse_json(normalized.fetch(key)) }
    normalized
  end

  def summary_artifact_for_run_in_transaction(run_id)
    rows = transaction_query("SELECT #{summary_artifact_columns} FROM local_report_summary_artifact WHERE run_id = #{literal(run_id)}")
    return nil if rows.empty?

    normalize_summary_artifact(row_to_hash(rows.fetch(0), SUMMARY_ARTIFACT_KEYS))
  end

  def summary_evidence_for(edition_id:, artifact:)
    citation_ids = []
    [artifact.fetch("overview"), *artifact.fetch("key_changes"), *artifact.fetch("uncertainties")].each do |unit|
      citation_ids.concat(Array(unit.fetch("cited_version_ids")))
    end
    citation_ids = citation_ids.map(&:to_s).uniq
    return [] if citation_ids.empty?

    values = citation_ids.map { |id| literal(id) }.join(", ")
    query(<<~SQL).map { |row| row_to_hash(row, %w[version_id title source_url publisher]) }
      SELECT v.version_id, v.title, v.source_url, v.publisher_name AS publisher
        FROM local_report_item_placement p
        JOIN local_reportable_arrival a ON a.arrival_id = p.arrival_id
        JOIN local_source_item_version v ON v.version_id = a.version_id
       WHERE p.edition_id = #{literal(edition_id)}
         AND v.version_id IN (#{values})
       ORDER BY array_position(ARRAY[#{values}]::text[], v.version_id)
    SQL
  end

  def normalize_edition_row(row)
    normalized = canonicalize_timestamps(row)
    normalized["reason_codes"] = parse_json(normalized.fetch("reason_codes"))
    normalized["item_count"] = normalized.fetch("item_count").to_i
    normalized
  end

  def deterministic_edition_id(slot_id, payload_hash)
    "edition-#{slot_id}-#{payload_hash[0, 16]}"
  end

  def parse_local_date(value)
    return value if value.is_a?(Date)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    raise Error, "invalid local date: #{value.inspect}"
  end

  def local_time(date, hour)
    Time.new(date.year, date.month, date.day, hour, 0, 0, "+08:00")
  end

  def parse_time(value)
    return value if value.is_a?(Time)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    begin
      Time.parse(value.to_s)
    rescue ArgumentError => error
      raise Error, "invalid timestamp: #{value.inspect} (#{error.message})"
    end
  end

  def same_value?(left, right, timestamp: false)
    return parse_time(left).utc == parse_time(right).utc if timestamp
    left.to_s == right.to_s
  rescue Error, ArgumentError
    left.to_s == right.to_s
  end

  def row_to_hash(row, keys)
    keys.each_with_index.to_h { |key, index| [key, row.to_s.split("\t", -1).fetch(index, "")] }
  end

  def canonicalize_timestamps(value)
    value.each_with_object({}) do |(key, raw), result|
      result[key] = if TIMESTAMP_KEYS.include?(key) && !raw.to_s.empty?
                      parse_time(raw).utc.iso8601
                    else
                      raw
                    end
    end
  end

  def parse_json(value)
    JSON.parse(value.to_s.empty? ? "[]" : value.to_s)
  rescue JSON::ParserError => error
    raise Error, "invalid report JSON value: #{error.message}"
  end

  def truthy?(value)
    %w[t true 1].include?(value.to_s.downcase)
  end

  def serialization_conflict?(error)
    error.message.to_s.match?(/could not serialize access|deadlock detected/i)
  end

  def literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  def query(sql)
    return transaction_query(sql) if @transaction_io
    stdout, stderr, status = Open3.capture3(*psql_args + ["-c", sql])
    raise Error, stderr.strip unless status.success?
    stdout.lines(chomp: true).reject(&:empty?)
  end

  def transaction
    raise Error, "nested report ledger transaction is not supported" if @transaction_io
    open_transaction
    begin_serializable_transaction
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

  def psql_args
    [@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", @host, "-p", @port, "-U", @user, "-d", @database]
  end

  def open_transaction
    @transaction_io = Open3.popen3(*psql_args)
    @transaction_stdin, @transaction_stdout, @transaction_stderr, @transaction_wait_thread = @transaction_io
    @transaction_stdin.sync = true
    @transaction_stdout.sync = true
  end

  def transaction_query(sql)
    raise Error, "local report ledger transaction is not open" unless @transaction_io
    marker = "__local_report_txn_marker_#{SecureRandom.hex(12)}__"
    command = sql.to_s.strip
    command = "#{command};" unless command.end_with?(";")
    @transaction_stdin.write("#{command}\nSELECT #{literal(marker)};\n")
    @transaction_stdin.flush
    rows = []
    loop do
      line = @transaction_stdout.gets
      if line.nil?
        error = @transaction_stderr.read.to_s.strip
        raise Error, error.empty? ? "local report transaction connection closed" : error
      end
      value = line.chomp
      break if value == marker
      rows << value unless value.empty?
    end
    rows
  end

  # Keep SET TRANSACTION before the marker SELECT (which itself is a query
  # visible to PostgreSQL).  This makes SERIALIZABLE the first statement after
  # BEGIN for every ledger transaction while retaining the streaming psql
  # protocol used by transaction_query.
  def begin_serializable_transaction
    marker = "__local_report_txn_begin_marker_#{SecureRandom.hex(12)}__"
    @transaction_stdin.write("BEGIN;\nSET TRANSACTION ISOLATION LEVEL SERIALIZABLE;\nSELECT #{literal(marker)};\n")
    @transaction_stdin.flush
    loop do
      line = @transaction_stdout.gets
      if line.nil?
        error = @transaction_stderr.read.to_s.strip
        raise Error, error.empty? ? "local report transaction connection closed" : error
      end
      break if line.chomp == marker
    end
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
end
