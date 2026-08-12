# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/rss_ingest"

class RSSIngestTest < Minitest::Test
  SOURCE = { "id" => "fixture", "name" => "中文来源", "url" => "https://example.test/feed.xml", "language" => "zh-CN", "region" => "全球", "max_items" => 5 }.freeze

  def test_rss_items_are_normalized_and_html_is_removed
    xml = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><item>
        <title><![CDATA[一个真实的中文标题]]></title>
        <link>https://example.test/item-1</link>
        <description><![CDATA[<p>第一段摘要</p><p>第二段摘要</p>]]></description>
        <pubDate>Sat, 08 Aug 2026 15:03:35 +0800</pubDate>
      </item></channel></rss>
    XML
    item = RSSIngest::Fetcher.new.send(:parse, SOURCE, xml).fetch(0)
    assert_equal "一个真实的中文标题", item.fetch("title")
    assert_equal "第一段摘要 第二段摘要", item.fetch("summary")
    assert_equal "全球", item.fetch("region")
    assert_equal "2026-08-08T07:03:35Z", item.fetch("published_at")
    assert_equal 64, item.fetch("item_key").length
  end

  def test_capture_and_publisher_lineage_are_carried_with_each_item
    xml = <<~XML
      <rss version="2.0"><channel><item>
        <title>Global item</title><link>https://example.test/item-2</link>
        <description>Summary</description><pubDate>Sat, 08 Aug 2026 15:03:35 +0800</pubDate>
        <source url="https://publisher.test">Publisher One</source>
      </item></channel></rss>
    XML
    capture = { "capture_id" => "capture-1", "captured_at" => "2026-08-08T07:03:35Z", "http_status" => 200,
                "content_type" => "application/rss+xml", "content_bytes" => 123, "body_hash" => "body-hash",
                "storage_status" => "metadata_only", "feed_url" => SOURCE.fetch("url") }
    item = RSSIngest::Fetcher.new.send(:parse, SOURCE.merge("language" => "en", "source_kind" => "discovery", "entry_source_role" => "publisher_domain"), xml, capture).fetch(0)
    assert_equal "publisher.test", item.fetch("publisher_name")
    assert_equal "https://publisher.test/", item.fetch("publisher_url")
    assert_equal "publisher.test", item.fetch("publisher_id")
    assert_equal "observed_domain", item.fetch("publisher_identity_status")
    assert_equal "capture-1", item.fetch("capture_id")
    assert_equal "metadata_only", item.fetch("capture_storage_status")
  end

  def test_configured_feed_uses_canonical_publisher_instead_of_entry_attribution
    xml = <<~XML
      <rss version="2.0"><channel><item>
        <title>Configured publisher</title><link>https://example.test/configured</link>
        <source url="https://afp.example/world">AFP</source>
      </item></channel></rss>
    XML
    source = SOURCE.merge("publisher_id" => "canonical", "publisher_name" => "Canonical Publisher", "publisher_url" => "https://canonical.example/")
    item = RSSIngest::Fetcher.new.send(:parse, source, xml).fetch(0)
    assert_equal "canonical", item.fetch("publisher_id")
    assert_equal "Canonical Publisher", item.fetch("publisher_name")
    assert_equal "configured", item.fetch("publisher_identity_status")
  end

  def test_discovery_missing_or_invalid_entry_url_is_unresolved_without_name_guessing
    %w[missing invalid].each do |kind|
      source_tag = kind == "missing" ? "<source>Associated Press</source>" : "<source url=\"not a url\">Associated Press</source>"
      xml = "<rss version=\"2.0\"><channel><item><title>#{kind}</title><link>https://example.test/#{kind}</link>#{source_tag}</item></channel></rss>"
      source = SOURCE.merge("source_kind" => "discovery", "entry_source_role" => "publisher_domain")
      item = RSSIngest::Fetcher.new.send(:parse, source, xml).fetch(0)
      assert_equal "unresolved", item.fetch("publisher_identity_status")
      assert_empty item.fetch("publisher_id")
      assert_empty item.fetch("publisher_name")
    end
  end

  def test_discovery_publisher_urls_normalize_to_one_domain
    source = SOURCE.merge("source_kind" => "discovery", "entry_source_role" => "publisher_domain")
    urls = ["https://WWW.TheGuardian.com/world", "https://theguardian.com/uk?edition=us"]
    ids = urls.map.with_index do |publisher_url, index|
      xml = "<rss version=\"2.0\"><channel><item><title>guardian #{index}</title><link>https://example.test/guardian-#{index}</link><source url=\"#{publisher_url}\">The Guardian</source></item></channel></rss>"
      RSSIngest::Fetcher.new.send(:parse, source, xml).fetch(0).fetch("publisher_id")
    end
    assert_equal ["theguardian.com", "theguardian.com"], ids
  end

  def test_atom_link_and_updated_time_are_supported
    xml = <<~XML
      <feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <title>Atom 中文条目</title><link href="https://example.test/atom-1"/>
        <summary>简短说明</summary><updated>2026-08-08T07:00:00Z</updated>
      </entry></feed>
    XML
    item = RSSIngest::Fetcher.new.send(:parse, SOURCE, xml).fetch(0)
    assert_equal "Atom 中文条目", item.fetch("title")
    assert_equal "https://example.test/atom-1", item.fetch("source_url")
    assert_equal "2026-08-08T07:00:00Z", item.fetch("published_at")
  end

  def test_content_hash_uses_the_persisted_truncated_summary
    summary = "前缀" + ("尾部" * 250)
    xml = <<~XML
      <rss version="2.0"><channel><item>
        <title>Hash fixture</title><link>https://example.test/hash</link>
        <description>#{summary}</description>
      </item></channel></rss>
    XML
    item = RSSIngest::Fetcher.new.send(:parse, SOURCE, xml).fetch(0)
    persisted_summary = item.fetch("summary")
    assert_equal 320, persisted_summary.length
    assert_equal Digest::SHA256.hexdigest([item.fetch("title"), persisted_summary, item.fetch("source_url")].join("\u0000")), item.fetch("content_hash")
  end

  def test_each_fetch_gets_a_unique_microsecond_capture_even_for_same_body_and_second
    xml = "<rss version=\"2.0\"><channel><item><title>same</title><link>https://example.test/same</link></item></channel></rss>"
    response_class = Class.new(Net::HTTPOK) do
      def initialize(body)
        super("1.1", "200", "OK")
        @fake_body = body
      end

      def body
        @fake_body
      end

      def [](key)
        key.to_s.downcase == "content-type" ? "application/rss+xml" : nil
      end
    end
    response = response_class.new(xml)
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    fixed_time = Time.utc(2026, 8, 8, 7, 0, 0, 123_456)
    first = second = nil
    Net::HTTP.stub(:start, ->(*_args, &block) { block.call(http) }) do
      Time.stub(:now, fixed_time) do
        first = RSSIngest::Fetcher.new.fetch(SOURCE).fetch(0)
        second = RSSIngest::Fetcher.new.fetch(SOURCE).fetch(0)
      end
    end
    refute_equal first.fetch("capture_id"), second.fetch("capture_id")
    assert_equal first.fetch("capture_body_hash"), second.fetch("capture_body_hash")
    assert_equal "2026-08-08T07:00:00.123456Z", first.fetch("capture_captured_at")
  end

  def test_http_sources_are_rejected_before_network_access
    assert_raises(RSSIngest::Error) do
      RSSIngest::Fetcher.new.fetch(SOURCE.merge("url" => "http://example.test/feed.xml"))
    end
  end

  def test_repository_sources_are_https_and_have_short_summary_policy
    sources = JSON.parse(File.read(File.expand_path("../config/sources.json", __dir__))).fetch("sources")
    refute_empty sources
    sources.each do |source|
      assert_equal "https", URI.parse(source.fetch("url")).scheme
      assert_equal "metadata_short_summary_link", source.fetch("rights_scope")
      assert_operator source.fetch("max_summary_chars"), :<=, 320
      assert_includes %w[zh-CN en], source.fetch("language")
      refute_empty source.fetch("region")
      refute_empty source.fetch("publisher_id")
      refute_empty source.fetch("publisher_name")
      assert_equal "editorial_scope_label", source.fetch("region_basis")
      refute source.fetch("query_conditioned")
    end
    discovery = JSON.parse(File.read(File.expand_path("../config/sources.json", __dir__))).fetch("discovery_sources")
    refute_empty discovery
    discovery.each do |source|
      assert_equal "discovery", source.fetch("source_kind")
      assert_equal "https", URI.parse(source.fetch("url")).scheme
      assert_equal "google-news", source.fetch("aggregator_id")
      assert_equal "publisher_domain", source.fetch("entry_source_role")
      assert_equal "query_target_label", source.fetch("region_basis")
      assert source.fetch("query_conditioned")
      refute_empty source.fetch("query_topics")
    end
  end

  def test_locale_headline_contract_rejects_query_keyword_parameters_and_topic_values
    fetcher = RSSIngest::Fetcher.new
    locale = {
      "id" => "locale", "name" => "locale", "url" => "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en",
      "source_kind" => "discovery", "discovery_basis" => "locale_headlines", "query_conditioned" => false,
      "analysis_policy" => "exploration_only", "aggregator_id" => "google-news", "locale_tag" => "en-US",
      "market_label" => "US", "market_label_basis" => "aggregator_locale_label", "query_topics" => []
    }
    %w[q query search topic keyword keywords category section].each do |key|
      assert_raises(RSSIngest::Error) { fetcher.send(:validate_source_contract!, locale.merge("url" => "https://news.google.com/rss?#{key}=topic")) }
    end
    assert_raises(RSSIngest::Error) { fetcher.send(:validate_source_contract!, locale.merge("url" => "https://news.google.com/rss?hl=en-US&foo=bar")) }
    assert_raises(RSSIngest::Error) { fetcher.send(:validate_source_contract!, locale.merge("url" => "https://example.test/rss?hl=en-US")) }
    assert_raises(RSSIngest::Error) { fetcher.send(:validate_source_contract!, locale.merge("query_topics" => ["topic"])) }
    assert_raises(RSSIngest::Error) do
      fetcher.send(:validate_source_contract!, locale.merge("discovery_basis" => "topic_query", "query_conditioned" => false, "analysis_policy" => "signal_eligible", "query_topics" => ["topic"]))
    end
  end

  def test_valid_feed_with_zero_entries_is_a_successful_empty_parse
    xml = '<rss version="2.0"><channel><title>empty</title></channel></rss>'
    assert_empty RSSIngest::Fetcher.new.send(:parse, SOURCE, xml)
    assert_raises(RSSIngest::Error) { RSSIngest::Fetcher.new.send(:parse, SOURCE, '<html/>') }
  end

  def test_locale_config_has_eight_verified_market_labels_without_query_search
    config = JSON.parse(File.read(File.expand_path("../config/sources.json", __dir__)))
    locale = config.fetch("locale_headlines")
    assert_operator locale.length, :>=, 6
    assert_operator locale.count { |source| source.fetch("enabled") }, :>=, 6
    locale.each do |source|
      assert_equal "locale_headlines", source.fetch("discovery_basis")
      refute source.fetch("query_conditioned")
      assert_equal [], source.fetch("query_topics")
      assert_equal "aggregator_locale_label", source.fetch("market_label_basis")
      refute_match(/[?&](?:q|query|search)=/i, source.fetch("url"))
      refute_empty source.fetch("aggregator_id")
      refute_empty source.fetch("locale_tag")
      refute_empty source.fetch("market_label")
      assert_match(/\Ahttp_200_/, source.fetch("verification_status"))
      refute_nil source.fetch("verified_at")
    end
  end
end
