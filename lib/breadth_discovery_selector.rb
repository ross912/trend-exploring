# frozen_string_literal: true

require "digest"
require "json"
require "time"

# Deterministic selector for the locale-conditioned, topic-unconditioned
# exploration lane.  This class deliberately operates on immutable version
# shaped hashes; it never reads the current item projection and never mutates
# its input rows.
class BreadthDiscoverySelector
  DEFAULT_LIMIT = 12
  DEFAULT_LOCALE_LIMIT = 2
  DEFAULT_PUBLISHER_LIMIT = 1
  MANIFEST_VERSION = "pre_detection_random_exploration_v1"
  DEFAULT_SCOPE_ID = "locale_frontier"
  DEFAULT_SEED = "trend-exploring-pre-detection-v1"
  DELIVERY_STATUS_UNMEASURED = "unmeasured"
  MANIFEST_ITEM_FIELDS = %w[
    version_id item_key capture_id source_id source_name publisher_id publisher_name
    publisher_url publisher_identity_status source_kind discovery_basis
    query_conditioned analysis_policy aggregator_id locale_tag market_label
    market_label_basis query_topics title summary source_url published_at fetched_at
    captured_at content_hash rights_scope
  ].freeze

  class Error < StandardError; end

  def initialize(limit: DEFAULT_LIMIT, locale_limit: DEFAULT_LOCALE_LIMIT,
                 publisher_limit: DEFAULT_PUBLISHER_LIMIT, seed: nil,
                 policy_version: MANIFEST_VERSION)
    @limit = Integer(limit)
    @locale_limit = Integer(locale_limit)
    @publisher_limit = Integer(publisher_limit)
    @default_seed = seed.nil? ? nil : seed.to_s
    @policy_version = policy_version.to_s
    raise Error, "limit must be positive" unless @limit.positive?
    raise Error, "locale_limit must be positive" unless @locale_limit.positive?
    raise Error, "publisher_limit must be positive" unless @publisher_limit.positive?
    raise Error, "seed cannot be empty" if !seed.nil? && @default_seed.empty?
    raise Error, "policy_version is required" if @policy_version.empty?
  end

  # Select at most +limit+ rows.  Rows must be immutable version records (or
  # hashes with the same fields).  The resulting order is independent of the
  # input order.
  def select(items:, limit: @limit, seed: nil, scope_id: DEFAULT_SCOPE_ID,
             detector_results: {})
    effective_seed = seed.nil? ? @default_seed : seed.to_s
    unless effective_seed.nil? || effective_seed.empty?
      return selection_manifest(items: items, scope_id: scope_id, seed: effective_seed,
                                limit: limit, detector_results: detector_results)
        .fetch("selected_items")
    end

    deterministic_select(items: items, limit: limit)
  end

  # Freeze a detector-independent, seeded random exploration decision.  The
  # manifest is deliberately a pure value: callers persist it together with a
  # batch and can reproduce it without reading a current projection, click
  # history, user profile, or personal memory.  Detector results are recorded
  # as context only; a no-candidate result never removes an eligible item.
  def selection_manifest(items:, scope_id: DEFAULT_SCOPE_ID, seed: @default_seed,
                         limit: @limit, detector_results: {})
    scope = scope_id.to_s.strip
    frozen_seed = seed.to_s
    raise Error, "scope_id is required" if scope.empty?
    raise Error, "seed is required" if frozen_seed.empty?
    limit = Integer(limit)
    raise Error, "limit must be positive" unless limit.positive?

    normalized = Array(items).each_with_index.map do |item, index|
      normalize_manifest_item(item, index: index)
    end
    normalized.sort_by! { |entry| [entry.fetch("identity_key"), entry.fetch("item_hash"), entry.fetch("input_index")] }
    # Input order is not a decision factor.  Reassign a canonical ordinal only
    # after sorting so the persisted manifest is byte-identical for a shuffled
    # copy of the same immutable input set.
    normalized.each_with_index { |entry, index| entry["input_index"] = index }

    # A duplicate immutable version is not silently counted twice.  It still
    # receives a terminal eligibility decision so the denominator cannot be
    # reduced by dropping rows after inspecting their content.
    seen_identities = Hash.new(0)
    eligibility_units = []
    eligibility_decisions = []
    normalized.each do |entry|
      identity = entry.fetch("identity_key")
      occurrence = seen_identities[identity]
      duplicate = occurrence.positive?
      seen_identities[identity] += 1
      eligible = entry.fetch("eligible") && !duplicate
      reason = if duplicate
                 "duplicate_version_id"
               else
                 entry.fetch("eligibility_reason")
               end
      unit_id = stable_id("eligibility", scope, frozen_seed, identity, entry.fetch("item_hash"), occurrence)
      decision_id = stable_id("eligibility-decision", unit_id)
      unit = {
        "eligibility_unit_id" => unit_id,
        "scope_id" => scope,
        "version_id" => entry.fetch("version_id"),
        "item_hash" => entry.fetch("item_hash"),
        "policy_version" => @policy_version,
        "eligibility_predicate" => "locale_headlines_exploration_contract_v1",
        "input_index" => entry.fetch("input_index")
      }
      decision = unit.merge(
        "eligibility_decision_id" => decision_id,
        "outcome" => eligible ? "eligible" : "ineligible",
        "reason_code" => reason,
        "terminal" => true
      )
      eligibility_units << unit
      eligibility_decisions << decision
      entry["eligibility_unit_id"] = unit_id
      entry["eligible"] = eligible
      entry["eligibility_reason"] = reason
    end

    eligibility_set_hash = digest(eligibility_decisions.map do |decision|
      [decision.fetch("eligibility_unit_id"), decision.fetch("outcome"), decision.fetch("reason_code")]
    end)
    manifest_id = stable_id("manifest", scope, frozen_seed, @policy_version, eligibility_set_hash)

    eligible_entries = normalized.select { |entry| entry.fetch("eligible") }
    eligible_entries.each do |entry|
      entry["random_key"] = digest([frozen_seed, scope, entry.fetch("identity_key")].join("\u0000"))
      entry["detector_outcome"] = detector_outcome_for(detector_results, entry.fetch("version_id"))
    end
    eligible_entries.sort_by! { |entry| [entry.fetch("random_key"), entry.fetch("identity_key"), entry.fetch("item_hash")] }

    publisher_counts = Hash.new(0)
    locale_counts = Hash.new(0)
    unresolved_counts = Hash.new(0)
    selected_entries = []
    exploration_units = []
    exploration_decisions = []
    eligible_entries.each_with_index do |entry, index|
      item = entry.fetch("item")
      publisher_id = item.fetch("publisher_id")
      locale_tag = item.fetch("locale_tag")
      resolved = resolved_publisher?(item)
      source_id = item.fetch("source_id")
      rejection = nil
      if selected_entries.length >= limit
        rejection = "selection_limit"
      elsif locale_counts[locale_tag] >= @locale_limit
        rejection = "locale_cap"
      elsif resolved && publisher_counts[publisher_id] >= @publisher_limit
        rejection = "publisher_cap"
      elsif !resolved && unresolved_counts[source_id] >= 1
        rejection = "unresolved_source_cap"
      end
      outcome = rejection.nil? ? "selected" : "not_selected"
      exploration_unit_id = stable_id("exploration", manifest_id, entry.fetch("eligibility_unit_id"))
      decision_id = stable_id("exploration-decision", exploration_unit_id)
      exploration_units << {
        "exploration_unit_id" => exploration_unit_id,
        "manifest_id" => manifest_id,
        "eligibility_unit_id" => entry.fetch("eligibility_unit_id"),
        "version_id" => entry.fetch("version_id"),
        "random_key" => entry.fetch("random_key"),
        "detector_outcome" => entry.fetch("detector_outcome"),
        "input_index" => entry.fetch("input_index")
      }
      exploration_decisions << {
        "exploration_decision_id" => decision_id,
        "exploration_unit_id" => exploration_unit_id,
        "manifest_id" => manifest_id,
        "outcome" => outcome,
        "reason_code" => rejection || "seeded_random_priority",
        "sort_order" => index,
        "selection_order" => nil,
        "not_a_signal" => true,
        "delivery_status" => DELIVERY_STATUS_UNMEASURED,
        "terminal" => true
      }
      next unless outcome == "selected"

      selected_entries << entry
      locale_counts[locale_tag] += 1
      if resolved
        publisher_counts[publisher_id] += 1
      else
        unresolved_counts[source_id] += 1
      end
    end

    selected_entries.each_with_index do |entry, selection_order|
      unit_id = stable_id("exploration", manifest_id, entry.fetch("eligibility_unit_id"))
      exploration_decisions.find { |decision| decision.fetch("exploration_unit_id") == unit_id }["selection_order"] = selection_order
    end

    selected_ids = selected_entries.map { |entry| entry.fetch("version_id") }
    selected_set_hash = digest(selected_ids.sort)
    selected_order_hash = digest(selected_ids)
    decisions_by_unit = exploration_decisions.to_h { |decision| [decision.fetch("exploration_unit_id"), decision] }
    selected_items = selected_entries.each_with_index.map do |entry, index|
      decision = decisions_by_unit.fetch(stable_id("exploration", manifest_id, entry.fetch("eligibility_unit_id")))
      entry.fetch("item").merge(
        "allocation_lane" => "random_exploration",
        "selection_manifest_id" => manifest_id,
        "selection_seed" => frozen_seed,
        "selection_order" => index,
        "selection_outcome" => decision.fetch("outcome"),
        "selection_reason" => decision.fetch("reason_code"),
        "not_a_signal" => true,
        "delivery_status" => DELIVERY_STATUS_UNMEASURED,
        "detector_outcome" => entry.fetch("detector_outcome")
      )
    end

    manifest = {
      "manifest_id" => manifest_id,
      "manifest_version" => MANIFEST_VERSION,
      "scope_id" => scope,
      "seed" => frozen_seed,
      "policy_version" => @policy_version,
      "limit" => limit,
      "locale_limit" => @locale_limit,
      "publisher_limit" => @publisher_limit,
      "eligibility_count" => eligibility_decisions.length,
      "eligible_count" => eligibility_decisions.count { |decision| decision.fetch("outcome") == "eligible" },
      "ineligible_count" => eligibility_decisions.count { |decision| decision.fetch("outcome") == "ineligible" },
      "selection_decision_count" => exploration_decisions.length,
      "selected_count" => selected_entries.length,
      "eligibility_set_hash" => eligibility_set_hash,
      "selected_set_hash" => selected_set_hash,
      "selected_order_hash" => selected_order_hash,
      "status" => "frozen",
      "delivery_status" => DELIVERY_STATUS_UNMEASURED,
      "not_a_signal" => true,
      "personalization" => "none",
      "eligibility_units" => eligibility_units,
      "eligibility_decisions" => eligibility_decisions,
      "exploration_units" => exploration_units,
      "exploration_decisions" => exploration_decisions,
      # Canonical long names are included so the value can be persisted
      # directly as a manifest payload without a caller-side reinterpretation.
      "pre_detection_exploration_eligibility_units" => eligibility_units,
      "pre_detection_exploration_eligibility_decisions" => eligibility_decisions,
      "pre_detection_exploration_units" => exploration_units,
      "pre_detection_exploration_decisions" => exploration_decisions,
      "selected_version_ids" => selected_ids,
      "selected_items" => selected_items
    }
    deep_freeze_value(manifest)
  rescue ArgumentError, TypeError, KeyError => error
    raise Error, "selection manifest is incomplete: #{error.message}"
  end

  alias pre_detection_selection_manifest selection_manifest
  alias seeded_selection_manifest selection_manifest

  def select_seeded(items:, scope_id: DEFAULT_SCOPE_ID, seed: DEFAULT_SEED,
                    limit: @limit, detector_results: {})
    selection_manifest(items: items, scope_id: scope_id, seed: seed, limit: limit,
                       detector_results: detector_results).fetch("selected_items")
  end

  private

  def deterministic_select(items:, limit:)
    limit = Integer(limit)
    raise Error, "limit must be positive" unless limit.positive?

    candidates = Array(items).each_with_object([]) do |item, result|
      candidate = normalize_candidate(item)
      result << candidate unless candidate.nil?
    end
    candidates.sort_by! { |item| sort_key(item) }

    publisher_counts = Hash.new(0)
    locale_counts = Hash.new(0)
    unresolved_counts = Hash.new(0)
    selected = []
    candidates.each do |item|
      break if selected.length >= limit

      publisher_id = item.fetch("publisher_id")
      locale_tag = item.fetch("locale_tag")
      resolved = resolved_publisher?(item)
      source_id = item.fetch("source_id")

      next if locale_counts[locale_tag] >= @locale_limit
      if resolved
        next if publisher_id.empty? || publisher_counts[publisher_id] >= @publisher_limit
      else
        # Unresolved publisher identities are not guessed.  At most one such
        # row per source is retained, while still allowing a resolved row from
        # the same source to win first under the stable ordering.
        next if unresolved_counts[source_id] >= 1
      end

      selected << item
      locale_counts[locale_tag] += 1
      if resolved
        publisher_counts[publisher_id] += 1
      else
        unresolved_counts[source_id] += 1
      end
    end
    selected
  end

  alias select_versions select

  def call(items, limit: @limit)
    select(items: items, limit: limit)
  end

  def normalize_candidate(item)
    raise Error, "selector row must be an object" unless item.is_a?(Hash)

    source_kind = item.fetch("source_kind", "").to_s
    discovery_basis = item.fetch("discovery_basis", "").to_s
    analysis_policy = item.fetch("analysis_policy", "").to_s
    query_conditioned = truthy?(item.fetch("query_conditioned", false))
    return nil unless source_kind == "discovery" && discovery_basis == "locale_headlines"
    return nil unless analysis_policy == "exploration_only" && !query_conditioned

    version_id = item.fetch("version_id", "").to_s
    source_id = item.fetch("source_id", "").to_s
    locale_tag = item.fetch("locale_tag", "").to_s
    raise Error, "selector row is missing version/source/locale" if version_id.empty? || source_id.empty? || locale_tag.empty?

    publisher_status = item.fetch("publisher_identity_status", "unresolved").to_s
    publisher_id = item.fetch("publisher_id", "").to_s
    publisher_id = "" if publisher_status == "unresolved"
    item.merge(
      "version_id" => version_id,
      "source_id" => source_id,
      "locale_tag" => locale_tag,
      "publisher_id" => publisher_id,
      "publisher_identity_status" => publisher_status
    )
  rescue KeyError => error
    raise Error, "selector row is incomplete: #{error.message}"
  end

  def normalize_manifest_item(item, index:)
    item_hash = canonical_hash(item)
    unless item.is_a?(Hash)
      return {
        "item" => {}, "version_id" => "invalid-#{item_hash[0, 16]}",
        "identity_key" => "invalid-#{item_hash}", "item_hash" => item_hash,
        "input_index" => index, "eligible" => false,
        "eligibility_reason" => "invalid_item"
      }
    end
    safe_item = item.select { |key, _value| MANIFEST_ITEM_FIELDS.include?(key.to_s) }
    version_id = safe_item.fetch("version_id", safe_item.fetch("item_key", "")).to_s.strip
    identity_key = version_id.empty? ? "item-#{item_hash}" : version_id
    begin
      candidate = normalize_candidate(safe_item)
      if candidate.nil?
        {
          "item" => safe_item, "version_id" => version_id.empty? ? identity_key : version_id,
          "identity_key" => identity_key, "item_hash" => item_hash,
          "input_index" => index, "eligible" => false,
          "eligibility_reason" => "not_locale_exploration_contract"
        }
      else
        {
          "item" => candidate, "version_id" => candidate.fetch("version_id"),
          "identity_key" => identity_key, "item_hash" => item_hash,
          "input_index" => index, "eligible" => true,
          "eligibility_reason" => "eligible_locale_exploration"
        }
      end
    rescue KeyError, ArgumentError, TypeError
      {
        "item" => safe_item, "version_id" => version_id.empty? ? identity_key : version_id,
        "identity_key" => identity_key, "item_hash" => item_hash,
        "input_index" => index, "eligible" => false,
        "eligibility_reason" => "invalid_item"
      }
    end
  end

  def detector_outcome_for(detector_results, version_id)
    case detector_results
    when Hash
      value = if detector_results.key?(version_id)
                detector_results.fetch(version_id)
              elsif detector_results.key?(version_id.to_sym)
                detector_results.fetch(version_id.to_sym)
              else
                "not_run"
              end
      value.is_a?(Hash) ? value.fetch("outcome", value.fetch(:outcome, "not_run")).to_s : value.to_s
    else
      "not_run"
    end
  end

  def stable_id(prefix, *parts)
    "#{prefix}-#{digest(parts.map(&:to_s))}"
  end

  def digest(value)
    payload = value.is_a?(Array) ? value.map(&:to_s).join("\u0000") : value.to_s
    Digest::SHA256.hexdigest(payload)
  end

  def canonical_hash(value)
    canonical = if value.is_a?(Hash)
                  value.keys.map(&:to_s).select { |key| MANIFEST_ITEM_FIELDS.include?(key) }.sort.to_h do |key|
                    [key, value.key?(key) ? value[key] : value[key.to_sym]]
                  end
                else
                  value
                end
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  rescue StandardError
    Digest::SHA256.hexdigest(value.to_s)
  end

  def deep_freeze_value(value)
    case value
    when Hash
      value.each { |key, child| deep_freeze_value(key); deep_freeze_value(child) }
    when Array
      value.each { |child| deep_freeze_value(child) }
    end
    value.freeze
  end

  def resolved_publisher?(item)
    status = item.fetch("publisher_identity_status", "unresolved").to_s
    !item.fetch("publisher_id", "").to_s.empty? && status != "unresolved"
  end

  def sort_key(item)
    [
      resolved_publisher?(item) ? 0 : 1,
      nullable_time_sort(item.fetch("published_at", nil), descending: true),
      nullable_time_sort(item.fetch("captured_at", item.fetch("fetched_at", nil)), descending: true),
      item.fetch("version_id").to_s
    ]
  end

  # Ruby sorts ascending.  Prefixing the numeric epoch with its negative keeps
  # the required descending time order while putting NULL values last.
  def nullable_time_sort(value, descending:)
    return [1, 0] if value.nil? || value.to_s.empty?

    parsed = Time.parse(value.to_s).utc.to_f
    [0, descending ? -parsed : parsed]
  rescue ArgumentError
    [1, 0]
  end

  def truthy?(value)
    value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
  end
end

LocaleFrontierSelector = BreadthDiscoverySelector unless defined?(LocaleFrontierSelector)
