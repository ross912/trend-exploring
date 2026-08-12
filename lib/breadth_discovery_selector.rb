# frozen_string_literal: true

require "time"

# Deterministic selector for the locale-conditioned, topic-unconditioned
# exploration lane.  This class deliberately operates on immutable version
# shaped hashes; it never reads the current item projection and never mutates
# its input rows.
class BreadthDiscoverySelector
  DEFAULT_LIMIT = 12
  DEFAULT_LOCALE_LIMIT = 2

  class Error < StandardError; end

  def initialize(limit: DEFAULT_LIMIT, locale_limit: DEFAULT_LOCALE_LIMIT)
    @limit = Integer(limit)
    @locale_limit = Integer(locale_limit)
    raise Error, "limit must be positive" unless @limit.positive?
    raise Error, "locale_limit must be positive" unless @locale_limit.positive?
  end

  # Select at most +limit+ rows.  Rows must be immutable version records (or
  # hashes with the same fields).  The resulting order is independent of the
  # input order.
  def select(items:, limit: @limit)
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
        next if publisher_id.empty? || publisher_counts[publisher_id] >= 1
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

  private

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
