APP_NAME ?= Fluent Dev
BUNDLE_ID ?= com.inhaq.fluent.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= Fluent Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)

# Swift optimization flags. `swiftc` defaults to -Onone, which keeps every
# bounds check, exclusivity check, and retain/release in the binary — measured
# 11x slower on the event-tap shortcut matcher, 32x on the audio high-pass, and
# 55x on the screenshot whitespace scan. Release builds must not ship that.
#
# -wmo enables cross-file specialization but disables incremental compilation,
# so a one-line edit becomes a full rebuild. For fast local iteration:
#   make SWIFT_FLAGS=-Onone
SWIFT_FLAGS ?= -O -wmo -g

# SWIFT_FLAGS and ARCH are not files, so make cannot see them change: `make`
# followed by `make ARCH=universal` found an up-to-date binary, rebuilt nothing,
# and packaged a single-architecture executable into a universal DMG. Both are
# recorded in a signature file, and a change to it deletes the built executable
# so the next thing make does is rebuild from scratch.
#
# The deletion happens in a *phony prerequisite of `all`*, not in a stamp file
# the executable depends on, and that placement is the whole trick. GNU make
# 3.81 decides whether to run a target's recipe from stat data gathered before
# its prerequisites are remade, and never looks again: with the signature as a
# prerequisite, make compared the old stamp mtime, concluded the executable was
# current, and skipped the recipe — after the stamp recipe had already deleted
# the executable, leaving a bundle with no binary in it. Ordering the
# invalidation ahead of the build as a separate goal means make stats the
# executable *after* the stale one is gone, so it can only conclude "missing,
# must build". (Verified across arm64<->universal in both directions, a flags
# change, and -j4.)
BUILD_SIGNATURE = $(SWIFT_FLAGS) ARCH=$(ARCH)
SIGNATURE_FILE = $(BUILD_DIR)/.build-signature

# swiftc runs dsymutil itself when -g is set, emitting <binary>.dSYM *next to
# the binary* — which is inside Contents/MacOS. Debug symbols must not ship in
# the app bundle, so each build moves them out to $(BUILD_DIR). Absence is fine
# (SWIFT_FLAGS may not include -g).
MOVE_DSYM = sh -c 'rm -rf "$$2"; [ -d "$$1" ] && mv "$$1" "$$2" || true' move-dsym

# With -wmo -g the driver also writes <module>-N.swiftmodule/.swiftdoc/
# .abi.json/.swiftsourceinfo into the working directory — i.e. the repo root.
# Nothing imports this module, so the build sweeps them up afterwards. (Do NOT
# try to relocate them with -emit-module-path: that changes swiftc's primary
# output action, and -o then receives a .swiftmodule instead of an executable.)
# Scoped by mtime against a marker stamped immediately before swiftc runs, so
# the sweep can only remove what this build just wrote. Matching on name alone
# also deleted any pre-existing file with one of these names sitting in the repo
# root — files the build did not create and has no business removing.
SWEEP_MARKER = $(BUILD_DIR)/.sweep-marker
STAMP_SWEEP_MARKER = mkdir -p "$(BUILD_DIR)" && touch "$(SWEEP_MARKER)"
SWEEP_MODULE_ARTIFACTS = find . -maxdepth 1 \
	\( -name '*.swiftmodule' -o -name '*.swiftdoc' \
	   -o -name '*.abi.json' -o -name '*.swiftsourceinfo' \) \
	-newer "$(SWEEP_MARKER)" -delete

# Pick the icon source based on which bundle we are building. Dev builds get
# a distinct hammer-on-waveform icon so a developer's dock shows at a glance
# which Fluent they are running when both are installed side by side.
ifeq ($(APP_NAME),Fluent Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

.PHONY: all clean run icon dmg codesign-dmg notarize invalidate-on-signature-change

# Serial by construction: the signature check must complete before make stats
# the executable, and -j would be free to interleave them.
.NOTPARALLEL:

# A recipe that fails partway can leave a newer-but-broken executable that the
# next invocation reads as up to date. Make removes the target instead.
.DELETE_ON_ERROR:

all: invalidate-on-signature-change $(APP_EXECUTABLE_TARGET)

invalidate-on-signature-change:
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s' '$(BUILD_SIGNATURE)' | cmp -s - "$(SIGNATURE_FILE)" || { \
		printf '%s' '$(BUILD_SIGNATURE)' > "$(SIGNATURE_FILE)"; \
		echo "build signature changed to: $(BUILD_SIGNATURE)"; \
		rm -f "$(APP_EXECUTABLE)" "$(APP_EXECUTABLE)-arm64" "$(APP_EXECUTABLE)-x86_64"; }

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	@$(STAMP_SWEEP_MARKER)
ifeq ($(ARCH),universal)
	swiftc \
		-parse-as-library \
		$(SWIFT_FLAGS) \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	swiftc \
		-parse-as-library \
		$(SWIFT_FLAGS) \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@$(MOVE_DSYM) "$(MACOS_DIR)/$(APP_NAME)-arm64.dSYM" "$(BUILD_DIR)/$(APP_NAME)-arm64.dSYM"
	@$(MOVE_DSYM) "$(MACOS_DIR)/$(APP_NAME)-x86_64.dSYM" "$(BUILD_DIR)/$(APP_NAME)-x86_64.dSYM"
else
	swiftc \
		-parse-as-library \
		$(SWIFT_FLAGS) \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
	@$(MOVE_DSYM) "$(MACOS_DIR)/$(APP_NAME).dSYM" "$(BUILD_DIR)/$(APP_NAME).dSYM"
endif
	@# Nothing named *.dSYM may remain inside the bundle: it would be copied
	@# into the DMG and would make codesign/notarization fail on unexpected
	@# nested content.
	@find "$(APP_BUNDLE)" -name '*.dSYM' -maxdepth 4 -exec rm -rf {} + 2>/dev/null || true
	@$(SWEEP_MODULE_ARTIFACTS)
	@# Fail loudly if the executable is not a real Mach-O — a bad flag
	@# combination can make swiftc write something else to -o.
	@file -b "$(APP_EXECUTABLE)" | grep -q 'Mach-O' \
		|| { echo "error: $(APP_EXECUTABLE) is not a Mach-O executable"; exit 1; }
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Fluent.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--background "Resources/dmg-background.tiff" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"
