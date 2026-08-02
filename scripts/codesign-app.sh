#!/usr/bin/env bash
# Sign Rocky.app (and nested Sparkle helpers) for Developer ID + notarization.
# Usage: scripts/codesign-app.sh path/to/Rocky.app "Developer ID Application: Name (TEAMID)"
set -euo pipefail

APP="${1:?path to Rocky.app}"
IDENTITY="${2:?codesign identity}"
ENTITLEMENTS="${ENTITLEMENTS:-$(dirname "$0")/../Support/Rocky.entitlements}"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements not found: $ENTITLEMENTS" >&2
  exit 1
fi

sign() {
  local path="$1"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
}

# Only Rocky itself needs the Apple Events entitlement; Sparkle's helpers are
# signed plain so we don't widen their runtime privileges.
sign_with_entitlements() {
  local path="$1"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$path"
}

# Innermost Sparkle components first (order matters).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  # XPC services (may be absent in some Sparkle builds / configs).
  while IFS= read -r -d '' xpc; do
    sign "$xpc"
  done < <(find "$SPARKLE" -name '*.xpc' -print0 2>/dev/null || true)

  # Follow Versions/Current rather than naming a version directory. Sparkle 2
  # ships Versions/B today, and hardcoding it means a future layout would skip
  # these two silently, leaving Sparkle's own signature inside a bundle that
  # claims to be ours. They are required, so a miss is an error.
  CURRENT="$SPARKLE/Versions/Current"
  for helper in Autoupdate Updater.app; do
    if [[ ! -e "$CURRENT/$helper" ]]; then
      echo "error: $helper not found under $CURRENT — Sparkle layout changed" >&2
      exit 1
    fi
    sign "$CURRENT/$helper"
  done
  sign "$SPARKLE"
fi

# Helper CLI shipped next to the main binary.
if [[ -f "$APP/Contents/MacOS/rocky-hook" ]]; then
  sign "$APP/Contents/MacOS/rocky-hook"
fi

sign_with_entitlements "$APP/Contents/MacOS/Rocky"
sign_with_entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q apple-events \
  || { echo "error: apple-events entitlement missing after signing" >&2; exit 1; }
echo "codesign ok: $APP"
