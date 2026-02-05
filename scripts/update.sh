#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

JSON_URL="https://ldc-1251285021.file.myqcloud.com/layaair/log/3.0/navConfig.json"

# Set FORCE_TEST=true (e.g. from workflow_dispatch) to force refresh even if version/url unchanged.
FORCE_TEST="${FORCE_TEST:-false}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

json=$(curl -fsSL "$JSON_URL")
latest=$(echo "$json" | jq -r 'max_by(.date)')

name=$(echo "$latest" | jq -r '.name')
url=$(echo "$latest" | jq -r '.download["IDE for Linux(x64)"]')
url=$(echo "$url" | sed 's/[[:space:]]*$//')

if [[ -z "$name" || -z "$url" || "$name" == "null" || "$url" == "null" ]]; then
  echo "Failed to parse upstream metadata" >&2
  exit 1
fi

ver=$(echo "$name" | awk '{print $NF}')
if [[ -z "$ver" ]]; then
  echo "Failed to parse version from name: $name" >&2
  exit 1
fi

pkgver=${ver//-/_}

current_ver=$(sed -n 's/^_upstream_ver=//p' PKGBUILD || true)
current_url=$(sed -n 's/^_url=//p' PKGBUILD || true)

if [[ "$current_ver" == "$ver" && "$current_url" == "$url" ]]; then
  if [[ "$FORCE_TEST" != "true" ]]; then
    echo "Already up to date: ${ver}"
    exit 0
  fi
  echo "[FORCE_TEST] Upstream unchanged, but forcing refresh for CI test."
fi

appimage="$workdir/LayaAirIDE.AppImage"
curl -fL "$url" -o "$appimage"
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
    # Insert at top so it’s obvious and harmless.
    sed -i "1i_force_test_ts=${ts}" PKGBUILD
  fi
fi

# Generate .SRCINFO (run as non-root; workflow should execute this script as an unprivileged user)
makepkg --printsrcinfo > .SRCINFO

echo "Updated to ${ver}"
