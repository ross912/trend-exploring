# frozen_string_literal: true

require "cgi"
require "digest"
require "json"
require "set"
require "time"

# Deterministic, evidence-first detector for non-lexical world-change
# candidates.  It deliberately keeps five channels separate.  It never
# compresses them into a score, probability, confidence, or prediction.
class WorldChangeDetector
  VERSION = "world_change_detector_v2"
  CHANNELS = %w[
    technical_capability
    capital_commitment
    policy_action
    real_world_adoption
    public_discussion
  ].freeze
  MIN_INDEPENDENT_PUBLISHERS = 2
  DEFAULT_MAX_AGE_HOURS = 168
  MAX_EVIDENCE_PER_CHANNEL = 50
  MAX_LABEL_CHARS = 96
  DERIVED_MIN_SHARED_ANCHORS = 3

  # This manifest is part of the detector contract.  A run is only allowed
  # to cross the public boundary when it carries this exact version/hash pair;
  # callers cannot opt into the precision gate by setting a boolean alone.
  PRECISION_VALIDATION_MANIFEST = {
    "manifest_version" => "world_change_precision_validation_v1",
    "detector_version" => VERSION,
    "rules" => {
      "numeric_only_proposition" => "reject",
      "requires_mapping_for_cross_language" => true,
      "complete_link" => {
        "scope" => "same_language_without_mapping",
        "min_shared_anchors" => DERIVED_MIN_SHARED_ANCHORS,
        "transitive_bridges" => "reject"
      },
      "strict_channel_rules" => true,
      "item_version_dedup" => "latest_published_version_per_item"
    }
  }.freeze
  PRECISION_VALIDATION_MANIFEST_HASH = Digest::SHA256.hexdigest(JSON.generate(PRECISION_VALIDATION_MANIFEST)).freeze

  class Error < StandardError; end

  ENGLISH_STOPWORDS = Set.new(%w[
    a an and are as at be been being by can could did do does for from had has have
    he her his how i if in into is it its me more most my of on or our people said
    she that the their them they this those to was we were what when where which who
    why will with would you your about after before during over under than then
    latest news report reports update updates story stories today yesterday world
    says said according officials official source sources public discussion discussions
  ]).freeze

  # Words used to describe a channel or generic journalistic framing are not
  # useful proposition identity tokens.  These are intentionally conservative:
  # the detector is allowed to keep a false candidate for review, but it must
  # not invent independent evidence.
  TOPIC_NOISE = Set.new(%w[
    announce announced announcement launch launched launches new plan plans planned
    proposal proposed proposes project projects program programmes programme initiative
    policy policies action actions move moves moving change changes changed changing
    funding fund funds invest investment invested financing finance capital valuation
    deploy deployed deployment adoption adopted adopts use users usage production rollout
    approve approved approval ban banned mandate mandated regulation regulatory law laws
    develop developed development breakthrough capability capabilities technology tech
    discuss discussion debate attention concern concerns reaction reactions
    confirm confirmed denies denied denial fail failed failure no not without
    人们 表示 指出 发布 报道 消息 计划 项目 项目组 公司 政府 官方 最近 今日 目前
    发展 变化 行动 采用 使用 部署 融资 投资 估值 资本 政策 法规 法律 监管
    技术 能力 突破 讨论 关注 争议 证实 否认 失败 没有 尚未
    world global international national latest major new year years area areas
    company companies government governments officials market markets economy
    economic business industry industries people person report reports news media
    announced announcement announcement press release statement statements update
    updated confirms confirmed according say says said source sources today yesterday
    country countries region regions officials data level levels issue issues
  ]).freeze

  # A derived proposition may only use concrete anchors.  These are kept
  # separate from channel vocabulary so a generic action word cannot bridge
  # otherwise unrelated stories.
  GENERIC_ANCHORS = Set.new(%w[
    rise rises fell fall falls increase increases decreased decrease growth
    crisis crisis-hit response responses effort efforts plan plans planned
    project projects program programmes programme initiative initiatives
    launch launched launches announce announces announced move moves action
    change changes changed changing new latest major first latest year years
    city cities state states country countries national international global
    people company companies government governments officials market markets
    fight fights used use using united south trump
  ]).freeze

  CHANNEL_HINT_ALIASES = {
    "technical" => "technical_capability", "technology" => "technical_capability",
    "technical_capability" => "technical_capability", "capability" => "technical_capability",
    "capital" => "capital_commitment", "funding" => "capital_commitment",
    "investment" => "capital_commitment", "capital_commitment" => "capital_commitment",
    "policy" => "policy_action", "regulation" => "policy_action", "policy_action" => "policy_action",
    "adoption" => "real_world_adoption", "deployment" => "real_world_adoption",
    "real_world_adoption" => "real_world_adoption", "real-world-adoption" => "real_world_adoption",
    "discussion" => "public_discussion", "attention" => "public_discussion",
    "public_discussion" => "public_discussion"
  }.freeze

  CONTRADICTION_TERMS = Set.new(%w[
    deny denies denied denial refute refuted rejected rejection cancel cancelled canceled
    halt halted stop stopped fail failed failure scrapped abandoned no not never without
    否认 否定 驳回 拒绝 取消 终止 停止 失败 失败率 尚未 没有 未 无 不再
  ]).freeze

  CHANNEL_PATTERNS = {
    "technical_capability" => [
      /\b(?:benchmark|prototype|chip|battery|vaccine|algorithm|software|hardware)\b[^.]{0,100}\b(?:demonstrat(?:ed|es|ion)|achiev(?:ed|es)|performance|accuracy|record|tested|validated|developed)\b/i,
      /\b(?:model|technology|capability)\b[^.]{0,100}\b(?:benchmark|performance|accuracy|record|tested|validated|trained|inference)\b/i,
      /(?:芯片|电池|疫苗|算法|软件|硬件|原型)[^。]{0,50}(?:性能|精度|纪录|测试|验证|研发|实现|突破)/
    ],
    "capital_commitment" => [
      /(?:(?:\$|€|£|¥|₹|R\$)\s?\d[\d,.]*|\b\d[\d,.]*\s?(?:million|billion|mn|bn)\b)[^.]{0,120}\b(?:fund(?:ing|ed)?|invest(?:ment|ed)?|financ(?:ing|e)|capital|commit(?:s|ted|ment)?|raise[sd]?|spend|award(?:ed)?|grant|loan)\b/i,
      /\b(?:fund(?:ing|ed)?|invest(?:ment|ed)?|financ(?:ing|e)|capital|commit(?:s|ted|ment)?|raise[sd]?|spend|award(?:ed)?|grant|loan)\b[^.]{0,120}(?:(?:\$|€|£|¥|₹|R\$)\s?\d[\d,.]*|\b\d[\d,.]*\s?(?:million|billion|mn|bn)\b)/i,
      /(?:(?:融资|投资|估值|资本|支出|采购|合同|拨款|贷款)[^。]{0,80}(?:亿元|亿美元|百万|十亿|金额|\d[\d,.]*\s?(?:万|亿)))|(?:(?:亿元|亿美元|百万|十亿)[^。]{0,80}(?:融资|投资|资本|承诺|投入|筹集))/
    ],
    "policy_action" => [
      /\b(?:government|parliament|regulator|agency|court)\b[^.]{0,100}\b(?:law|legislation|regulation|regulatory|mandate|ban|sanction|tax credit|order|approved|approval)\b/i,
      /\b(?:law|legislation|regulation|mandate|ban|sanction|tax credit)\b[^.]{0,100}\b(?:takes effect|effective|enacted|approved|passed|requires|prohibits)\b/i,
      /(?:政府|议会|监管机构|法院)[^。]{0,60}(?:法律|立法|法规|监管|强制|禁令|制裁|税收|行政令|批准|通过)/
    ],
    "real_world_adoption" => [
      /\b(?:deployed|deployment|adopted|adoption|rolled out|rollout|in production|installed|operational)\b[^.]{0,100}\b(?:customers|users|facilities|sites|fleet|service|system|product|production|sales|revenue)\b/i,
      /\b(?:customers|users|sales|revenue)\b[^.]{0,100}\b(?:adopt(?:ed|ion)?|use|usage|deployed|installed|operational|rolled out)\b/i,
      /(?:部署|采用|落地|上线|生产|客户|用户|销量|安装|运营|开通|投入使用)[^。]{0,50}(?:系统|产品|服务|工厂|设施|平台|收入|销量)/
    ],
    "public_discussion" => [
      /\b(?:discussion|debate|conversation|opinion|survey|poll|protest|backlash|trend)\b[^.]{0,100}\b(?:public|people|voters|users|online|social|opinion|support|oppose)\b/i,
      /\b(?:public|people|voters|users|online|social)\b[^.]{0,100}\b(?:discuss(?:ed|ion)?|debate|conversation|survey|poll|protest|backlash|trend)\b/i,
      /(?:讨论|舆论|谈论|民调|调查|抗议|反弹|热议|呼声|争论)[^。]{0,50}(?:公众|民众|网友|投票|社交|舆论)/i
    ]
  }.freeze

  attr_reader :detector_version

  def self.precision_validation_manifest
    JSON.parse(JSON.generate(PRECISION_VALIDATION_MANIFEST))
  end

  def self.precision_validation_manifest_hash
    PRECISION_VALIDATION_MANIFEST_HASH
  end

  def precision_validation_manifest
    self.class.precision_validation_manifest
  end

  def precision_validation_manifest_hash
    self.class.precision_validation_manifest_hash
  end

  def initialize(max_age_hours: DEFAULT_MAX_AGE_HOURS, detector_version: VERSION)
    @max_age_hours = Integer(max_age_hours)
    raise Error, "max age must be positive" unless @max_age_hours.positive?
    @detector_version = detector_version.to_s
    raise Error, "detector version is required" if @detector_version.empty?
  rescue ArgumentError, TypeError => error
    raise Error, error.message
  end

  # Analyze immutable source-item shaped rows.  The order of rows never
  # changes the output.  Explicit channel/proposition fields are accepted for
  # structured upstream fixtures; lexical fallback remains deterministic and
  # auditable for raw title/summary rows.
  def analyze(items:, now: Time.now.utc)
    ending = parse_time(now)
    raise Error, "now must be a valid time" unless ending

    records = []
    Array(items).each do |item|
      record = normalize_item(item, ending: ending)
      records << record if record
    end
    records = dedupe_input_versions(records)
    records.sort_by! { |record| record.fetch("stable_key") }

    groups = proposition_groups(records)
    result = groups.map { |group| build_candidate(group, ending: ending) }.compact
      .select { |candidate| candidate.fetch("qualifying_publisher_count") >= MIN_INDEPENDENT_PUBLISHERS }
    result.sort_by { |candidate| [candidate.fetch("candidate_key"), candidate.fetch("label")] }
  end

  alias detect analyze
  alias call analyze

  private

  def normalize_item(item, ending:)
    return nil unless item.is_a?(Hash)
    value = item.transform_keys(&:to_s)
    version_id = value.fetch("version_id", "").to_s.strip
    return nil if version_id.empty?

    published_at = parse_time(value["published_at"] || value["created_at"])
    return nil unless published_at
    return nil if published_at > ending
    return nil if published_at < ending - (@max_age_hours * 3600)

    title = clean_text(value.fetch("title", ""))
    summary = clean_text(value.fetch("summary", ""))
    text = [title, summary].reject(&:empty?).join(" ")
    return nil if text.empty?

    publisher_id = value.fetch("publisher_id", "").to_s.strip
    publisher_status = value.fetch("publisher_identity_status", publisher_id.empty? ? "unresolved" : "configured").to_s
    query = truthy?(value.fetch("query_conditioned", value.fetch("query", false)))
    exploration = truthy?(value.fetch("exploration_only", value.fetch("exploration", false))) ||
      value.fetch("analysis_policy", "").to_s == "exploration_only" ||
      value.fetch("discovery_basis", "").to_s == "locale_headlines"
    source_kind = value.fetch("source_kind", "").to_s
    exploration ||= source_kind == "discovery" && value.fetch("analysis_policy", "").to_s == "exploration_only"

    proposition_key = explicit_proposition(value)
    explicit_proposition_flag = !proposition_key.empty?
    tokens = lexical_tokens(text)
    proposition_key = derive_proposition_key(tokens) if proposition_key.empty?
    return nil if proposition_key.empty?
    return nil if numeric_only_proposition?(proposition_key)

    explicit_channel_values = explicit_channels(value)
    channels = if explicit_channel_values.empty?
      inferred_channels(text).select { |channel| channel_evidence?(channel, text) }
    else
      explicit_channel_values
    end
    # Structured proposition rows are still useful when their prose does not
    # contain one of the narrow channel phrases.  Keep them in the detector as
    # discussion-only evidence rather than dropping them entirely.  This is a
    # deliberately non-action default: no amount of generic wording such as
    # "launch plan announced" can infer policy, capital, technology, or
    # adoption.  Rows without a proposition remain subject to the lexical
    # evidence gate below and are therefore not admitted merely because they
    # contain a headline-shaped sentence.
    channels = ["public_discussion"] if channels.empty? && !proposition_key.empty?
    return nil if channels.empty?

    contradiction = explicit_contradiction?(value) || contradiction_text?(text)
    reason_codes = []
    reason_codes << "query_conditioned_support" if query
    reason_codes << "exploration_support" if exploration
    reason_codes << "contradicting_claim" if contradiction
    eligible = !query && !exploration && resolved_publisher?(publisher_id, publisher_status)
    stable_key = [version_id, publisher_id, published_at.iso8601(6), proposition_key].join("\u0000")

    {
      "version_id" => version_id,
      "item_key" => value.fetch("item_key", "").to_s,
      "publisher_id" => publisher_id,
      "publisher_name" => value.fetch("publisher_name", publisher_id).to_s,
      "publisher_identity_status" => publisher_status,
      "source_id" => value.fetch("source_id", "").to_s,
      "source_kind" => source_kind,
      "query_conditioned" => query,
      "exploration" => exploration,
      "language" => value.fetch("language", "").to_s,
      "concept_mapping" => normalize_concept_mapping(value),
      "title" => title,
      "summary" => summary,
      "source_url" => value.fetch("source_url", "").to_s,
      "published_at" => published_at.iso8601(6),
      "proposition_key" => proposition_key,
      "explicit_proposition" => explicit_proposition_flag,
      "label" => explicit_label(value, proposition_key, tokens),
      "channels" => channels,
      "contradicting" => contradiction,
      "eligible" => eligible,
      "reason_codes" => reason_codes,
      "stable_key" => stable_key,
      "tokens" => tokens
    }
  end

  def proposition_groups(records)
    # Explicit propositions and provider-backed concept mappings are already
    # identity claims.  A derived proposition key, however, is only a
    # deterministic seed from one headline; using it as a hard pre-bucket
    # would prevent two rewrites of the same event from ever reaching the
    # complete-link check.  Derived rows are therefore clustered within their
    # language, and never across languages unless the shared mapping identity
    # above has proved equivalence.
    mapped_or_explicit = records.reject { |record| derived_without_mapping?(record) }
    derived = records.select { |record| derived_without_mapping?(record) }

    groups = mapped_or_explicit.group_by { |record| proposition_identity(record) }
      .keys.sort.flat_map do |key|
        group = mapped_or_explicit.group_by { |record| proposition_identity(record) }.fetch(key)
          .sort_by { |record| record.fetch("stable_key") }
        # An explicit proposition or a valid concept mapping is the upstream
        # identity boundary.  Do not apply lexical bridging inside it.
        [group]
      end

    derived.group_by { |record| record.fetch("language").to_s.downcase }.keys.sort.each do |language|
      rows = derived.group_by { |record| record.fetch("language").to_s.downcase }.fetch(language)
        .sort_by { |record| record.fetch("stable_key") }
      clusters = rows.each_with_object([]) do |record, result|
        index = result.index { |other| complete_link_compatible?([record], other) }
        index ? result[index] << record : result << [record]
      end
      groups.concat(clusters)
    end

    groups.map { |group| group.sort_by { |record| record.fetch("stable_key") } }
  end

  def derived_without_mapping?(record)
    !record.fetch("explicit_proposition") && !record.fetch("concept_mapping").fetch("valid", false)
  end

  def proposition_identity(record)
    mapping = record.fetch("concept_mapping", {})
    if mapping.fetch("valid", false)
      return "concept:#{mapping.fetch("canonical_concept_key")}:#{mapping.fetch("provider")}:#{mapping.fetch("model")}:#{mapping.fetch("prompt_version")}"
    end
    language = record.fetch("language").to_s.downcase
    "#{record.fetch("explicit_proposition") ? "explicit" : "derived"}:#{language}:#{record.fetch("proposition_key")}"
  end

  def complete_link_compatible?(left_group, right_group)
    (left_group + right_group).combination(2).all? do |left, right|
      next true if left.equal?(right)
      strong_anchor_overlap?(left, right)
    end
  end

  def strong_anchor_overlap?(left, right)
    left_tokens = left.fetch("tokens").reject { |token| GENERIC_ANCHORS.include?(token) }.to_set
    right_tokens = right.fetch("tokens").reject { |token| GENERIC_ANCHORS.include?(token) }.to_set
    overlap = left_tokens & right_tokens
    overlap.length >= DERIVED_MIN_SHARED_ANCHORS
  end

  def dedupe_input_versions(records)
    records.group_by do |record|
      item_key = record.fetch("item_key").to_s
      item_key.empty? ? "version:#{record.fetch("version_id")}" : "item:#{item_key}"
    end
      .values.map do |versions|
        versions.max_by { |record| [record.fetch("published_at"), record.fetch("version_id")] }
      end
  end

  def normalize_concept_mapping(value)
    raw = value.fetch("concept_mapping", value.fetch("concept", nil))
    raw = raw.to_h.transform_keys(&:to_s) if raw.respond_to?(:to_h)
    return { "valid" => false } unless raw.is_a?(Hash)
    required = %w[canonical_concept_key provider model prompt_version input_hash output_hash]
    return { "valid" => false } unless required.all? { |key| !raw.fetch(key, "").to_s.strip.empty? }
    relation = raw.fetch("relation", "unknown").to_s
    return { "valid" => false } unless %w[exact_alias translation_equivalent].include?(relation)
    {
      "valid" => true,
      "canonical_concept_key" => raw.fetch("canonical_concept_key").to_s.strip,
      "provider" => raw.fetch("provider").to_s.strip,
      "model" => raw.fetch("model").to_s.strip,
      "prompt_version" => raw.fetch("prompt_version").to_s.strip,
      "input_hash" => raw.fetch("input_hash").to_s.strip,
      "output_hash" => raw.fetch("output_hash").to_s.strip,
      "relation" => relation
    }
  end

  def common_label(group)
    labels = group.map { |record| clean_text(record.fetch("label", "")) }.reject(&:empty?)
    return shorten_label(labels.first) if labels.uniq.length == 1
    token_sets = group.map { |record| record.fetch("tokens").reject { |token| GENERIC_ANCHORS.include?(token) } }
    shared = token_sets.reduce { |acc, tokens| acc & tokens }
    shared = shared.sort_by { |token| [-token.length, token] }.first(4)
    return shorten_label(shared.join(" ")) unless shared.empty?
    ""
  end

  def shorten_label(value)
    text = clean_text(value)
    return text if text.length <= MAX_LABEL_CHARS

    words = text.scan(/[A-Za-z0-9][A-Za-z0-9'\-]*|\p{Han}+/u)
    short = words.first(8).join(" ")
    short = text[0, MAX_LABEL_CHARS].strip if short.empty?
    short[0, MAX_LABEL_CHARS].strip
  end

  def build_candidate(group, ending:)
    # Candidate identity is proposition-based, not evidence-count based: adding
    # a query-conditioned/supporting row must not create a new candidate key.
    proposition_identity = group.map { |record| record.fetch("proposition_key") }.uniq.sort.join("\u0000")
    proposition_key = Digest::SHA256.hexdigest(proposition_identity)[0, 24]
    label = common_label(group)

    # A publisher may emit several titles or rewrites for the same proposition.
    # Keep one deterministic representative per publisher for qualification and
    # channel evidence so a prolific source cannot inflate independence or
    # channel breadth. Raw rows remain in evidence_items for auditability.
    qualifying = dedupe_qualifying_rows(group.select { |record| record.fetch("eligible") && !record.fetch("contradicting") })
    qualifying_publishers = qualifying.map { |record| record.fetch("publisher_id") }.reject(&:empty?).uniq.sort
    channel_output = {}
    CHANNELS.each do |channel|
      channel_rows = group.select { |record| record.fetch("channels").include?(channel) }
      eligible_rows = qualifying.select { |record| record.fetch("channels").include?(channel) }
      support_rows = channel_rows.reject { |record| qualifying.include?(record) }
      contradiction_rows = channel_rows.select { |record| record.fetch("contradicting") }
      channel_output[channel] = {
        "version_ids" => eligible_rows.map { |record| record.fetch("version_id") }.uniq.sort,
        "publisher_ids" => eligible_rows.map { |record| record.fetch("publisher_id") }.reject(&:empty?).uniq.sort,
        "evidence" => eligible_rows.map { |record| evidence_row(record, channel: channel, role: "qualifying") }.first(MAX_EVIDENCE_PER_CHANNEL),
        "supporting_evidence" => support_rows.map do |record|
          evidence_row(record, channel: channel, role: support_role(record, qualifying_rows: qualifying))
        end.first(MAX_EVIDENCE_PER_CHANNEL),
        "contradicting_evidence" => contradiction_rows.map { |record| evidence_row(record, channel: channel, role: "contradicting") }.first(MAX_EVIDENCE_PER_CHANNEL)
      }
    end

    qualifying_channels = CHANNELS.select { |channel| !channel_output.fetch(channel).fetch("version_ids").empty? }
    missing_channels = CHANNELS - qualifying_channels
    contradictions = group.select { |record| record.fetch("contradicting") }
      .map { |record| evidence_row(record, channel: record.fetch("channels").first, role: "contradicting") }
    query_count = group.count { |record| record.fetch("query_conditioned") }
    exploration_count = group.count { |record| record.fetch("exploration") }
    alternative = alternative_explanations(group, qualifying, qualifying_publishers, qualifying_channels)
    next_steps = next_verification(missing_channels, contradictions)

    {
      "candidate_key" => "world-change-#{proposition_key}",
      "label" => label,
      "detector_version" => @detector_version,
      "candidate_status" => qualifying_channels.length >= 2 ? "convergence_candidate" : "candidate",
      "qualifying_publisher_ids" => qualifying_publishers,
      "qualifying_publisher_count" => qualifying_publishers.length,
      "qualifying_version_ids" => qualifying.map { |record| record.fetch("version_id") }.uniq.sort,
      "channel_count" => qualifying_channels.length,
      "channels" => channel_output,
      "evidence_items" => group.sort_by { |record| record.fetch("stable_key") }.map do |record|
        evidence_row(record, channel: record.fetch("channels").first,
                     role: evidence_role(record, qualifying_rows: qualifying))
      end,
      "contradicting_evidence" => contradictions,
      "missing_channels" => missing_channels,
      "alternative_explanations" => alternative,
      "next_verification" => next_steps,
      "query_conditioned_evidence_count" => query_count,
      "exploration_evidence_count" => exploration_count,
      "observed_publisher_ids" => group.map { |record| record.fetch("publisher_id") }.reject(&:empty?).uniq.sort,
      "first_published_at" => group.map { |record| record.fetch("published_at") }.min,
      "last_published_at" => group.map { |record| record.fetch("published_at") }.max,
      "analysis_as_of" => ending.iso8601(6)
    }
  end

  def dedupe_qualifying_rows(rows)
    rows.group_by { |record| record.fetch("publisher_id") }
      .sort_by { |publisher_id, _| publisher_id }
      .map do |_publisher_id, publisher_rows|
        publisher_rows.max_by do |record|
          [record.fetch("published_at"), record.fetch("version_id"), record.fetch("stable_key")]
        end
      end
      .sort_by { |record| record.fetch("stable_key") }
  end

  def evidence_row(record, channel:, role:)
    {
      "version_id" => record.fetch("version_id"),
      "item_key" => record.fetch("item_key"),
      "publisher_id" => record.fetch("publisher_id"),
      "publisher_name" => record.fetch("publisher_name"),
      "source_id" => record.fetch("source_id"),
      "source_kind" => record.fetch("source_kind"),
      "source_url" => record.fetch("source_url"),
      "language" => record.fetch("language"),
      "title" => record.fetch("title"),
      "summary" => record.fetch("summary"),
      "published_at" => record.fetch("published_at"),
      "channel" => channel,
      "lineage_role" => role,
      "qualification_eligible" => record.fetch("eligible") && role == "qualifying",
      "query_conditioned" => record.fetch("query_conditioned"),
      "exploration" => record.fetch("exploration"),
      "contradicting" => record.fetch("contradicting"),
      "reason_codes" => record.fetch("reason_codes")
    }
  end

  def evidence_role(record, qualifying_rows: nil)
    return "contradicting" if record.fetch("contradicting")
    return "query_conditioned_support" if record.fetch("query_conditioned")
    return "exploration_support" if record.fetch("exploration")
    if qualifying_rows && record.fetch("eligible") && !qualifying_rows.include?(record)
      return "duplicate_publisher_support"
    end

    "qualifying"
  end

  def support_role(record, qualifying_rows: nil)
    evidence_role(record, qualifying_rows: qualifying_rows)
  end

  def alternative_explanations(group, qualifying, publishers, channels)
    values = []
    duplicate_publishers = group.group_by { |record| record.fetch("publisher_id") }.values.select { |rows| rows.length > 1 && !rows.first.fetch("publisher_id").empty? }
    values << "同一 publisher 的多标题或转载可能夸大表面上的证据数量；独立性按 publisher_id 去重。" unless duplicate_publishers.empty?
    values << "query-conditioned 或 exploration 材料只能作为支持线索，不能单独取得资格。" if group.any? { |record| record.fetch("query_conditioned") || record.fetch("exploration") }
    values << "当前只有 public_discussion 证据，讨论不等于政策、资本、技术或现实采用。" if channels == ["public_discussion"]
    values << "存在相互矛盾或否定性材料，候选状态不能视为已确认。" if group.any? { |record| record.fetch("contradicting") }
    values << "不同标题可能描述同一原始消息或共同来源，需要回查 source lineage。" if group.map { |record| record.fetch("source_url") }.reject(&:empty?).uniq.length < qualifying.length
    values << "证据窗口、地域或语言覆盖有限，不能外推为全世界变化。"
    values.uniq
  end

  def next_verification(missing_channels, contradictions)
    steps = missing_channels.map { |channel| "补充可追溯的 #{channel} 证据，并记录对应 version_id。" }
    steps << "逐条复核 contradicting evidence 与原始 version_id、发布时间和 source lineage。" unless contradictions.empty?
    steps << "核验至少一个新的独立 publisher 是否提供同一命题的原始证据。"
    steps.uniq
  end

  def explicit_proposition(value)
    %w[proposition_key proposition topic_key topic subject event_key concept_key].each do |key|
      text = value.fetch(key, "").to_s.strip
      return normalize_key(text) unless text.empty?
    end
    ""
  end

  def explicit_label(value, proposition_key, tokens)
    text = value.fetch("label", value.fetch("proposition", "")).to_s.strip
    return clean_text(text) unless text.empty?

    fallback = proposition_key.to_s.split(" ").reject { |token| token.length < 2 }.first(8).join(" ")
    fallback.empty? ? proposition_key.to_s : fallback
  end

  def explicit_channels(value)
    raw = []
    %w[channel evidence_channel channel_hint].each { |key| raw << value.fetch(key) if value.key?(key) }
    %w[channels evidence_channels change_channels channel_tags].each { |key| raw.concat(Array(value.fetch(key))) if value.key?(key) }
    raw.map { |entry| CHANNEL_HINT_ALIASES.fetch(entry.to_s.downcase, entry.to_s.downcase) }
      .select { |channel| CHANNELS.include?(channel) }.uniq.sort
  end

  def inferred_channels(text)
    CHANNELS.select do |channel|
      CHANNEL_PATTERNS.fetch(channel).any? { |pattern| text.match?(pattern) }
    end
  end

  def channel_evidence?(channel, text)
    CHANNEL_PATTERNS.fetch(channel).any? { |pattern| text.match?(pattern) }
  end

  def explicit_contradiction?(value)
    truthy?(value.fetch("contradicting", value.fetch("contradiction", false))) ||
      %w[contradicts contradictory negative denied rejected refuted].include?(value.fetch("evidence_polarity", value.fetch("claim_relation", "")).to_s.downcase)
  end

  def contradiction_text?(text)
    words = text.downcase.scan(/[a-z]+|\p{Han}+/u)
    words.any? { |word| CONTRADICTION_TERMS.include?(word) }
  end

  def token_sets_overlap?(left_group, right_group)
    left = left_group.flat_map { |record| record.fetch("tokens") }.to_set
    right = right_group.flat_map { |record| record.fetch("tokens") }.to_set
    overlap = left & right
    overlap.length >= 2
  end

  def lexical_tokens(text)
    tokens = text.downcase.scan(/[a-z][a-z0-9'\-]{2,}|\p{Han}{2,}|\p{Hiragana}{2,}|\p{Katakana}{2,}|\p{Hangul}{2,}|\d+(?:\.\d+)?/u)
    tokens.each_with_object([]) do |token, result|
      next if ENGLISH_STOPWORDS.include?(token) || TOPIC_NOISE.include?(token)
      next if token.match?(/\A\d+(?:\.\d+)?\z/)

      result << token
    end.uniq.sort
  end

  def derive_proposition_key(tokens)
    tokens.first(10).join(" ")
  end

  def numeric_only_proposition?(value)
    value.to_s.match?(/\A[\d\s.,%+\-]+\z/)
  end

  def normalize_key(value)
    clean_text(value).downcase.split.join(" ")
  end

  def clean_text(value)
    text = value.to_s
    text = CGI.unescapeHTML(text)
    text = text.gsub(/<[^>]*>/, " ")
    text.gsub(/\s+/, " ").strip
  end

  def resolved_publisher?(publisher_id, status)
    !publisher_id.to_s.empty? && %w[configured observed_domain].include?(status.to_s)
  end

  def truthy?(value)
    value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
  end

  def parse_time(value)
    return nil if value.nil? || value.to_s.empty?

    (value.is_a?(Time) ? value : Time.parse(value.to_s)).utc
  rescue ArgumentError, TypeError
    nil
  end
end

WorldChangeDetectorV1 = WorldChangeDetector unless defined?(WorldChangeDetectorV1)
