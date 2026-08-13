# frozen_string_literal: true

require "set"

# Deterministically derives the short-lived query sent to the global archive.
#
# The raw question is a private-domain value.  This class intentionally emits
# only a canonical bag of public-looking topic/entity/time terms.  It does not
# attempt to infer a user's intent, profile, or stance.  If no public query can
# be derived safely, callers must fail closed rather than send the raw text.
class QueryNeutralizer
  VERSION = "query_neutralizer_v1"
  MAX_LENGTH = 2_000

  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "QUERY_NEUTRALIZATION_FAILED")
      @code = code
      super(message)
    end
  end

  # These patterns are deliberately conservative.  A possible secret or
  # direct identifier blocks the global leg entirely; it is never copied into
  # a canonical query or an error message.
  CHINESE_SENSITIVE_PATTERNS = [
    # Direct medical/identity fields followed by a value.  The field names
    # alone are not blocked so a public explainer such as “身份证办理政策” can
    # still be searched; a first-person field mention is handled below.
    /(?:病历(?:号|编号)?|病案(?:号|编号)?|病例(?:号|编号)?|就诊(?:号|编号|卡号)?|住院(?:号|编号)?|医疗记录(?:号|编号)?|医保(?:号|卡号)?)\s*[:：#]?\s*[A-Za-z0-9][A-Za-z0-9\-]{4,}/i,
    /(?:身份证|居民身份证|证件|护照|社保卡|医保卡|驾驶证|通行证)(?:号码|号|编号|信息)?\s*[:：#]?\s*[A-Za-z0-9][A-Za-z0-9\-]{5,}/i,
    /(?<!\d)(?:\+?86[-\s]?)?1[3-9]\d{9}(?!\d)/,
    /(?<!\d)\d{17}[\dXx](?!\d)|(?<!\d)\d{15}(?!\d)/,
    /(?:我的|本人|我这边的|我自己的)\s*(?:病历|病案|病例|就诊卡|住院|医疗记录|医保卡|身份证|居民身份证|证件|护照|社保卡|驾驶证|通行证|手机号|手机号码|电话|住址|家庭住址|联系地址|收货地址)/,
    /(?:手机号|手机号码|联系电话|电话号码|电话)\s*[:：#]?\s*(?:\+?86[-\s]?)?1[3-9]\d{9}/,
    /(?:住址|家庭住址|联系地址|收货地址|最新地址|地址是|地址为|我住在|家住|住在)\s*[:：]?\s*[^，,。；;!?！？]{6,}(?:号|路|街|区|县|镇|市|省|大厦|小区|室|单元|楼|巷|弄|道)/,
    /(?:地址|住址)\s*[:：]\s*[^，,。；;!?！？]{6,}(?:号|路|街|区|县|镇|市|省|大厦|小区|室|单元|楼|巷|弄|道)/,
    # “内部/未公开 + company/project/plan/code + name” is a high-signal
    # unpublished artifact cue.  Public place + public topic has no such cue.
    /(?:未公开|未披露|尚未公开|尚未发布|未发布|非公开)\s*(?:的)?\s*(?:公司|项目|产品|计划|代号|代码|名称)?\s*[:：]?\s*[“"‘']?[\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9_\-]{2,40}/,
    /(?:内部|机密|保密|私有|内部代号|项目代号)\s*(?:的)?\s*(?:公司|项目|产品|计划|代号|代码|名称)\s*[:：]?\s*[“"‘']?[\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9_\-]{1,40}/,
    /(?:公司|项目|产品|计划)\s*(?:内部|机密|保密|私有|未公开|未披露)\s*(?:代号|代码|名称)?\s*[:：]?\s*[“"‘']?[\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9_\-]{1,40}/
  ].freeze

  SENSITIVE_PATTERNS = [
    /https?:\/\//i,
    /\bwww\./i,
    /\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i,
    /\b(?:\+?\d[\d\s().\-]{7,}\d)\b/,
    /\b(?:sk|pk|api[_-]?key|token|secret)[_-]?[A-Za-z0-9]{8,}\b/i,
    /\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b/i,
    /\bBearer\s+[A-Za-z0-9._\-]{12,}\b/i,
    /\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/,
    /\b(?:canary|private|internal|confidential|secret)[-_]?[A-Za-z0-9]{4,}\b/i,
    *CHINESE_SENSITIVE_PATTERNS
  ].freeze

  # Query syntax rather than subject matter.  Keeping this list explicit and
  # versioned makes the transformation reviewable and reproducible.
  NOISE_TERMS = Set.new(%w[
    a an and are as at be by can could do does for from has have how i if in is it
    me mine my of on or our ours please should tell than that the their them they
    this those to us was were what when where which who why with would you your
    explain about latest update updates information question questions answer
    think thinks thought matters matter happen happens happened happening change changes changed changing
    development developments view views opinion opinions position positions stance stances
    good bad better worse best worst great terrible important unimportant useful harmful
    dangerous safe unsafe true false right wrong agree disagree
    我 我们 我的 我们的 你 你的 您 本人 个人 这 这件 事情 请 请问 告诉
    关于 哪些 哪个 什么 为什么 怎么 如何 是否 有没有 能否 可以 需要 想要
    觉得 认为 感觉 看来 观点 意见 立场 希望 担心 关心 感兴趣 喜欢 讨厌
    支持 反对 偏好 好 坏 更好 最好 糟糕 重要 不重要 有用 有害 危险 安全 正确 错误 同意 不同意
    只 完全 非常 很 会 能 要 将 为 对 从 与 和 了 的 在 是 有
  ]).freeze

  # Relative time words are public query dimensions, not personal sentiment.
  TIME_TERMS = Set.new(%w[
    today yesterday tomorrow recent recently now current currently
    week month year quarter today
    今天 昨天 明天 最近 当前 目前 本周 上周 本月 上月 今年 去年 过去 未来
  ]).freeze

  PERSONAL_PHRASES = [
    /\b(?:i|me|my|mine|we|our|ours)\b\s*(?:only\s*)?(?:just\s*)?(?:care|interested|interest|prefer|like|love|hate|support|oppose|believe|think|feel|want|need|worry|concern)\b/i,
    /\b(?:in\s+my\s+opinion|from\s+my\s+perspective|for\s+me|personally)\b/i,
    /\b(?:i|we)\s+(?:do\s+not|don't|dont|never)\s+(?:care|like|support|want|believe|think)\b/i,
    /我(?:只|完全)?(?:关心|在意|感兴趣|喜欢|讨厌|支持|反对|认为|觉得|担心|偏好)/,
    /(?:关心|在意|感兴趣|喜欢|讨厌|支持|反对|认为|觉得|担心|偏好|发生|变化|发展|同意|不同意)/,
    /(?:对我来说|在我看来|以我看来|我的观点是|我的立场是)/,
    /我(?:叫|是)\s*[^，,;；。.!！？?]+/,
    /\b(?:canary|private|internal|confidential|secret)[-_]?[A-Za-z0-9]+\b/i
  ].freeze

  INTERROGATIVE_PHRASES = [
    /\b(?:what|why|how|can|could|would|should|is|are|do|does|please|tell|explain)\b/i,
    /(?:请问|告诉我|为什么|怎么|如何|是否|有没有|能否|可以|哪些|哪个|什么)/
  ].freeze

  class << self
    def neutralize(question, max_length: MAX_LENGTH)
      new(max_length: max_length).neutralize(question)
    end

    def neutral_query(question, max_length: MAX_LENGTH)
      neutralize(question, max_length: max_length)
    end
  end

  def initialize(max_length: MAX_LENGTH)
    @max_length = Integer(max_length)
    raise Error.new("max length must be positive", code: "QUERY_NEUTRALIZATION_CONFIG_INVALID") unless @max_length.positive?
  rescue ArgumentError, TypeError => error
    raise Error.new(error.message, code: "QUERY_NEUTRALIZATION_CONFIG_INVALID")
  end

  def neutralize(question)
    raw = question.to_s
    raise Error.new("question is empty", code: "QUERY_EMPTY") if raw.strip.empty?
    raise Error.new("question is too long", code: "QUERY_TOO_LONG") if raw.length > @max_length
    reject_sensitive!(raw)

    text = normalize_unicode(raw)
    text = remove_private_language(text)
    text = remove_interrogative_language(text)
    terms = extract_terms(text)
    raise Error.new("no public topic, entity, or time term remains", code: "QUERY_NO_PUBLIC_TERMS") if terms.empty?

    # Sorting removes presentation order and subjective framing as sources of
    # global ranking variance.  The result is still a plain string because the
    # archive retriever is intentionally a lexical, read-only interface.
    terms.uniq.sort.join(" ")
  end

  private

  def reject_sensitive!(raw)
    return unless SENSITIVE_PATTERNS.any? { |pattern| raw.match?(pattern) }

    raise Error.new("sensitive query is not eligible for global retrieval", code: "QUERY_SENSITIVE_BLOCKED")
  end

  def normalize_unicode(raw)
    value = raw.respond_to?(:unicode_normalize) ? raw.unicode_normalize(:nfkc) : raw
    value.downcase
  end

  def remove_private_language(text)
    PERSONAL_PHRASES.reduce(text) { |value, pattern| value.gsub(pattern, " ") }
  end

  def remove_interrogative_language(text)
    INTERROGATIVE_PHRASES.reduce(text) { |value, pattern| value.gsub(pattern, " ") }
  end

  def extract_terms(text)
    # Split punctuation and whitespace while preserving CJK runs and ordinary
    # public entity names.  Opaque long hexadecimal/UUID-like values are not
    # useful public terms and are dropped before the query leaves the process.
    tokens = text.scan(/[a-z][a-z0-9+'’\-]*|\p{Han}+|\p{Hiragana}+|\p{Katakana}+|\p{Hangul}+|\d{4}(?:[-\/.]\d{1,2}){0,2}/u)
    tokens.each_with_object([]) do |token, result|
      normalized = token.to_s.strip
      next if normalized.empty?
      next if normalized.match?(/\A[a-f0-9]{16,}\z/i)
      next if normalized.match?(/\A(?:canary|private|internal|confidential|secret)[-_]?[a-z0-9]+\z/i)
      next if NOISE_TERMS.include?(normalized) && !TIME_TERMS.include?(normalized)
      next if normalized.length < 2 && normalized !~ /\A\d\z/

      result << normalized
    end
  end
end

QueryNeutralizerV1 = QueryNeutralizer unless defined?(QueryNeutralizerV1)
