# frozen_string_literal: true

require "minitest/autorun"

class BreadthUiTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_exploration_frontier_copy_and_safe_rendering_are_present
    html = File.read(File.join(ROOT, "app/public/index.html"))
    js = File.read(File.join(ROOT, "app/public/app.js"))
    css = File.read(File.join(ROOT, "app/public/styles.css"))
    assert_includes html, "预设主题之外，本批看到了什么？"
    assert_includes html, "仅归档/浏览"
    assert_includes html, "事件地域未验证"
    assert_includes js, "exploration.latest_batch"
    assert_includes js, "topic_conditioned"
    assert_includes js, "publisher_id/domain"
    assert_includes js, "出版方域名未解析"
    assert_includes html, "signal 投影"
    assert_includes js, "reused_previous"
    assert_includes js, "watermark 未推进"
    assert_includes js, "escapeHtml(item.title)"
    assert_includes js, "target=\"_blank\" rel=\"noopener noreferrer\""
    assert_includes css, ".exploration-card"
  end
end
