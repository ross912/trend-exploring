# frozen_string_literal: true

require "cgi"
require "digest"
require "net/http"
require "rexml/document"
require "time"
require "uri"

module ArticleArchive
  class Error < StandardError
    attr_reader :code
    def initialize(message, code: "archive_error"); @code = code; super(message); end
  end

  # Conservative HTML extractor for explicitly permitted sources. It never
  # bypasses login, paywalls, CAPTCHAs, robots interstitials or script gates.
  class Fetcher
    USER_AGENT = RSSIngest::Fetcher::USER_AGENT rescue "TrendExploring/0.1 (+local archive)"
    BLOCK_MARKERS = [/captcha/i, /sign in to continue/i, /subscribe to continue/i, /enable javascript/i, /access denied/i].freeze

    def initialize(open_timeout: 8, read_timeout: 20, max_bytes: 5_000_000, max_chars: 200_000)
      @open_timeout, @read_timeout, @max_bytes, @max_chars = open_timeout, read_timeout, max_bytes, max_chars
    end

    def fetch(item, redirect_count = 0, original_url: nil)
      rights = item.fetch("archive_rights_scope", item.fetch("rights_scope", "link_only")).to_s
      return failure(item, rights, "not_permitted", "source rights do not permit full article archive") unless rights == "full_archive"

      uri = URI.parse(item.fetch("source_url"))
      original_url ||= uri.to_s
      raise Error.new("article URL must use HTTPS", code: "not_permitted") unless uri.scheme == "https" && !uri.host.to_s.empty?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8"
        http.request(request)
      end
      if response.is_a?(Net::HTTPRedirection)
        raise Error.new("too many article redirects", code: "fetch_failed") if redirect_count >= 3
        target = URI.join(uri.to_s, response["location"].to_s)
        raise Error.new("redirect target must use HTTPS", code: "not_permitted") unless target.scheme == "https"
        return fetch(item.merge("source_url" => target.to_s), redirect_count + 1, original_url: original_url)
      end
      return failure(item, rights, "fetch_failed", "article returned HTTP #{response.code}", response: response, final_url: uri.to_s) unless response.is_a?(Net::HTTPSuccess)
      bytes = response.body.to_s.bytesize
      return failure(item, rights, "too_large", "article response exceeds #{@max_bytes} bytes", response: response, final_url: uri.to_s) if bytes > @max_bytes
      content_type = response["content-type"].to_s.downcase
      unless content_type.include?("html") || content_type.include?("text/plain")
        return failure(item, rights, "parse_failed", "unsupported article content type", response: response, final_url: uri.to_s)
      end
      body = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      if BLOCK_MARKERS.any? { |marker| body.match?(marker) }
        return failure(item, rights, "not_permitted", "access gate detected; archive bypass is forbidden", response: response, final_url: uri.to_s)
      end
      extracted = extract(body, content_type: content_type)
      return failure(item, rights, "empty_body", "article body extraction returned no substantive text", response: response, final_url: uri.to_s) if extracted.fetch("body_text").length < 200
      return failure(item, rights, "too_large", "extracted article exceeds #{@max_chars} characters", response: response, final_url: uri.to_s) if extracted.fetch("body_text").length > @max_chars
      now = Time.now.utc.iso8601(6)
      attempt_id = Digest::SHA256.hexdigest([item.fetch("version_id"), rights, "article-archive-v1"].join("\0"))
      archive_id = Digest::SHA256.hexdigest([item.fetch("version_id"), extracted.fetch("body_hash")].join("\0"))
      {
        "attempt" => attempt(item, attempt_id, rights, "archived", "", response: response, final_url: uri.to_s, fetched_at: now),
        "archive" => {
          "archive_id" => archive_id, "attempt_id" => attempt_id, "source_version_id" => item.fetch("version_id"),
          "source_url" => original_url, "final_url" => uri.to_s,
          "source_language" => item.fetch("language"), "title" => item.fetch("title"),
          "body_text" => extracted.fetch("body_text"), "image_captions" => extracted.fetch("image_captions"),
          "extraction_method" => extracted.fetch("method"), "extractor_version" => "article-html-v1",
          "body_hash" => extracted.fetch("body_hash"), "body_chars" => extracted.fetch("body_text").length,
          "archived_at" => now
        }
      }
    rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SystemCallError => error
      failure(item, rights || "link_only", "fetch_failed", error.message)
    rescue KeyError, TypeError => error
      raise Error.new("article archive input is incomplete: #{error.message}", code: "invalid_input")
    end

    private

    def extract(raw, content_type:)
      if content_type.include?("text/plain")
        text = clean_text(raw)
        return { "body_text" => text, "image_captions" => [], "method" => "plain_text", "body_hash" => Digest::SHA256.hexdigest(text) }
      end
      html = raw.gsub(/<script\b[^>]*>.*?<\/script>/mi, " ").gsub(/<style\b[^>]*>.*?<\/style>/mi, " ")
      candidates = html.scan(/<(?:article|main)\b[^>]*>(.*?)<\/(?:article|main)>/mi).flatten
      candidates = html.scan(/<body\b[^>]*>(.*?)<\/body>/mi).flatten if candidates.empty?
      fragment = candidates.max_by(&:length).to_s
      paragraphs = fragment.scan(/<(?:p|h[1-6]|li|blockquote)\b[^>]*>(.*?)<\/(?:p|h[1-6]|li|blockquote)>/mi).flatten
      text = paragraphs.map { |value| clean_text(value) }.reject { |value| value.length < 20 }.join("\n\n")
      captions = html.scan(/<(?:figcaption|caption)\b[^>]*>(.*?)<\/(?:figcaption|caption)>/mi).flatten.map { |value| clean_text(value) }.reject(&:empty?).uniq
      { "body_text" => text, "image_captions" => captions, "method" => "semantic_html_blocks", "body_hash" => Digest::SHA256.hexdigest(text) }
    end

    def clean_text(value)
      CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>/, " ").gsub(/[\u00a0\u2007\u202f]/, " ").gsub(/[ \t]+/, " ").gsub(/\s*\n\s*/, "\n").strip)
    end

    def failure(item, rights, outcome, reason, response: nil, final_url: "", fetched_at: Time.now.utc.iso8601(6))
      id = Digest::SHA256.hexdigest([item.fetch("version_id"), rights, "article-archive-v1"].join("\0"))
      { "attempt" => attempt(item, id, rights, outcome, reason, response: response, final_url: final_url, fetched_at: fetched_at), "archive" => nil }
    end

    def attempt(item, id, rights, outcome, reason, response:, final_url:, fetched_at:)
      { "attempt_id" => id, "source_version_id" => item.fetch("version_id"), "rights_scope" => rights,
        "outcome" => outcome, "http_status" => response&.code&.to_i, "fetched_at" => fetched_at,
        "final_url" => final_url, "content_type" => (response ? response["content-type"].to_s : ""),
        "response_bytes" => response&.body.to_s.bytesize, "error_reason" => reason }
    end
  end
end
