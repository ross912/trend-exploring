#!/usr/bin/env bash
# Idempotent package/bootstrap installer. Existing env and configs are kept.
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
dry_run=0
skip_packages=0
replace_config=0
enable_migrations=0
enable_backups=0
while (($#)); do
  case "$1" in
    --repo-root) repo_root="${2:?--repo-root needs a path}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --skip-packages) skip_packages=1; shift ;;
    --replace-config) replace_config=1; shift ;;
    --enable-migrations) enable_migrations=1; shift ;;
    --enable-backups) enable_backups=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: install.sh [--repo-root PATH] [--dry-run] [--skip-packages]
                  [--replace-config] [--enable-migrations] [--enable-backups]
Installs native systemd/Caddy cloud runtime. No services are started.
USAGE
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

run() {
  if ((dry_run)); then printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
warn() { printf 'WARN: %s\n' "$*" >&2; }
require_root() { ((dry_run)) || [[ "${EUID}" == 0 ]] || { echo "ERROR: install requires root" >&2; exit 1; }; }
require_root
[[ -d "${repo_root}" ]] || { echo "ERROR: repository root does not exist" >&2; exit 1; }

packages=(ca-certificates curl caddy postgresql postgresql-contrib ruby-full ruby-dev ruby-webrick build-essential libpq-dev ufw gpg logrotate)
if (( !skip_packages )); then
  run apt-get update
  run apt-get install -y "${packages[@]}"
fi

if id trendexploring >/dev/null 2>&1; then
  printf 'dedicated user trendexploring already exists\n'
else
  run useradd --system --user-group --home-dir /var/lib/trend-exploring --create-home --shell /usr/sbin/nologin trendexploring
fi
if id caddy >/dev/null 2>&1; then
  # Release directories are 0750; Caddy needs group read access to the public
  # landing assets while the application user remains the only writer.
  run usermod --append --groups trendexploring caddy
fi
run install -d -o trendexploring -g trendexploring -m 0750 /var/lib/trend-exploring /var/lib/trend-exploring/locks /var/log/trend-exploring /var/backups/trend-exploring
run install -d -o root -g trendexploring -m 0750 /etc/trend-exploring
run install -d -o root -g root -m 0755 /opt/trend-exploring/releases
run install -d -o root -g root -m 0755 /usr/local/libexec/trend-exploring /usr/local/libexec/trend-exploring/lib

env_file=/etc/trend-exploring/trend-exploring.env
if [[ ! -e "${env_file}" ]]; then
  run install -o root -g trendexploring -m 0600 "${repo_root}/config/cloud/trend-exploring.env.example" "${env_file}"
  warn "edit ${env_file} with deployment-specific values before starting services"
else
  printf 'preserving existing %s\n' "${env_file}"
fi

for wrapper in run_server.sh run_collect.sh run_cycle.sh run_translation.sh run_migration.sh run_backup.sh run_as_app_user.sh migrate.sh backup.sh verify_backup.sh restore_backup.sh bootstrap_postgresql.sh configure_ufw.sh configure_swap.sh preflight_ubuntu.sh verify_postgresql.sh; do
  run install -o root -g root -m 0755 "${repo_root}/scripts/cloud/${wrapper}" "/usr/local/libexec/trend-exploring/${wrapper}"
done
run install -o root -g root -m 0644 "${repo_root}/scripts/cloud/lib/runtime.sh" /usr/local/libexec/trend-exploring/lib/runtime.sh

install_config() {
  local source="$1" target="$2" mode="$3"
  if [[ -e "${target}" && "${replace_config}" != 1 ]]; then
    printf 'preserving existing %s\n' "${target}"
  else
    run install -o root -g root -m "${mode}" "${source}" "${target}"
  fi
}

for unit in "${repo_root}"/deploy/cloud/systemd/*.service "${repo_root}"/deploy/cloud/systemd/*.timer; do
  run install -o root -g root -m 0644 "${unit}" "/etc/systemd/system/$(basename -- "${unit}")"
done
run install_config "${repo_root}/deploy/cloud/caddy/Caddyfile" /etc/caddy/Caddyfile 0644
run install -o root -g root -m 0644 "${repo_root}/deploy/cloud/logrotate.d/trend-exploring" /etc/logrotate.d/trend-exploring

if command -v pg_lsclusters >/dev/null 2>&1; then
  while read -r _version _cluster _port _status _owner _data _log; do
    [[ -n "${_version:-}" ]] || continue
    conf_dir="/etc/postgresql/${_version}/${_cluster}/conf.d"
    run install -d -o root -g root -m 0755 "${conf_dir}"
    install_config "${repo_root}/deploy/cloud/postgresql/99-trend-exploring.conf" "${conf_dir}/99-trend-exploring.conf" 0644
  done < <(pg_lsclusters -h 2>/dev/null || true)
else
  warn "pg_lsclusters is unavailable; install PostgreSQL tuning file after package setup"
fi

if ((enable_migrations)); then
  run install -o root -g trendexploring -m 0600 /dev/null /etc/trend-exploring/enable-migrations
  warn "migration timer is enabled by request; review backups and SQL first"
fi

run systemctl daemon-reload
for unit in trend-exploring-server.service trend-exploring-collect.timer trend-exploring-cycle.timer trend-exploring-translation.timer; do
  run systemctl enable "${unit}"
done
if ((enable_migrations)); then run systemctl enable trend-exploring-migration.timer; fi
if ((enable_backups)); then
  run systemctl enable trend-exploring-backup.timer
  warn "backup timer enabled by request; verify GPG recipient and run a disposable restore"
fi

printf 'cloud install prepared (services were not started)\n'
