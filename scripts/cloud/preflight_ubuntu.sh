#!/usr/bin/env bash
# Read-only Ubuntu 24.04 and runtime preflight. No system changes are made.
set -Eeuo pipefail

release_root=""
json_output=0
strict=0
cloud_env_file="${CLOUD_ENV_FILE:-/etc/trend-exploring/trend-exploring.env}"
while (($#)); do
  case "$1" in
    --release-root) release_root="${2:?--release-root needs a path}"; shift 2 ;;
    --json) json_output=1; shift ;;
    --strict) strict=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: preflight_ubuntu.sh [--release-root PATH] [--json] [--strict]
Read-only checks for Ubuntu 24.04, Ruby/WEBrick, PostgreSQL, memory and disk.
USAGE
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

error_count=0
warn_count=0
report() {
  local key="$1" value="$2"
  if ((json_output)); then
    printf '%s\t%s\n' "${key}" "${value}"
  else
    printf '%s=%s\n' "${key}" "${value}"
  fi
}
error() { printf 'ERROR: %s\n' "$*" >&2; error_count=$((error_count + 1)); }
warning() { printf 'WARN: %s\n' "$*" >&2; warn_count=$((warn_count + 1)); }
capacity_gate() {
  if ((strict)); then error "$*"; else warning "$*"; fi
}

if [[ -r "${cloud_env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cloud_env_file}"
else
  warning "cloud env file is missing: ${cloud_env_file}"
fi
if [[ "${CLOUD_PUBLIC_DEPLOYMENT:-0}" != "1" ]]; then error "CLOUD_PUBLIC_DEPLOYMENT=1 is required"; fi
if [[ "${PUBLIC_UNAUTHENTICATED_MODE:-0}" != "0" ]]; then error "PUBLIC_UNAUTHENTICATED_MODE must be 0"; fi
if [[ "${AUTH_REQUIRED_FOR_APP:-0}" != "1" ]]; then error "AUTH_REQUIRED_FOR_APP=1 is required"; fi
if [[ "${AUTH_MODE:-required}" != "required" ]]; then error "AUTH_MODE=required is required"; fi
if [[ -z "${CLOUD_IDENTITY_PEPPER:-}" ]]; then error "CLOUD_IDENTITY_PEPPER must be provisioned outside the repository"; fi
if [[ -z "${CLOUD_SESSION_PEPPER:-}" ]]; then error "CLOUD_SESSION_PEPPER must be provisioned outside the repository"; fi
if [[ "${BIND_ADDRESS:-127.0.0.1}" != "127.0.0.1" && "${BIND_ADDRESS:-127.0.0.1}" != "::1" ]]; then error "BIND_ADDRESS must be loopback"; fi
trusted_proxy_cidrs="${TRUSTED_PROXY_CIDRS:-}"
if [[ -z "${trusted_proxy_cidrs}" ]]; then
  error "TRUSTED_PROXY_CIDRS must contain 127.0.0.1/32 and ::1/128"
else
  IFS=',' read -r -a trusted_proxy_values <<< "${trusted_proxy_cidrs}"
  for trusted_proxy in "${trusted_proxy_values[@]}"; do
    case "${trusted_proxy}" in
      127.0.0.1/32|::1/128) ;;
      *) error "TRUSTED_PROXY_CIDRS must be loopback-only (found ${trusted_proxy})";;
    esac
  done
fi
if [[ "${PUBLISH_API_ENABLED:-1}" != "0" ]]; then error "PUBLISH_API_ENABLED must be 0"; fi
pg_role="${CLOUD_PG_ROLE:-${LOCAL_PGUSER:-}}"
pg_global_db="${CLOUD_PG_GLOBAL_DATABASE:-${LOCAL_PGDATABASE:-}}"
pg_personal_db="${CLOUD_PG_PERSONAL_DATABASE:-${PERSONAL_PGDATABASE:-}}"
report CLOUD_PG_ROLE "${pg_role:-missing}"
report CLOUD_PG_GLOBAL_DATABASE "${pg_global_db:-missing}"
report CLOUD_PG_PERSONAL_DATABASE "${pg_personal_db:-missing}"
[[ "${pg_role}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "CLOUD_PG_ROLE must be a safe identifier"
[[ "${pg_global_db}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "global database name must be a safe identifier"
[[ "${pg_personal_db}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "personal database name must be a safe identifier"
[[ "${pg_global_db}" != "${pg_personal_db}" ]] || error "global and personal database names must differ"

if command -v ufw >/dev/null 2>&1; then
  ufw_snapshot="$(ufw status 2>/dev/null || true)"
  ufw_state="$(printf '%s\n' "${ufw_snapshot}" | awk -F': ' '/^Status:/ { print $2; exit }')"
  report UFW_STATUS "${ufw_state:-unknown}"
  unexpected_ufw="$(printf '%s\n' "${ufw_snapshot}" | awk '
    /ALLOW/ && $1 !~ /^(22|80|443)\/tcp$/ { print }
  ' | sed '/^[[:space:]]*$/d')"
  if [[ -n "${unexpected_ufw}" ]]; then
    error "UFW has unexpected ALLOW rules; remove them manually after reviewing the SSH session"
    printf 'UFW_UNEXPECTED_ALLOW_RULE: %s\n' "${unexpected_ufw}" >&2
  fi
else
  warning "ufw is missing; firewall cannot be audited"
fi

if [[ ! -r /etc/os-release ]]; then
  error "/etc/os-release is unavailable; expected Ubuntu 24.04"
else
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || error "expected Ubuntu, found ${ID:-unknown}"
  if [[ "${VERSION_ID:-}" != "24.04" ]]; then warning "expected Ubuntu 24.04, found ${VERSION_ID:-unknown}"; fi
  report OS "${PRETTY_NAME:-unknown}"
fi

report ARCH "$(uname -m)"
report CPUS "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"
mem_kib="$(awk '/MemTotal/ { print $2; exit }' /proc/meminfo 2>/dev/null || printf 0)"
swap_kib="$(awk '/SwapTotal/ { print $2; exit }' /proc/meminfo 2>/dev/null || printf 0)"
root_free_kib="$(df -Pk / | awk 'NR == 2 { print $4; exit }')"
root_used_percent="$(df -Pk / | awk 'NR == 2 { gsub(/%/, "", $5); print $5; exit }')"
report MEMORY_KIB "${mem_kib:-0}"
report SWAP_KIB "${swap_kib:-0}"
report ROOT_FREE_KIB "${root_free_kib:-0}"
report ROOT_USED_PERCENT "${root_used_percent:-unknown}"
if (( ${mem_kib:-0} < 1572864 )); then capacity_gate "MemTotal is below 1.5 GiB"; fi
if (( ${swap_kib:-0} < 1048576 )); then capacity_gate "SwapTotal is below 1 GiB; configure 1-2 GiB swap before production"; fi
if (( ${root_free_kib:-0} < 10485760 )); then capacity_gate "root filesystem has less than 10 GiB free"; fi
if [[ "${root_used_percent:-100}" =~ ^[0-9]+$ ]] && (( root_used_percent >= 75 )); then capacity_gate "root filesystem usage is >= 75%"; fi

if command -v ruby >/dev/null 2>&1; then
  ruby_version="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || printf unknown)"
  report RUBY "${ruby_version}"
  if ruby -e 'parts = RUBY_VERSION.split(".").map(&:to_i); exit(parts[0] > 3 || (parts[0] == 3 && parts[1] >= 1) ? 0 : 1)' 2>/dev/null; then :; else error "Ruby >= 3.1 is required (found ${ruby_version})"; fi
  webrick_version="$(ruby -rwebrick -e 'print(defined?(WEBrick::VERSION) ? WEBrick::VERSION : "unknown")' 2>/dev/null || true)"
  if [[ -z "${webrick_version}" ]]; then
    error "WEBrick is unavailable; install the locked runtime dependency"
  else
    report WEBRICK "${webrick_version}"
    required_webrick="${CLOUD_WEBRICK_VERSION:-1.8.1}"
    [[ "${webrick_version}" == "${required_webrick}" ]] || error "WEBrick ${required_webrick} is required (found ${webrick_version})"
  fi
else
  error "Ruby is not installed"
fi

if command -v psql >/dev/null 2>&1; then report PSQL "$(psql --version)"; else warning "psql is missing"; fi
if command -v postgres >/dev/null 2>&1; then report POSTGRES "$(postgres --version)"; else warning "postgres is missing"; fi
if command -v systemctl >/dev/null 2>&1; then report SYSTEMD_POSTGRES "$(systemctl is-active postgresql 2>/dev/null || true)"; fi

if [[ -n "${release_root}" ]]; then
  [[ -d "${release_root}" ]] || error "release root does not exist: ${release_root}"
  [[ -r "${release_root}/config/cloud/trend-exploring.env.example" || -r "${release_root}/config/cloud/trend-exploring.env" ]] || warning "cloud env template is missing from release"
  [[ -x "${release_root}/scripts/cloud/bootstrap_postgresql.sh" ]] || warning "PostgreSQL bootstrap helper is missing from release"
fi

if ((strict && error_count > 0)); then exit 1; fi
report PREFLIGHT_ERRORS "${error_count}"
report PREFLIGHT_WARNINGS "${warn_count}"
echo "PREFLIGHT COMPLETE"
