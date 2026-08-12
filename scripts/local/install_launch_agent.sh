#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="com.trendexploring.local-cycle"
server_label="com.trendexploring.local-server"
collect_label="com.trendexploring.local-collect"
agent_dir="${LOCAL_LAUNCH_AGENT_DIR:-${HOME:-/tmp}/Library/LaunchAgents}"
plist="${agent_dir}/${label}.plist"
server_plist="${agent_dir}/${server_label}.plist"
collect_plist="${agent_dir}/${collect_label}.plist"
state_dir="${LOCAL_STATE_DIR:-${HOME:-/tmp}/Library/Application Support/TrendExploring}"
mkdir -p "${agent_dir}" "${state_dir}/logs"

# launchd may start after the checkout is moved, or with a cwd that is not
# traversable (notably a localized Documents path).  Keep a small, atomic
# runtime copy in the user-owned state directory.  It contains no tests,
# evidence, git metadata, .env files, or credentials.
app_dir="${state_dir}/app"
app_stage="${state_dir}/app.next.$$"
mkdir -p "${app_stage}"
for component in app config lib schema scripts; do
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.env*' --exclude 'evidence' --exclude 'test' "${project_root}/${component}/" "${app_stage}/${component}/"
  else
    mkdir -p "${app_stage}/${component}"
    cp -R "${project_root}/${component}/." "${app_stage}/${component}/"
    find "${app_stage}/${component}" -name '.env*' -type f -delete
  fi
done
find "${app_stage}" -type f -name '.env*' -delete
find "${app_stage}" -type d \( -name test -o -name evidence \) -prune -exec rm -rf {} +
chmod -R u+rwX,go-rwx "${app_stage}"
previous_dir="${state_dir}/app.previous"
if [[ -d "${app_dir}" ]]; then
  rm -rf "${previous_dir}"
  mv "${app_dir}" "${previous_dir}"
fi
mv "${app_stage}" "${app_dir}"
cycle_wrapper="${app_dir}/scripts/local/run_launchd_cycle.sh"
server_wrapper="${app_dir}/scripts/local/run_launchd_server.sh"
collect_wrapper="${app_dir}/scripts/local/run_launchd_collect.sh"

cat > "${plist}.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array><string>${cycle_wrapper}</string></array>
  <key>StartCalendarInterval</key><array>
    <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>5</integer></dict>
    <dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>5</integer></dict>
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${state_dir}/logs/cycle.log</string>
  <key>StandardErrorPath</key><string>${state_dir}/logs/cycle.error.log</string>
  <key>WorkingDirectory</key><string>${app_dir}</string>
</dict></plist>
EOF
chmod 700 "${cycle_wrapper}" "${server_wrapper}" "${collect_wrapper}"
mv "${plist}.tmp" "${plist}"
cat > "${server_plist}.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${server_label}</string>
  <key>ProgramArguments</key><array><string>${server_wrapper}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${state_dir}/logs/server.log</string>
  <key>StandardErrorPath</key><string>${state_dir}/logs/server.error.log</string>
  <key>WorkingDirectory</key><string>${app_dir}</string>
</dict></plist>
EOF
mv "${server_plist}.tmp" "${server_plist}"
cat > "${collect_plist}.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${collect_label}</string>
  <key>ProgramArguments</key><array><string>${collect_wrapper}</string></array>
  <key>StartCalendarInterval</key><array>
    <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>55</integer></dict>
    <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>55</integer></dict>
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${state_dir}/logs/collect.log</string>
  <key>StandardErrorPath</key><string>${state_dir}/logs/collect.error.log</string>
  <key>WorkingDirectory</key><string>${app_dir}</string>
</dict></plist>
EOF
mv "${collect_plist}.tmp" "${collect_plist}"
if [[ "${LOCAL_SKIP_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "${plist}" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "${server_plist}" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "${collect_plist}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "${plist}"
  launchctl bootstrap "gui/$(id -u)" "${server_plist}"
  launchctl bootstrap "gui/$(id -u)" "${collect_plist}"
fi
# On macOS, plutil validates the generated launchd topology without loading
# secrets or making network calls.  Non-macOS environments still receive the
# deterministic plist files for review.
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${plist}" "${server_plist}" "${collect_plist}" >/dev/null
fi
printf '%s\n' "${plist}" "${server_plist}" "${collect_plist}"
