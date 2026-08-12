# frozen_string_literal: true

require "cgi"
require "digest"
require "set"
require "time"

# A deliberately conservative, deterministic pre-layer for event candidates.
#
# This class only says that a small set of same-language source items share
# enough literal anchors to be reviewed together.  It does not identify an
# event, estimate importance, or infer propagation.  In particular, query
# conditioned items can only be attached after two independently resolved,
# non-query publishers have already formed a candidate.
class EventCandidateAnalyzer
  MATCHING_METHOD = "deterministic_anchor_similarity_v1"
  DEFAULT_MAX_AGE_HOURS = 72
  MAX_PAIR_HOURS = 36
  FUTURE_GRACE_SECONDS = 0

  ENGLISH_MEDIA_NOISE = Set.new(%w[
    breaking latest news update updates live report reports story stories
    official officials video watch read says said according source sources
    world today yesterday this morning tonight media press release statement
    agency correspondent coverage global international home page
  ]).freeze
  ENGLISH_FUNCTION = Set.new(%w[
    a an and are as at be by for from in into is it its of on or that the their
    this to was were with after before over under about against between could
    should than these those through while would has have had will can may might
  ]).freeze
  CHINESE_MEDIA_NOISE = Set.new(%w[
    最新 今日 昨日 日前 近日 目前 报道 消息 记者 本台 综合 来源 新闻 资讯
    视频 图片 现场 关注 焦点 发布 表示 指出 称 据悉 相关 有关 网页
  ]).freeze
  CHINESE_FUNCTION_CHARS = Set.new(%w[的 了 和 与 在 是 有 要 将 为 对 从 等 及 被 让 于 也 其 并]).freeze
  # Units are intentionally generic.  They are lexical anchors, not an
  # attempt to interpret measurements or classify topics.
  UNITS = %w[
    magnitude mag level km kilometer kilometers metre meter metres meters m
    miles mile mph kph percent % degree degrees celsius fahrenheit °c °f
    级 度 米 公里 千米 万人 人 万户 户 公顷 公里每小时 米每秒
  ].freeze

  def initialize(max_age_hours: DEFAULT_MAX_AGE_HOURS)
    @max_age_hours = Integer(max_age_hours)
    raise ArgumentError, "max age must be positive" unless @max_age_hours.positive?
  end

  # Analyze an array of raw source-item hashes.  The input may contain the
  # extra registry fields returned by LocalRadarStore#event_analysis_items;
  # missing registry fields are accepted for direct, deterministic fixtures.
  def analyze(items:, now: Time.now.utc)
    ending = parse_time(now)
    raise ArgumentError, "now must be a valid time" unless ending

    records = Array(items).each_with_object([]) do |item, prepared|
      record = prepare(item, ending)
      prepared << record if record
    end
    records = records.sort_by { |record| record.fetch(:stable_key) }
    return [] if records.empty?

    by_language = records.group_by { |record| record.fetch(:language_key) }
    candidates = []
    by_language.keys.sort.each do |language_key|
      language_records = by_language.fetch(language_key)
      non_query = language_records.reject { |record| record.fetch(:query_conditioned) }
      clusters = complete_link_clusters(non_query)
      clusters.each do |cluster|
        selected = deduplicate_cluster(cluster)
        qualifying = selected.reject { |record| record.fetch(:query_conditioned) }
        next if qualifying.map { |record| record.fetch(:publisher_id) }.uniq.length < 2

        attached_query = language_records
          .select { |record| record.fetch(:query_conditioned) }
          .sort_by { |record| record.fetch(:stable_key) }
          .each_with_object([]) do |record, attached|
            next if selected.any? { |member| member.fetch(:publisher_id) == record.fetch(:publisher_id) }
            next unless compatible_with_cluster?(record, qualifying)

            # A query publisher is represented once per candidate.  The
            # deterministic input order plus priority keeps this stable if a
            # query feed emits duplicate rows.
            existing_index = attached.index { |member| member.fetch(:publisher_id) == record.fetch(:publisher_id) }
            if existing_index.nil?
              attached << record
            elsif better_record?(record, attached.fetch(existing_index))
              attached[existing_index] = record
            end
          end
        candidates << build_candidate(qualifying, attached_query)
      end
    end

    # A publisher can emit two feeds for the same text.  Complete-link
    # insertion already prefers one row, but this final deterministic guard
    # also prevents duplicate candidates when two alternative rows matched the
    # same qualifying publisher set.
    deduplicate_candidates(candidates)
  end

  private

  def prepare(item, ending)
    return nil unless item.is_a?(Hash)
    return nil if item.fetch("registry_enabled", item.fetch("source_enabled", true)) == false
    return nil if item.key?("registry_enabled") && false_value?(item.fetch("registry_enabled"))
    return nil if item.key?("source_enabled") && false_value?(item.fetch("source_enabled"))

    published_at = parse_time(item["published_at"])
    return nil unless published_at
    return nil if published_at > ending + FUTURE_GRACE_SECONDS
    return nil if published_at < ending - (@max_age_hours * 3600)

    language = item.fetch("language", "").to_s.strip
    return nil if language.empty?
    publisher_id = item.fetch("publisher_id", "").to_s.strip
    return nil if publisher_id.empty?
    return nil unless resolved_publisher?(item)

    title = normalize_text(item.fetch("title", ""))
    summary = normalize_text(item.fetch("summary", ""))
    return nil if title.empty?
    language_key = language.downcase
    english = english_language?(language_key)
    features = english ? english_features(title, summary) : chinese_features(title, summary)
    return nil if features.fetch(:similarity_tokens).empty?

    stable_key = item.fetch("item_key", "").to_s
    stable_key = Digest::SHA256.hexdigest([publisher_id, published_at.iso8601(6), title, summary].join("\u0000")) if stable_key.empty?
    query_conditioned = if item.key?("query_conditioned")
                          truthy?(item.fetch("query_conditioned"))
                        else
                          truthy?(item.fetch("query", false)) || item.fetch("source_kind", "").to_s == "discovery"
                        end
    {
      item: item,
      title: title,
      summary: summary,
      published_at: published_at,
      language: language,
      language_key: language_key,
      publisher_id: publisher_id,
      query_conditioned: query_conditioned,
      stable_key: stable_key,
      features: features
    }
  end

  def resolved_publisher?(item)
    status = item.fetch("publisher_identity_status", "configured").to_s
    %w[configured observed_domain].include?(status)
  end

  def complete_link_clusters(records)
    clusters = []
    records.each do |record|
      compatible_indexes = clusters.each_index.select do |index|
        cluster = clusters.fetch(index)
        same_publisher = cluster.find { |member| member.fetch(:publisher_id) == record.fetch(:publisher_id) }
        others = same_publisher ? cluster.reject { |member| member.equal?(same_publisher) } : cluster
        replacement = same_publisher && !better_record?(record, same_publisher) ? same_publisher : record
        compatible_with_cluster?(replacement, others)
      end

      if compatible_indexes.empty?
        clusters << [record]
        next
      end

      # One item belongs to the first deterministically ordered compatible
      # cluster.  If a publisher already has an item in that cluster, choose
      # the higher-information row instead of making a duplicate candidate.
      chosen = compatible_indexes.min_by do |index|
        cluster = clusters.fetch(index)
        [
          -cluster.length,
          cluster.map { |member| member.fetch(:stable_key) }.sort.join("\u0000"),
          index
        ]
      end
      cluster = clusters.fetch(chosen)
      same_index = cluster.index { |member| member.fetch(:publisher_id) == record.fetch(:publisher_id) }
      if same_index.nil?
        cluster << record
      elsif better_record?(record, cluster.fetch(same_index))
        cluster[same_index] = record
      end
    end
    clusters
  end

  def deduplicate_cluster(cluster)
    cluster.group_by { |record| record.fetch(:publisher_id) }.values.map do |records|
      records.min_by { |record| record_priority(record) }
    end.sort_by { |record| record.fetch(:stable_key) }
  end

  def record_priority(record)
    [
      record.fetch(:query_conditioned) ? 1 : 0,
      -information_amount(record),
      record.fetch(:stable_key)
    ]
  end

  def better_record?(left, right)
    (record_priority(left) <=> record_priority(right)) == -1
  end

  def information_amount(record)
    features = record.fetch(:features)
    features.fetch(:similarity_tokens).length + features.fetch(:anchors).length + record.fetch(:title).length
  end

  def compatible_with_cluster?(record, cluster)
    cluster.all? { |member| pair_compatible?(record, member) }
  end

  def pair_compatible?(left, right)
    return false unless left.fetch(:language_key) == right.fetch(:language_key)
    return false if left.fetch(:publisher_id) == right.fetch(:publisher_id)

    delta = (left.fetch(:published_at) - right.fetch(:published_at)).abs
    return false if delta > MAX_PAIR_HOURS * 3600

    left_numbers = left.fetch(:features).fetch(:numbers)
    right_numbers = right.fetch(:features).fetch(:numbers)
    return false if left_numbers.any? && right_numbers.any? && (left_numbers & right_numbers).empty?

    left_features = left.fetch(:features)
    right_features = right.fetch(:features)
    if left_features.fetch(:english)
      similarity = jaccard(left_features.fetch(:similarity_tokens), right_features.fetch(:similarity_tokens))
      return false if similarity < 0.35
    else
      similarity = dice(left_features.fetch(:three_grams), right_features.fetch(:three_grams))
      return false if similarity < 0.40
    end

    shared = shared_anchors(left_features, right_features)
    return false if shared.length < 2
    shared.any? { |anchor| anchor.fetch("strength") == "strong" }
  end

  def shared_anchors(left, right)
    # Build the pair intersection before component suppression.  Suppressing
    # each source independently can discard a short phrase merely because a
    # longer, source-specific shingle exists on that side; the short phrase
    # may still be the only anchor shared by both sources.
    left_anchors = raw_feature_anchor_list(left)
    right_anchors = raw_feature_anchor_list(right)
    left_by_key = left_anchors.to_h { |anchor| [[anchor.fetch("kind"), anchor.fetch("value")], anchor] }
    right_by_key = right_anchors.to_h { |anchor| [[anchor.fetch("kind"), anchor.fetch("value")], anchor] }
    suppress_component_anchors((left_by_key.keys & right_by_key.keys).sort.map { |key| left_by_key.fetch(key) })
  end

  def feature_anchor_list(features)
    suppress_component_anchors(raw_feature_anchor_list(features))
  end

  def raw_feature_anchor_list(features)
    anchors = []
    features.fetch(:numbers).each { |value| anchors << { "kind" => "number", "value" => value, "strength" => "strong" } }
    features.fetch(:number_units).each { |value| anchors << { "kind" => "number_unit", "value" => value, "strength" => "strong" } }
    features.fetch(:trigrams).each { |value| anchors << { "kind" => "trigram", "value" => value, "strength" => "strong" } }
    features.fetch(:capitalized_names).each { |value| anchors << { "kind" => "name_candidate", "value" => value, "strength" => "strong" } }
    features.fetch(:abbreviations).each { |value| anchors << { "kind" => "abbreviation", "value" => value, "strength" => "supporting" } }
    features.fetch(:long_shingles).each { |value| anchors << { "kind" => "long_shingle", "value" => value, "strength" => "strong" } }
    features.fetch(:quoted_phrases).each { |value| anchors << { "kind" => "quoted_phrase", "value" => value, "strength" => "strong" } }
    features.fetch(:tokens).each { |value| anchors << { "kind" => "token", "value" => value, "strength" => "supporting" } }
    features.fetch(:bigrams).each { |value| anchors << { "kind" => "bigram", "value" => value, "strength" => "supporting" } }
    anchors.uniq { |anchor| [anchor.fetch("kind"), anchor.fetch("value")] }
  end

  def suppress_component_anchors(anchors)
    unique = anchors.uniq { |anchor| [anchor.fetch("kind"), anchor.fetch("value")] }
    strong = unique.select { |anchor| anchor.fetch("strength") == "strong" }
    strong_number_units = strong.select { |anchor| anchor.fetch("kind") == "number_unit" }
      .map { |anchor| anchor.fetch("value").split.first }.to_set
    unique.reject! do |anchor|
      anchor.fetch("kind") == "number" && strong_number_units.include?(anchor.fetch("value"))
    end
    strong_phrase_anchors = strong.select do |anchor|
      %w[trigram name_candidate long_shingle quoted_phrase].include?(anchor.fetch("kind"))
    end
    retained_strong_phrases = []
    strong_phrase_anchors.sort_by { |anchor| [-anchor.fetch("value").length, anchor.fetch("kind"), anchor.fetch("value")] }.each do |anchor|
      value = anchor.fetch("value").downcase
      next if retained_strong_phrases.any? { |other| overlapping_strong_phrase?(value, other) }

      retained_strong_phrases << value
    end
    unique.reject! do |anchor|
      anchor.fetch("strength") == "strong" && strong_phrase_anchors.include?(anchor) && !retained_strong_phrases.include?(anchor.fetch("value").downcase)
    end
    strong_phrases = retained_strong_phrases
    unique.reject! do |anchor|
      next false unless anchor.fetch("strength") == "supporting"
      # An abbreviation is a distinct lexical component even when it is the
      # first token of a longer entity phrase (for example, “DRC Kinshasa”).
      # Keep it available as the supporting side of the two-component pair
      # gate; ordinary token/bigram overlap remains suppressed below.
      next false if anchor.fetch("kind") == "abbreviation"
      value = anchor.fetch("value").downcase
      strong_phrases.any? do |phrase|
        phrase == value || phrase.split.include?(value) || value.split.all? { |part| phrase.split.include?(part) } ||
          phrase.include?(value) ||
          (phrase.match?(/\p{Han}/) && value.match?(/\p{Han}/) && overlapping_strong_phrase?(phrase, value))
      end
    end
    unique.sort_by { |anchor| [anchor.fetch("kind"), anchor.fetch("value")] }
  end

  def overlapping_strong_phrase?(left, right)
    return true if left.include?(right) || right.include?(left)

    left_tokens = left.split
    right_tokens = right.split
    return (left_tokens & right_tokens).length >= 2 unless left_tokens.length == 1 || right_tokens.length == 1

    left_chars = left.chars
    right_chars = right.chars
    # Chinese long shingles are character spans rather than whitespace
    # tokens. Two shared Han characters already indicate the same component;
    # requiring a three-character overlap would leave a pile of adjacent
    # shingles from one short title.
    han_phrases = left.match?(/\p{Han}/) && right.match?(/\p{Han}/)
    minimum_overlap = han_phrases ? 2 : 3
    maximum_overlap = [left_chars.length, right_chars.length].min
    return false if maximum_overlap < minimum_overlap

    (minimum_overlap..maximum_overlap).any? do |length|
      left_chars.each_cons(length).any? { |part| right.include?(part.join) }
    end
  end

  def build_candidate(qualifying, query_records)
    members = (qualifying + query_records).sort_by { |record| record.fetch(:stable_key) }
    support_sets = Hash.new { |hash, key| hash[key] = Set.new }
    qualifying.each_with_index do |record, index|
      raw_feature_anchor_list(record.fetch(:features)).each do |anchor|
        support_sets[[anchor.fetch("kind"), anchor.fetch("value")]] << index
      end
    end
    anchors = support_sets.each_with_object([]) do |(key, support), result|
      next unless support.length == qualifying.length
      anchor = qualifying.map { |record| raw_feature_anchor_list(record.fetch(:features)).find { |entry| [entry.fetch("kind"), entry.fetch("value")] == key } }.compact.first
      result << anchor.merge("supporting_qualifying_source_count" => support.length) if anchor
    end.sort_by { |anchor| [anchor.fetch("kind"), anchor.fetch("value")] }
    anchors = suppress_component_anchors(anchors)
    phrases = anchors.select { |anchor| %w[trigram name_candidate long_shingle quoted_phrase bigram].include?(anchor.fetch("kind")) }
      .map { |anchor| anchor.fetch("value") }.uniq.sort

    medoid = qualifying.min_by do |record|
      similarity_sum = qualifying.reject { |other| other.equal?(record) }.sum do |other|
        pair_similarity(record, other)
      end
      [-similarity_sum, -information_amount(record), record.fetch(:stable_key)]
    end
    member_keys = qualifying.map { |record| record.fetch(:stable_key) }.sort
    candidate_key = "event-candidate-#{Digest::SHA256.hexdigest([qualifying.first.fetch(:language_key), *member_keys].join("\u0000"))[0, 20]}"
    evidence_items = members.map { |record| evidence_item(record, qualifying.include?(record) ? "qualifying_non_query" : "query_conditioned_support") }
    first = qualifying.map { |record| record.fetch(:published_at) }.min
    last = qualifying.map { |record| record.fetch(:published_at) }.max
    span_hours = ((last - first) / 3600.0).round(3)
    anchor_values = anchors.sort_by { |anchor| [anchor.fetch("strength") == "strong" ? 0 : 1, anchor.fetch("kind"), anchor.fetch("value")] }
      .first(3).map { |anchor| anchor.fetch("value") }.join(", ")
    common_anchor_text = anchor_values.empty? ? "全体共同锚无" : "全体共同锚 #{anchor_values}"
    explanation = "#{qualifying.length} 个非 query 去重出版方在 #{format_hours(span_hours)} 小时内通过门槛；每一对均通过门槛，#{common_anchor_text}；附加 #{query_records.length} 条 query-conditioned 证据不计资格。仅作确定性文本相似候选，未确认事件、影响或重要性。"

    {
      "candidate_key" => candidate_key,
      "candidate_status" => "event_candidate",
      "language" => medoid.fetch(:language),
      "label" => medoid.fetch(:item).fetch("title", medoid.fetch(:title)).to_s,
      "matching_method" => MATCHING_METHOD,
      "explanation" => explanation,
      "member_count" => members.length,
      "dedup_source_count" => members.map { |record| record.fetch(:publisher_id) }.uniq.length,
      "qualifying_source_count" => qualifying.map { |record| record.fetch(:publisher_id) }.uniq.length,
      "query_conditioned_evidence_count" => query_records.length,
      "first_published_at" => first.iso8601,
      "last_published_at" => last.iso8601,
      "time_span_hours" => span_hours,
      "shared_anchors" => anchors,
      "shared_phrases" => phrases,
      "evidence_items" => evidence_items,
      "member_item_keys" => members.map { |record| record.fetch(:stable_key) },
      "qualifying_item_keys" => qualifying.map { |record| record.fetch(:stable_key) },
      "query_item_keys" => query_records.map { |record| record.fetch(:stable_key) }
    }
  end

  def evidence_item(record, lineage_role)
    item = record.fetch(:item)
    evidence = {
      "item_key" => record.fetch(:stable_key),
      "source_id" => item.fetch("source_id", "").to_s,
      "source_name" => item.fetch("source_name", "").to_s,
      "region" => item.fetch("region", "").to_s,
      "publisher_url" => item.fetch("publisher_url", "").to_s,
      "source_kind" => item.fetch("source_kind", "configured").to_s,
      "version_id" => item.fetch("version_id", "").to_s,
      "capture_id" => item.fetch("capture_id", "").to_s,
      "content_hash" => item.fetch("content_hash", "").to_s,
      "publisher_id" => record.fetch(:publisher_id),
      "publisher_identity_status" => item.fetch("publisher_identity_status", "configured").to_s,
      "publisher_name" => item.fetch("publisher_name", item.fetch("source_name", "")).to_s,
      "source_url" => item.fetch("source_url", "").to_s,
      "title" => item.fetch("title", "").to_s,
      "summary" => item.fetch("summary", "").to_s,
      "language" => record.fetch(:language),
      "published_at" => record.fetch(:published_at).iso8601,
      "query_conditioned" => record.fetch(:query_conditioned),
      "lineage_role" => lineage_role
    }
    basis = item.fetch("lineage_metadata_basis", "").to_s
    evidence["lineage_metadata_basis"] = basis unless basis.empty?
    evidence
  end

  def pair_similarity(left, right)
    a = left.fetch(:features)
    b = right.fetch(:features)
    a.fetch(:english) ? jaccard(a.fetch(:similarity_tokens), b.fetch(:similarity_tokens)) : dice(a.fetch(:three_grams), b.fetch(:three_grams))
  end

  def deduplicate_candidates(candidates)
    by_identity = {}
    candidates.each do |candidate|
      identity = [candidate.fetch("language"), candidate.fetch("qualifying_item_keys").sort]
      current = by_identity[identity]
      by_identity[identity] = candidate if current.nil? || candidate.fetch("member_count") > current.fetch("member_count") || candidate.fetch("candidate_key") < current.fetch("candidate_key")
    end
    by_identity.values.sort_by { |candidate| [candidate.fetch("language").downcase, candidate.fetch("candidate_key")] }
  end

  def english_features(title, summary)
    title_words = lexical_words(title)
    all_text = [title, summary].join(" ")
    all_words = lexical_words(all_text)
    {
      english: true,
      similarity_tokens: title_words.to_set,
      tokens: title_words.select { |word| word.length >= 4 }.to_set,
      bigrams: title_words.each_cons(2).map { |pair| pair.join(" ") }.to_set,
      trigrams: title_words.each_cons(3).map { |triple| triple.join(" ") }.to_set,
      capitalized_names: capitalized_names(title),
      abbreviations: abbreviations(title),
      numbers: numbers(all_text).to_set,
      number_units: number_units([title, summary].join(" ")).to_set,
      long_shingles: Set.new,
      quoted_phrases: quoted_phrases(title).to_set,
      anchors: title_words.to_set
    }
  end

  def chinese_features(title, summary)
    title_spans = chinese_spans(title)
    all_text = [title, summary].join(" ")
    three_grams = title_spans.flat_map { |span| shingles(span, 3, 3) }.reject { |value| chinese_noise?(value) }.to_set
    long_shingles = title_spans.flat_map { |span| shingles(span, 4, 5) }.reject { |value| chinese_noise?(value) }.to_set
    title_shingles = title_spans.flat_map { |span| shingles(span, 3, 5) }.reject { |value| chinese_noise?(value) }
    {
      english: false,
      similarity_tokens: title_shingles.to_set,
      three_grams: three_grams,
      tokens: title_shingles.select { |value| value.length >= 4 }.to_set,
      bigrams: Set.new,
      trigrams: Set.new,
      capitalized_names: Set.new,
      abbreviations: Set.new,
      numbers: numbers(all_text).to_set,
      number_units: number_units(all_text).to_set,
      long_shingles: long_shingles,
      quoted_phrases: quoted_phrases(title).select { |phrase| phrase.length >= 2 }.to_set,
      anchors: title_shingles.to_set
    }
  end

  def lexical_words(text)
    normalize_text(text).scan(/[A-Za-z]+(?:['’-][A-Za-z]+)*|[0-9]+[.,][0-9]+|[0-9]+|[A-Z]{2,}[0-9]*/).map do |word|
      word.downcase
    end.reject { |word| ENGLISH_FUNCTION.include?(word) || ENGLISH_MEDIA_NOISE.include?(word) || word.length < 2 }
  end

  def capitalized_names(title)
    words = normalize_text(title).scan(/[A-Z][A-Za-z'’-]*/)
    names = []
    # Re-scan the title in sequence so punctuation/number boundaries break a
    # name candidate instead of accidentally joining unrelated capitals.
    normalize_text(title).scan(/[A-Z][A-Za-z'’-]*(?:\s+[A-Z][A-Za-z'’-]*)+/).each do |value|
      name = value.downcase.gsub(/\s+/, " ").strip
      next if name.split.length < 2
      names << name
    end
    names.to_set
  end

  def abbreviations(title)
    normalize_text(title).scan(/\b[A-Z]{2,}[0-9]*\b/).map(&:downcase).to_set
  end

  def chinese_spans(text)
    noise_pattern = CHINESE_MEDIA_NOISE.to_a.sort_by(&:length).reverse.map { |noise| Regexp.escape(noise) }.join("|")
    function_pattern = CHINESE_FUNCTION_CHARS.to_a.map { |char| Regexp.escape(char) }.join
    normalize_text(text).scan(/\p{Han}+/).flat_map do |span|
      pieces = noise_pattern.empty? ? [span] : span.split(/(?:#{noise_pattern})/)
      function_pattern.empty? ? pieces : pieces.flat_map { |piece| piece.split(/[#{function_pattern}]/) }
    end.reject(&:empty?)
  end

  def chinese_noise?(value)
    CHINESE_MEDIA_NOISE.any? { |noise| value.include?(noise) } || value.chars.any? { |char| CHINESE_FUNCTION_CHARS.include?(char) }
  end

  def shingles(span, min_length, max_length)
    chars = span.chars
    (min_length..max_length).flat_map do |length|
      next [] if chars.length < length

      chars.each_cons(length).map(&:join)
    end
  end

  def numbers(text)
    normalize_text(text).scan(/(?<![A-Za-z])\d+(?:[.,]\d+)?(?:%|％)?/).map do |value|
      value.tr(",", ".").sub(/[％%]\z/, "").sub(/\A(\d+\.\d*?)0+\z/, '\\1').sub(/\.0+\z/, "")
    end.to_set
  end

  def number_units(text)
    escaped_units = UNITS.sort_by(&:length).reverse.map { |unit| Regexp.escape(unit) }.join("|")
    normalize_text(text).scan(/(?<![A-Za-z])(\d+(?:[.,]\d+)?)(?:\s*)(#{escaped_units})/i).map do |number, unit|
      "#{number.tr(',', '.')} #{unit.downcase}"
    end.to_set
  end

  def quoted_phrases(text)
    normalize_text(text).scan(/[“"「『《](.{2,80}?)[”"」』》]/).flatten.map { |value| value.strip }.reject(&:empty?).to_set
  end

  def normalize_text(value)
    text = value.to_s
    text = CGI.unescapeHTML(text)
    text = text.gsub(/<[^>]*>/, " ")
    text = text.unicode_normalize(:nfkc)
    text = text.gsub(/[\u00a0\u2007\u202f]/, " ")
    text = text.gsub(/\b(?:nbsp|amp)\b/i, " ")
    text.gsub(/[\s\u0000]+/, " ").strip
  rescue ArgumentError
    value.to_s
  end

  def english_language?(language)
    language == "en" || language.start_with?("en-")
  end

  def parse_time(value)
    return value.utc if value.is_a?(Time)
    return nil if value.nil? || value.to_s.strip.empty?

    Time.parse(value.to_s).utc
  rescue ArgumentError, TypeError
    nil
  end

  def format_hours(value)
    format("%.3f", value).sub(/\.?0+\z/, "")
  end

  def truthy?(value)
    value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def false_value?(value)
    value == false || %w[f false 0 no n].include?(value.to_s.downcase)
  end

  def jaccard(left, right)
    left = left.to_set
    right = right.to_set
    union = (left | right).length
    union.zero? ? 0.0 : (left & right).length.to_f / union
  end

  def dice(left, right)
    left = left.to_set
    right = right.to_set
    denominator = left.length + right.length
    denominator.zero? ? 0.0 : 2.0 * (left & right).length / denominator
  end

  def shared_values(left, right)
    (left.to_set & right.to_set).to_a.sort
  end
end
