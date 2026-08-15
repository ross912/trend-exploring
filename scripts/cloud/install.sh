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
proxy="${CLOUD_PROXY:-caddy}"
proxy_domain="${CLOUD_PROXY_DOMAIN:-${NGINX_DOMAIN:-radar.zixin.space}}"
proxy_explicit=0
[[ -n "${CLOUD_PROXY+x}" ]] && proxy_explicit=1
[[ -n "${CLOUD_PROXY_DOMAIN+x}" || -n "${NGINX_DOMAIN+x}" ]] && proxy_domain_explicit=1 || proxy_domain_explicit=0
while (($#)); do
  case "$1" in
    --repo-root) repo_root="${2:?--repo-root needs a path}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --skip-packages) skip_packages=1; shift ;;
    --replace-config) replace_config=1; shift ;;
    --enable-migrations) enable_migrations=1; shift ;;
    --enable-backups) enable_backups=1; shift ;;
    --proxy) proxy="${2:?--proxy needs caddy or nginx}"; proxy_explicit=1; shift 2 ;;
    --domain) proxy_domain="${2:?--domain needs a hostname}"; proxy_domain_explicit=1; shift 2 ;;
    --help|-h)
      cat <<'USAGE'
Usage: install.sh [--repo-root PATH] [--dry-run] [--skip-packages]
                  [--replace-config] [--enable-migrations] [--enable-backups]
                  [--proxy caddy|nginx] [--domain HOSTNAME]
Installs native systemd plus a Caddy or coexisting Nginx cloud runtime.
No services are started. Existing proxy configuration is preserved unless
--replace-config is supplied.
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
env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
if ((proxy_explicit == 0)) && [[ -r "${env_file}" ]]; then
  configured_proxy="$(sed -n 's/^CLOUD_PROXY[[:space:]]*=[[:space:]]*//p' "${env_file}" | tail -n 1)"
  case "${configured_proxy}" in caddy|nginx) proxy="${configured_proxy}" ;; esac
  if ((proxy_domain_explicit == 0)); then
    configured_domain="$(sed -n 's/^NGINX_DOMAIN[[:space:]]*=[[:space:]]*//p' "${env_file}" | tail -n 1)"
    [[ -n "${configured_domain}" ]] && proxy_domain="${configured_domain}"
  fi
fi
case "${proxy}" in
  caddy|nginx) ;;
  *) echo "ERROR: --proxy must be caddy or nginx" >&2; exit 2 ;;
esac
if [[ ! "${proxy_domain}" =~ ^[A-Za-z0-9.-]+$ || "${proxy_domain}" == .* || "${proxy_domain}" == *. || "${proxy_domain}" == *..* ]]; then
  echo "ERROR: --domain must be a plain DNS hostname" >&2
  exit 2
fi

packages=(ca-certificates curl postgresql postgresql-contrib ruby-full ruby-dev ruby-webrick build-essential libpq-dev ufw gpg logrotate)
if [[ "${proxy}" == "caddy" ]]; then
  packages+=(caddy)
else
  packages+=(nginx certbot python3-certbot-nginx)
fi
if (( !skip_packages )); then
  run apt-get update
  run apt-get install -y "${packages[@]}"
fi

if id trendexploring >/dev/null 2>&1; then
  printf 'dedicated user trendexploring already exists\n'
else
  run useradd --system --user-group --home-dir /var/lib/trend-exploring --create-home --shell /usr/sbin/nologin trendexploring
fi
if [[ "${proxy}" == "caddy" ]] && id caddy >/dev/null 2>&1; then
  # Release directories are 0750; Caddy needs group read access to the public
  # landing assets while the application user remains the only writer.
  run usermod --append --groups trendexploring caddy
fi
if [[ "${proxy}" == "nginx" ]] && id www-data >/dev/null 2>&1; then
  # Nginx must read immutable releases while the application user remains the
  # only writer.  Keep /opt/trend-exploring out of the world-readable path.
  run usermod --append --groups trendexploring www-data
fi
run install -d -o trendexploring -g trendexploring -m 0750 /var/lib/trend-exploring /var/lib/trend-exploring/locks /var/log/trend-exploring /var/backups/trend-exploring
run install -d -o root -g trendexploring -m 0750 /etc/trend-exploring
run install -d -o root -g root -m 0755 /opt/trend-exploring/releases
run install -d -o root -g root -m 0755 /usr/local/libexec/trend-exploring /usr/local/libexec/trend-exploring/lib
if [[ "${proxy}" == "nginx" ]]; then
  run install -d -o root -g root -m 0755 /var/www/trend-exploring-acme /etc/nginx/snippets /etc/nginx/sites-available /etc/nginx/sites-enabled
fi

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
if [[ "${proxy}" == "caddy" ]]; then
  run install_config "${repo_root}/deploy/cloud/caddy/Caddyfile" /etc/caddy/Caddyfile 0644
else
  nginx_site="/etc/nginx/sites-available/${proxy_domain}.conf"
  nginx_link="/etc/nginx/sites-enabled/${proxy_domain}.conf"
  nginx_template="${repo_root}/deploy/cloud/nginx/radar.zixin.space.http.conf"
  nginx_certificate="/etc/letsencrypt/live/${proxy_domain}/fullchain.pem"
  nginx_key="/etc/letsencrypt/live/${proxy_domain}/privkey.pem"
  if [[ -r "${nginx_certificate}" && -r "${nginx_key}" ]]; then
    nginx_template="${repo_root}/deploy/cloud/nginx/radar.zixin.space.tls.conf"
  fi
  install_nginx_template() {
    local source="$1" target="$2" mode="$3" rendered
    if [[ -e "${target}" && "${replace_config}" != 1 ]]; then
      printf 'preserving existing %s\n' "${target}"
      return 0
    fi
    rendered="${target}.rendered.$$"
    if ((dry_run)); then
      printf 'DRY-RUN: render %s -> %s (domain=%s)\n' "${source}" "${target}" "${proxy_domain}"
      return 0
    fi
    sed "s/__TREND_EXPLORING_DOMAIN__/${proxy_domain}/g" "${source}" > "${rendered}"
    install -o root -g root -m "${mode}" "${rendered}" "${target}"
    rm -f -- "${rendered}"
  }
  install_nginx_template "${nginx_template}" "${nginx_site}" 0644
  install_nginx_template "${repo_root}/deploy/cloud/nginx/trend-exploring-proxy.conf" /etc/nginx/snippets/trend-exploring-proxy.conf 0644
  install_nginx_template "${repo_root}/deploy/cloud/nginx/trend-exploring-proxy-short.conf" /etc/nginx/snippets/trend-exploring-proxy-short.conf 0644
  install_nginx_template "${repo_root}/deploy/cloud/nginx/trend-exploring-proxy-login.conf" /etc/nginx/snippets/trend-exploring-proxy-login.conf 0644
  if [[ -e "${nginx_link}" && ! -L "${nginx_link}" && "${replace_config}" != 1 ]]; then
    warn "preserving existing non-symlink ${nginx_link}; enable the managed site manually"
  elif [[ -L "${nginx_link}" && "$(readlink -- "${nginx_link}")" != "${nginx_site}" && "${replace_config}" != 1 ]]; then
    warn "preserving existing nginx site link ${nginx_link}; pass --replace-config only after review"
  else
    run ln -sfn "${nginx_site}" "${nginx_link}"
  fi
  if [[ -r "${nginx_certificate}" && -r "${nginx_key}" ]]; then
    warn "Nginx TLS site prepared for ${proxy_domain}; run nginx -t and reload"
  else
    warn "Nginx HTTP bootstrap prepared for ${proxy_domain}; issue its certificate, then rerun with --replace-config"
  fi
fi
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
if [[ "${proxy}" == "nginx" ]]; then run systemctl enable nginx; fi
for unit in trend-exploring-server.service trend-exploring-collect.timer trend-exploring-cycle.timer trend-exploring-translation.timer; do
  run systemctl enable "${unit}"
done
if ((enable_migrations)); then run systemctl enable trend-exploring-migration.timer; fi
if ((enable_backups)); then
  run systemctl enable trend-exploring-backup.timer
  warn "backup timer enabled by request; verify GPG recipient and run a disposable restore"
fi

printf 'cloud install prepared (services were not started)\n'
