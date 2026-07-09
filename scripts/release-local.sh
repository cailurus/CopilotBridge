#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/CopilotBridge.app"
BUILD_SCRIPT="$ROOT/scripts/build-app.sh"

VERSION=""
NOTARY_PROFILE=""
SKIP_DMG_NOTARY=0

usage() {
  printf '%s\n' \
    "Usage: $0 --version <x.y.z> --notary-profile <profile> [--skip-dmg-notary]" \
    "" \
    "Examples:" \
    "  $0 --version 0.1.1 --notary-profile CopilotBridge" \
    "  $0 --version 0.1.1 --notary-profile CopilotBridge --skip-dmg-notary"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-dmg-notary)
      SKIP_DMG_NOTARY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$NOTARY_PROFILE" ]]; then
  echo "--version and --notary-profile are required" >&2
  usage
  exit 1
fi

for cmd in xcrun ditto hdiutil; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
done

mkdir -p "$DIST"

ZIP_APP="$DIST/CopilotBridge-$VERSION-app.zip"
DMG="$DIST/CopilotBridge-$VERSION.dmg"

echo "==> 1) Build app (stamping version $VERSION into Info.plist)"
"$BUILD_SCRIPT" release "$VERSION"

if [[ ! -d "$APP" ]]; then
  echo "App bundle not found after build: $APP" >&2
  exit 1
fi

echo "==> 2) Package app zip"
rm -f "$ZIP_APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_APP"

echo "==> 3) Notarize app zip"
xcrun notarytool submit "$ZIP_APP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> 4) Staple app"
xcrun stapler staple "$APP"

echo "==> 5) Build dmg"
rm -f "$DMG"
hdiutil create -volname "CopilotBridge" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [[ "$SKIP_DMG_NOTARY" -eq 0 ]]; then
  echo "==> 6) Notarize dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> 7) Staple dmg"
  xcrun stapler staple "$DMG"
else
  echo "==> 6) Skip dmg notarization (--skip-dmg-notary)"
fi

echo ""
echo "Done. Artifacts:"
echo "  $ZIP_APP"
echo "  $DMG"
