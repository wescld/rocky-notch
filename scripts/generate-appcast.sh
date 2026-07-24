#!/usr/bin/env bash
# Generate a minimal Sparkle 2 appcast item XML for a release zip.
#
# Usage:
#   scripts/generate-appcast.sh \
#     --version 1.2.3 \
#     --build 42 \
#     --url https://github.com/wescld/rocky-notch/releases/download/v1.2.3/Rocky-1.2.3.zip \
#     --zip dist/Rocky-1.2.3.zip \
#     [--private-key-file /path/to/eddsa_private.pem] \
#     [--out dist/appcast.xml]
#
# If Sparkle's sign_update is available and a private key is provided (file or
# Keychain), the enclosure is EdDSA-signed. Otherwise a skeleton appcast is
# written and you must fill sparkle:edSignature later.
set -euo pipefail

VERSION=""
BUILD=""
URL=""
ZIP=""
OUT="dist/appcast.xml"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
PRIVATE_KEY_INLINE="${SPARKLE_PRIVATE_KEY:-}"
TITLE="Rocky"
MIN_SYSTEM="14.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --private-key-file) PRIVATE_KEY_FILE="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --min-system) MIN_SYSTEM="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$VERSION" && -n "$URL" && -n "$ZIP" ]] || {
  echo "error: --version, --url, and --zip are required" >&2
  exit 1
}
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 1; }

# sparkle:version is the internal build number (CFBundleVersion); fall back to marketing version.
if [[ -z "$BUILD" ]]; then
  BUILD="$VERSION"
fi

LENGTH=$(wc -c <"$ZIP" | tr -d ' ')
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

ED_SIGNATURE=""
SIGN_UPDATE=""
# Prefer tools from a local SPM checkout, then PATH.
for candidate in \
  ".build/artifacts/sparkle/Sparkle/bin/sign_update" \
  ".build/checkouts/Sparkle/bin/sign_update" \
  "sign_update"
do
  if [[ -x "$candidate" ]] || command -v "$candidate" >/dev/null 2>&1; then
    SIGN_UPDATE="$candidate"
    break
  fi
done

# Returns 0 and prints signature on stdout only when signing succeeded.
try_sign() {
  local out
  if ! out=$("$@" 2>/dev/null); then
    return 1
  fi
  out=$(printf '%s' "$out" | tr -d '[:space:]')
  # sign_update sometimes prints ERROR!… on stdout with a zero exit — reject it.
  if [[ -z "$out" || "$out" == ERROR!* || "$out" == *"not found"* || ${#out} -lt 40 ]]; then
    return 1
  fi
  printf '%s' "$out"
  return 0
}

if [[ -n "$SIGN_UPDATE" ]]; then
  if [[ -n "$PRIVATE_KEY_INLINE" ]]; then
    # -s takes the raw private key string (CI secret).
    ED_SIGNATURE=$(try_sign "$SIGN_UPDATE" -p -s "$PRIVATE_KEY_INLINE" "$ZIP" || true)
  elif [[ -n "$PRIVATE_KEY_FILE" && -f "$PRIVATE_KEY_FILE" ]]; then
    ED_SIGNATURE=$(try_sign "$SIGN_UPDATE" -p --ed-key-file "$PRIVATE_KEY_FILE" "$ZIP" || true)
  else
    # Keychain (interactive / local make release) — skip quietly if no keys.
    ED_SIGNATURE=$(try_sign "$SIGN_UPDATE" -p "$ZIP" || true)
  fi
fi

SIGNATURE_ATTR=""
if [[ -n "$ED_SIGNATURE" ]]; then
  SIGNATURE_ATTR=" sparkle:edSignature=\"${ED_SIGNATURE}\""
else
  echo "warning: no EdDSA signature produced; appcast enclosure lacks sparkle:edSignature" >&2
fi

mkdir -p "$(dirname "$OUT")"
cat >"$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${TITLE}</title>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${URL}"
        length="${LENGTH}"
        type="application/octet-stream"${SIGNATURE_ATTR} />
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

echo "wrote $OUT (version=${VERSION} build=${BUILD} length=${LENGTH})"
