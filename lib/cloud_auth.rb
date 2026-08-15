# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "open3"
require "securerandom"
require "time"
require_relative "local_runtime"

module CloudAuth
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class SecureTransportRequired < Error; end

  # PBKDF2-HMAC-SHA256 is provided by OpenSSL and is available in the Ruby
  # standard library on the supported runtime.  A versioned, self-describing
  # encoding makes future KDF migration auditable without reinterpreting old
  # credentials.
  class Kdf
    ALGORITHM = "pbkdf2-sha256".freeze
    DEFAULT_ITERATIONS = 600_000
    SALT_BYTES = 16
    DERIVED_BYTES = 32

    attr_reader :iterations

    def initialize(iterations: DEFAULT_ITERATIONS, allow_weak: false)
      @iterations = Integer(iterations)
      @allow_weak = !!allow_weak
      raise ConfigurationError, "KDF iterations are too low" if @iterations < 600_000 && !@allow_weak
    rescue ArgumentError, TypeError
      raise ConfigurationError, "KDF iterations must be an integer"
    end

    def digest(secret, iterations: @iterations)
      value = secret.to_s
      raise ArgumentError, "secret must not be empty" if value.empty?
      iter = Integer(iterations)
      raise ConfigurationError, "KDF iterations are too low" if iter < 600_000 && !@allow_weak
      salt = SecureRandom.random_bytes(SALT_BYTES)
      derived = derive(value, salt, iter)
      [ALGORITHM, iter, encode(salt), encode(derived)].join("$")
    end

    def verify(secret, encoded)
      algorithm, iteration_text, salt_text, expected_text = encoded.to_s.split("$", 4)
      return false unless algorithm == ALGORITHM
      iterations = Integer(iteration_text)
      return false if iterations < 100_000 || iterations > 10_000_000
      salt = decode(salt_text)
      expected = decode(expected_text)
      return false unless salt.bytesize == SALT_BYTES && expected.bytesize == DERIVED_BYTES

      actual = derive(secret.to_s, salt, iterations)
      secure_compare(actual, expected)
    rescue ArgumentError, TypeError, OpenSSL::OpenSSLError
      false
    end

    def self.password_valid?(password)
      value = password.to_s
      value.bytesize >= 12 && value.bytesize <= 256 && value.match?(/\S/)
    end

    def self.recovery_code_valid?(code)
      value = code.to_s
      value.bytesize >= 32 && value.bytesize <= 512 && value.match?(/\S/)
    end

    private

    def derive(secret, salt, iterations)
      OpenSSL::KDF.pbkdf2_hmac(secret, salt: salt, iterations: iterations,
                               length: DERIVED_BYTES, hash: "sha256")
    end

    def encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def decode(value)
      text = value.to_s
      raise ArgumentError, "invalid KDF encoding" unless text.match?(/\A[A-Za-z0-9_-]+\z/)
      Base64.urlsafe_decode64(text + ("=" * ((4 - text.length % 4) % 4)))
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= (a ^ b) }
      difference == 0
    end
  end

  class Token
    BYTES = 32

    def self.generate
      SecureRandom.hex(BYTES)
    end

    def self.valid?(value)
      value.to_s.match?(/\A[0-9a-f]{64}\z/)
    end

    def self.hash(value, pepper: "")
      Digest::SHA256.hexdigest("#{pepper}\0#{value}")
    end
  end

  # Thin psql-backed store.  It intentionally accepts an executor for focused
  # tests, while production uses the repository's existing psql-only runtime.
  class Store
    class Error < CloudAuth::Error; end

    attr_reader :psql, :host, :port, :database, :user

    def initialize(psql: ENV.fetch("LOCAL_PSQL", File.join(LocalRuntime.pg_bin, "psql")),
                   host: ENV.fetch("LOCAL_PGHOST", LocalRuntime.socket_dir),
                   port: ENV.fetch("LOCAL_PGPORT", LocalRuntime.port),
                   database: ENV.fetch("PERSONAL_PGDATABASE", LocalRuntime.personal_database),
                   user: ENV.fetch("LOCAL_PGUSER", LocalRuntime.user), executor: nil)
      @psql, @host, @port, @database, @user, @executor = psql, host, port, database.to_s, user, executor
      raise Error, "auth database must be explicit" if @database.empty?
    end

    def migration_ready?
      query("SELECT to_regclass('cloud_owner_account') IS NOT NULL").first.to_s == "t"
    rescue Error
      false
    end

    def owner(username:)
      value = CloudAuth.normalize_username(username)
      row = query(<<~SQL).first
        SELECT account_id, username, password_digest, recovery_code_digest,
               COALESCE(EXTRACT(EPOCH FROM recovery_used_at), 0),
               failed_login_count, COALESCE(EXTRACT(EPOCH FROM login_locked_until), 0),
               COALESCE(EXTRACT(EPOCH FROM disabled_at), 0)
          FROM cloud_owner_account
         WHERE account_id = 'owner' AND username = #{literal(value)}
         LIMIT 1
      SQL
      parse_owner(row)
    end

    def owner_any
      row = query(<<~SQL).first
        SELECT account_id, username, password_digest, recovery_code_digest,
               COALESCE(EXTRACT(EPOCH FROM recovery_used_at), 0),
               failed_login_count, COALESCE(EXTRACT(EPOCH FROM login_locked_until), 0),
               COALESCE(EXTRACT(EPOCH FROM disabled_at), 0)
          FROM cloud_owner_account WHERE account_id = 'owner' LIMIT 1
      SQL
      parse_owner(row)
    end

    def create_owner!(username:, password_digest:, recovery_code_digest:)
      value = CloudAuth.normalize_username(username)
      raise Error, "owner already exists" if owner_any
      execute!(<<~SQL)
        INSERT INTO cloud_owner_account
          (account_id, username, password_digest, recovery_code_digest)
        VALUES ('owner', #{literal(value)}, #{literal(password_digest)}, #{literal(recovery_code_digest)})
      SQL
      owner(username: value)
    end

    def replace_credentials!(account_id: "owner", username:, password_digest:, recovery_code_digest:)
      value = CloudAuth.normalize_username(username)
      execute!(<<~SQL)
        UPDATE cloud_owner_account
           SET username = #{literal(value)}, password_digest = #{literal(password_digest)},
               recovery_code_digest = #{literal(recovery_code_digest)}, recovery_used_at = NULL,
               failed_login_count = 0, login_locked_until = NULL,
               password_changed_at = now(), updated_at = now()
         WHERE account_id = #{literal(account_id)}
      SQL
      owner(username: value)
    end

    def reset_failed_login!(account_id: "owner")
      execute!("UPDATE cloud_owner_account SET failed_login_count = 0, login_locked_until = NULL, updated_at = now() WHERE account_id = #{literal(account_id)}")
    end

    def record_failed_login!(account_id:, failed_count:, locked_until:)
      lock_literal = locked_until ? "#{literal(locked_until.utc.iso8601(6))}::timestamptz" : "NULL"
      execute!(<<~SQL)
        UPDATE cloud_owner_account
           SET failed_login_count = #{Integer(failed_count)},
               login_locked_until = #{lock_literal}, updated_at = now()
         WHERE account_id = #{literal(account_id)}
      SQL
    end

    # Recovery is consumed atomically.  The caller passes the already stored
    # digest, not the plaintext recovery code.
    def consume_recovery!(account_id:, username:, recovery_code_digest:, password_digest:)
      value = CloudAuth.normalize_username(username)
      row = query(<<~SQL)
        UPDATE cloud_owner_account
           SET password_digest = #{literal(password_digest)}, recovery_used_at = now(),
               failed_login_count = 0, login_locked_until = NULL,
               password_changed_at = now(), updated_at = now()
         WHERE account_id = #{literal(account_id)} AND username = #{literal(value)}
           AND recovery_code_digest = #{literal(recovery_code_digest)}
           AND recovery_used_at IS NULL AND disabled_at IS NULL
         RETURNING account_id
      SQL
      !row.empty?
    end

    def create_session!(session_hash:, account_id:, csrf_hash:, issued_at:, idle_expires_at:, absolute_expires_at:)
      execute!(<<~SQL)
        INSERT INTO cloud_auth_session
          (session_hash, account_id, csrf_hash, issued_at, last_seen_at, idle_expires_at, absolute_expires_at)
        VALUES (#{literal(session_hash)}, #{literal(account_id)}, #{literal(csrf_hash)},
                #{literal(issued_at.utc.iso8601(6))}::timestamptz,
                #{literal(issued_at.utc.iso8601(6))}::timestamptz,
                #{literal(idle_expires_at.utc.iso8601(6))}::timestamptz,
                #{literal(absolute_expires_at.utc.iso8601(6))}::timestamptz)
      SQL
      true
    end

    def session(session_hash:)
      row = query(<<~SQL).first
        SELECT session_hash, account_id, csrf_hash,
               EXTRACT(EPOCH FROM issued_at), EXTRACT(EPOCH FROM last_seen_at),
               EXTRACT(EPOCH FROM idle_expires_at), EXTRACT(EPOCH FROM absolute_expires_at),
               COALESCE(EXTRACT(EPOCH FROM revoked_at), 0)
          FROM cloud_auth_session WHERE session_hash = #{literal(session_hash)} LIMIT 1
      SQL
      return nil unless row
      fields = row.split("\t", -1)
      {
        "session_hash" => fields[0], "account_id" => fields[1], "csrf_hash" => fields[2],
        "issued_at" => epoch(fields[3]), "last_seen_at" => epoch(fields[4]),
        "idle_expires_at" => epoch(fields[5]), "absolute_expires_at" => epoch(fields[6]),
        "revoked_at" => epoch(fields[7])
      }
    end

    def touch_session!(session_hash:, last_seen_at:, idle_expires_at:)
      execute!(<<~SQL)
        UPDATE cloud_auth_session
           SET last_seen_at = #{literal(last_seen_at.utc.iso8601(6))}::timestamptz,
               idle_expires_at = #{literal(idle_expires_at.utc.iso8601(6))}::timestamptz
         WHERE session_hash = #{literal(session_hash)} AND revoked_at IS NULL
      SQL
    end

    def revoke_session!(session_hash:)
      execute!("UPDATE cloud_auth_session SET revoked_at = now() WHERE session_hash = #{literal(session_hash)} AND revoked_at IS NULL")
    end

    def revoke_all!(account_id: "owner")
      execute!("UPDATE cloud_auth_session SET revoked_at = now() WHERE account_id = #{literal(account_id)} AND revoked_at IS NULL")
    end

    def record_event!(event_type:, account_id: nil, ip_hash: nil, request_id: nil)
      event_id = "auth-#{SecureRandom.uuid}"
      execute!(<<~SQL)
        INSERT INTO cloud_auth_event(event_id, account_id, event_type, ip_hash, request_id)
        VALUES (#{literal(event_id)}, #{account_id ? literal(account_id) : "NULL"}, #{literal(event_type)},
                #{ip_hash ? literal(ip_hash) : "NULL"}, #{request_id ? literal(request_id) : "NULL"})
      SQL
      true
    rescue Error
      # Event logging is best effort and must never turn a successful login
      # into a 503.  The request id is still returned to the caller.
      false
    end

    def execute!(sql)
      output = execute(sql)
      output
    end

    def query(sql)
      output = execute(sql)
      return output if output.is_a?(Array)
      output.to_s.lines.map { |line| line.chomp }.reject(&:empty?)
    end

    private

    def execute(sql)
      return @executor.call(sql) if @executor

      stdout, stderr, status = Open3.capture3(@psql, "-XAtq", "-F", "\t", "-v", "ON_ERROR_STOP=1",
                                              "-h", @host, "-p", @port.to_s, "-U", @user,
                                              "-d", @database, "-c", sql)
      raise Error, "auth database operation failed" unless status.success?
      stdout
    end

    def parse_owner(line)
      return nil if line.nil? || line.to_s.empty?
      fields = line.split("\t", -1)
      return nil if fields.length < 8
      {
        "account_id" => fields[0], "username" => fields[1],
        "password_digest" => fields[2], "recovery_code_digest" => fields[3],
        "recovery_used_at" => epoch(fields[4]), "failed_login_count" => fields[5].to_i,
        "login_locked_until" => epoch(fields[6]), "disabled_at" => epoch(fields[7])
      }
    end

    def epoch(value)
      number = value.to_f
      number.zero? ? nil : Time.at(number).utc
    end

    def literal(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end
  end

  # A small in-process source-address throttle complements the persistent
  # account backoff.  Its key is a keyed digest supplied by CloudRequestContext
  # and it is intentionally not serialized to disk.
  class AttemptLimiter
    def initialize(limit: 12, window: 60, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @limit, @window, @clock = Integer(limit), Integer(window), clock
      @mutex = Mutex.new
      @attempts = {}
    end

    def allow?(key)
      now = @clock.call
      @mutex.synchronize do
        if @attempts.length > 10_000
          @attempts.delete_if { |_candidate, timestamps| Array(timestamps).all? { |timestamp| now - timestamp >= @window } }
        end
        values = Array(@attempts[key]).select { |timestamp| now - timestamp < @window }
        allowed = values.length < @limit
        values << now if allowed
        @attempts[key] = values
        allowed
      end
    end
  end

  class Manager
    Result = Struct.new(:ok, :error, :retry_after, :session_token, :csrf_token, :account, keyword_init: true)
    DEFAULT_OWNER = "owner"

    attr_reader :store, :config

    def initialize(store:, config: CloudConfig.new, kdf: Kdf.new, clock: -> { Time.now.utc }, token_factory: -> { Token.generate }, limiter: AttemptLimiter.new)
      @store, @config, @kdf, @clock, @token_factory, @limiter = store, config, kdf, clock, token_factory, limiter
      @dummy_digest = @kdf.digest("cloud-auth-dummy-password-#{SecureRandom.hex(16)}")
    end

    def login(username:, password:, ip_hash:, request_id: nil, secure: true)
      require_secure!(secure)
      unless @limiter.allow?(ip_hash.to_s)
        return Result.new(ok: false, error: "invalid credentials", retry_after: 60)
      end

      normalized = begin
        CloudAuth.normalize_username(username)
      rescue ArgumentError
        verify_password_candidate(password, @dummy_digest)
        record_event("login_failure", ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "invalid credentials", retry_after: 1)
      end
      row = @store.owner(username: normalized)
      unless row
        verify_password_candidate(password, @dummy_digest)
        record_event("login_failure", ip_hash: ip_hash, request_id: request_id)
        # Keep this response shape identical to a known-account failure.  The
        # persistent account backoff still protects the owner, while callers
        # cannot use Retry-After to enumerate whether a username exists.
        return Result.new(ok: false, error: "invalid credentials", retry_after: 1)
      end

      # Disabled accounts always fail, but still perform one password KDF
      # verification so the response is indistinguishable from an unknown or
      # locked username.  The result is deliberately ignored.
      if row["disabled_at"]
        verify_password_candidate(password, row["password_digest"] || @dummy_digest)
        record_event("login_failure", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "invalid credentials", retry_after: 1)
      end

      password_matches = verify_password_candidate(password, row.fetch("password_digest"))
      if row["login_locked_until"] && row["login_locked_until"] > now
        # A correct password unlocks the single owner account.  A wrong
        # password leaves the existing lock/counter untouched, so rotating
        # source IPs cannot extend the lock indefinitely.
        unless password_matches
          record_event("login_failure", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
          return Result.new(ok: false, error: "invalid credentials", retry_after: 1)
        end
        @store.reset_failed_login!(account_id: row.fetch("account_id"))
        token, csrf = issue_session(row.fetch("account_id"))
        record_event("login_success", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: true, account: { "account_id" => row["account_id"], "username" => row["username"] },
                          session_token: token, csrf_token: csrf)
      end

      unless password_matches
        count = [row.fetch("failed_login_count", 0).to_i + 1, 1_000].min
        delay = backoff_seconds(count)
        locked_until = delay ? now + delay : nil
        @store.record_failed_login!(account_id: row.fetch("account_id"), failed_count: count, locked_until: locked_until)
        record_event("login_failure", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "invalid credentials", retry_after: 1)
      end

      @store.reset_failed_login!(account_id: row.fetch("account_id"))
      token, csrf = issue_session(row.fetch("account_id"))
      record_event("login_success", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
      Result.new(ok: true, account: { "account_id" => row["account_id"], "username" => row["username"] },
                 session_token: token, csrf_token: csrf)
    rescue ArgumentError, ConfigurationError
      Result.new(ok: false, error: "invalid credentials", retry_after: nil)
    end

    def authenticate(session_token:, secure: true)
      return nil unless transport_allowed?(secure) && Token.valid?(session_token)

      session = @store.session(session_hash: session_hash(session_token))
      return nil unless session
      timestamp = now
      return nil if session["revoked_at"] || timestamp >= session["absolute_expires_at"] || timestamp >= session["idle_expires_at"]

      next_idle = [timestamp + @config.session_idle_ttl, session["absolute_expires_at"]].min
      @store.touch_session!(session_hash: session.fetch("session_hash"), last_seen_at: timestamp, idle_expires_at: next_idle)
      session.merge("authenticated" => true, "csrf_hash" => session.fetch("csrf_hash"))
    rescue Store::Error
      nil
    end

    def csrf_valid?(session:, token:, cookie_token: nil)
      value = token.to_s
      return false unless Token.valid?(value)
      return false if cookie_token && cookie_token.to_s != value
      secure_compare(Token.hash(value, pepper: @config.session_pepper), session.fetch("csrf_hash").to_s)
    end

    def logout(session_token:)
      return false unless Token.valid?(session_token)
      @store.revoke_session!(session_hash: session_hash(session_token))
      true
    end

    def revoke_all!(account_id: DEFAULT_OWNER, ip_hash: nil, request_id: nil)
      @store.revoke_all!(account_id: account_id)
      record_event("revoke_all", account_id: account_id, ip_hash: ip_hash, request_id: request_id)
      true
    end

    def recover(username:, recovery_code:, new_password:, ip_hash:, request_id: nil, secure: true)
      require_secure!(secure)
      unless @limiter.allow?(ip_hash.to_s)
        return Result.new(ok: false, error: "recovery failed", retry_after: 60)
      end
      normalized = begin
        CloudAuth.normalize_username(username)
      rescue ArgumentError
        verify_recovery_candidate(recovery_code, @dummy_digest)
        record_event("recovery_failure", ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "recovery failed", retry_after: nil)
      end
      row = @store.owner(username: normalized)
      recovery_value = recovery_code.to_s
      recovery_digest = row && row["recovery_code_digest"]
      code_matches = verify_recovery_candidate(recovery_value, recovery_digest || @dummy_digest)
      valid_code = row && !row["recovery_used_at"] && !row["disabled_at"] && code_matches
      valid_password = Kdf.password_valid?(new_password)
      unless valid_code && valid_password
        record_event("recovery_failure", account_id: row && row["account_id"], ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "recovery failed", retry_after: nil)
      end
      password_digest = @kdf.digest(new_password)
      consumed = @store.consume_recovery!(account_id: row.fetch("account_id"), username: normalized,
                                           recovery_code_digest: row.fetch("recovery_code_digest"), password_digest: password_digest)
      unless consumed
        record_event("recovery_failure", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
        return Result.new(ok: false, error: "recovery failed", retry_after: nil)
      end
      @store.revoke_all!(account_id: row.fetch("account_id"))
      record_event("recovery_success", account_id: row["account_id"], ip_hash: ip_hash, request_id: request_id)
      Result.new(ok: true)
    rescue ArgumentError
      Result.new(ok: false, error: "recovery failed", retry_after: nil)
    end

    private

    def verify_password_candidate(value, digest)
      candidate = value.to_s.byteslice(0, 256).to_s
      @kdf.verify(candidate, verification_digest(digest))
    end

    def verify_recovery_candidate(value, digest)
      candidate = value.to_s.byteslice(0, 512).to_s
      @kdf.verify(candidate, verification_digest(digest))
    end

    def verification_digest(value)
      digest = value.to_s
      # A malformed persisted digest must not turn the disabled/unknown path
      # into a cheap parse-and-return.  Fall back to the valid dummy record so
      # every failure still pays one full KDF verification.
      digest.match?(/\Apbkdf2-sha256\$\d+\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+\z/) ? digest : @dummy_digest
    end

    def issue_session(account_id)
      token = @token_factory.call.to_s
      token = Token.generate unless Token.valid?(token)
      csrf = @token_factory.call.to_s
      csrf = Token.generate unless Token.valid?(csrf)
      timestamp = now
      @store.create_session!(session_hash: session_hash(token), account_id: account_id,
                             csrf_hash: Token.hash(csrf, pepper: @config.session_pepper), issued_at: timestamp,
                             idle_expires_at: timestamp + @config.session_idle_ttl,
                             absolute_expires_at: timestamp + @config.session_absolute_ttl)
      [token, csrf]
    end

    def now
      value = @clock.call
      value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
    end

    def backoff_seconds(count)
      return nil if count <= 0
      return 1 if count == 1
      return 2 if count == 2
      [30 * (2**([count - 3, 5].min)), 900].min
    end

    def require_secure!(secure)
      raise SecureTransportRequired, "HTTPS is required" unless transport_allowed?(secure)
    end

    def transport_allowed?(secure)
      !@config.secure_public_mode? || !!secure
    end

    def record_event(type, account_id: nil, ip_hash: nil, request_id: nil)
      @store.record_event!(event_type: type, account_id: account_id, ip_hash: ip_hash, request_id: request_id)
    rescue Store::Error
      false
    end

    def secure_compare(left, right)
      return false unless left.to_s.bytesize == right.to_s.bytesize
      difference = 0
      left.to_s.bytes.zip(right.to_s.bytes) { |a, b| difference |= (a ^ b) }
      difference == 0
    end

    def session_hash(value)
      Token.hash(value, pepper: @config.session_pepper)
    end
  end

  def self.normalize_username(value)
    username = value.to_s.strip.downcase
    raise ArgumentError, "username is invalid" unless username.match?(/\A[a-z0-9][a-z0-9._@+-]{1,127}\z/)
    username
  end
end

# A descriptive alias keeps callers that prefer an explicit store name
# readable without introducing a second implementation.
CloudAuthStore = CloudAuth::Store unless defined?(CloudAuthStore)
