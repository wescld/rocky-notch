#!/usr/bin/env bash
# Sign Rocky.app (and nested Sparkle helpers) for Developer ID + notarization.
# Usage: scripts/codesign-app.sh path/to/Rocky.app "Developer ID Application: Name (TEAMID)"
set -euo pipefail

APP="${1:?path to Rocky.app}"
IDENTITY="${2:?codesign identity}"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

sign() {
  local path="$1"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
}

# Innermost Sparkle components first (order matters).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  # XPC services (may be absent in some Sparkle builds / configs).
  while IFS= read -r -d '' xpc; do
    sign "$xpc"
  done < <(find "$SPARKLE" -name '*.xpc' -print0 2>/dev/null || true)

  if [[ -e "$SPARKLE/Versions/B/Autoupdate" ]]; then
    sign "$SPARKLE/Versions/B/Autoupdate"
  fi
  if [[ -d "$SPARKLE/Versions/B/Updater.app" ]]; then
    sign "$SPARKLE/Versions/B/Updater.app"
  fi
  sign "$SPARKLE"
fi

# Helper CLI shipped next to the main binary.
if [[ -f "$APP/Contents/MacOS/rocky-hook" ]]; then
  sign "$APP/Contents/MacOS/rocky-hook"
fi

sign "$APP/Contents/MacOS/Rocky"
sign "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "codesign ok: $APP"
