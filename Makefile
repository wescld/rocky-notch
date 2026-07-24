CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP := dist/Rocky.app

.PHONY: build test app run clean

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Support/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(BUILD_DIR)/Rocky $(APP)/Contents/MacOS/Rocky
	cp $(BUILD_DIR)/rocky-hook $(APP)/Contents/MacOS/rocky-hook
	mkdir -p $(APP)/Contents/Resources/Sounds $(APP)/Contents/Resources/Art $(APP)/Contents/Resources/Fonts
	cp Support/Sounds/*.mp3 $(APP)/Contents/Resources/Sounds/
	cp Support/Art/rocky/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/logos/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-idle/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-dance/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-walk/*.png $(APP)/Contents/Resources/Art/
	cp Support/Art/rocky-eat/*.png $(APP)/Contents/Resources/Art/
	if ls Support/Art/rocky-think/*.png >/dev/null 2>&1; then cp Support/Art/rocky-think/*.png $(APP)/Contents/Resources/Art/; fi
	if ls Support/Art/rocky-react/*.png >/dev/null 2>&1; then cp Support/Art/rocky-react/*.png $(APP)/Contents/Resources/Art/; fi
	cp Support/Fonts/PressStart2P-Regular.ttf Support/Fonts/OFL.txt $(APP)/Contents/Resources/Fonts/
	if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	codesign --force --deep --sign - $(APP)

run: app
	open $(APP)

# Signed + notarized release. Requires a "Developer ID Application"
# certificate in the keychain and a notarytool keychain profile:
#   xcrun notarytool store-credentials rocky-notary \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-pw
# Usage: make release SIGN="Developer ID Application: Your Name (TEAMID)"
release: app
	codesign --force --deep --options runtime --timestamp \
		--sign "$(SIGN)" $(APP)
	ditto -c -k --keepParent $(APP) dist/Rocky.zip
	xcrun notarytool submit dist/Rocky.zip \
		--keychain-profile rocky-notary --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) dist/Rocky.zip
	@echo "release pronto: dist/Rocky.zip"

clean:
	rm -rf .build dist
