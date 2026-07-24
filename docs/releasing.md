# Releasing Rocky (codesign, notarization, Sparkle)

Rocky ships from GitHub Actions (`.github/workflows/release.yml`) as a
`Rocky-<version>.zip`. Signing and notarization are **optional**: without
secrets the workflow still builds an ad-hoc-signed zip so contributors can
cut test releases.

## Local release (Makefile)

```sh
# Ad-hoc .app for local testing
make app

# One-time Sparkle Ed25519 keys (public key printed; private stays in Keychain)
make sparkle-keys
# Paste the public key into Support/Info.plist → SUPublicEDKey
# Or export for CI:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_eddsa_private.pem

# Developer ID + notarytool (local)
#   xcrun notarytool store-credentials rocky-notary \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-pw
make release SIGN="Developer ID Application: Your Name (TEAMID)"
```

## GitHub Actions secrets

Set these under **Settings → Secrets and variables → Actions**. All are
optional; missing groups fall back gracefully.

### Codesign (Developer ID)

| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE_BASE64` | `.p12` of *Developer ID Application* cert, base64 (`base64 -i cert.p12 \| pbcopy`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_TEAM_ID` | 10-character Team ID |

### Notarization (choose one)

**App Store Connect API key (preferred for CI)**

| Secret | Description |
|--------|-------------|
| `APPLE_API_KEY_ID` | Key ID |
| `APPLE_API_ISSUER` | Issuer UUID |
| `APPLE_API_KEY_BASE64` | Contents of `AuthKey_….p8`, base64-encoded |

**Or Apple ID + app-specific password**

| Secret | Description |
|--------|-------------|
| `APPLE_ID` | Apple ID email |
| `APPLE_APP_SPECIFIC_PASSWORD` | [appleid.apple.com](https://appleid.apple.com) app-specific password |
| `APPLE_TEAM_ID` | Same Team ID as above |

### Sparkle (in-app updates)

| Secret | Description |
|--------|-------------|
| `SPARKLE_PUBLIC_ED_KEY` | Public key string written into `SUPublicEDKey` at release time |
| `SPARKLE_PRIVATE_KEY` | Private key string for `sign_update -s` (never commit this) |

Generate keys once with `make sparkle-keys` (or Sparkle’s `generate_keys`).
Keep the private key offline or only in CI secrets. Rotating keys is possible
when the app is also Developer ID signed — see [Sparkle docs](https://sparkle-project.org/documentation/).

`Support/Info.plist` already points `SUFeedURL` at:

```
https://github.com/wescld/rocky-notch/releases/latest/download/appcast.xml
```

Each release uploads `appcast.xml` next to the zip so that URL resolves.

## Appcast

`scripts/generate-appcast.sh` builds a single-item Sparkle 2 appcast:

```sh
scripts/generate-appcast.sh \
  --version 1.2.3 \
  --build 99 \
  --url https://github.com/wescld/rocky-notch/releases/download/v1.2.3/Rocky-1.2.3.zip \
  --zip dist/Rocky-1.2.3.zip \
  --out dist/appcast.xml
```

With `SPARKLE_PRIVATE_KEY` set (or Keychain keys locally), the enclosure gets
a `sparkle:edSignature`. Without it the XML is still valid but clients that
require EdDSA signatures will reject the update.

For multi-version appcasts, keep historical items or point `SUFeedURL` at a
stable host and run Sparkle’s full `generate_appcast` against an updates
folder.

## Packaging notes (SPM + Makefile)

Rocky is SwiftPM + Makefile — no Xcode project. `make app`:

1. `swift build -c release` (links Sparkle via SPM binary XCFramework)
2. Copies `Rocky` + `rocky-hook` into `dist/Rocky.app`
3. Embeds `.build/release/Sparkle.framework` → `Contents/Frameworks/`
4. Adds `@executable_path/../Frameworks` rpath
5. Ad-hoc `codesign` for local runs

Release signing walks nested Sparkle XPC/Updater helpers in
`scripts/codesign-app.sh` before notarization.

## In-app updater behavior

- `UpdateChecker` wraps `SPUStandardUpdaterController`
- **DEBUG** builds never start automatic checks (manual “Check for Updates…”
  still works once configured)
- Status menu + Settings expose “Check for Updates…” when `SUFeedURL` is set
- Fail-open hooks are unrelated and unchanged
