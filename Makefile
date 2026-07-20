CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP := dist/Vibenotch.app

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
	cp $(BUILD_DIR)/Vibenotch $(APP)/Contents/MacOS/Vibenotch
	cp $(BUILD_DIR)/vibenotch-hook $(APP)/Contents/MacOS/vibenotch-hook
	codesign --force --deep --sign - $(APP)

run: app
	open $(APP)

clean:
	rm -rf .build dist
