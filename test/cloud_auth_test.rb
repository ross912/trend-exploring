# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/cloud_config"
require_relative "../lib/cloud_auth"

class CloudAuthTest < Minitest::Test
  class FakeStore
    attr_reader :events, :sessions, :failed_login_updates
    attr_accessor :reset_count
    attr_accessor :owner_row

    def initialize(owner_row)
      @owner_row = owner_row
      @events = []
      @sessions = {}
      @failed_login_updates = []
      @reset_count = 0
    end

    def owner(username:)
      return nil unless @owner_row && @owner_row.fetch("username") == username
      @owner_row
    end

    def owner_any
      @owner_row
    end

    def record_failed_login!(account_id:, failed_count:, locked_until:)
      @failed_login_updates << { account_id: account_id, failed_count: failed_count, locked_until: locked_until }
      @owner_row["failed_login_count"] = failed_count
      @owner_row["login_locked_until"] = locked_until
    end

    def reset_failed_login!(account_id:)
      @reset_count += 1
      @owner_row["failed_login_count"] = 0
      @owner_row["login_locked_until"] = nil
    end

    def create_session!(**attrs)
      @sessions[attrs.fetch(:session_hash)] = attrs.transform_keys(&:to_s)
    end

    def session(session_hash:)
      row = @sessions[session_hash]
      return nil unless row
      {
        "session_hash" => session_hash,
        "account_id" => row.fetch("account_id"),
        "csrf_hash" => row.fetch("csrf_hash"),
        "issued_at" => row.fetch("issued_at"),
        "last_seen_at" => row.fetch("issued_at"),
        "idle_expires_at" => row.fetch("idle_expires_at"),
        "absolute_expires_at" => row.fetch("absolute_expires_at"),
        "revoked_at" => nil
      }
    end

    def touch_session!(**_); end

    def revoke_session!(session_hash:)
      @sessions.delete(session_hash)
    end

    def revoke_all!(account_id:)
      @sessions.clear
    end

    def consume_recovery!(account_id:, username:, recovery_code_digest:, password_digest:)
      return false if @owner_row["recovery_used_at"]
      @owner_row["recovery_used_at"] = Time.now.utc
      @owner_row["password_digest"] = password_digest
      true
    end

    def record_event!(**event)
      @events << event
      true
    end
  end

  class CountingKdf
    attr_reader :digest_calls, :verify_calls

    def initialize(outcome = false, &verifier)
      @outcome = outcome
      @verifier = verifier
      @digest_calls = 0
      @verify_calls = 0
    end

    def digest(_secret, iterations: nil)
      @digest_calls += 1
      "dummy"
    end

    def verify(secret, _encoded)
      @verify_calls += 1
      @verifier ? @verifier.call(secret) : @outcome
    end

    def reset!
      @digest_calls = 0
      @verify_calls = 0
    end
  end

  def setup
    @kdf = CloudAuth::Kdf.new(iterations: 100_000, allow_weak: true)
    @config = CloudConfig.new(env: {
      "BIND_ADDRESS" => "127.0.0.1", "AUTH_MODE" => "required", "CLOUD_DEVELOPMENT" => "1",
      "CLOUD_IDENTITY_PEPPER" => "identity-test", "CLOUD_SESSION_PEPPER" => "session-test"
    })
    @now = Time.utc(2026, 8, 15, 12, 0, 0)
    @row = {
      "account_id" => "owner", "username" => "owner",
      "password_digest" => @kdf.digest("correct-password"),
      "recovery_code_digest" => @kdf.digest("r" * 32),
      "recovery_used_at" => nil, "failed_login_count" => 0,
      "login_locked_until" => nil, "disabled_at" => nil
    }
    @store = FakeStore.new(@row)
    @manager = CloudAuth::Manager.new(
      store: @store, config: @config, kdf: @kdf,
      clock: -> { @now }, limiter: CloudAuth::AttemptLimiter.new(limit: 100)
    )
  end

  def test_password_digest_is_versioned_and_constant_time_verified
    digest = @kdf.digest("a-long-password")
    assert_match(/\Apbkdf2-sha256\$\d+\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+\z/, digest)
    assert @kdf.verify("a-long-password", digest)
    refute @kdf.verify("another-password", digest)
    assert_raises(CloudAuth::ConfigurationError) { CloudAuth::Kdf.new(iterations: 99_999) }
  end

  def test_login_issues_256_bit_tokens_and_authenticate_touches_session
    result = @manager.login(username: "owner", password: "correct-password", ip_hash: "ip-hash", secure: true)
    assert result.ok
    assert_equal 64, result.session_token.length
    assert_equal 64, result.csrf_token.length
    assert_equal 1, @store.sessions.length
    session = @manager.authenticate(session_token: result.session_token, secure: true)
    assert_equal "owner", session.fetch("account_id")
    assert @manager.csrf_valid?(session: session, token: result.csrf_token, cookie_token: result.csrf_token)
    refute @manager.csrf_valid?(session: session, token: result.csrf_token, cookie_token: "forged")
  end

  def test_bad_login_is_generic_and_backed_off
    first = @manager.login(username: "owner", password: "wrong-password", ip_hash: "ip-hash", secure: true)
    refute first.ok
    assert_equal "invalid credentials", first.error
    assert_operator first.retry_after, :>, 0
    wrong_while_locked = @manager.login(username: "owner", password: "wrong-password", ip_hash: "different-ip", secure: true)
    refute wrong_while_locked.ok
    assert_equal "invalid credentials", wrong_while_locked.error
    assert_equal 1, @store.failed_login_updates.length
    unlocked = @manager.login(username: "owner", password: "correct-password", ip_hash: "different-ip", secure: true)
    assert unlocked.ok
    assert_nil @row["login_locked_until"]
    assert_equal 1, @store.reset_count
  end

  def test_recovery_is_single_use_and_revokes_sessions
    logged_in = @manager.login(username: "owner", password: "correct-password", ip_hash: "a", secure: true)
    assert logged_in.ok
    recovery = @manager.recover(username: "owner", recovery_code: "r" * 32,
                                new_password: "new-correct-password", ip_hash: "b", secure: true)
    assert recovery.ok
    assert_empty @store.sessions
    second = @manager.recover(username: "owner", recovery_code: "r" * 32,
                              new_password: "another-correct-password", ip_hash: "b", secure: true)
    refute second.ok
    assert_equal "recovery failed", second.error
  end

  def test_unknown_disabled_and_locked_logins_each_pay_one_kdf_verification
    kdf = CountingKdf.new(false)
    row = @row.merge("password_digest" => "stored-digest", "recovery_code_digest" => "stored-recovery")
    store = FakeStore.new(row)
    manager = CloudAuth::Manager.new(store: store, config: @config, kdf: kdf,
                                     clock: -> { @now }, limiter: CloudAuth::AttemptLimiter.new(limit: 100))
    kdf.reset!
    unknown = manager.login(username: "nobody", password: "wrong-password", ip_hash: "a", secure: true)
    unknown_calls = kdf.verify_calls
    kdf.reset!

    row["disabled_at"] = @now
    disabled = manager.login(username: "owner", password: "wrong-password", ip_hash: "b", secure: true)
    disabled_calls = kdf.verify_calls
    kdf.reset!

    row["disabled_at"] = nil
    row["login_locked_until"] = @now + 60
    locked = manager.login(username: "owner", password: "wrong-password", ip_hash: "c", secure: true)
    locked_calls = kdf.verify_calls

    refute unknown.ok
    refute disabled.ok
    refute locked.ok
    assert_equal [1, 1, 1], [unknown_calls, disabled_calls, locked_calls]
    assert_equal [unknown.error, unknown.retry_after], [disabled.error, disabled.retry_after]
    assert_equal [unknown.error, unknown.retry_after], [locked.error, locked.retry_after]
  end

  def test_correct_password_unlocks_and_wrong_locked_password_does_not_extend_lock
    kdf = CountingKdf.new { |secret| secret == "correct-password" }
    row = @row.merge("password_digest" => "stored-digest", "login_locked_until" => @now + 60,
                     "failed_login_count" => 7)
    store = FakeStore.new(row)
    manager = CloudAuth::Manager.new(store: store, config: @config, kdf: kdf,
                                     clock: -> { @now }, limiter: CloudAuth::AttemptLimiter.new(limit: 100))
    kdf.reset!
    wrong = manager.login(username: "owner", password: "wrong-password", ip_hash: "new-ip", secure: true)
    assert_equal 1, kdf.verify_calls
    refute wrong.ok
    assert_equal 7, row["failed_login_count"]
    assert_equal @now + 60, row["login_locked_until"]
    assert_empty store.failed_login_updates

    kdf.reset!
    correct = manager.login(username: "owner", password: "correct-password", ip_hash: "new-ip", secure: true)
    assert_equal 1, kdf.verify_calls
    assert correct.ok
    assert_equal 0, row["failed_login_count"]
    assert_nil row["login_locked_until"]
    assert_equal 1, store.reset_count
  end

  def test_unknown_used_and_disabled_recovery_fail_after_one_kdf_verification
    kdf = CountingKdf.new(true)
    row = @row.merge("password_digest" => "stored-digest", "recovery_code_digest" => "stored-recovery")
    store = FakeStore.new(row)
    manager = CloudAuth::Manager.new(store: store, config: @config, kdf: kdf,
                                     clock: -> { @now }, limiter: CloudAuth::AttemptLimiter.new(limit: 100))
    args = { recovery_code: "r" * 32, new_password: "new-correct-password", ip_hash: "a", secure: true }

    kdf.reset!
    unknown = manager.recover(username: "nobody", **args)
    assert_equal 1, kdf.verify_calls
    kdf.reset!

    row["recovery_used_at"] = @now
    used = manager.recover(username: "owner", **args)
    assert_equal 1, kdf.verify_calls
    kdf.reset!

    row["recovery_used_at"] = nil
    row["disabled_at"] = @now
    disabled = manager.recover(username: "owner", **args)
    assert_equal 1, kdf.verify_calls

    [unknown, used, disabled].each do |result|
      refute result.ok
      assert_equal "recovery failed", result.error
      assert_nil result.retry_after
    end
  end

  def test_public_mode_requires_secure_transport
    config = CloudConfig.new(env: {
      "BIND_ADDRESS" => "127.0.0.1", "AUTH_MODE" => "required", "CLOUD_PUBLIC_DEPLOYMENT" => "1",
      "CLOUD_IDENTITY_PEPPER" => "identity-test", "CLOUD_SESSION_PEPPER" => "session-test"
    })
    manager = CloudAuth::Manager.new(store: @store, config: config, kdf: @kdf,
                                     limiter: CloudAuth::AttemptLimiter.new(limit: 100))
    assert_raises(CloudAuth::SecureTransportRequired) do
      manager.login(username: "owner", password: "correct-password", ip_hash: "ip", secure: false)
    end
    assert_nil manager.authenticate(session_token: "0" * 64, secure: false)
  end
end
