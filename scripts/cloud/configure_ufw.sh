#!/usr/bin/env bash
# Firewall changes are opt-in. Without --confirm this script is a dry plan.
set -Eeuo pipefail

confirm=0
dry_run=0
while (($#)); do
  case "$1" in
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h)
      echo "Usage: configure_ufw.sh [--dry-run] [--confirm]"
      exit 0
      ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if ((dry_run || !confirm)); then
  cat <<'PLAN'
UFW plan (no changes made):
  default deny incoming
  default allow outgoing
  allow 22/tcp (SSH)
  allow 80/tcp (HTTP redirect/challenge)
  allow 443/tcp (HTTPS)
  enable UFW
Pass --confirm on the VPS after verifying the current SSH session and provider console.
PLAN
  exit 0
fi

[[ "${EUID}" == 0 ]] || { echo "ERROR: firewall configuration requires root" >&2; exit 1; }
command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw is not installed" >&2; exit 1; }
current_rules="$(ufw status 2>/dev/null || true)"
unexpected_rules="$(printf '%s\n' "${current_rules}" | awk '/ALLOW/ && $1 !~ /^(22|80|443)\/tcp$/ { print }' | sed '/^[[:space:]]*$/d')"
if [[ -n "${unexpected_rules}" ]]; then
  echo "ERROR: unexpected existing UFW ALLOW rule(s); refusing automatic deletion" >&2
  printf '%s\n' "${unexpected_rules}" >&2
  echo "Review with 'ufw status numbered', remove rules manually if intended, then re-run with --confirm." >&2
  exit 78
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP TLS challenge/redirect'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw status verbose
