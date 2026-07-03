#!/usr/bin/env bash
# Builds CopilotBridge.app as a native menu-bar app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/CopilotBridge.app"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/CopilotBridge"

echo "==> Assembling bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CopilotBridge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Run with: open \"$APP\"   (or double-click in Finder)"
