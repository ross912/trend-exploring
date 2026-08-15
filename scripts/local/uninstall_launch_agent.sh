#!/usr/bin/env bash
set -euo pipefail

label="com.trendexploring.local-cycle"
server_label="com.trendexploring.local-server"
collect_label="com.trendexploring.local-collect"
translation_label="com.trendexploring.local-translation"
agent_dir="${LOCAL_LAUNCH_AGENT_DIR:-${HOME:-/tmp}/Library/LaunchAgents}"
plist="${agent_dir}/${label}.plist"
server_plist="${agent_dir}/${server_label}.plist"
collect_plist="${agent_dir}/${collect_label}.plist"
translation_plist="${agent_dir}/${translation_label}.plist"
if [[ "${LOCAL_SKIP_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "${plist}" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "${server_plist}" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "${collect_plist}" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "${translation_plist}" >/dev/null 2>&1 || true
fi
rm -f "${plist}" "${plist}.tmp" "${server_plist}" "${server_plist}.tmp" "${collect_plist}" "${collect_plist}.tmp" "${translation_plist}" "${translation_plist}.tmp"
printf '%s\n' "${plist}, ${server_plist}, ${collect_plist}, and ${translation_plist} removed"
