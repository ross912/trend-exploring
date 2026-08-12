# frozen_string_literal: true

require "digest"
require "json"
require "set"
require "time"

# Deterministic, reviewable weak-signal detector v1.
#
# This detector deliberately works on immutable source-item-version shaped
# hashes.  It reports lexical recurrence/expansion/participation/decline only;
# it does not infer entities, translate text, estimate probability, or claim
# importance.  Registry and policy fields are treated as qualification data,
# never as mutable current-source projections.
class WeakSignalDetector
  DETECTOR_VERSION = "weak_signal_detector_v1"
  RECENT_WINDOW_HOURS = 24
  PRIOR_BUCKET_COUNT = 6
  PRIOR_WINDOW_DAYS = 7
  MIN_BASELINE_HOURS = 72
  MAX_EVIDENCE_IDS = 20
  REASONS = %w[
    NEWLY_REPEATED
    SOURCE_EXPANSION
    NEW_LANGUAGE_OR_LOCALE_PARTICIPATION
    DISCUSSION_DECLINE
  ].freeze

  # This is intentionally small.  It is not a language model vocabulary.
  ENGLISH_STOPWORDS = Set.new(%w[
    a an and are as at be by for from has have he her his i in is it its of on
    or our she that the their them they this to was were with you your
  ]).freeze
  CHINESE_STOPWORDS = Set.new(%w[
    的 了 和 与 在 是 有 要 将 为 对 从 等 及 被 让 也 其 并
  ]).freeze

  class Error < StandardError; end

  def initialize(recent_window_hours: RECENT_WINDOW_HOURS,
                 prior_bucket_count: PRIOR_BUCKET_COUNT,
                 detector_version: DETECTOR_VERSION)
    @recent_window_hours = Integer(recent_window_hours)
    @prior_bucket_count = Integer(prior_bucket_count)
    @detector_version = detector_version.to_s
    raise Error, "recent window must be positive" unless @recent_window_hours.positive?
    raise Error, "prior bucket count must be positive" unless @prior_bucket_count.positive?
    raise Error, "detector version is required" if @detector_version.empty?
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  attr_reader :detector_version

  # Analyze an immutable input set at an explicitly controlled as_of.  The
  # returned object is JSON-safe and has stable ordering independent of input
  # row order.
  def analyze(items:, as_of:)
    ending = parse_time(as_of)
    raise Error, "as_of must be a valid time" unless ending

    canonical_items = Array(items).map { |item| normalize_item(item) }.compact
    canonical_items.sort_by! { |item| item.fetch("stable_key") }
    input_hash = Digest::SHA256.hexdigest(JSON.generate(canonical_items.map { |item| canonical_input(item) }))

    # created_at is the only controlled analysis time.  published_at is an
    # evidence attribute, not a fallback clock, so rows without created_at
    # cannot enter a run.
    usable = canonical_items.reject { |item| item.fetch("created_at") > ending }
    earliest = usable.map { |item| item.fetch("created_at") }.min
    coverage_hours = earliest ? ((ending - earliest) / 3600.0) : 0.0
    metadata = {
      "detector_version" => @detector_version,
      "as_of" => ending.iso8601(6),
      "input_cutoff" => ending.iso8601(6),
      "input_hash" => input_hash,
      "recent_window_hours" => @recent_window_hours,
      "prior_window_days" => PRIOR_WINDOW_DAYS,
      "prior_bucket_count" => @prior_bucket_count,
      "baseline_coverage_hours" => coverage_hours.round(6)
    }

    if coverage_hours < MIN_BASELINE_HOURS
      return metadata.merge("status" => "warming_up", "candidates" => [], "phrase_stats" => [])
    end

    recent_start = ending - (@recent_window_hours * 3600)
    prior_end = recent_start
    prior_start = ending - ((@prior_bucket_count + 1) * 24 * 3600)
    records = usable.select do |item|
      timestamp = item.fetch("created_at")
      timestamp >= prior_start && timestamp <= ending
    end

    grouped = collect_phrase_records(records, ending: ending, recent_start: recent_start,
                                     prior_start: prior_start, prior_end: prior_end)
    stats = grouped.keys.sort.map { |key| build_phrase_stat(key, grouped.fetch(key), ending: ending) }
    candidates = stats.select { |stat| !stat.fetch("reason_codes").empty? }
      .sort_by { |candidate| [candidate.fetch("language"), candidate.fetch("phrase")] }
      .each_with_index.map { |candidate, index| candidate.merge("sort_order" => index) }

    metadata.merge("status" => "evaluated", "candidates" => candidates, "phrase_stats" => stats)
  end

  alias detect analyze
  alias call analyze

  private

  def normalize_item(item)
    return nil unless item.is_a?(Hash)
    return nil if item.fetch("registry_enabled", true) == false
    return nil if false_value?(item.fetch("registry_enabled", true))
    return nil unless item.fetch("analysis_policy", "signal_eligible").to_s == "signal_eligible"

    created_at = parse_time(item["created_at"])
    return nil unless created_at

    language = item.fetch("language", "").to_s.strip
    return nil if language.empty?
    version_id = item.fetch("version_id", item.fetch("item_key", "")).to_s.strip
    return nil if version_id.empty?
    source_id = item.fetch("source_id", "").to_s.strip
    publisher_id = item.fetch("publisher_id", "").to_s.strip
    publisher_status = item.fetch("publisher_identity_status", publisher_id.empty? ? "unresolved" : "configured").to_s
    query_conditioned = truthy?(item.fetch("query_conditioned", item.fetch("query", false)))
    discovery_basis = item.fetch("discovery_basis", "editorial_feed").to_s
    # Locale is only meaningful when supplied by the signal-eligible registry
    # field.  Region is intentionally not used as a locale proxy.
    locale_tag = item.fetch("locale_tag", "").to_s.strip
    text = [item.fetch("title", ""), item.fetch("summary", "")].map(&:to_s).join(" ")
      .gsub(%r{https?://\S+}i, " ").strip
    return nil if text.empty?

    canonical_language = canonical_language(language)
    phrases = if chinese_language?(language, text)
                chinese_phrases(text)
              else
                english_phrases(text)
              end
    stable_key = [version_id, created_at.iso8601(6), item.fetch("item_key", "").to_s].join("\u0000")
    {
      "version_id" => version_id,
      "item_key" => item.fetch("item_key", version_id).to_s,
      "source_id" => source_id,
      "publisher_id" => publisher_id,
      "publisher_status" => publisher_status,
      "language" => canonical_language,
      "locale_tag" => locale_tag,
      "query_conditioned" => query_conditioned,
      "discovery_basis" => discovery_basis,
      "title" => item.fetch("title", "").to_s,
      "summary" => item.fetch("summary", "").to_s,
      "created_at" => created_at,
      "phrases" => phrases,
      "stable_key" => stable_key
    }
  end

  def canonical_input(item)
    item.reject { |key, _| key == "created_at" }.merge("created_at" => item.fetch("created_at").iso8601(6), "phrases" => item.fetch("phrases"))
  end

  def collect_phrase_records(records, ending:, recent_start:, prior_start:, prior_end:)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    records.each do |item|
      item.fetch("phrases").each do |phrase|
        window = if item.fetch("created_at") >= recent_start
                   "recent"
                 elsif item.fetch("created_at") >= prior_start && item.fetch("created_at") < prior_end
                   "prior"
                 end
        next unless window
        bucket = window == "recent" ? nil : bucket_index(item.fetch("created_at"), ending: ending)
          # The phrase itself is the comparison unit.  Language is retained as
          # an observed dimension so NEW_LANGUAGE_OR_LOCALE_PARTICIPATION can
          # detect a previously absent language using the same literal phrase;
          # no translation or cross-language semantic equivalence is inferred.
          grouped[phrase] << {
          "item" => item, "window" => window, "bucket" => bucket
        }
      end
    end

    # A publisher contributes at most one observation for the same phrase in a
    # window.  Unresolved publisher rows use source identity only as a
    # deduplication guard and are never promoted to qualifying publisher count.
    grouped.each_with_object({}) do |(key, observations), result|
      seen = Set.new
      # Prefer qualifying editorial observations when the same publisher emits
      # both a query-conditioned and an editorial row in one window.
      result[key] = observations.sort_by do |obs|
        item = obs.fetch("item")
        [obs.fetch("window"), obs.fetch("bucket", -1), qualifying_publisher_observation?(item) ? 0 : 1, item.fetch("stable_key")]
      end.select do |obs|
        item = obs.fetch("item")
        identity = if resolved_publisher?(item)
                     "publisher:#{item.fetch("publisher_id")}"
                   else
                     source_identity = item.fetch("source_id").to_s
                     source_identity = item.fetch("version_id") if source_identity.empty?
                     "unresolved:#{source_identity}"
                   end
        # Prior metrics are daily publisher presence, so retain one
        # observation per publisher in each prior 24h bucket.  The recent
        # window remains one observation per publisher for the whole window.
        scope = if obs.fetch("window") == "prior"
                  "prior:#{obs.fetch('bucket')}"
                else
                  "recent"
                end
        dedup_key = [scope, identity]
        next false if seen.include?(dedup_key)

        seen << dedup_key
        true
      end
    end
  end

  def bucket_index(time, ending:)
    # Chronological prior buckets are numbered 0 (oldest) through N-1
    # (closest to recent).  The recent 24h interval is excluded.
    age_hours = (ending - time) / 3600.0
    index_from_recent = (age_hours / 24).floor - 1
    index = @prior_bucket_count - 1 - index_from_recent
    [[index, 0].max, @prior_bucket_count - 1].min
  end

  def build_phrase_stat(key, observations, ending:)
      phrase = key
    recent = observations.select { |obs| obs.fetch("window") == "recent" }
    prior = observations.select { |obs| obs.fetch("window") == "prior" }
    recent_qualifying = recent.select { |obs| qualifying_publisher_observation?(obs.fetch("item")) }
    prior_qualifying = prior.select { |obs| qualifying_publisher_observation?(obs.fetch("item")) }
    recent_publishers = recent_qualifying.map { |obs| obs.fetch("item").fetch("publisher_id") }.uniq.sort
    prior_publishers = prior_qualifying.map { |obs| obs.fetch("item").fetch("publisher_id") }.uniq.sort
    buckets = Array.new(@prior_bucket_count, 0)
    @prior_bucket_count.times do |index|
      buckets[index] = prior_qualifying.select { |obs| obs.fetch("bucket") == index }
        .map { |obs| obs.fetch("item").fetch("publisher_id") }.uniq.length
    end
    prior_max_daily = buckets.max || 0
    recent_qualifying_languages = recent_qualifying.map { |obs| obs.fetch("item").fetch("language") }.uniq.sort
    prior_qualifying_languages = prior_qualifying.map { |obs| obs.fetch("item").fetch("language") }.uniq.sort
    recent_qualifying_locales = recent_qualifying.map { |obs| obs.fetch("item").fetch("locale_tag") }.reject(&:empty?).uniq.sort
    prior_qualifying_locales = prior_qualifying.map { |obs| obs.fetch("item").fetch("locale_tag") }.reject(&:empty?).uniq.sort
    recent_languages = recent.map { |obs| obs.fetch("item").fetch("language") }.uniq.sort
    prior_languages = prior.map { |obs| obs.fetch("item").fetch("language") }.uniq.sort
    recent_locales = recent.map { |obs| obs.fetch("item").fetch("locale_tag") }.reject(&:empty?).uniq.sort
    prior_locales = prior.map { |obs| obs.fetch("item").fetch("locale_tag") }.reject(&:empty?).uniq.sort
    recent_query = recent.count { |obs| obs.fetch("item").fetch("query_conditioned") }
    prior_query = prior.count { |obs| obs.fetch("item").fetch("query_conditioned") }
    qualifying_recent_obs = recent_qualifying.length
    reasons = []
    reasons << "NEWLY_REPEATED" if prior_max_daily <= 1 && recent_publishers.length >= 3 && qualifying_recent_obs >= 3
    if prior_max_daily >= 2 && recent_publishers.length >= prior_max_daily + 2 &&
       recent_publishers.length.to_f / prior_max_daily >= 1.5
      reasons << "SOURCE_EXPANSION"
    end
    if prior_qualifying.any? && recent_publishers.length >= 3 &&
       ((recent_qualifying_languages - prior_qualifying_languages).any? ||
        (recent_qualifying_locales - prior_qualifying_locales).any?)
      reasons << "NEW_LANGUAGE_OR_LOCALE_PARTICIPATION"
    end
    consecutive_decline = buckets.each_cons(3).any? { |window| window.all? { |count| count >= 4 } }
    reasons << "DISCUSSION_DECLINE" if consecutive_decline && recent_publishers.length <= 1

    evidence_recent = evidence_ids(recent)
    evidence_prior = evidence_ids(prior)
    all_records = (recent + prior).sort_by { |obs| obs.fetch("item").fetch("stable_key") }
    first = all_records.map { |obs| obs.fetch("item").fetch("created_at") }.min
    last = all_records.map { |obs| obs.fetch("item").fetch("created_at") }.max
    recent_support_publishers = recent.map { |obs| publisher_label(obs.fetch("item")) }.uniq.sort
    prior_support_publishers = prior.map { |obs| publisher_label(obs.fetch("item")) }.uniq.sort

    {
      "phrase" => phrase,
      "language" => (recent_qualifying_languages + prior_qualifying_languages).uniq.sort.first.to_s,
      "reason_codes" => reasons,
      "recent_publisher_count" => recent_publishers.length,
      "prior_publisher_count" => prior_max_daily,
      "prior_max_daily_publisher_count" => prior_max_daily,
      "recent_observation_count" => recent.length,
      "prior_observation_count" => prior.length,
      "recent_qualifying_observation_count" => qualifying_recent_obs,
      "prior_qualifying_observation_count" => prior_qualifying.length,
      "prior_bucket_counts" => buckets,
      "recent_evidence_version_ids" => evidence_recent,
      "prior_evidence_version_ids" => evidence_prior,
      "recent_evidence_count" => recent.length,
      "prior_evidence_count" => prior.length,
      "query_evidence_count" => recent_query + prior_query,
      "recent_query_evidence_count" => recent_query,
      "prior_query_evidence_count" => prior_query,
      "unresolved_evidence_count" => (recent + prior).count { |obs| !resolved_publisher?(obs.fetch("item")) },
      "publishers" => (recent_publishers + prior_publishers).uniq.sort,
      "recent_publishers" => recent_publishers,
      "prior_publishers" => prior_publishers,
      "support_publishers" => (recent_support_publishers + prior_support_publishers).uniq.sort,
      "languages" => (recent_qualifying_languages + prior_qualifying_languages).uniq.sort,
      "recent_languages" => recent_qualifying_languages,
      "prior_languages" => prior_qualifying_languages,
      "locales" => (recent_qualifying_locales + prior_qualifying_locales).uniq.sort,
      "recent_locales" => recent_qualifying_locales,
      "prior_locales" => prior_qualifying_locales,
      "support_languages" => (recent_languages + prior_languages).uniq.sort,
      "support_locales" => (recent_locales + prior_locales).uniq.sort,
      "first_created_at" => first&.iso8601(6),
      "last_created_at" => last&.iso8601(6),
      "explanation" => explanation_for(phrase, reasons, recent_publishers.length, prior_max_daily,
                                       recent_query + prior_query, recent_qualifying_languages - prior_qualifying_languages,
                                       recent_qualifying_locales - prior_qualifying_locales, buckets)
    }
  end

  def explanation_for(phrase, reasons, recent_count, prior_max, query_count, new_languages, new_locales, buckets)
    return "未达到弱信号规则门槛：#{phrase}。" if reasons.empty?
    parts = reasons.map do |reason|
      case reason
      when "NEWLY_REPEATED"
        "最近24小时在#{recent_count}个已解析发布者出现，先前单日最高#{prior_max}个"
      when "SOURCE_EXPANSION"
        "最近发布者数#{recent_count}，高于先前单日最高#{prior_max}个"
      when "NEW_LANGUAGE_OR_LOCALE_PARTICIPATION"
        dimensions = []
        dimensions << "语言#{new_languages.join('、')}" unless new_languages.empty?
        dimensions << "注册表locale#{new_locales.join('、')}" unless new_locales.empty?
        "新增#{dimensions.join('、')}参与"
      when "DISCUSSION_DECLINE"
        "先前连续日桶达到#{buckets.last(3).join('、')}个发布者，最近为#{recent_count}个"
      else
        reason
      end
    end
    suffix = query_count.positive? ? "；另有#{query_count}条query-conditioned支持证据未计入发布者资格" : ""
    "短语“#{phrase}”#{parts.join('；')}#{suffix}。这是可复核的词组变化候选，不代表事件确认或预测。"
  end

  def evidence_ids(observations)
    observations.map { |obs| obs.fetch("item") }.sort_by { |item| item.fetch("stable_key") }
      .map { |item| item.fetch("version_id") }.uniq.first(MAX_EVIDENCE_IDS)
  end

  def qualifying_publisher_observation?(item)
    resolved_publisher?(item) && !item.fetch("query_conditioned") && item.fetch("discovery_basis") == "editorial_feed"
  end

  def resolved_publisher?(item)
    !item.fetch("publisher_id").to_s.empty? && item.fetch("publisher_status").to_s != "unresolved"
  end

  def publisher_label(item)
    return "unresolved:#{item.fetch('source_id')}" unless resolved_publisher?(item)

    item.fetch("publisher_id")
  end

  def english_phrases(text)
    words = text.downcase.scan(/[a-z][a-z'-]*/).reject { |word| ENGLISH_STOPWORDS.include?(word) }
    (2..3).flat_map do |length|
      words.each_cons(length).map { |parts| parts.join(" ") }
    end
      .uniq
      .reject { |phrase| invalid_phrase?(phrase, english: true) }
      .sort
  end

  def chinese_phrases(text)
    chunks = text.scan(/\p{Han}{2,}/)
    chunks.flat_map do |chunk|
      chars = chunk.chars
      (2..4).flat_map { |length| chars.each_cons(length).map(&:join) }
    end
      .uniq
      .reject { |phrase| invalid_phrase?(phrase, english: false) }
      .sort
  end

  def invalid_phrase?(phrase, english:)
    value = phrase.to_s.strip
    return true if value.empty? || value.match?(%r{\Ahttps?://}i)
    return true if value.match?(%r{\A[\d\W_]+\z})
    return true if english ? value.gsub(/\s+/, "").length < 4 : value.length < 2
    if english
      words = value.split
      return true if words.empty? || words.all? { |word| ENGLISH_STOPWORDS.include?(word) }
    else
      return true if value.chars.all? { |char| CHINESE_STOPWORDS.include?(char) }
      return true if CHINESE_STOPWORDS.include?(value)
    end
    false
  end

  def canonical_language(language)
    value = language.to_s.strip
    return "zh-CN" if value.downcase.start_with?("zh")

    value.downcase
  end

  def chinese_language?(language, text)
    language.to_s.downcase.start_with?("zh") || text.scan(/\p{Han}/).length >= 2
  end

  def parse_time(value)
    return nil if value.nil? || value.to_s.empty?

    value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
  rescue ArgumentError, TypeError
    nil
  end

  def false_value?(value)
    %w[false f 0 no n].include?(value.to_s.downcase)
  end

  def truthy?(value)
    value == true || %w[true t 1 yes y].include?(value.to_s.downcase)
  end
end
