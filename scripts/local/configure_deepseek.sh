#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_dir="${LOCAL_STATE_DIR:-${HOME:-/tmp}/Library/Application Support/TrendExploring}"
secret_dir="${LOCAL_SECRETS_DIR:-${state_dir}/secrets}"
secret_file="${DEEPSEEK_API_KEY_FILE:-${secret_dir}/deepseek_api_key}"
mkdir -p "${secret_dir}"
chmod 700 "${secret_dir}"

if [[ -t 0 ]]; then
  printf 'DeepSeek API Key（输入不会回显）: ' >&2
  IFS= read -r -s key
  printf '\n' >&2
else
  IFS= read -r key
fi
key="${key//$'\r'/}"
[[ -n "${key}" ]] || { echo "API Key 不能为空" >&2; exit 1; }
umask 077
tmp="${secret_file}.tmp.$$"
printf '%s\n' "${key}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${secret_file}"
printf 'DeepSeek 凭据已写入 %s（权限 600，不进入 Git、数据库或备份）\n' "${secret_file}"
