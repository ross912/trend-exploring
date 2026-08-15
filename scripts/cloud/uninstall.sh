#!/usr/bin/env bash
# Idempotent uninstall of service wiring. Data, encrypted backups, releases,
# and /etc/trend-exploring secrets are retained unless separately removed.
set -Eeuo pipefail

confirm=0
dry_run=0
remove_user=0
while (($#)); do
  case "$1" in
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --remove-user) remove_user=1; shift ;;
    --help|-h) echo "Usage: uninstall.sh [--dry-run] [--confirm] [--remove-user]"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if ((dry_run || !confirm)); then
  cat <<'PLAN'
uninstall plan (no changes made): stop/disable trend-exploring units, remove
their unit files and Caddy/logrotate wiring; keep /etc/trend-exploring,
/var/lib/trend-exploring, /var/backups/trend-exploring, and releases.
Pass --confirm on the VPS. --remove-user additionally deletes the dedicated
service account after services are stopped.
PLAN
  exit 0
fi
[[ "${EUID}" == 0 ]] || { echo "ERROR: uninstall requires root" >&2; exit 1; }
units=(trend-exploring-server.service trend-exploring-collect.timer trend-exploring-cycle.timer trend-exploring-translation.timer trend-exploring-migration.timer trend-exploring-backup.timer trend-exploring-backup.service)
for unit in "${units[@]}"; do systemctl disable --now "${unit}" 2>/dev/null || true; done
for unit in "${units[@]}"; do rm -f -- "/etc/systemd/system/${unit}"; done
rm -f -- /etc/logrotate.d/trend-exploring /usr/local/libexec/trend-exploring/run_server.sh /usr/local/libexec/trend-exploring/run_collect.sh /usr/local/libexec/trend-exploring/run_cycle.sh /usr/local/libexec/trend-exploring/run_translation.sh /usr/local/libexec/trend-exploring/run_migration.sh /usr/local/libexec/trend-exploring/run_backup.sh /usr/local/libexec/trend-exploring/run_as_app_user.sh /usr/local/libexec/trend-exploring/migrate.sh /usr/local/libexec/trend-exploring/backup.sh /usr/local/libexec/trend-exploring/verify_backup.sh /usr/local/libexec/trend-exploring/restore_backup.sh /usr/local/libexec/trend-exploring/bootstrap_postgresql.sh /usr/local/libexec/trend-exploring/configure_ufw.sh /usr/local/libexec/trend-exploring/configure_swap.sh /usr/local/libexec/trend-exploring/preflight_ubuntu.sh /usr/local/libexec/trend-exploring/verify_postgresql.sh /usr/local/libexec/trend-exploring/lib/runtime.sh
systemctl daemon-reload
if ((remove_user)); then userdel trendexploring 2>/dev/null || true; fi
echo "cloud service wiring removed; data and secrets retained"
