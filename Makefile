DEBUG_APP   = .build/arm64-apple-macosx/debug/iClaw.app
RELEASE_APP = .build/release/iClaw.app
RELEASE_BIN = .build/arm64-apple-macosx/release/iClaw
ICON_SRC    = iClaw.icon
ICON_BUILD  = .build/icon
RESOURCES   = Sources/iClaw/Resources
ENTITLEMENTS = $(RESOURCES)/iClaw.entitlements
DMG         = .build/iClaw.dmg

.PHONY: build release run run-release dmg clean icon

# --- Debug ---

build: icon
	swift build
	@mkdir -p $(DEBUG_APP)/Contents/Resources
	@cp -f $(ICON_BUILD)/Assets.car $(DEBUG_APP)/Contents/Resources/
	@cp -f $(ICON_BUILD)/iClaw.icns $(DEBUG_APP)/Contents/Resources/
	@echo "Debug build complete."

run: build
	open $(DEBUG_APP)

# --- Release ---

release: icon
	swift build -c release
	@mkdir -p $(RELEASE_APP)/Contents/MacOS $(RELEASE_APP)/Contents/Resources
	@cp -f $(RELEASE_BIN) $(RELEASE_APP)/Contents/MacOS/iClaw
	@cp -f $(RESOURCES)/Info.plist $(RELEASE_APP)/Contents/Info.plist
	@cp -f $(ICON_BUILD)/Assets.car $(RELEASE_APP)/Contents/Resources/
	@cp -f $(ICON_BUILD)/iClaw.icns $(RELEASE_APP)/Contents/Resources/
	@# Copy SwiftPM resource bundle if present
	@BUNDLE=$$(find .build/arm64-apple-macosx/release -name "iClaw_iClaw.bundle" -type d 2>/dev/null | head -1); \
		if [ -n "$$BUNDLE" ]; then cp -R "$$BUNDLE" $(RELEASE_APP)/Contents/Resources/; fi
	@# Ad-hoc sign without sandbox (sandbox requires a Developer ID)
	@codesign --force --sign - --deep $(RELEASE_APP)
	@echo "Release build complete: $(RELEASE_APP)"

run-release: release
	open $(RELEASE_APP)

# --- DMG ---

dmg: release
	@rm -rf .build/dmg-staging $(DMG)
	@mkdir -p .build/dmg-staging
	@cp -R $(RELEASE_APP) .build/dmg-staging/
	@ln -s /Applications .build/dmg-staging/Applications
	@hdiutil create -volname "iClaw" -srcfolder .build/dmg-staging -ov -format UDZO $(DMG)
	@echo "DMG created: $(DMG)"

# --- Icon ---

icon: $(ICON_BUILD)/Assets.car

$(ICON_BUILD)/Assets.car: $(ICON_SRC)/icon.json $(ICON_SRC)/Assets/appleclaw.png
	@mkdir -p $(ICON_BUILD)
	xcrun actool $(ICON_SRC) --compile $(ICON_BUILD) \
		--output-format human-readable-text --notices --warnings --errors \
		--output-partial-info-plist $(ICON_BUILD)/temp.plist \
		--app-icon iClaw --include-all-app-icons \
		--enable-on-demand-resources NO --development-region en \
		--target-device mac --minimum-deployment-target 26.0 --platform macosx

# --- Clean ---

clean:
	swift package clean
	rm -rf $(ICON_BUILD) .build/release .build/dmg-staging $(DMG)
