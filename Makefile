# ndi-bar — native macOS menubar NDI screen sender
#
# Common entry points. xcodegen generates the .xcodeproj from project.yml so
# the project file stays small, diff-friendly, and easy for agents to edit.

PROJECT       := ndi-bar.xcodeproj
SCHEME        := ndi-bar
CONFIGURATION ?= Debug
DESTINATION   := platform=macOS
INSTALL_DIR   ?= $(HOME)/Applications

# --- Release signing / notarization -----------------------------------------
# Override from the environment, e.g.
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=NDIBAR_NOTARY make dist
TEAM_ID        ?=
NOTARY_PROFILE ?= NDIBAR_NOTARY
SIGN_IDENTITY  ?= Developer ID Application
DIST_DIR       := dist
VERSION        := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ndi-bar/Info.plist 2>/dev/null || echo 0.0.0)

.PHONY: help gen open build release clean run kill install uninstall reset-tcc dist notary-login reset-dist

help:
	@echo "make gen       - generate ndi-bar.xcodeproj from project.yml"
	@echo "make open      - open the project in Xcode"
	@echo "make build     - xcodebuild Debug"
	@echo "make release   - xcodebuild Release"
	@echo "make run       - build Debug and launch the .app"
	@echo "make kill      - terminate any running ndi-bar process"
	@echo "make install   - build Release and copy ndi-bar.app into $(INSTALL_DIR)"
	@echo "make uninstall - remove ndi-bar.app from $(INSTALL_DIR)"
	@echo "make reset-tcc - clear stale Screen Recording TCC record (see README)"
	@echo "make clean     - xcodebuild clean"
	@echo ""
	@echo "Distribution (requires Apple Developer Program):"
	@echo "  make notary-login   - one-time: store notarytool credentials in keychain"
	@echo "  make dist           - Developer-ID sign, notarize, staple, and zip"
	@echo "                        required: TEAM_ID=ABCDE12345 make dist"

gen:
	@command -v xcodegen >/dev/null || (echo 'xcodegen missing — brew install xcodegen'; exit 1)
	xcodegen generate

open: gen
	open $(PROJECT)

build: gen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		build

release: CONFIGURATION := Release
release: build

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' clean

run: build
	@APP_PATH=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2}' | head -n1)/ndi-bar.app; \
	echo "Launching $$APP_PATH"; \
	open "$$APP_PATH"

kill:
	@pkill -x ndi-bar 2>/dev/null && echo "ndi-bar terminated" || echo "ndi-bar not running"

install: gen
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' build
	@APP_PATH=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2}' | head -n1)/ndi-bar.app; \
	mkdir -p "$(INSTALL_DIR)"; \
	pkill -x ndi-bar 2>/dev/null; sleep 0.3; \
	rm -rf "$(INSTALL_DIR)/ndi-bar.app"; \
	cp -R "$$APP_PATH" "$(INSTALL_DIR)/ndi-bar.app"; \
	echo "Installed to $(INSTALL_DIR)/ndi-bar.app"; \
	echo "Resetting TCC so the fresh cdhash gets a clean Screen Recording grant…"; \
	tccutil reset ScreenCapture com.ryanvogel.ndi-bar >/dev/null 2>&1 || true; \
	open "$(INSTALL_DIR)/ndi-bar.app"; \
	echo ""; \
	echo "Click the menubar icon → Grant Screen Recording → Allow, then relaunch."

uninstall:
	@pkill -x ndi-bar 2>/dev/null; sleep 0.3; \
	rm -rf "$(INSTALL_DIR)/ndi-bar.app" && echo "Removed $(INSTALL_DIR)/ndi-bar.app" || true

# Clears the stored Screen Recording grant for ndi-bar's bundle id.
# Use this when the System Settings toggle shows ON but the app still
# acts like permission is denied — classic symptom of ad-hoc-signed
# rebuilds invalidating the stored cdhash.
reset-tcc:
	@pkill -x ndi-bar 2>/dev/null; sleep 0.3
	tccutil reset ScreenCapture com.ryanvogel.ndi-bar
	@echo "Relaunch ndi-bar and grant Screen Recording when macOS prompts."

# -----------------------------------------------------------------------------
# Release distribution
# -----------------------------------------------------------------------------
# One-time: walk the user through generating and storing notarytool credentials
# in the login keychain. After this, `xcrun notarytool submit` can run
# non-interactively using --keychain-profile "$(NOTARY_PROFILE)".
notary-login:
	@if [ -z "$(TEAM_ID)" ]; then \
		echo "Set TEAM_ID=ABCDE12345 (your Apple Developer Team ID)"; exit 1; \
	fi
	@echo "You'll need an app-specific password from https://appleid.apple.com"
	@echo "(Sign-In and Security → App-Specific Passwords → Generate)"
	@echo ""
	@read -p "Apple ID email: " APPLE_ID; \
	read -s -p "App-specific password: " APP_PASS; echo; \
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--apple-id "$$APPLE_ID" \
		--team-id  "$(TEAM_ID)" \
		--password "$$APP_PASS"
	@echo "Stored. From now on: TEAM_ID=$(TEAM_ID) make dist"

reset-dist:
	@rm -rf $(DIST_DIR) && mkdir -p $(DIST_DIR)

# Builds a Developer-ID-signed, notarized, stapled .app and produces
# dist/ndi-bar-vX.Y.Z.zip + .sha256 ready to attach to a GitHub release.
#
# Requires:
#   - TEAM_ID set (your Apple Developer Team ID)
#   - Developer ID Application certificate installed in login keychain
#   - Notarization credentials stored via `make notary-login`
dist: reset-dist gen
	@if [ -z "$(TEAM_ID)" ]; then \
		echo "error: TEAM_ID is required. Usage: TEAM_ID=ABCDE12345 make dist"; exit 1; \
	fi
	@echo "==> Release-building with Developer ID signing (Team: $(TEAM_ID))"
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(DESTINATION)' \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		"CODE_SIGN_IDENTITY=$(SIGN_IDENTITY)" \
		"OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime" \
		ENABLE_HARDENED_RUNTIME=YES \
		build | xcbeautify 2>/dev/null || \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(DESTINATION)' \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		"CODE_SIGN_IDENTITY=$(SIGN_IDENTITY)" \
		"OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime" \
		ENABLE_HARDENED_RUNTIME=YES \
		build | grep -E "error:|warning:|BUILD "
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2}' | head -n1)/ndi-bar.app; \
	ZIP="$(DIST_DIR)/ndi-bar-v$(VERSION).zip"; \
	echo "==> Verifying signature"; \
	codesign --verify --deep --strict --verbose=2 "$$APP"; \
	echo "==> Packaging $$ZIP"; \
	ditto -c -k --keepParent "$$APP" "$$ZIP"; \
	echo "==> Submitting to Apple notary service (this can take a few minutes)"; \
	xcrun notarytool submit "$$ZIP" --keychain-profile "$(NOTARY_PROFILE)" --wait; \
	echo "==> Stapling ticket"; \
	xcrun stapler staple "$$APP"; \
	echo "==> Re-zipping with stapled ticket"; \
	rm "$$ZIP"; ditto -c -k --keepParent "$$APP" "$$ZIP"; \
	shasum -a 256 "$$ZIP" | tee "$$ZIP.sha256"; \
	echo ""; \
	echo "Release artifact:  $$ZIP"; \
	echo "Checksum:          $$ZIP.sha256"; \
	echo ""; \
	echo "Next: gh release create v$(VERSION) $$ZIP $$ZIP.sha256 --title \"ndi-bar $(VERSION)\""
