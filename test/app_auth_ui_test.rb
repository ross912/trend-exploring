# frozen_string_literal: true

require "minitest/autorun"

class AppAuthUiTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @html = File.read(File.join(ROOT, "app/public/index.html"))
    @js = File.read(File.join(ROOT, "app/public/app.js"))
    @css = File.read(File.join(ROOT, "app/public/styles.css"))
  end

  def test_logout_control_is_accessible_and_hidden_until_authenticated_session
    assert_match(/id="logout-button"[^>]+type="button"[^>]+hidden/, @html)
    assert_match(/id="logout-status"[^>]+role="status"[^>]+aria-live="polite"/, @html)
    assert_includes @js, "loadAuthSession"
    assert_includes @js, 'authMode === "local_disabled"'
    assert_includes @js, "button.hidden = localDisabled || !authenticated"
    assert_includes @js, 'fetchJson("/api/auth/logout"'
    assert_includes @js, 'window.location.assign("/")'
    assert_includes @css, ".logout-button"
  end

  def test_all_frontend_writes_use_cookie_csrf_and_api_401_has_one_redirect_guard
    assert_includes @js, 'readCookie("zixin_csrf")'
    assert_includes @js, 'headers.set("X-CSRF-Token", readCookie("zixin_csrf"))'
    assert_includes @js, 'response.status === 401'
    assert_includes @js, "redirectToLoginOnce()"
    assert_includes @js, "if (authRedirected) return"
    assert_includes @js, 'if (authMode === "local_disabled") return'
    assert_includes @js, 'method: "POST"'
    assert_includes @js, "/api/translations/run"
    assert_includes @js, "/api/conversation/query"
    assert_operator @js.scan(/\bfetch\(/).length, :<=, 1, "API calls should go through fetchJson"
  end

  def test_api_requests_are_serialized_without_poisoning_later_refreshes
    assert_includes @js, "let apiRequestTail = Promise.resolve();"
    assert_includes @js, "function queueApiRequest(request)"
    assert_includes @js, "apiRequestTail = queued.catch(() => undefined);"
    assert_match(/return queueApiRequest\(async \(\) => \{/, @js)
  end
end
