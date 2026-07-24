CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP := dist/Rocky.app
# SPM copies the binary Sparkle.framework next to the linked product.
SPARKLE_FRAMEWORK := $(BUILD_DIR)/Sparkle.framework
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin

.PHONY: build test app run clean release sparkle-keys

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp Support/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(BUILD_DIR)/Rocky $(APP)/Contents/MacOS/Rocky
	cp $(BUILD_DIR)/rocky-hook $(APP)/Contents/MacOS/rocky-hook
	# Embed Sparkle so @rpath resolves inside the .app (preserve symlinks).
	if [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
		ditto "$(SPARKLE_FRAMEWORK)" $(APP)/Contents/Frameworks/Sparkle.framework; \
		install_name_tool -add_rpath @executable_path/../Frameworks $(APP)/Contents/MacOS/Rocky 2>/dev/null || true; \
	fi
	mkdir -p $(APP)/Contents/Resources/Sounds $(APP)/Contents/Resources/Art $(APP)/Contents/Resources/Fonts
	cp Support/Sounds/*.mp3 $(APP)/Contents/Resources/Sounds/
	cp Support/Art/rocky/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-idle/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-dance/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-walk/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-eat/*.png $(APP)/Contents/Resources/Art/
	if ls Support/Art/rocky-think/*.png >/dev/null 2>&1; then cp Support/Art/rocky-think/*.png $(APP)/Contents/Resources/Art/; fi
	if ls Support/Art/rocky-react/*.png >/dev/null 2>&1; then cp Support/Art/rocky-react/*.png $(APP)/Contents/Resources/Art/; fi
	cp Support/Fonts/PressStart2P-Regular.ttf Support/Fonts/OFL.txt $(APP)/Contents/Resources/Fonts/
	if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	# Ad-hoc sign for local runs (no hardened runtime → library validation off).
	codesign --force --deep --sign - $(APP)

run: app
	open $(APP)

# Generate Sparkle Ed25519 keys once. Public key → Info.plist SUPublicEDKey;
# private key stays in Keychain (or export with -x for CI: SPARKLE_PRIVATE_KEY).
sparkle-keys: build
	@test -x "$(SPARKLE_BIN)/generate_keys" || { echo "Sparkle tools missing; run make build first"; exit 1; }
	"$(SPARKLE_BIN)/generate_keys"

# Signed + notarized release. Requires a "Developer ID Application"
# certificate in the keychain and a notarytool keychain profile:
#   xcrun notarytool store-credentials rocky-notary \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-pw
# Usage: make release SIGN="Developer ID Application: Your Name (TEAMID)"
release: app
	@test -n "$(SIGN)" || { echo 'Set SIGN="Developer ID Application: … (TEAMID)"'; exit 1; }
	# Sign nested Sparkle helpers, then the app (hardened runtime for notarization).
	scripts/codesign-app.sh "$(APP)" "$(SIGN)"
	ditto -c -k --keepParent $(APP) dist/Rocky.zip
	xcrun notarytool submit dist/Rocky.zip \
		--keychain-profile rocky-notary --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) dist/Rocky.zip
	@echo "release pronto: dist/Rocky.zip"

clean:
	rm -rf .build dist
