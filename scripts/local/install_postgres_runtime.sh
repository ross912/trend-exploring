#!/usr/bin/env bash
set -euo pipefail

# Install/reuse the exact PostgreSQL source version used by the local product.
# The archive is verified before extraction; no unverified executable is used.
version="15.18"
sha256="11df0df97fe3ea4ba9a791faaf39cee1d2fe571e78885b5b55d8517d27c323b4"
url="https://ftp.postgresql.org/pub/source/v${version}/postgresql-${version}.tar.bz2"
user_home="${HOME:-/tmp}"
if [[ -n "${LOCAL_STATE_DIR:-}" ]]; then
  state_dir="${LOCAL_STATE_DIR}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  state_dir="${user_home}/Library/Application Support/TrendExploring"
else
  state_dir="${XDG_STATE_HOME:-${user_home}/.local/state}/trend-exploring"
fi
runtime_dir="${LOCAL_PG_RUNTIME_DIR:-${state_dir}/postgresql-${version}}"

if [[ "${1:-}" == "--print-bin" ]]; then
  if [[ -n "${PG_BIN:-}" ]]; then
    printf '%s\n' "${PG_BIN}"
    exit 0
  fi
  if command -v pg_config >/dev/null 2>&1; then
    system_bin="$(pg_config --bindir 2>/dev/null || true)"
    if [[ -x "${system_bin}/pg_ctl" && -x "${system_bin}/initdb" && -x "${system_bin}/psql" ]]; then
      printf '%s\n' "${system_bin}"
      exit 0
    fi
  fi
  printf '%s\n' "${runtime_dir}/bin"
  exit 0
fi

if [[ -n "${PG_BIN:-}" ]]; then
  pg_bin="${PG_BIN}"
  for command_name in pg_config pg_ctl initdb psql createdb pg_dump pg_restore; do
    [[ -x "${pg_bin}/${command_name}" ]] || { echo "PG_BIN lacks ${command_name}: ${pg_bin}" >&2; exit 1; }
  done
  printf '%s\n' "${pg_bin}"
  exit 0
fi

if command -v pg_config >/dev/null 2>&1; then
  system_bin="$(pg_config --bindir 2>/dev/null || true)"
  if [[ -x "${system_bin}/pg_ctl" && -x "${system_bin}/initdb" && -x "${system_bin}/psql" && -x "${system_bin}/createdb" && -x "${system_bin}/pg_dump" && -x "${system_bin}/pg_restore" ]]; then
    printf '%s\n' "${system_bin}"
    exit 0
  fi
fi

if [[ -x "${runtime_dir}/bin/pg_ctl" && -x "${runtime_dir}/bin/initdb" && -x "${runtime_dir}/bin/psql" && -x "${runtime_dir}/bin/createdb" && -x "${runtime_dir}/bin/pg_dump" && -x "${runtime_dir}/bin/pg_restore" ]]; then
  printf '%s\n' "${runtime_dir}/bin"
  exit 0
fi

for required in curl tar make; do
  command -v "${required}" >/dev/null 2>&1 || { echo "required build tool missing: ${required}" >&2; exit 1; }
done
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "required checksum tool missing: shasum or sha256sum" >&2
  exit 1
fi
command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || { echo "C compiler missing (gcc or clang)" >&2; exit 1; }

archive_dir="${runtime_dir}/archives"
archive="${archive_dir}/postgresql-${version}.tar.bz2"
mkdir -p "${state_dir}"
mkdir -p "${archive_dir}"
verify_archive() {
  local actual
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  else
    actual="$(sha256sum "${archive}" | awk '{print $1}')"
  fi
  [[ "${actual}" == "${sha256}" ]]
}
if [[ ! -f "${archive}" ]] || ! verify_archive; then
  rm -f "${archive}"
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --output "${archive}.part" "${url}"
  mv "${archive}.part" "${archive}"
  verify_archive || { echo "SHA256 verification failed for ${url}" >&2; rm -f "${archive}"; exit 1; }
fi

build_root="$(mktemp -d "${state_dir}/postgres-build.XXXXXX")"
cleanup() { rm -rf "${build_root}"; }
trap cleanup EXIT
tar -xjf "${archive}" -C "${build_root}"
source_dir="${build_root}/postgresql-${version}"
mkdir -p "${runtime_dir}"
pushd "${source_dir}" >/dev/null
./configure --prefix="${runtime_dir}" --without-readline --without-zlib --without-icu >/dev/null
make -j"${LOCAL_PG_BUILD_JOBS:-2}" >/dev/null
make install >/dev/null
popd >/dev/null

for command_name in pg_config pg_ctl initdb psql createdb pg_dump pg_restore; do
  [[ -x "${runtime_dir}/bin/${command_name}" ]] || { echo "PostgreSQL build missing ${command_name}" >&2; exit 1; }
done
printf '%s\n' "${runtime_dir}/bin"
