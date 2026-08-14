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

# Deployment is fail-closed by default.  A checkout/app copy is never
# switched while a collection/cycle/server process or a live summary lease
# may still be using the previous copy.  The override is intentionally
# explicit and named for human disaster recovery; it is not a normal restart
# path and is never inferred from LOCAL_SKIP_LAUNCHCTL.
disaster_override="${LOCAL_DEPLOY_DISASTER_RECOVERY:-${LOCAL_FORCE_DEPLOY:-0}}"
lock_root="${state_dir}/locks"
deploy_lock="${state_dir}/deploy.lock"
preflight_fail() {
  echo "install_launch_agent: refusing deployment: $*" >&2
  echo "install_launch_agent: use LOCAL_DEPLOY_DISASTER_RECOVERY=1 only for an explicit human disaster recovery" >&2
  exit 75
}

mkdir -p "${lock_root}"
if [[ "${disaster_override}" != "1" ]]; then
  [[ ! -e "${deploy_lock}" ]] || preflight_fail "deployment lock is active (${deploy_lock})"
else
  # An orphaned deployment lock is recoverable only under the explicit
  # override.  The target is an exact product-owned path, never a broad
  # directory or workspace.
  rm -rf "${deploy_lock}"
fi
if ! mkdir "${deploy_lock}" 2>/dev/null; then
  preflight_fail "another deployment is active (${deploy_lock})"
fi
printf '%s\n' "$$" > "${deploy_lock}/pid"
cleanup_deploy_lock() { rm -rf "${deploy_lock}"; }
trap cleanup_deploy_lock EXIT INT TERM

if [[ "${disaster_override}" != "1" ]]; then
  active_processes="$(pgrep -f 'run_launchd_(collect|cycle|server)\.sh' 2>/dev/null || true)"
  [[ -z "${active_processes}" ]] || preflight_fail "active launchd process detected (pids: ${active_processes//$'\n'/ })"
  for active_lock in "${lock_root}/collect.lock" "${lock_root}/cycle.lock" "${lock_root}/server.lock"; do
    [[ ! -e "${active_lock}" ]] || preflight_fail "active runtime lock detected (${active_lock})"
  done

  # Query only the local PostgreSQL socket.  If a configured client exists but
  # the database cannot be inspected, unknown state is unsafe and blocks the
  # app switch.  Environments without a local client (for example a static
  # plist lint) retain the historical no-database install behavior.
  summary_psql="${LOCAL_PSQL:-}"
  if [[ -z "${summary_psql}" && -n "${PG_BIN:-}" ]]; then summary_psql="${PG_BIN}/psql"; fi
  if [[ -z "${summary_psql}" ]]; then summary_psql="${project_root}/.runtime/bin/psql"; fi
  summary_pgdata="${LOCAL_PGDATA:-${state_dir}/postgres}"
  # A static plist install may be run before the local runtime has ever been
  # initialized (the normal first-run path).  In that case there is no
  # summary database to inspect yet; once PG_VERSION exists, an unavailable
  # query is unsafe and fail-closed.  Operators can require the probe even
  # before initialization with LOCAL_PREFLIGHT_REQUIRE_DB=1.
  if [[ -x "${summary_psql}" && ( -f "${summary_pgdata}/PG_VERSION" || "${LOCAL_PREFLIGHT_REQUIRE_DB:-0}" == "1" ) ]]; then
    summary_host="${LOCAL_PGHOST:-${LOCAL_PGSOCKET:-${state_dir}/socket}}"
    summary_port="${LOCAL_PGPORT:-55433}"
    summary_user="${LOCAL_PGUSER:-${USER:-postgres}}"
    summary_database="${LOCAL_PGDATABASE:-trend_exploring_local}"
    relation_state="$(PGCONNECT_TIMEOUT=2 "${summary_psql}" -XAtq -w -h "${summary_host}" -p "${summary_port}" -U "${summary_user}" -d "${summary_database}" -c "SELECT to_regclass('local_report_summary_run') IS NOT NULL" 2>/dev/null || true)"
    [[ -n "${relation_state}" ]] || preflight_fail "summary run state is unavailable from local database"
    if [[ "${relation_state}" == "t" ]]; then
      lease_columns="$(PGCONNECT_TIMEOUT=2 "${summary_psql}" -XAtq -w -h "${summary_host}" -p "${summary_port}" -U "${summary_user}" -d "${summary_database}" -c "SELECT COUNT(*) = 3 FROM information_schema.columns WHERE table_schema='public' AND table_name='local_report_summary_run' AND column_name IN ('lease_owner','lease_expires_at','heartbeat_at')" 2>/dev/null || true)"
      [[ -n "${lease_columns}" ]] || preflight_fail "summary lease schema state is unavailable"
      if [[ "${lease_columns}" == "t" ]]; then
        running_summary="$(PGCONNECT_TIMEOUT=2 "${summary_psql}" -XAtq -w -h "${summary_host}" -p "${summary_port}" -U "${summary_user}" -d "${summary_database}" -c "SELECT run_id FROM local_report_summary_run WHERE state='running' AND lease_expires_at > now() ORDER BY started_at, run_id" 2>/dev/null || true)"
      else
        running_summary="$(PGCONNECT_TIMEOUT=2 "${summary_psql}" -XAtq -w -h "${summary_host}" -p "${summary_port}" -U "${summary_user}" -d "${summary_database}" -c "SELECT run_id FROM local_report_summary_run WHERE state='running' AND started_at > now() - interval '20 minutes' ORDER BY started_at, run_id" 2>/dev/null || true)"
      fi
      [[ -z "${running_summary}" ]] || preflight_fail "non-expired summary run is active (run ids: ${running_summary//$'\n'/ })"
    fi
  fi
fi

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
