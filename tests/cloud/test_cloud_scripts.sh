#!/usr/bin/env bash
# Static/dry-run cloud package checks. No command touches production paths.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

bash -n scripts/cloud/*.sh scripts/cloud/lib/*.sh
grep -q 'CLOUD_PUBLIC_DEPLOYMENT=1' config/cloud/trend-exploring.env.example
grep -q 'PUBLIC_UNAUTHENTICATED_MODE=0' config/cloud/trend-exploring.env.example
grep -q 'PUBLISH_API_ENABLED=0' config/cloud/trend-exploring.env.example
grep -q 'AUTH_REQUIRED_FOR_APP=1' config/cloud/trend-exploring.env.example
grep -q 'LOCAL_PGSOCKET=/var/run/postgresql' config/cloud/trend-exploring.env.example
grep -q 'PERSONAL_PGDATABASE=trend_exploring_personal' config/cloud/trend-exploring.env.example
grep -q 'CLOUD_PG_ROLE=trendexploring' config/cloud/trend-exploring.env.example
scripts/cloud/run_as_app_user.sh --dry-run id -un | grep -q 'effective_user=trendexploring'
deploy_plan="$(scripts/cloud/deploy_release.sh --dry-run --source "${root}" 2>/dev/null)"
grep -q 'effective_user=trendexploring' <<< "${deploy_plan}"
grep -q 'LOCAL_STATE_DIR=/var/lib/trend-exploring' config/cloud/trend-exploring.env.example
grep -q 'flock' scripts/cloud/lib/runtime.sh
! grep -R -q '^exec ruby\|^exec bash' scripts/cloud
grep -q -- '--skip-ingest' scripts/cloud/run_cycle.sh deploy/cloud/systemd/trend-exploring-cycle.service
grep -q 'Persistent=true' deploy/cloud/systemd/*.timer
grep -q 'User=trendexploring' deploy/cloud/systemd/*.service
grep -q 'Environment=HOME=/var/lib/trend-exploring' deploy/cloud/systemd/*.service
grep -q 'StateDirectory=trend-exploring' deploy/cloud/systemd/*.service
grep -q '07:55:00 Asia/Shanghai' deploy/cloud/systemd/trend-exploring-collect.timer
grep -q '18:55:00 Asia/Shanghai' deploy/cloud/systemd/trend-exploring-collect.timer
! grep -q '\*:0/15' deploy/cloud/systemd/trend-exploring-collect.timer
grep -q 'MemoryMax=512M' deploy/cloud/systemd/trend-exploring-server.service
grep -q 'MemoryMax=768M' deploy/cloud/systemd/trend-exploring-collect.service
grep -q 'TasksMax=64' deploy/cloud/systemd/trend-exploring-cycle.service
grep -q 'LimitNOFILE=4096' deploy/cloud/systemd/trend-exploring-translation.service
grep -q '03:00:00 Asia/Shanghai' deploy/cloud/systemd/trend-exploring-backup.timer
grep -q 'Persistent=true' deploy/cloud/systemd/trend-exploring-backup.timer
grep -q 'ExecStart=/usr/local/libexec/trend-exploring/run_backup.sh' deploy/cloud/systemd/trend-exploring-backup.service
grep -q 'ReadWritePaths=.*var/backups/trend-exploring' deploy/cloud/systemd/trend-exploring-backup.service
grep -q 'listen_addresses = '\''localhost'\''' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'max_connections = 20' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'shared_buffers = 128MB' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'work_mem = 2MB' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'effective_cache_size = 1GB' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'max_parallel_workers_per_gather = 1' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'temp_buffers = 8MB' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'temp_file_limit = 256MB' deploy/cloud/postgresql/99-trend-exploring.conf
grep -q 'max_size 2MB' deploy/cloud/caddy/Caddyfile
grep -q 'path /api/livez' deploy/cloud/caddy/Caddyfile
grep -q '/api/auth/recovery' deploy/cloud/caddy/Caddyfile
grep -q 'path /app\* /api\*' deploy/cloud/caddy/Caddyfile
grep -q 'CLOUD_PUBLIC_DEPLOYMENT=1' config/cloud/trend-exploring.env.example
grep -q 'TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128' config/cloud/trend-exploring.env.example
grep -q 'CLOUD_PROXY=nginx' config/cloud/trend-exploring.env.example
grep -q 'NGINX_DOMAIN=radar.zixin.space' config/cloud/trend-exploring.env.example
grep -q 'auth peppers must be provisioned' scripts/cloud/preflight_ubuntu.sh scripts/cloud/lib/runtime.sh
grep -q 'unexpected existing UFW ALLOW' scripts/cloud/configure_ufw.sh
grep -q '1572864' scripts/cloud/preflight_ubuntu.sh
grep -q '1048576' scripts/cloud/preflight_ubuntu.sh
grep -q '10485760' scripts/cloud/preflight_ubuntu.sh
grep -q 'ROOT_USED_PERCENT' scripts/cloud/preflight_ubuntu.sh
grep -q 'Signal.trap("TERM")' scripts/local/translation_worker.rb
grep -q 'owner_pid == Process.pid' scripts/local/translation_worker.rb
grep -q 'cloud_acquire_lock translation-wrapper' scripts/cloud/run_translation.sh
! grep -q 'cloud_acquire_lock translation$' scripts/cloud/run_translation.sh
grep -q 'lock_dir = File.join(lock_root, "translation.lock")' scripts/local/translation_worker.rb
grep -q 'Everything else is still handled by the backend' deploy/cloud/caddy/Caddyfile
grep -q '/styles.css and /app.js' deploy/cloud/caddy/Caddyfile
grep -q '/assets/landing-hero-v1.webp' deploy/cloud/caddy/Caddyfile
! grep -q '/assets/\*' deploy/cloud/caddy/Caddyfile
grep -q 'Content-Security-Policy' deploy/cloud/caddy/Caddyfile
grep -q '@external_ready path /readyz /api/readyz' deploy/cloud/caddy/Caddyfile
grep -q 'respond "Not found" 404' deploy/cloud/caddy/Caddyfile
grep -q 'read_timeout 60s' deploy/cloud/caddy/Caddyfile
grep -q 'personal.dump.gpg' scripts/cloud/backup.sh
grep -q 'restore_hook_configured' scripts/cloud/backup.sh
grep -q 'gpg --batch --list-packets' scripts/cloud/verify_backup.sh
grep -q -- '--confirm' scripts/cloud/restore_backup.sh
grep -q 'personal migrations' scripts/cloud/migrate.sh
grep -q 'personal_database_url' scripts/cloud/migrate.sh
grep -q '011_local_radar.sql' scripts/cloud/migrate.sh
grep -q '024_metadata_translation_leases.sql' scripts/cloud/migrate.sh
grep -q 'M1 001-010 are disposable verification schemas only' scripts/cloud/migrate.sh
for migration in \
  011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql \
  014_local_report_summary.sql 015_local_weak_signal.sql 016_local_fulltext_translation.sql \
  017_raw_archive_immutability.sql 018_multilingual_concepts.sql 019_world_change_candidates.sql \
  020_signal_lifecycle.sql 021_report_claim_gate.sql 022_report_summary_repair.sql \
  023_summary_run_leases.sql 024_metadata_translation_leases.sql; do
  grep -q "schema/postgres/${migration}" scripts/local/bootstrap_radar.rb
done
! grep -qi 'basicauth' deploy/cloud/caddy/Caddyfile
grep -q 'server_name __TREND_EXPLORING_DOMAIN__' deploy/cloud/nginx/radar.zixin.space.http.conf
grep -q 'server_name __TREND_EXPLORING_DOMAIN__' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'ssl_certificate /etc/letsencrypt/live/__TREND_EXPLORING_DOMAIN__/fullchain.pem' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'location = /api/readyz { return 404; }' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'location = /readyz { return 404; }' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'client_max_body_size 2m' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'client_max_body_size 128k' deploy/cloud/nginx/radar.zixin.space.tls.conf
grep -q 'trend-exploring-proxy-base.conf' deploy/cloud/nginx/trend-exploring-proxy.conf
grep -q 'trend-exploring-proxy-base.conf' deploy/cloud/nginx/trend-exploring-proxy-short.conf
grep -q 'trend-exploring-proxy-base.conf' deploy/cloud/nginx/trend-exploring-proxy-login.conf
! grep -q 'trend-exploring-proxy.conf' deploy/cloud/nginx/trend-exploring-proxy-short.conf
! grep -q 'trend-exploring-proxy.conf' deploy/cloud/nginx/trend-exploring-proxy-login.conf
grep -q 'X-Forwarded-Proto \$scheme' deploy/cloud/nginx/trend-exploring-proxy-base.conf
grep -q 'X-Forwarded-For \$proxy_add_x_forwarded_for' deploy/cloud/nginx/trend-exploring-proxy-base.conf
grep -q 'proxy_read_timeout 60s' deploy/cloud/nginx/trend-exploring-proxy.conf
grep -q 'proxy_read_timeout 5s' deploy/cloud/nginx/trend-exploring-proxy-short.conf
grep -q 'proxy_read_timeout 10s' deploy/cloud/nginx/trend-exploring-proxy-login.conf
[[ "$(grep -c '^proxy_.*_timeout ' deploy/cloud/nginx/trend-exploring-proxy.conf)" == 3 ]]
[[ "$(grep -c '^proxy_.*_timeout ' deploy/cloud/nginx/trend-exploring-proxy-short.conf)" == 3 ]]
[[ "$(grep -c '^proxy_.*_timeout ' deploy/cloud/nginx/trend-exploring-proxy-login.conf)" == 3 ]]
grep -q 'trend-exploring-proxy-base.conf' scripts/cloud/install.sh
grep -q 'CLOUD_PROXY:-caddy' scripts/cloud/install.sh
grep -q -- '--proxy caddy|nginx' scripts/cloud/install.sh
grep -q 'systemctl enable nginx' scripts/cloud/install.sh
nginx_plan="$(scripts/cloud/install.sh --repo-root "${root}" --dry-run --skip-packages --proxy nginx --domain radar.zixin.space 2>/dev/null)"
grep -q 'nginx' <<< "${nginx_plan}"
grep -q 'radar.zixin.space' <<< "${nginx_plan}"
! grep -q 'apt-get.*caddy' <<< "${nginx_plan}"

tmp_root="$(mktemp -d)"
env CLOUD_ENV_FILE="${tmp_root}/missing.env" CLOUD_PUBLIC_DEPLOYMENT=1 \
  PUBLIC_UNAUTHENTICATED_MODE=0 AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session PUBLISH_API_ENABLED=0 \
  CLOUD_DRY_RUN=1 CLOUD_RELEASE_ROOT="${root}" CLOUD_LOCK_ROOT="${tmp_root}/locks" \
  scripts/cloud/run_collect.sh >/dev/null
[[ ! -e "${tmp_root}/locks/collect.lock" ]]
env CLOUD_ENV_FILE="${tmp_root}/missing.env" CLOUD_PUBLIC_DEPLOYMENT=1 \
  PUBLIC_UNAUTHENTICATED_MODE=0 AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session PUBLISH_API_ENABLED=0 \
  CLOUD_DRY_RUN=1 CLOUD_RELEASE_ROOT="${root}" CLOUD_LOCK_ROOT="${tmp_root}/locks" \
  scripts/cloud/run_translation.sh >/dev/null
[[ ! -e "${tmp_root}/locks/translation-wrapper.lock" ]]
[[ ! -e "${tmp_root}/locks/translation.lock" ]]
translation_state="${tmp_root}/translation-state"
if env LOCAL_STATE_DIR="${translation_state}" LOCAL_PSQL=/usr/bin/false \
  LOCAL_PGSOCKET="${tmp_root}/missing-socket" LOCAL_PGPORT=1 LOCAL_PGUSER=test \
  LOCAL_PGDATABASE=test DEEPSEEK_API_KEY_FILE="${tmp_root}/missing-key" \
  ruby scripts/local/translation_worker.rb --limit 1 >/dev/null 2>&1; then
  echo "translation worker unexpectedly passed an unavailable database" >&2
  exit 1
fi
[[ ! -e "${translation_state}/locks/translation.lock" ]]
env CLOUD_ENV_FILE="${tmp_root}/missing.env" CLOUD_PUBLIC_DEPLOYMENT=1 \
  PUBLIC_UNAUTHENTICATED_MODE=0 AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session PUBLISH_API_ENABLED=0 \
  CLOUD_DRY_RUN=1 CLOUD_RELEASE_ROOT="${root}" CLOUD_LOCK_ROOT="${tmp_root}/locks" \
  scripts/cloud/run_cycle.sh >/dev/null
[[ ! -e "${tmp_root}/locks/global-batch.lock.d" ]]
env CLOUD_ENV_FILE="${tmp_root}/missing.env" CLOUD_PUBLIC_DEPLOYMENT=1 \
  PUBLIC_UNAUTHENTICATED_MODE=0 AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session PUBLISH_API_ENABLED=0 CLOUD_DRY_RUN=1 \
  CLOUD_RELEASE_ROOT="${root}" CLOUD_LOCK_ROOT="${tmp_root}/locks" \
  DATABASE_URL=postgresql:///test PERSONAL_DATABASE_URL=postgresql:///personal \
  scripts/cloud/run_backup.sh >/dev/null
if env CLOUD_ENV_FILE="${tmp_root}/missing.env" CLOUD_PUBLIC_DEPLOYMENT=1 \
  PUBLIC_UNAUTHENTICATED_MODE=0 AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required \
  TRUSTED_PROXY_CIDRS=10.0.0.0/8 CLOUD_IDENTITY_PEPPER=test-id CLOUD_SESSION_PEPPER=test-session \
  PUBLISH_API_ENABLED=0 CLOUD_DRY_RUN=1 \
  CLOUD_RELEASE_ROOT="${root}" CLOUD_LOCK_ROOT="${tmp_root}/bad-locks" \
  scripts/cloud/run_cycle.sh >/dev/null 2>&1; then
  echo "cloud runtime accepted non-loopback trusted proxy" >&2
  exit 1
fi

scripts/cloud/configure_ufw.sh --dry-run >/dev/null
scripts/cloud/configure_swap.sh --size 2G --dry-run >/dev/null
env CLOUD_DRY_RUN=1 CLOUD_DATABASE_URL=postgresql:///test PERSONAL_DATABASE_URL=postgresql:///personal \
  CLOUD_BACKUP_RETENTION=10 \
  scripts/cloud/backup.sh >/dev/null
scripts/cloud/bootstrap_postgresql.sh --dry-run >/dev/null
mkdir -p "${tmp_root}/runtime-migrations/personal"
for migration in \
  011_local_radar.sql 012_breadth_discovery.sql 013_local_report_ledger.sql \
  014_local_report_summary.sql 015_local_weak_signal.sql 016_local_fulltext_translation.sql \
  017_raw_archive_immutability.sql 018_multilingual_concepts.sql 019_world_change_candidates.sql \
  020_signal_lifecycle.sql 021_report_claim_gate.sql 022_report_summary_repair.sql \
  023_summary_run_leases.sql 024_metadata_translation_leases.sql; do
  cp "schema/postgres/${migration}" "${tmp_root}/runtime-migrations/${migration}"
done
for migration in 001_personal_memory.sql 002_conversation_ledger.sql 003_single_owner_auth.sql; do
  cp "schema/postgres/personal/${migration}" "${tmp_root}/runtime-migrations/personal/${migration}"
done
env CLOUD_DRY_RUN=1 CLOUD_PUBLIC_DEPLOYMENT=1 PUBLIC_UNAUTHENTICATED_MODE=0 \
  AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required PUBLISH_API_ENABLED=0 \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session DATABASE_URL=postgresql:///test \
  PERSONAL_DATABASE_URL=postgresql:///personal \
  CLOUD_MIGRATIONS_DIR="${tmp_root}/runtime-migrations" \
  scripts/cloud/migrate.sh >/dev/null
if env CLOUD_DRY_RUN=1 CLOUD_PUBLIC_DEPLOYMENT=1 PUBLIC_UNAUTHENTICATED_MODE=0 \
  AUTH_REQUIRED_FOR_APP=1 AUTH_MODE=required PUBLISH_API_ENABLED=0 \
  TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128 CLOUD_IDENTITY_PEPPER=test-id \
  CLOUD_SESSION_PEPPER=test-session DATABASE_URL=postgresql:///test \
  PERSONAL_DATABASE_URL=postgresql:///personal CLOUD_MIGRATIONS_DIR="${root}/schema/postgres" \
  scripts/cloud/migrate.sh >/dev/null 2>&1; then
  echo "migration accepted M1 verification schemas in runtime directory" >&2
  exit 1
fi
env CLOUD_DRY_RUN=1 CLOUD_DATABASE_URL=postgresql:///test PERSONAL_DATABASE_URL=postgresql:///personal \
  scripts/cloud/restore_backup.sh "${tmp_root}" >/dev/null 2>&1 || true
scripts/cloud/install.sh --repo-root "${root}" --dry-run --skip-packages >/dev/null
scripts/cloud/status.sh --dry-run >/dev/null
scripts/cloud/uninstall.sh --dry-run >/dev/null

printf 'cloud script dry-run checks passed\n'
