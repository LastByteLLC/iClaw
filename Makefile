ICON_SRC    = iClaw.icon
ICON_BUILD  = .build/icon
RESOURCES   = Sources/iClawCore/Resources
ENTITLEMENTS     = $(RESOURCES)/iClaw.entitlements
MAS_ENTITLEMENTS = $(RESOURCES)/iClaw-MAS.entitlements
PROVISIONING_PROFILE = iClaw_Distribution_Profile.provisionprofile
DMG              = .build/iClaw.dmg
MAS_PKG          = .build/iClaw.pkg
DEVELOPER_ID     ?= Developer ID Application: Last Byte LLC (5QGXMKNW2A)
MAS_APP_IDENTITY ?= 3rd Party Mac Developer Application: Last Byte LLC (5QGXMKNW2A)
MAS_PKG_IDENTITY ?= 3rd Party Mac Developer Installer: Last Byte LLC (5QGXMKNW2A)

# Version: derived from git tag (e.g. v1.0.0 → 1.0.0), build number from commit count.
VERSION      := $(or $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'),1.0.0)
BUILD_NUMBER := $(or $(shell git rev-list --count HEAD 2>/dev/null),1)

# Plists stamped by swift-build targets only (Xcode targets use MARKETING_VERSION/CURRENT_PROJECT_VERSION)
PLISTS       := $(RESOURCES)/Info.plist \
                Sources/iClawMobile/Resources/Info-iOS.plist \
                Extension/safari/Info.plist

# xcodebuild configuration
XCODE_SYMROOT    = $(shell pwd)/.build/xcode
XCODE_APP_DEBUG  = .build/xcode/Debug/iClaw.app
XCODE_APP_REL    = .build/xcode/Release/iClaw.app

XCODE_VERSION_FLAGS = \
    MARKETING_VERSION=$(VERSION) \
    CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

XCODE_COMMON = \
    -project iClaw.xcodeproj -scheme iClaw \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    SYMROOT=$(XCODE_SYMROOT)

# Legacy swift-build paths (for CLI, stress-test, energy-bench)
STRESS_APP       = .build/arm64-apple-macosx/debug/iClawStressTest.app
STRESS_ENTITLEMENTS = Sources/iClawStressTest/Resources/StressTest.entitlements

ENERGY_APP       = .build/arm64-apple-macosx/debug/iClawEnergyBench.app
ENERGY_ENTITLEMENTS = Sources/iClawEnergyBench/Resources/EnergyBench.entitlements

.PHONY: build release run run-release dmg mas clean icon test stress-test energy-bench retrain-classifier benchmark-classifier generate-synthetic retrain-loop train-toxicity safari-extension

# --- Test ---

test:
	@# 60-second timeout enforced — a timeout is a test failure (see CLAUDE.md "Preventing test hangs").
	@if command -v gtimeout >/dev/null 2>&1; then \
		gtimeout 60 swift test --parallel; \
	elif command -v timeout >/dev/null 2>&1; then \
		timeout 60 swift test --parallel; \
	else \
		swift test --parallel; \
	fi

# --- Stress Test ---

stress-test:
	swift build --product iClawStressTest
	@mkdir -p $(STRESS_APP)/Contents/MacOS $(STRESS_APP)/Contents/Resources
	@cp -f .build/arm64-apple-macosx/debug/iClawStressTest $(STRESS_APP)/Contents/MacOS/iClawStressTest
	@cp -f Sources/iClawStressTest/Resources/Info.plist $(STRESS_APP)/Contents/Info.plist
	@# Copy SwiftPM resource bundles into Contents/Resources
	@rm -rf $(STRESS_APP)/Contents/Resources/iClaw_iClawCore.bundle
	@BUNDLE=$$(find .build -path "*/debug/iClaw_iClawCore.bundle" -type d 2>/dev/null | head -1); \
		if [ -n "$$BUNDLE" ]; then cp -R "$$BUNDLE" $(STRESS_APP)/Contents/Resources/; fi
	@xattr -cr $(STRESS_APP) 2>/dev/null || true
	@codesign --force --sign - --entitlements $(STRESS_ENTITLEMENTS) --deep $(STRESS_APP)
	@echo "Stress test app built. Launching..."
	@open $(STRESS_APP)

# --- CLI Daemon ---

CLI_ENTITLEMENTS = Sources/iClawCLI/iClawCLI.entitlements

cli:
	swift build --product iClawCLI
	@codesign --force --sign - --entitlements $(CLI_ENTITLEMENTS) .build/arm64-apple-macosx/debug/iClawCLI 2>/dev/null || true
	@echo "iClawCLI built at .build/debug/iClawCLI"
	@echo "Run with: .build/debug/iClawCLI"

# --- Energy Benchmark ---

energy-bench:
	swift build --product iClawEnergyBench
	@mkdir -p $(ENERGY_APP)/Contents/MacOS $(ENERGY_APP)/Contents/Resources
	@cp -f .build/arm64-apple-macosx/debug/iClawEnergyBench $(ENERGY_APP)/Contents/MacOS/iClawEnergyBench
	@cp -f Sources/iClawEnergyBench/Resources/Info.plist $(ENERGY_APP)/Contents/Info.plist
	@xattr -cr $(ENERGY_APP) 2>/dev/null || true
	@codesign --force --sign - --entitlements $(ENERGY_ENTITLEMENTS) --deep $(ENERGY_APP)
	@echo "Energy benchmark app built. Launching..."
	@open $(ENERGY_APP)

# --- Retrain Classifier ---

retrain-classifier:
	@echo "Augmenting training data from latest stress test..."
	cd MLTraining && swift AugmentFromStress.swift
	@echo "Training classifier..."
	cd MLTraining && swift TrainClassifier.swift
	@echo "Compiling model..."
	xcrun coremlcompiler compile MLTraining/ToolClassifier_MaxEnt.mlmodel /tmp/mlmodel_output/
	rm -rf Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc
	cp -R /tmp/mlmodel_output/ToolClassifier_MaxEnt.mlmodelc Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc
	@echo "Validating..."
	swift test --filter MLClassifier
	@echo "Retrained model installed."

# --- Toxicity Classifier ---

train-toxicity:
	@echo "Generating toxicity training data..."
	cd MLTraining && swift GenerateToxicityData.swift
	@echo "Training toxicity classifier..."
	cd MLTraining && swift TrainToxicityClassifier.swift
	@echo "Compiling model..."
	xcrun coremlcompiler compile MLTraining/ToxicityClassifier_MaxEnt.mlmodel /tmp/mlmodel_output/
	rm -rf Sources/iClawCore/Resources/ToxicityClassifier_MaxEnt.mlmodelc
	cp -R /tmp/mlmodel_output/ToxicityClassifier_MaxEnt.mlmodelc Sources/iClawCore/Resources/
	@echo "Validating..."
	swift test --filter ToxicityClassifier
	@echo "Toxicity classifier installed."

# --- Classifier Benchmark (headless, no Apple FM needed) ---

benchmark-classifier:
	@echo "Running classifier benchmark..."
	cd MLTraining && swift ClassifierBenchmark.swift

# --- Generate Synthetic Training Data ---

generate-synthetic:
	@echo "Generating synthetic training data for weak labels..."
	cd MLTraining && swift GenerateSyntheticData.swift

# --- Automated Retrain Loop ---
# Cycles: augment → generate synthetic → train → compile → install → benchmark
# Repeats up to 5 iterations or until benchmark passes.

retrain-loop:
	@echo "Starting automated retrain loop..."
	@for i in 1 2 3 4 5; do \
		echo ""; \
		echo "========== Iteration $$i =========="; \
		echo ""; \
		echo "[$$i/5] Augmenting from stress test..."; \
		cd MLTraining && swift AugmentFromStress.swift && cd ..; \
		echo "[$$i/5] Generating synthetic data for weak labels..."; \
		cd MLTraining && swift GenerateSyntheticData.swift && cd ..; \
		echo "[$$i/5] Training classifier..."; \
		cd MLTraining && swift TrainClassifier.swift && cd ..; \
		echo "[$$i/5] Compiling model..."; \
		xcrun coremlcompiler compile MLTraining/ToolClassifier_MaxEnt.mlmodel /tmp/mlmodel_output/; \
		rm -rf Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc; \
		cp -R /tmp/mlmodel_output/ToolClassifier_MaxEnt.mlmodelc Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc; \
		echo "[$$i/5] Running benchmark..."; \
		cd MLTraining && swift ClassifierBenchmark.swift && cd .. && echo "CONVERGED after $$i iterations!" && break; \
		echo "[$$i/5] Benchmark failed, iterating..."; \
	done

# --- Version Stamping ---

stamp-version:
	@echo "Stamping version $(VERSION) ($(BUILD_NUMBER))"
	@for plist in $(PLISTS); do \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$$plist" 2>/dev/null || true; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$$plist" 2>/dev/null || true; \
	done

# --- Safari Extension (standalone, for when only the extension is needed) ---

safari-extension:
	@echo "Building Safari extension..."
	@xcodebuild -project iClaw.xcodeproj -target iClawSafariExtension \
		-configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		SYMROOT=$(XCODE_SYMROOT) \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		-quiet
	@echo "Safari extension built."

# --- Debug (xcodebuild) ---

build: stamp-version
	xcodebuild $(XCODE_COMMON) -configuration Debug \
		$(XCODE_VERSION_FLAGS) \
		-destination "platform=macOS,arch=arm64" -quiet
	@# Embed provisioning profile
	@if [ -f "$(PROVISIONING_PROFILE)" ]; then \
		cp -f "$(PROVISIONING_PROFILE)" $(XCODE_APP_DEBUG)/Contents/embedded.provisionprofile; \
		codesign --force --sign "$(DEVELOPER_ID)" --entitlements $(ENTITLEMENTS) $(XCODE_APP_DEBUG) 2>/dev/null \
			|| codesign --force --sign - --entitlements $(ENTITLEMENTS) $(XCODE_APP_DEBUG); \
	fi
	@echo "Debug build complete."

run: build
	open $(XCODE_APP_DEBUG)

# --- Release (xcodebuild) ---

release: stamp-version safari-extension
	xcodebuild $(XCODE_COMMON) -configuration Release \
		$(XCODE_VERSION_FLAGS) \
		-destination "platform=macOS,arch=arm64" -quiet
	@# Embed Safari extension (built separately to avoid signing conflicts)
	@mkdir -p $(XCODE_APP_REL)/Contents/PlugIns
	@cp -R $(XCODE_SYMROOT)/Release/iClawSafariExtension.appex $(XCODE_APP_REL)/Contents/PlugIns/ 2>/dev/null || true
	@# Embed provisioning profile
	@cp -f "$(PROVISIONING_PROFILE)" $(XCODE_APP_REL)/Contents/embedded.provisionprofile
	@# Sign everything inside-out with Developer ID (or ad-hoc fallback).
	@# xcodebuild uses ad-hoc signing; we must re-sign all nested code for notarization.
	@if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$(DEVELOPER_ID)"; then \
		echo "Signing with Developer ID..."; \
		for nested in $$(find $(XCODE_APP_REL)/Contents/Frameworks -type d \( -name "*.xpc" -o -name "*.app" \) 2>/dev/null | sort -r); do \
			codesign --force --sign "$(DEVELOPER_ID)" --timestamp --options runtime "$$nested"; \
		done; \
		for exe in $$(find $(XCODE_APP_REL)/Contents/Frameworks -type f -perm +111 ! -name "*.dylib" ! -name "*.metallib" 2>/dev/null); do \
			if file "$$exe" | grep -q "Mach-O"; then \
				codesign --force --sign "$(DEVELOPER_ID)" --timestamp --options runtime "$$exe"; \
			fi; \
		done; \
		for fw in $$(find $(XCODE_APP_REL)/Contents/Frameworks -name "*.framework" -type d -maxdepth 1 2>/dev/null); do \
			codesign --force --sign "$(DEVELOPER_ID)" --timestamp --options runtime "$$fw"; \
		done; \
		if [ -d "$(XCODE_APP_REL)/Contents/PlugIns/iClawSafariExtension.appex" ]; then \
			codesign --force --sign "$(DEVELOPER_ID)" \
				--entitlements Extension/safari/iClawSafariExtension.entitlements \
				--timestamp --options runtime \
				$(XCODE_APP_REL)/Contents/PlugIns/iClawSafariExtension.appex; \
		fi; \
		codesign --force --sign "$(DEVELOPER_ID)" \
			--entitlements $(ENTITLEMENTS) \
			--timestamp --options runtime \
			$(XCODE_APP_REL); \
		echo "Release build signed with Developer ID."; \
	else \
		echo "Developer ID not found, using ad-hoc signing..."; \
		for nested in $$(find $(XCODE_APP_REL)/Contents/Frameworks -type d \( -name "*.xpc" -o -name "*.app" \) 2>/dev/null | sort -r); do \
			codesign --force --sign - "$$nested"; \
		done; \
		for fw in $$(find $(XCODE_APP_REL)/Contents/Frameworks -name "*.framework" -type d -maxdepth 1 2>/dev/null); do \
			codesign --force --sign - "$$fw"; \
		done; \
		if [ -d "$(XCODE_APP_REL)/Contents/PlugIns/iClawSafariExtension.appex" ]; then \
			codesign --force --sign - --entitlements Extension/safari/iClawSafariExtension.entitlements \
				$(XCODE_APP_REL)/Contents/PlugIns/iClawSafariExtension.appex 2>/dev/null || true; \
		fi; \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) $(XCODE_APP_REL); \
		echo "Release build signed ad-hoc."; \
	fi
	@echo "Release build complete: $(XCODE_APP_REL)"

run-release: release
	open $(XCODE_APP_REL)

# --- DMG ---

dmg: release
	@hdiutil detach /Volumes/iClaw 2>/dev/null || true
	@rm -rf .build/dmg-staging $(DMG)
	@mkdir -p .build/dmg-staging
	@cp -R $(XCODE_APP_REL) .build/dmg-staging/
	@ln -s /Applications .build/dmg-staging/Applications
	@hdiutil create -volname "iClaw" -srcfolder .build/dmg-staging -ov -format UDZO $(DMG)
	@echo "DMG created: $(DMG)"

# --- MAS ---

mas: stamp-version safari-extension
	xcodebuild $(XCODE_COMMON) -configuration Release \
		$(XCODE_VERSION_FLAGS) \
		"SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$$(inherited) MAS_BUILD" \
		-destination "platform=macOS,arch=arm64" -quiet
	@# Embed Safari extension
	@mkdir -p $(XCODE_APP_REL)/Contents/PlugIns
	@cp -R $(XCODE_SYMROOT)/Release/iClawSafariExtension.appex $(XCODE_APP_REL)/Contents/PlugIns/ 2>/dev/null || true
	@# Strip Sparkle plist keys (MAS doesn't allow third-party updaters)
	@/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" $(XCODE_APP_REL)/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" $(XCODE_APP_REL)/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" $(XCODE_APP_REL)/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" $(XCODE_APP_REL)/Contents/Info.plist 2>/dev/null || true
	@# Embed provisioning profile
	@cp -f "$(PROVISIONING_PROFILE)" $(XCODE_APP_REL)/Contents/embedded.provisionprofile
	@# Sign with MAS identity
	@codesign --force --sign "$(MAS_APP_IDENTITY)" --entitlements $(MAS_ENTITLEMENTS) --options runtime --deep $(XCODE_APP_REL)
	@productbuild --component $(XCODE_APP_REL) /Applications --sign "$(MAS_PKG_IDENTITY)" $(MAS_PKG)
	@echo "MAS package created: $(MAS_PKG)"

# --- Icon (for swift-build targets only; xcodebuild compiles assets automatically) ---

icon: $(ICON_BUILD)/Assets.car

$(ICON_BUILD)/Assets.car: $(ICON_SRC)/icon.json $(ICON_SRC)/Assets/lobster-claw.png
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
	rm -rf $(ICON_BUILD) .build/xcode .build/dmg-staging $(DMG)
