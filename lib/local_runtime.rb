# frozen_string_literal: true

# Shared, non-secret runtime path policy for the local product.  The local
# product is intentionally single-user, but its archive and database live
# outside the repository so a checkout refresh cannot erase them.
module LocalRuntime
  POSTGRES_VERSION = "15.18"
  POSTGRES_SHA256 = "11df0df97fe3ea4ba9a791faaf39cee1d2fe571e78885b5b55d8517d27c323b4"

  module_function

  def home_dir
    value = ENV["HOME"].to_s
    return value unless value.empty?

    "/tmp"
  end

  def default_state_dir
    explicit = ENV["LOCAL_STATE_DIR"].to_s
    return explicit unless explicit.empty?

    if RUBY_PLATFORM.include?("darwin")
      File.join(home_dir, "Library", "Application Support", "TrendExploring")
    else
      File.join(ENV.fetch("XDG_STATE_HOME", File.join(home_dir, ".local", "state")), "trend-exploring")
    end
  end

  def state_dir
    default_state_dir
  end

  def runtime_dir
    ENV.fetch("LOCAL_PG_RUNTIME_DIR", File.join(state_dir, "postgresql-#{POSTGRES_VERSION}"))
  end

  def pg_bin
    ENV.fetch("PG_BIN", File.join(runtime_dir, "bin"))
  end

  def pgdata
    ENV.fetch("LOCAL_PGDATA", File.join(state_dir, "postgres"))
  end

  def socket_dir
    ENV.fetch("LOCAL_PGSOCKET", File.join(state_dir, "socket"))
  end

  def port
    ENV.fetch("LOCAL_PGPORT", "55433")
  end

  def user
    ENV.fetch("LOCAL_PGUSER", ENV.fetch("USER", "postgres"))
  end

  def global_database
    ENV.fetch("LOCAL_PGDATABASE", "trend_exploring_local")
  end

  def personal_database
    ENV.fetch("PERSONAL_PGDATABASE", "trend_exploring_personal")
  end

  def backup_dir
    ENV.fetch("LOCAL_BACKUP_DIR", File.join(state_dir, "backups"))
  end

  def secrets_dir
    ENV.fetch("LOCAL_SECRETS_DIR", File.join(state_dir, "secrets"))
  end

  def deepseek_secret_file
    ENV.fetch("DEEPSEEK_API_KEY_FILE", File.join(secrets_dir, "deepseek_api_key"))
  end

  def env_hash
    {
      "LOCAL_STATE_DIR" => state_dir,
      "LOCAL_PGDATA" => pgdata,
      "LOCAL_PGSOCKET" => socket_dir,
      "LOCAL_PGPORT" => port,
      "LOCAL_PGUSER" => user,
      "LOCAL_PGDATABASE" => global_database,
      "PERSONAL_PGDATABASE" => personal_database,
      "PG_BIN" => pg_bin
    }
  end
end
