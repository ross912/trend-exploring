# frozen_string_literal: true

require "cgi"
require "digest"
require "net/http"
require "rexml/document"
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
    end

    def fetch(source, redirect_count = 0)
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
      raise Error, "source returned HTTP #{response.code}: #{source.fetch('id')}" unless response.is_a?(Net::HTTPSuccess)
      body = response.body.to_s
      raise Error, "source response is too large: #{source.fetch('id')}" if body.bytesize > @max_bytes

      parse(source, body)
    rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
      raise Error, "source fetch failed for #{source.fetch('id')}: #{error.message}"
    rescue REXML::ParseException => error
      raise Error, "source XML is invalid for #{source.fetch('id')}: #{error.message}"
    end

    private

    def parse(source, body)
      document = REXML::Document.new(body)
      elements = REXML::XPath.match(document, "//item")
      elements = REXML::XPath.match(document, "//*[local-name()='entry']") if elements.empty?
      raise Error, "source has no RSS/Atom entries: #{source.fetch('id')}" if elements.empty?

      fetched_at = Time.now.utc.iso8601
      elements.first(Integer(source.fetch("max_items", 20))).map do |element|
        title = text(element, "title")
        link = text(element, "link")
        link = element.elements.to_a("link").map { |node| node.attributes["href"] }.compact.first.to_s if link.empty?
        next if title.empty? || link.empty?

        summary = clean_text(text(element, "description"))
        summary = clean_text(text(element, "summary")) if summary.empty?
        published = text(element, "pubDate")
        published = text(element, "published") if published.empty?
        published = text(element, "updated") if published.empty?
        item_key = Digest::SHA256.hexdigest([source.fetch("id"), link].join("\u0000"))
        {
          "item_key" => item_key,
          "source_id" => source.fetch("id"),
          "source_name" => source.fetch("name"),
          "language" => source.fetch("language", "zh-CN"),
          "region" => source.fetch("region", "未标注"),
          "publisher_region" => source.fetch("publisher_region", source.fetch("region", "未标注")),
          "title" => title,
          "summary" => summary[0, Integer(source.fetch("max_summary_chars", 320))],
          "source_url" => link,
          "published_at" => parse_time(published),
          "fetched_at" => fetched_at,
          "content_hash" => Digest::SHA256.hexdigest([title, summary, link].join("\u0000"))
        }
      end.compact
    end

    def text(element, name)
      node = element.elements[name]
      node ? node.texts.map { |text_node| text_node.value.to_s }.join.strip : ""
    end

    def clean_text(value)
      CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip)
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s).utc.iso8601
    rescue ArgumentError
      nil
    end
  end
end
