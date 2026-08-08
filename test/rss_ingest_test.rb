# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/rss_ingest"

class RSSIngestTest < Minitest::Test
  SOURCE = { "id" => "fixture", "name" => "中文来源", "url" => "https://example.test/feed.xml", "language" => "zh-CN", "max_items" => 5 }.freeze

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
    assert_equal "2026-08-08T07:03:35Z", item.fetch("published_at")
    assert_equal 64, item.fetch("item_key").length
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
    end
  end
end
