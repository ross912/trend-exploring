#!/usr/bin/env bash
# Add a bounded 1-2 GiB swapfile only after explicit confirmation.
set -Eeuo pipefail

size="2G"
confirm=0
dry_run=0
swapfile="${CLOUD_SWAPFILE:-/swapfile}"
while (($#)); do
  case "$1" in
    --size) size="${2:?--size needs 1G or 2G}"; shift 2 ;;
    --confirm) confirm=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) echo "Usage: configure_swap.sh [--size 1G|2G] [--dry-run] [--confirm]"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done
[[ "${size}" == 1G || "${size}" == 2G ]] || { echo "ERROR: swap size must be 1G or 2G" >&2; exit 2; }

if ((dry_run || !confirm)); then
  printf 'swap plan (no changes made): %s at %s, idempotent fstab entry\n' "${size}" "${swapfile}"
  echo 'Pass --confirm on the VPS after checking disk space and provider recovery access.'
  exit 0
fi

[[ "${EUID}" == 0 ]] || { echo "ERROR: swap configuration requires root" >&2; exit 1; }
command -v swapon >/dev/null 2>&1 || { echo "ERROR: swapon is unavailable" >&2; exit 1; }
if awk 'NR > 1 { print $1 }' /proc/swaps | grep -Fxq "${swapfile}"; then
  echo "swap already active at ${swapfile}"
  exit 0
fi
if [[ -e "${swapfile}" ]]; then
  echo "ERROR: ${swapfile} exists but is not an active swap device; refusing overwrite" >&2
  exit 1
fi
free_kib="$(df -Pk "$(dirname -- "${swapfile}")" | awk 'NR == 2 { print $4; exit }')"
required_kib=$([[ "${size}" == 2G ]] && echo 2097152 || echo 1048576)
((free_kib >= required_kib)) || { echo "ERROR: insufficient free space for ${size}" >&2; exit 1; }
fallocate -l "${size}" "${swapfile}"
chmod 600 "${swapfile}"
mkswap "${swapfile}" >/dev/null
swapon "${swapfile}"
if ! grep -Fqx "${swapfile} none swap sw 0 0" /etc/fstab; then
  printf '%s\n' "${swapfile} none swap sw 0 0" >> /etc/fstab
fi
swapon --show
