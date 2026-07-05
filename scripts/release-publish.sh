#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

VERSION=""
NOTES_FILE=""

usage() {
  printf '%s\n' \
    "Usage: $0 --version <x.y.z> [--notes-file <path>]" \
    "" \
    "Examples:" \
    "  $0 --version 0.1.1" \
    "  $0 --version 0.1.1 --notes-file docs/release-notes/v0.1.1.md"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
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

if [[ -z "$VERSION" ]]; then
  echo "--version is required" >&2
  usage
  exit 1
fi

command -v gh >/dev/null 2>&1 || {
  echo "Missing required command: gh" >&2
  exit 1
}

TAG="v$VERSION"
ZIP_APP="$DIST/CopilotBridge-$VERSION-app.zip"
DMG="$DIST/CopilotBridge-$VERSION.dmg"

for f in "$ZIP_APP" "$DMG"; do
  [[ -f "$f" ]] || {
    echo "Missing artifact: $f" >&2
    echo "Run scripts/release-local.sh first." >&2
    exit 1
  }
done

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG not found locally; creating it on current HEAD"
  git tag -a "$TAG" -m "Copilot Bridge $VERSION"
fi

if ! git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  echo "Pushing tag $TAG to origin"
  git push origin "$TAG"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; uploading assets (clobber)."
  gh release upload "$TAG" "$ZIP_APP" "$DMG" --clobber
else
  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || {
      echo "Notes file not found: $NOTES_FILE" >&2
      exit 1
    }
    gh release create "$TAG" "$ZIP_APP" "$DMG" --title "Copilot Bridge $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" "$ZIP_APP" "$DMG" --title "Copilot Bridge $VERSION" --generate-notes
  fi
fi

echo ""
echo "Release ready:"
gh release view "$TAG" --json url -q .url
