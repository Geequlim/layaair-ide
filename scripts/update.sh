#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/update.sh [--check-only] [--format plain|json]

Options:
  --check-only     Only detect whether an update is available.
  --format         Output format for --check-only. Defaults to plain.
  -h, --help       Show this help.
EOF
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

JSON_URL="https://ldc-1251285021.file.myqcloud.com/layaair/log/3.0/navConfig.json"

FORCE_TEST="${FORCE_TEST:-false}"
CACHE_DIR="${CACHE_DIR:-}"
CHECK_ONLY=false
OUTPUT_FORMAT="plain"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      ;;
    --format)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --format" >&2
        exit 1
      fi
      OUTPUT_FORMAT="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$OUTPUT_FORMAT" != "plain" && "$OUTPUT_FORMAT" != "json" ]]; then
  echo "Unsupported format: $OUTPUT_FORMAT" >&2
  exit 1
fi

print_detection_result() {
  local status="$1"
  local reason="$2"
  local current_ver="$3"
  local current_url="$4"
  local latest_name="$5"
  local latest_ver="$6"
  local latest_url="$7"
  local latest_date="$8"
  local needs_update="$9"
  local source_url="${10}"
  local source_hash="${11}"

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg status "$status" \
      --arg reason "$reason" \
      --arg current_ver "$current_ver" \
      --arg current_url "$current_url" \
      --arg latest_name "$latest_name" \
      --arg latest_ver "$latest_ver" \
      --arg latest_url "$latest_url" \
      --arg latest_date "$latest_date" \
      --arg source_url "$source_url" \
      --arg source_hash "$source_hash" \
      --arg force_test "$FORCE_TEST" \
      --argjson needs_update "$needs_update" \
      '{
        status: $status,
        reason: $reason,
        current_ver: $current_ver,
        current_url: $current_url,
        latest_name: $latest_name,
        latest_ver: $latest_ver,
        latest_url: $latest_url,
        latest_date: $latest_date,
        source_url: $source_url,
        source_hash: $source_hash,
        force_test: ($force_test == "true"),
        needs_update: $needs_update
      }'
    return
  fi

  cat <<EOF
status=${status}
reason=${reason}
needs_update=${needs_update}
current_ver=${current_ver}
current_url=${current_url}
latest_name=${latest_name}
latest_ver=${latest_ver}
latest_url=${latest_url}
latest_date=${latest_date}
source_url=${source_url}
source_hash=${source_hash}
force_test=${FORCE_TEST}
EOF
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cache_buster="$(date -u +%s)-$$"
separator='?'
if [[ "$JSON_URL" == *\?* ]]; then
  separator='&'
fi
source_url="${JSON_URL}${separator}_=${cache_buster}"

json=$(curl -fsSL \
  -H 'Cache-Control: no-cache, no-store, max-age=0' \
  -H 'Pragma: no-cache' \
  -H 'Expires: 0' \
  "$source_url")
source_hash="$(printf '%s' "$json" | sha256sum | awk '{print $1}')"
latest=$(printf '%s' "$json" | jq -cr 'map(select(.download["IDE for Linux(x64)"]? != null and .download["IDE for Linux(x64)"] != "")) | sort_by(.date) | last')

name=$(printf '%s' "$latest" | jq -r '.name')
date=$(printf '%s' "$latest" | jq -r '.date')
url=$(printf '%s' "$latest" | jq -r '.download["IDE for Linux(x64)"]')
url=$(printf '%s' "$url" | sed 's/[[:space:]]*$//')

if [[ -z "$latest" || "$latest" == "null" || -z "$name" || -z "$url" || "$name" == "null" || "$url" == "null" ]]; then
  echo "Failed to parse upstream metadata" >&2
  exit 1
fi

ver=$(printf '%s' "$name" | awk '{print $NF}')
if [[ -z "$ver" ]]; then
  echo "Failed to parse version from name: $name" >&2
  exit 1
fi

pkgver=${ver//-/_}

current_ver=$(sed -n 's/^_upstream_ver=//p' PKGBUILD || true)
current_url=$(sed -n 's/^_url=//p' PKGBUILD || true)
status="up-to-date"
reason="no_change"
needs_update=false

if [[ "$current_ver" != "$ver" || "$current_url" != "$url" ]]; then
  status="update-available"
  reason="upstream_changed"
  needs_update=true
elif [[ "$FORCE_TEST" == "true" ]]; then
  status="update-available"
  reason="force_test"
  needs_update=true
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  print_detection_result "$status" "$reason" "$current_ver" "$current_url" "$name" "$ver" "$url" "$date" "$needs_update" "$source_url" "$source_hash"
  exit 0
fi

echo "Detection result: status=${status}, reason=${reason}, current=${current_ver:-unknown}, latest=${ver}, source_hash=${source_hash}"

if [[ "$needs_update" != "true" ]]; then
  echo "Already up to date: ${ver}"
  exit 0
fi

if [[ "$reason" == "force_test" ]]; then
  echo "[FORCE_TEST] Upstream unchanged, but forcing refresh for CI test."
fi

# ---------- AppImage cache ----------
cached_appimage=""
if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
  # Use url hash as stable cache key
  url_hash="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  cached_appimage="${CACHE_DIR}/${url_hash}.AppImage"
fi

appimage="$workdir/LayaAirIDE.AppImage"

if [[ -n "$cached_appimage" && -s "$cached_appimage" ]]; then
  echo "Using cached AppImage: $cached_appimage"
  cp -f "$cached_appimage" "$appimage"
else
  echo "Downloading AppImage: $url"
  if ! curl --retry 3 --retry-all-errors --connect-timeout 30 -fL "$url" -o "$appimage"; then
    echo "Failed to download AppImage: $url" >&2
    exit 1
  fi
  if [[ -n "$cached_appimage" ]]; then
    cp -f "$appimage" "$cached_appimage"
    echo "Saved AppImage to cache: $cached_appimage"
  fi
fi
# -----------------------------------

sha256=$(sha256sum "$appimage" | awk '{print $1}')

sed -i "s/^_upstream_ver=.*/_upstream_ver=${ver}/" PKGBUILD
sed -i "s/^pkgver=.*/pkgver=${pkgver}/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
sed -i "s#^_url=.*#_url=${url}#" PKGBUILD
sed -i "s/^sha256sums=.*/sha256sums=('${sha256}')/" PKGBUILD

# Ensure FORCE_TEST runs produce a diff, without affecting packaging behavior.
if [[ "$FORCE_TEST" == "true" ]]; then
  ts="$(date -u +%Y%m%d%H%M%S)"
  if grep -q '^_force_test_ts=' PKGBUILD; then
    sed -i "s/^_force_test_ts=.*/_force_test_ts=${ts}/" PKGBUILD
  else
    sed -i "1i_force_test_ts=${ts}" PKGBUILD
  fi
fi

makepkg --printsrcinfo > .SRCINFO

echo "Updated to ${ver}"
