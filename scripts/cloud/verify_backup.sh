#!/usr/bin/env bash
# Read-only verification of an encrypted two-database backup. It does not
# decrypt, drop, or restore a database.
set -Eeuo pipefail

backup_dir="${1:-}"
[[ -n "${backup_dir}" && -d "${backup_dir}" ]] || { echo "usage: verify_backup.sh BACKUP_DIR" >&2; exit 2; }
manifest="${backup_dir}/manifest.json"
[[ -r "${manifest}" ]] || { echo "backup verification failed: manifest missing" >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo "backup verification failed: ruby is missing" >&2; exit 78; }
command -v sha256sum >/dev/null 2>&1 || { echo "backup verification failed: sha256sum is missing" >&2; exit 78; }
command -v gpg >/dev/null 2>&1 || { echo "backup verification failed: gpg is missing" >&2; exit 78; }

files=()
while IFS= read -r item; do files+=("${item}"); done < <(ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "manifest is not encrypted" unless value.fetch("encrypted") == true
  db = value.fetch("databases")
  abort "manifest must contain global and personal" unless db.key?("global") && db.key?("personal")
  db.values.each { |entry| puts [entry.fetch("file"), entry.fetch("sha256")].join("\t") }
' "${manifest}")
[[ "${#files[@]}" == 2 ]] || { echo "backup verification failed: manifest database count" >&2; exit 1; }
for item in "${files[@]}"; do
  file="${item%%$'\t'*}"
  expected="${item#*$'\t'}"
  [[ "${file}" != */* && "${file}" != .* ]] || { echo "backup verification failed: unsafe manifest path" >&2; exit 1; }
  actual="$(sha256sum "${backup_dir}/${file}" | awk '{ print $1 }')"
  [[ "${actual}" == "${expected}" ]] || { echo "backup verification failed: checksum mismatch" >&2; exit 1; }
  gpg --batch --list-packets "${backup_dir}/${file}" >/dev/null 2>&1 || { echo "backup verification failed: invalid encrypted packet" >&2; exit 1; }
done
echo "encrypted global+personal backup verified (no restore performed)"
