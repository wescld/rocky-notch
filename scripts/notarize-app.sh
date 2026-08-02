#!/usr/bin/env bash
# Notarize and staple an app bundle, then prove the ticket is really embedded.
#
# Usage: scripts/notarize-app.sh path/to/Rocky.app <notarytool auth flags…>
#   scripts/notarize-app.sh dist/Rocky.app --keychain-profile rocky-notary
#   scripts/notarize-app.sh dist/Rocky.app --key … --key-id … --issuer …
#   scripts/notarize-app.sh dist/Rocky.app --apple-id … --password … --team-id …
#
# The auth flags are passed straight through, so submit and log always agree.
# Both the Makefile and the release workflow call this: a local release has to
# fail the same way CI does, or debugging a rejected build starts from a lie.
set -euo pipefail

APP="${1:?path to the .app bundle}"
shift
if [[ $# -eq 0 ]]; then
  echo "error: no notarytool authentication flags given" >&2
  exit 1
fi
AUTH=("$@")

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

ZIP="${APP%.app}-notary.zip"
trap 'rm -f "$ZIP"' EXIT
ditto -c -k --keepParent "$APP" "$ZIP"

# notarytool can exit 0 on a rejected submission, which would leave stapler to
# fail with an error that says nothing about the cause. Read the verdict here
# and print Apple's log when it is not Accepted — that log names the binary
# that was rejected and why.
RESULT=$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait --output-format json)
echo "$RESULT"
STATUS=$(printf '%s' "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
SUBMISSION_ID=$(printf '%s' "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || echo "")

if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization failed with status: $STATUS" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" >&2 || true
  fi
  exit 1
fi

xcrun stapler staple "$APP"
# A stapled app has to validate with no network, which is how anyone who
# downloads the zip will launch it.
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"
echo "notarized and stapled: $APP"
