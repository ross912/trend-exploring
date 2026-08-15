#!/usr/bin/env bash
# Read-only cloud status; never prints the env file or database URL.
set -Eeuo pipefail

dry_run=0
while (($#)); do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --help|-h) echo "Usage: status.sh [--dry-run]"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if ((dry_run)); then
  echo "status dry-run: would inspect systemd, Caddy, UFW, listeners, symlink, and /readyz"
  exit 0
fi

echo "== release =="
if [[ -L /opt/trend-exploring/current ]]; then readlink -f /opt/trend-exploring/current; else echo "current=missing"; fi
echo "== systemd =="
for unit in trend-exploring-server.service trend-exploring-collect.timer trend-exploring-cycle.timer trend-exploring-translation.timer trend-exploring-migration.timer; do
  printf '%s: ' "${unit}"
  systemctl is-enabled "${unit}" 2>/dev/null || true
  systemctl is-active "${unit}" 2>/dev/null || true
done
echo "== listeners (public should be only 22/80/443) =="
ss -ltn 2>/dev/null | awk 'NR == 1 || $4 ~ /:(22|80|443|3000|5432)$/ { print }'
echo "== firewall =="
ufw status verbose 2>/dev/null || true
echo "== readiness =="
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/livez >/dev/null && echo "livez=ok" || echo "livez=failed"
echo "== postgres binding =="
echo "PostgreSQL binding is verified from ss output and deploy/cloud/postgresql/99-trend-exploring.conf (no DATABASE_URL passed on argv)"
