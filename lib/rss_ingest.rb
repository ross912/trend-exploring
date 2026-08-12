# frozen_string_literal: true

require "cgi"
require "digest"
require "net/http"
require "rexml/document"
require "securerandom"
require "time"
require "uri"

module RSSIngest
  class Error < StandardError; end

  class Fetcher
    USER_AGENT = "TrendExploring/0.1 (+local RSS reader)".freeze

    def initialize(open_timeout: 8, read_timeout: 15, max_bytes: 2_000_000)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_bytes = max_bytes
      @last_capture = nil
    end

    attr_reader :last_capture

    def fetch(source, redirect_count = 0)
      validate_source_contract!(source)
      uri = URI.parse(source.fetch("url"))
      raise Error, "source URL must use HTTPS: #{uri}" unless uri.scheme == "https"
      raise Error, "source host is missing: #{uri}" if uri.host.to_s.empty?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9"
        http.request(request)
      end
      if response.is_a?(Net::HTTPRedirection)
        raise Error, "too many HTTPS redirects: #{source.fetch('id')}" if redirect_count >= 3
        location = response["location"].to_s
        raise Error, "redirect location is missing: #{source.fetch('id')}" if location.empty?
        redirected = URI.join(uri.to_s, location).to_s
        raise Error, "redirect target must use HTTPS: #{redirected}" unless URI.parse(redirected).scheme == "https"
        return fetch(source.merge("url" => redirected), redirect_count + 1)
      end
      unless response.is_a?(Net::HTTPSuccess)
        # Keep the observed status for the batch denominator without creating
        # a capture row for a failed response.
        @last_capture = {
          "captured_at" => Time.now.utc.iso8601(6), "http_status" => response.code.to_i,
          "content_type" => response["content-type"].to_s, "content_bytes" => response.body.to_s.bytesize,
          "body_hash" => "", "source_url" => source.fetch("url")
        }
        raise Error, "source returned HTTP #{response.code}: #{source.fetch('id')}"
      end
      body = response.body.to_s
      raise Error, "source response is too large: #{source.fetch('id')}" if body.bytesize > @max_bytes

      captured_at = Time.now.utc.iso8601(6)
      body_hash = Digest::SHA256.hexdigest(body)
      @last_capture = {
        "captured_at" => captured_at, "http_status" => response.code.to_i,
        "content_type" => response["content-type"].to_s, "content_bytes" => body.bytesize,
        "body_hash" => body_hash, "source_url" => source.fetch("url")
      }
      parse(source, body, {
        "capture_id" => Digest::SHA256.hexdigest([source.fetch("id"), body_hash, captured_at, SecureRandom.uuid].join("\u0000")),
        "captured_at" => captured_at,
        "http_status" => response.code.to_i,
        "content_type" => response["content-type"].to_s,
        "content_bytes" => body.bytesize,
        "body_hash" => body_hash,
        "feed_url" => source.fetch("url"),
        "storage_status" => source.fetch("storage_status", "metadata_only"),
        "rights_scope" => source.fetch("rights_scope", "metadata_short_summary_link")
      })
    rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      raise Error, "source fetch failed for #{source.fetch('id')}: #{error.message}"
    rescue REXML::ParseException => error
      raise Error, "source XML is invalid for #{source.fetch('id')}: #{error.message}"
    end

    private

    # Validate the registry/source lineage before touching the network.  The
    # legacy 011 source fixtures did not carry the new fields, so omitted
    # values are inferred conservatively; once a basis is explicitly present,
    # the complete contract is mandatory.
    def validate_source_contract!(source)
      source_kind = source.fetch("source_kind", "configured").to_s
      raise Error, "source_kind is invalid: #{source_kind}" unless %w[configured discovery].include?(source_kind)

      explicit_basis = source.key?("discovery_basis")
      default_query_conditioned = truthy?(source.fetch("query_conditioned", false))
      basis = source.fetch("discovery_basis", default_query_conditioned ? "topic_query" : "editorial_feed").to_s
      raise Error, "discovery_basis is invalid: #{basis}" unless %w[editorial_feed topic_query locale_headlines].include?(basis)

      query_conditioned = truthy?(source.fetch("query_conditioned", basis == "topic_query"))
      analysis_policy = source.fetch("analysis_policy", basis == "locale_headlines" ? "exploration_only" : "signal_eligible").to_s
      raise Error, "analysis_policy is invalid: #{analysis_policy}" unless %w[signal_eligible exploration_only].include?(analysis_policy)
      topics = source.fetch("query_topics", [])
      raise Error, "query_topics must be an array" unless topics.is_a?(Array)

      if basis == "locale_headlines"
        raise Error, "locale_headlines must be a discovery source" unless source_kind == "discovery"
        raise Error, "locale_headlines cannot be query conditioned" if query_conditioned
        raise Error, "locale_headlines must be exploration_only" unless analysis_policy == "exploration_only"
        raise Error, "locale_headlines requires aggregator_id" if source.fetch("aggregator_id", "").to_s.strip.empty?
        raise Error, "locale_headlines requires locale_tag" if source.fetch("locale_tag", "").to_s.strip.empty?
        raise Error, "locale_headlines requires market_label" if source.fetch("market_label", "").to_s.strip.empty?
        raise Error, "locale_headlines requires aggregator_locale_label basis" unless source.fetch("market_label_basis", "").to_s == "aggregator_locale_label"
        raise Error, "locale_headlines publisher_region must be empty" unless source.fetch("publisher_region", "").to_s.empty?
        raise Error, "locale_headlines registry publisher_id must be empty" unless source.fetch("publisher_id", "").to_s.empty?
        raise Error, "locale_headlines query_topics must be empty" unless topics.empty?
        validate_locale_headline_url!(source.fetch("url"), aggregator_id: source.fetch("aggregator_id", "").to_s)
      elsif basis == "topic_query"
        raise Error, "topic_query must be a discovery source" unless source_kind == "discovery"
        raise Error, "topic_query must be query conditioned" unless query_conditioned
        raise Error, "topic_query cannot be exploration_only" if analysis_policy == "exploration_only"
        raise Error, "topic_query requires query_topics" if topics.empty? && explicit_basis
      else
        raise Error, "editorial_feed cannot be query conditioned" if source_kind == "configured" && query_conditioned
        raise Error, "editorial_feed cannot be exploration_only" if analysis_policy == "exploration_only"
      end
      true
    rescue KeyError, TypeError => error
      raise Error, "source contract is incomplete: #{error.message}"
    end

    def validate_locale_headline_url!(value, aggregator_id: "")
      uri = URI.parse(value.to_s)
      raise Error, "locale_headlines URL must use HTTPS" unless uri.scheme == "https" && !uri.host.to_s.empty?
      if aggregator_id == "google-news"
        raise Error, "google-news locale URL host/path is invalid" unless uri.host.to_s.downcase == "news.google.com" && uri.path == "/rss"
      end
      return if uri.query.to_s.empty?

      keys = uri.query.to_s.split("&").reject(&:empty?).map { |pair| CGI.unescape(pair.split("=", 2).first.to_s).downcase }
      forbidden = keys & %w[q query search topic keyword keywords category section]
      raise Error, "locale_headlines URL cannot contain topic/query parameters" unless forbidden.empty?
      raise Error, "locale_headlines URL cannot repeat query parameters" unless keys.uniq.length == keys.length
      if aggregator_id == "google-news"
        raise Error, "google-news locale URL has unsupported query parameters" unless (keys - %w[hl gl ceid]).empty?
      else
        raise Error, "locale_headlines URL query parameters require a registered aggregator validator"
      end
    rescue URI::InvalidURIError => error
      raise Error, "locale_headlines URL is invalid: #{error.message}"
    end

    def parse(source, body, capture = {})
      document = REXML::Document.new(body)
      elements = REXML::XPath.match(document, "//item")
      elements = REXML::XPath.match(document, "//*[local-name()='entry']") if elements.empty?
      if elements.empty?
        root_name = document.root&.name.to_s.downcase
        channel_present = !REXML::XPath.first(document, "//*[local-name()='channel']").nil?
        feed_present = !REXML::XPath.first(document, "//*[local-name()='feed']").nil?
        return [] if ((%w[rss rdf].include?(root_name) && channel_present) || (root_name == "feed" && feed_present))

        raise Error, "source has no RSS/Atom entries: #{source.fetch('id')}"
      end

      fetched_at = capture.fetch("fetched_at", capture.fetch("captured_at", Time.now.utc.iso8601))
      captured_at = capture.fetch("captured_at", fetched_at)
      elements.first(Integer(source.fetch("max_items", 20))).map do |element|
        title = text(element, "title")
        link = text(element, "link")
        link = element.elements.to_a("link").map { |node| node.attributes["href"] }.compact.first.to_s if link.empty?
        next if title.empty? || link.empty?

        summary = clean_text(text(element, "description"))
        summary = clean_text(text(element, "summary")) if summary.empty?
        max_summary_chars = [[Integer(source.fetch("max_summary_chars", 320)), 0].max, 320].min
        persisted_summary = summary[0, max_summary_chars]
        publisher_id, publisher_name, publisher_url, publisher_identity_status = publisher_identity(source, element)
        published = text(element, "pubDate")
        published = text(element, "published") if published.empty?
        published = text(element, "updated") if published.empty?
        item_key = Digest::SHA256.hexdigest([source.fetch("id"), link].join("\u0000"))
        {
          "item_key" => item_key,
          "source_id" => source.fetch("id"),
          "source_name" => source.fetch("name"),
          "source_kind" => source.fetch("source_kind", "configured"),
          "discovery_basis" => source.fetch("discovery_basis", truthy?(source.fetch("query_conditioned", false)) ? "topic_query" : "editorial_feed"),
          "analysis_policy" => source.fetch("analysis_policy", source.fetch("discovery_basis", "") == "locale_headlines" ? "exploration_only" : "signal_eligible"),
          "publisher_id" => publisher_id,
          "publisher_name" => publisher_name,
          "publisher_url" => publisher_url,
          "publisher_identity_status" => publisher_identity_status,
          "region_basis" => source.fetch("region_basis", source.fetch("source_kind", "configured") == "discovery" ? "query_target_label" : "editorial_scope_label"),
          "query_conditioned" => source.fetch("query_conditioned", source.fetch("source_kind", "configured") == "discovery"),
          "entry_source_role" => source.fetch("entry_source_role", source.fetch("source_kind", "configured") == "discovery" ? "publisher_domain" : "configured_publisher"),
          "aggregator_id" => source.fetch("aggregator_id", ""),
          "locale_tag" => source.fetch("locale_tag", ""),
          "market_label" => source.fetch("market_label", ""),
          "market_label_basis" => source.fetch("market_label_basis", ""),
          "query_topics" => Array(source.fetch("query_topics", [])),
          "capture_id" => capture.fetch("capture_id", ""),
          "capture_captured_at" => captured_at,
          "capture_http_status" => capture.fetch("http_status", 200),
          "capture_content_type" => capture.fetch("content_type", ""),
          "capture_content_bytes" => capture.fetch("content_bytes", 0),
          "capture_body_hash" => capture.fetch("body_hash", ""),
          "capture_storage_status" => capture.fetch("storage_status", "metadata_only"),
          "capture_source_url" => capture.fetch("feed_url", source.fetch("url")),
          "rights_scope" => capture.fetch("rights_scope", source.fetch("rights_scope", "metadata_short_summary_link")),
          "language" => source.fetch("language", "zh-CN"),
          "region" => source.fetch("region", "未标注"),
          "publisher_region" => source.fetch("publisher_region", source.fetch("region", "未标注")),
          "title" => title,
          "summary" => persisted_summary,
          "source_url" => link,
          "published_at" => parse_time(published),
          "fetched_at" => fetched_at,
          "content_hash" => Digest::SHA256.hexdigest([title, persisted_summary, link].join("\u0000"))
        }
      end.compact
    end

    def text(element, name)
      node = element.elements[name]
      node ? node.texts.map { |text_node| text_node.value.to_s }.join.strip : ""
    end

    def publisher_identity(source, element)
      discovery_domain = source.fetch("source_kind", "configured") == "discovery" && source.fetch("entry_source_role", "") == "publisher_domain"
      unless discovery_domain
        publisher_id = source.fetch("publisher_id", "").to_s
        publisher_name = source.fetch("publisher_name", "").to_s
        publisher_url = source.fetch("publisher_url", "").to_s
        configured = !publisher_id.empty? && !publisher_name.empty? && !publisher_url.empty?
        return configured ? [publisher_id, publisher_name, publisher_url, "configured"] : ["", "", "", "unresolved"]
      end

      publisher_node = element.elements["source"]
      source_url = publisher_node&.attributes&.[]("url").to_s.strip
      domain = normalize_publisher_domain(source_url)
      return ["", "", "", "unresolved"] if domain.nil?

      [domain, domain, "https://#{domain}/", "observed_domain"]
    end

    def normalize_publisher_domain(value)
      uri = URI.parse(value.to_s.strip)
      return nil unless %w[http https].include?(uri.scheme.to_s.downcase)

      host = uri.host.to_s.downcase.sub(/\Awww\d*\./, "")
      return nil unless host.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/)

      host
    rescue URI::InvalidURIError
      nil
    end

    def clean_text(value)
      CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>/, " ").gsub(/[\u00a0\u2007\u202f]/, " ").gsub(/\s+/, " ").strip)
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s).utc.iso8601
    rescue ArgumentError
      nil
    end

    def truthy?(value)
      value == true || %w[t true 1 yes y].include?(value.to_s.downcase)
    end
  end
end
