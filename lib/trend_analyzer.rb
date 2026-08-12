# frozen_string_literal: true

require "digest"
require "set"
require "time"

# A deliberately small, inspectable trend detector for the local product slice.
# It counts terms across independent source IDs and compares two time windows;
# it never calls a single article a trend.
class TrendAnalyzer
  DEFAULT_WINDOW_HOURS = 48
  DEFAULT_RECENT_WINDOW_HOURS = 12
  MIN_MENTIONS = 2
  MIN_INDEPENDENT_SOURCES = 2

  CHINESE_STOPWORDS = Set.new(%w[
    中国 中方 我国 记者 报道 消息 表示 指出 相关 有关 今天 近日 日前 目前
    此外 同时 以及 这是 进行 工作 发布 新闻 世界 国际 方面 现场 可能
    北京 举行 联合 项目 国家 推动 大学 协会 参加 政府 登陆 发展 会议
    市场 公司 企业 事件 经济 社会 期间 地方 班牙 方面 计划 活动 组织
    文章 中新网 新网 网杭州 今年 微信公众 微信 公众 合主办 联合主办 主办
  ]).freeze
  ENGLISH_STOPWORDS = Set.new(%w[
    about after again against being between could first from have into more most other
    over said says should than that their there these they this those through under were
    what when where which while with would world news latest report reports people
    killed fire police president shooting article articles story stories government
    before office return latest update updates call calls days year years time times
    child three four more than near amid been home authorities first major live takes
    start started died death kill attack
    department announced provide assistance administration plans security
    school himself
  ]).freeze
  CHINESE_FUNCTION_CHARS = Set.new(%w[的 了 和 与 在 是 有 要 将 为 对 从 等 及 被 让 号]).freeze
  CHINESE_SHORT_TOPIC_WORDS = Set.new(%w[台风 地震 战争 选举 制裁 关税 通胀 疫情 芯片 能源 气候 量子 人工 智能]).freeze

  def initialize(window_hours: DEFAULT_WINDOW_HOURS, recent_window_hours: DEFAULT_RECENT_WINDOW_HOURS)
    @window_hours = Integer(window_hours)
    @recent_window_hours = Integer(recent_window_hours)
    raise ArgumentError, "recent window must be shorter than total window" unless @recent_window_hours < @window_hours
  end

  def analyze(items:, now: Time.now.utc)
    ending = parse_time(now)
    window_start = ending - (@window_hours * 3600)
    recent_start = ending - (@recent_window_hours * 3600)
    candidates = Hash.new { |hash, key| hash[key] = { "items" => [], "topic" => nil, "language" => nil } }

    Array(items).each do |item|
      # A feed without a publication timestamp cannot prove a time-window
      # change. Keep it available as source material, but exclude it from
      # trend evidence rather than treating fetch time as publication time.
      timestamp = parse_time(item["published_at"])
      next if timestamp.nil? || timestamp < window_start || timestamp > ending + 300

      analysis_language = item.fetch("translation_status", "") == "translated" ? "zh-CN" : item.fetch("language", "")
      item_tokens = tokens(item.fetch("display_title", item.fetch("title", "")), item.fetch("display_summary", item.fetch("summary", "")), analysis_language)
      token_labels = item_tokens.map { |token| token.fetch("label") }
      item_tokens.each do |token|
        bucket = candidates[token.fetch("key")]
        bucket["items"] << item.merge("_trend_timestamp" => timestamp, "_trend_tokens" => token_labels)
        bucket["topic"] ||= token.fetch("label")
        bucket["language"] ||= token.fetch("language")
        bucket["topic_kind"] ||= token.fetch("kind", "term")
      end
    end

    trends = candidates.each_with_object([]) do |(topic_key, bucket), result|
      records = bucket.fetch("items")
      unique_sources = records.map { |item| source_identity(item) }.uniq
      next if records.length < MIN_MENTIONS || unique_sources.length < MIN_INDEPENDENT_SOURCES
      next if bucket.fetch("topic_kind", "term") == "term" && !contextual_support?(records, bucket.fetch("topic"))

      recent_records, prior_records = records.partition { |item| item.fetch("_trend_timestamp") >= recent_start }
      recent_count = recent_records.length
      prior_count = prior_records.length
      next if recent_count.zero?
      state = if prior_count.zero?
                "new"
              elsif recent_count > prior_count
                "rising"
              else
                "watching"
              end
      source_names = records.map { |item| item.fetch("publisher_name", item.fetch("source_name")) }.uniq.sort
      regions = records.map { |item| item.fetch("region", "未标注") }.uniq.sort
      languages = records.map { |item| item.fetch("language", "未标注") }.uniq.sort
      growth_rate = prior_count.zero? ? nil : (((recent_count - prior_count).to_f / prior_count) * 100).round(1)
      growth_text = if growth_rate.nil?
                      "前一窗口无记录"
                    else
                      "相对前一窗口 #{format_growth(growth_rate)}"
                    end
      topic = bucket.fetch("topic")
      semantic_status = bucket.fetch("topic_kind", "term") == "phrase" ? "deterministic_episode" : "contextual_term"
      result << {
        "trend_key" => topic_key,
        "topic_key" => topic_key,
        "topic" => topic,
        "topic_language" => bucket.fetch("language"),
        "topic_kind" => bucket.fetch("topic_kind", "term"),
        "semantic_status" => semantic_status,
        "topic_label" => topic,
        "topic_explanation" => bucket.fetch("topic_kind", "term") == "phrase" ? "多个去重来源标识共享同一重复相邻词组。" : "多个去重来源标识提及同一词，并共享标题上下文。",
        "signal_state" => state,
        "summary" => "“#{topic}”在最近 #{@recent_window_hours} 小时出现 #{recent_count} 次，包含 #{unique_sources.length} 个去重来源标识；这是词频线索，#{growth_text}。",
        "mention_count" => records.length,
        "recent_mention_count" => recent_count,
        "prior_mention_count" => prior_count,
        "source_count" => unique_sources.length,
        "region_count" => regions.length,
        "language_count" => languages.length,
        "growth_rate" => growth_rate,
        "window_hours" => @window_hours,
        "recent_window_hours" => @recent_window_hours,
        "window_start" => window_start.iso8601,
        "window_end" => ending.iso8601,
        "source_names" => source_names,
        "regions" => regions,
        "languages" => languages,
        "evidence_urls" => records.map { |item| item.fetch("source_url") }.uniq.first(4)
      }
    end

    consolidate_fragments(trends).sort_by { |trend| [trend.fetch("topic_kind") == "phrase" ? 0 : 1, -trend.fetch("source_count"), -trend.fetch("recent_mention_count"), -trend.fetch("mention_count"), -trend.fetch("topic").length, trend.fetch("topic")] }.first(12)
  end

  private

  def tokens(title, summary, language)
    text = [title, summary].join(" ").to_s
    if language.to_s.downcase.start_with?("zh")
      chinese_tokens(text).map { |label| { "key" => "zh:#{label}", "label" => label, "language" => "zh-CN", "kind" => "term" } }
    else
      english_tokens(text).map { |label| { "key" => "en:#{label}", "label" => label, "language" => "en", "kind" => label.include?(" ") ? "phrase" : "term" } }
    end
  end

  def chinese_tokens(text)
    chunks = text.scan(/\p{Han}{2,}/)
    tokens = chunks.flat_map do |chunk|
      chars = chunk.chars
      (2..[4, chars.length].min).flat_map { |length| chars.each_cons(length).map(&:join) }
    end
    tokens.uniq.reject do |token|
      token.length < 3 && !CHINESE_SHORT_TOPIC_WORDS.include?(token) ||
        CHINESE_STOPWORDS.any? { |stopword| token.include?(stopword) } ||
        token.chars.any? { |char| CHINESE_FUNCTION_CHARS.include?(char) }
    end
  end

  def english_tokens(text)
    words = text.downcase.scan(/[a-z][a-z'-]{3,}/).uniq.reject { |token| ENGLISH_STOPWORDS.include?(token) }
    phrases = words.each_cons(2).map { |left, right| "#{left} #{right}" }
    words + phrases
  end

  def consolidate_fragments(trends)
    trends.reject do |candidate|
      candidate_label = candidate.fetch("topic")
      candidate_sources = candidate.fetch("source_names")
      trends.any? do |other|
        next false if other.equal?(candidate)
        other_label = other.fetch("topic")
        other.fetch("topic_language") == candidate.fetch("topic_language") &&
          (other_label.length > candidate_label.length ||
            (other_label.length == candidate_label.length && better_fragment_representative?(other, candidate))) &&
          (other_label.include?(candidate_label) || overlapping_cjk_fragment?(candidate_label, other_label)) &&
          (candidate_sources - other.fetch("source_names")).empty?
      end
    end
  end

  def overlapping_cjk_fragment?(shorter, longer)
    return false unless shorter.match?(/\A\p{Han}+\z/) && longer.match?(/\A\p{Han}+\z/)

    shorter.chars.each_cons(shorter.length >= 3 ? 3 : 2).any? { |chars| longer.include?(chars.join) }
  end

  def better_fragment_representative?(candidate, other)
    candidate.fetch("source_count") > other.fetch("source_count") ||
      (candidate.fetch("source_count") == other.fetch("source_count") && candidate.fetch("mention_count") >= other.fetch("mention_count"))
  end

  def source_identity(item)
    publisher_url = item.fetch("publisher_url", "").to_s.strip.downcase
    publisher_url.empty? ? "feed:#{item.fetch('source_id')}" : "publisher:#{publisher_url}"
  end

  def contextual_support?(records, topic)
    context_counts = Hash.new { |hash, key| hash[key] = Set.new }
    records.each do |item|
      Array(item.fetch("_trend_tokens", [])).uniq.each do |token|
        next if token == topic

        context_counts[token] << source_identity(item)
      end
    end
    context_counts.values.any? { |sources| sources.length >= MIN_INDEPENDENT_SOURCES }
  end

  def parse_time(value)
    return nil if value.nil? || value.to_s.empty?

    value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
  rescue ArgumentError, TypeError
    nil
  end

  def format_growth(value)
    value.positive? ? "+#{value}%" : "#{value}%"
  end
end
