#!/usr/bin/env bash
# Builds CopilotBridge.app as a native menu-bar app bundle.
#
# Usage:
#   ./scripts/build-app.sh [config] [version]
#   VERSION=0.1.3 ./scripts/build-app.sh
#
#   config  : debug | release   (default: release)
#   version : marketing version to stamp into Info.plist (default: keep plist value).
#             When given, updates both the bundled Info.plist and the source template so
#             CFBundleShortVersionString stays the single source of truth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/CopilotBridge.app"
CONFIG="${1:-release}"
VERSION="${2:-${VERSION:-}}"

find_identity() {
  local pattern="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' -v pattern="$pattern" '$2 ~ pattern { print $2; exit }'
}

sign_app() {
  local identity="${CODE_SIGN_IDENTITY:-}"
  local source="CODE_SIGN_IDENTITY"

  if [[ -z "$identity" ]]; then
    identity="$(find_identity '^Developer ID Application:')"
    source="Developer ID Application"
  fi
  if [[ -z "$identity" ]]; then
    identity="$(find_identity '^Apple Development:')"
    source="Apple Development"
  fi

  if [[ -n "$identity" ]]; then
    echo "==> Code signing with $source"
    echo "    $identity"
    local args=(--force --deep --sign "$identity")
    if [[ "$identity" == Developer\ ID\ Application:* ]]; then
      args+=(--options runtime --timestamp)
    fi
    codesign "${args[@]}" "$APP"
  else
    echo "==> Code signing ad-hoc (no Apple signing identity found)"
    codesign --force --deep --sign - "$APP"
  fi

  codesign --verify --deep --strict --verbose=2 "$APP"
}

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/CopilotBridge"

echo "==> Assembling bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CopilotBridge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$VERSION" ]]; then
  echo "==> Stamping version $VERSION into Info.plist"
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  for plist in "$APP/Contents/Info.plist" "$ROOT/Resources/Info.plist"; do
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
  done
fi

sign_app

echo "==> Done: $APP"
echo "    Run with: open \"$APP\"   (or double-click in Finder)"
