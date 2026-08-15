#!/usr/bin/env ruby
# frozen_string_literal: true

# Local/SSH-only owner provisioning.  Passwords and recovery codes are read
# from a TTY (masked) or controlled stdin; neither is accepted as an argv
# argument, written to the database, or printed except for a newly generated
# recovery code, which is shown once to the operator.
require "base64"
require "io/console"
require "json"
require "securerandom"
require_relative "../../lib/cloud_auth"
require_relative "../../lib/local_runtime"

def secret_input(prompt)
  if STDIN.tty?
    $stderr.print(prompt)
    value = STDIN.noecho(&:gets)
    $stderr.puts
    value.to_s.chomp
  else
    value = STDIN.gets
    raise "controlled stdin ended before a secret was provided" if value.nil?
    value.chomp
  end
end

begin
  store = CloudAuth::Store.new
  kdf_iterations = ENV.fetch("CLOUD_AUTH_KDF_ITERATIONS", CloudAuth::Kdf::DEFAULT_ITERATIONS)
  kdf = CloudAuth::Kdf.new(iterations: Integer(kdf_iterations), allow_weak: ENV.fetch("CLOUD_AUTH_ALLOW_WEAK_KDF", "0") == "1")
  username = ENV.fetch("CLOUD_OWNER_USERNAME", "owner").to_s.strip.downcase
  password = secret_input("Owner password: ")
  confirmation = secret_input("Confirm password: ")
  raise "passwords do not match" unless password == confirmation
  raise "password does not meet minimum policy" unless CloudAuth::Kdf.password_valid?(password)

  # Recovery material is always generated locally and printed exactly once;
  # it is never accepted through an environment variable or argv.
  recovery_code = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
  raise "recovery code does not meet minimum policy" unless CloudAuth::Kdf.recovery_code_valid?(recovery_code)

current = store.owner(username: username)
if current
  raise "owner exists; re-run with CLOUD_CONFIRM_REPLACE=1" unless ENV["CLOUD_CONFIRM_REPLACE"] == "1"
  if STDIN.tty?
    $stderr.print("Type REPLACE to rotate the owner credentials and revoke all sessions: ")
    raise "replacement not confirmed" unless STDIN.gets.to_s.chomp == "REPLACE"
  end
  store.replace_credentials!(account_id: current.fetch("account_id"), username: username,
                             password_digest: kdf.digest(password), recovery_code_digest: kdf.digest(recovery_code))
  store.revoke_all!(account_id: current.fetch("account_id"))
  store.record_event!(event_type: "revoke_all", account_id: current.fetch("account_id"))
  puts JSON.generate("status" => "replaced", "username" => username)
else
  raise "an owner account already exists with a different username" if store.owner_any
  store.create_owner!(username: username, password_digest: kdf.digest(password),
                      recovery_code_digest: kdf.digest(recovery_code))
  puts JSON.generate("status" => "created", "username" => username)
end

  $stderr.puts "ONE-TIME RECOVERY CODE (store it now; it will not be shown again):"
  $stderr.puts recovery_code
rescue StandardError => error
  warn error.message
  exit 1
end
