#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release is unavailable; expected an Ubuntu server." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "ERROR: expected Ubuntu, found ${ID:-unknown}." >&2
  exit 1
fi

echo "OS=${PRETTY_NAME:-unknown}"
echo "ARCH=$(uname -m)"
echo "CPUS=$(getconf _NPROCESSORS_ONLN)"
awk '/MemTotal/ { printf "MEMORY_KIB=%s\n", $2 }' /proc/meminfo
awk '/SwapTotal/ { printf "SWAP_KIB=%s\n", $2 }' /proc/meminfo
df -Pk / | awk 'NR == 2 { printf "ROOT_FREE_KIB=%s\n", $4 }'

if command -v psql >/dev/null 2>&1; then
  echo "PSQL=$(psql --version)"
else
  echo "PSQL=missing"
fi

if command -v postgres >/dev/null 2>&1; then
  echo "POSTGRES=$(postgres --version)"
else
  echo "POSTGRES=missing"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active postgresql 2>/dev/null || true
fi

echo "PREFLIGHT COMPLETE"
