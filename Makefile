# ndi-bar — native macOS menubar NDI screen sender
#
# Common entry points. xcodegen generates the .xcodeproj from project.yml.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
# macOS still ships GNU Make 3.81, which does not honor .SHELLFLAGS. Start
# every multi-command recipe explicitly with this as well.
FAIL_FAST := set -eu -o pipefail

PROJECT       := ndi-bar.xcodeproj
SCHEME        := ndi-bar
CONFIGURATION ?= Debug
DESTINATION   := platform=macOS
INSTALL_DIR   ?= $(HOME)/Applications

# --- Release signing / notarization -----------------------------------------
# Keep credentials and machine-specific Xcode selection outside this file:
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=NDIBAR_NOTARY make dist
TEAM_ID             ?=
NOTARY_PROFILE      ?= NDIBAR_NOTARY
SIGN_IDENTITY       ?= Developer ID Application
DIST_DIR            := dist
RELEASE_DERIVED_DATA ?= build/ReleaseDerivedData
SIGNED_APP          := $(RELEASE_DERIVED_DATA)/Build/Products/Release/$(SCHEME).app

# project.yml is the version source of truth. Command-line/environment VERSION
# overrides are intentionally ignored so artifact names cannot drift from the
# app metadata being built.
override VERSION := $(strip $(shell awk '/^[[:space:]]*MARKETING_VERSION:[[:space:]]*/ { value=$$2; gsub(/["'\'']/, "", value); print value; exit }' project.yml 2>/dev/null))
override BUILD_NUMBER := $(strip $(shell awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*/ { value=$$2; gsub(/["'\'']/, "", value); print value; exit }' project.yml 2>/dev/null))
VERSION_IS_VALID := $(shell printf '%s\n' '$(VERSION)' | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$' && printf yes)
BUILD_IS_VALID := $(shell printf '%s\n' '$(BUILD_NUMBER)' | grep -Eq '^[1-9][0-9]*$$' && printf yes)

ifeq ($(VERSION_IS_VALID),)
$(error project.yml MARKETING_VERSION is missing or invalid; expected X.Y.Z)
endif
ifeq ($(BUILD_IS_VALID),)
$(error project.yml CURRENT_PROJECT_VERSION is missing or invalid; expected a positive integer)
endif

ZIP_NAME      := ndi-bar-v$(VERSION).zip
CHECKSUM_NAME := $(ZIP_NAME).sha256
ZIP_PATH      := $(DIST_DIR)/$(ZIP_NAME)
CHECKSUM_PATH := $(DIST_DIR)/$(CHECKSUM_NAME)

.PHONY: help gen open build release test strict-concurrency clean run kill install uninstall reset-tcc sign dist notary-login reset-dist

help:
	@echo "make gen                - generate $(PROJECT) from project.yml"
	@echo "make open               - open the generated project in Xcode"
	@echo "make build              - xcodebuild Debug (no release credentials)"
	@echo "make release            - xcodebuild Release, ad-hoc signed"
	@echo "make test               - run unit tests"
	@echo "make strict-concurrency - build with complete Swift concurrency checks"
	@echo "make run                - build Debug and launch the app"
	@echo "make kill               - terminate any running ndi-bar process"
	@echo "make install            - build Release and copy the app to $(INSTALL_DIR)"
	@echo "make uninstall          - remove the app from $(INSTALL_DIR)"
	@echo "make reset-tcc          - clear stale local-development media grants"
	@echo "make clean              - xcodebuild clean"
	@echo ""
	@echo "Distribution (requires Apple Developer Program credentials):"
	@echo "  TEAM_ID=ABCDE12345 make notary-login - store notary credentials once"
	@echo "  TEAM_ID=ABCDE12345 make sign         - clean Developer-ID build + verify"
	@echo "  TEAM_ID=ABCDE12345 make dist         - sign, notarize, staple, zip, checksum"
	@echo "  output: $(ZIP_PATH) and $(CHECKSUM_PATH)"

gen:
	@command -v xcodegen >/dev/null 2>&1 || { echo 'error: xcodegen missing — install it with brew install xcodegen' >&2; exit 1; }
	xcodegen generate

open: gen
	open "$(PROJECT)"

build: gen
	@$(FAIL_FAST); \
	if command -v xcbeautify >/dev/null 2>&1; then \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-configuration "$(CONFIGURATION)" -destination '$(DESTINATION)' build | xcbeautify; \
	else \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-configuration "$(CONFIGURATION)" -destination '$(DESTINATION)' build; \
	fi

release: CONFIGURATION := Release
release: build

test: gen
	@$(FAIL_FAST); \
	if command -v xcbeautify >/dev/null 2>&1; then \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-destination '$(DESTINATION)' test | xcbeautify; \
	else \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-destination '$(DESTINATION)' test; \
	fi

strict-concurrency: gen
	@$(FAIL_FAST); \
	if command -v xcbeautify >/dev/null 2>&1; then \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-configuration Debug -destination '$(DESTINATION)' \
			SWIFT_STRICT_CONCURRENCY=complete build | xcbeautify; \
	else \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
			-configuration Debug -destination '$(DESTINATION)' \
			SWIFT_STRICT_CONCURRENCY=complete build; \
	fi

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination '$(DESTINATION)' clean

run: build
	@$(FAIL_FAST); \
	APP_PATH=$$(xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR / { print $$2; exit }')/$(SCHEME).app; \
	test -d "$$APP_PATH"; \
	echo "Launching $$APP_PATH"; \
	open "$$APP_PATH"

kill:
	@pkill -x "$(SCHEME)" 2>/dev/null && echo "ndi-bar terminated" || echo "ndi-bar not running"

install: gen
	@xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination '$(DESTINATION)' build
	@$(FAIL_FAST); \
	APP_PATH=$$(xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR / { print $$2; exit }')/$(SCHEME).app; \
	test -d "$$APP_PATH"; \
	mkdir -p "$(INSTALL_DIR)"; \
	pkill -x "$(SCHEME)" 2>/dev/null || true; \
	sleep 0.3; \
	rm -rf "$(INSTALL_DIR)/$(SCHEME).app"; \
	cp -R "$$APP_PATH" "$(INSTALL_DIR)/$(SCHEME).app"; \
	echo "Installed to $(INSTALL_DIR)/$(SCHEME).app"; \
	echo "Resetting TCC so the fresh cdhash gets clean media grants…"; \
	tccutil reset ScreenCapture com.ryanvogel.ndi-bar >/dev/null 2>&1 || true; \
	tccutil reset Microphone com.ryanvogel.ndi-bar >/dev/null 2>&1 || true; \
	open "$(INSTALL_DIR)/$(SCHEME).app"; \
	echo ""; \
	echo "Click the menubar icon → Grant Screen Recording → Allow, then relaunch."

uninstall:
	@$(FAIL_FAST); \
	pkill -x "$(SCHEME)" 2>/dev/null || true; \
	sleep 0.3; \
	rm -rf "$(INSTALL_DIR)/$(SCHEME).app"; \
	echo "Removed $(INSTALL_DIR)/$(SCHEME).app"

# Clears local ad-hoc-signature grants only. Distribution never invokes this.
reset-tcc:
	@pkill -x "$(SCHEME)" 2>/dev/null || true
	@sleep 0.3
	tccutil reset ScreenCapture com.ryanvogel.ndi-bar
	tccutil reset Microphone com.ryanvogel.ndi-bar
	@echo "Relaunch ndi-bar and grant Screen Recording / Microphone when macOS prompts."

# One-time interactive storage of notarytool credentials in the login keychain.
notary-login:
	@$(FAIL_FAST); \
	command -v xcrun >/dev/null 2>&1 || { echo 'error: xcrun is required' >&2; exit 1; }; \
	xcrun --find notarytool >/dev/null; \
	if [[ -z "$(TEAM_ID)" ]]; then \
		echo 'error: TEAM_ID is required. Usage: TEAM_ID=ABCDE12345 make notary-login' >&2; \
		exit 1; \
	fi; \
	if [[ ! "$(TEAM_ID)" =~ ^[A-Z0-9]{10}$$ ]]; then \
		echo 'error: TEAM_ID must be a 10-character Apple Developer Team ID' >&2; \
		exit 1; \
	fi; \
	if [[ -z "$(NOTARY_PROFILE)" ]]; then \
		echo 'error: NOTARY_PROFILE must be nonempty' >&2; \
		exit 1; \
	fi; \
	echo "Store notarization credentials as keychain profile '$(NOTARY_PROFILE)'."; \
	echo 'Create an app-specific password at https://appleid.apple.com first.'; \
	read -r -p 'Apple ID email: ' APPLE_ID; \
	read -r -s -p 'App-specific password: ' APP_PASS; \
	echo; \
	if [[ -z "$$APPLE_ID" || -z "$$APP_PASS" ]]; then \
		echo 'error: Apple ID and app-specific password are required' >&2; \
		exit 1; \
	fi; \
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--apple-id "$$APPLE_ID" --team-id "$(TEAM_ID)" --password "$$APP_PASS"; \
	unset APP_PASS; \
	echo "Stored profile '$(NOTARY_PROFILE)'."

reset-dist:
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)"

# Clean universal Developer-ID build. The exact certificate SHA-1 is resolved
# from the requested team, and ambiguous certificate sets fail rather than
# allowing Xcode to choose nondeterministically.
sign: gen
	@$(FAIL_FAST); \
	if [[ -z "$(TEAM_ID)" ]]; then \
		echo 'error: TEAM_ID is required. Usage: TEAM_ID=ABCDE12345 make sign' >&2; \
		exit 1; \
	fi; \
	if [[ ! "$(TEAM_ID)" =~ ^[A-Z0-9]{10}$$ ]]; then \
		echo 'error: TEAM_ID must be a 10-character Apple Developer Team ID' >&2; \
		exit 1; \
	fi; \
	for TOOL in xcodebuild security codesign xcrun lipo; do \
		command -v "$$TOOL" >/dev/null 2>&1 || { echo "error: required tool missing: $$TOOL" >&2; exit 1; }; \
	done; \
	IDENTITIES=$$(security find-identity -v -p codesigning | awk -v team="$(TEAM_ID)" -v kind="$(SIGN_IDENTITY)" 'index($$0, "\"" kind ":") && index($$0, "(" team ")\"") { print $$2 }'); \
	set -- $$IDENTITIES; \
	if [[ $$# -ne 1 ]]; then \
		echo "error: expected exactly one '$(SIGN_IDENTITY)' identity for Team $(TEAM_ID); found $$#" >&2; \
		exit 1; \
	fi; \
	CERT_SHA=$$1; \
	echo "==> Clean Release build v$(VERSION) ($(BUILD_NUMBER)) for Team $(TEAM_ID)"; \
	rm -rf "$(RELEASE_DERIVED_DATA)"; \
	if command -v xcbeautify >/dev/null 2>&1; then \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release \
			-destination '$(DESTINATION)' -derivedDataPath "$(RELEASE_DERIVED_DATA)" \
			ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
			DEVELOPMENT_TEAM="$(TEAM_ID)" CODE_SIGN_IDENTITY="$$CERT_SHA" \
			OTHER_CODE_SIGN_FLAGS='--timestamp' ENABLE_HARDENED_RUNTIME=YES build | xcbeautify; \
	else \
		xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release \
			-destination '$(DESTINATION)' -derivedDataPath "$(RELEASE_DERIVED_DATA)" \
			ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
			DEVELOPMENT_TEAM="$(TEAM_ID)" CODE_SIGN_IDENTITY="$$CERT_SHA" \
			OTHER_CODE_SIGN_FLAGS='--timestamp' ENABLE_HARDENED_RUNTIME=YES build; \
	fi; \
	APP="$(SIGNED_APP)"; \
	test -d "$$APP" || { echo "error: signed app not found at $$APP" >&2; exit 1; }; \
	ACTUAL_VERSION=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$APP/Contents/Info.plist"); \
	ACTUAL_BUILD=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$APP/Contents/Info.plist"); \
	[[ "$$ACTUAL_VERSION" == "$(VERSION)" ]] || { echo "error: app version $$ACTUAL_VERSION != $(VERSION)" >&2; exit 1; }; \
	[[ "$$ACTUAL_BUILD" == "$(BUILD_NUMBER)" ]] || { echo "error: app build $$ACTUAL_BUILD != $(BUILD_NUMBER)" >&2; exit 1; }; \
	ARCHS=$$(lipo -archs "$$APP/Contents/MacOS/$(SCHEME)"); \
	[[ " $$ARCHS " == *' arm64 '* && " $$ARCHS " == *' x86_64 '* ]] || { echo "error: expected universal arm64+x86_64 app; found: $$ARCHS" >&2; exit 1; }; \
	ACTUAL_TEAM=$$(codesign -d --verbose=4 "$$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $$2; exit }'); \
	[[ "$$ACTUAL_TEAM" == "$(TEAM_ID)" ]] || { echo "error: signed TeamIdentifier $$ACTUAL_TEAM != $(TEAM_ID)" >&2; exit 1; }; \
	codesign --verify --deep --strict --verbose=2 "$$APP"; \
	if /usr/bin/find "$$APP" -type f -iname '*libndi*.dylib' -print -quit | /usr/bin/grep -q .; then \
		echo 'error: libndi must not be bundled in the app' >&2; \
		exit 1; \
	fi; \
	echo "==> Verified signed universal app: $$APP"

# Notarizes a temporary archive, staples and validates the app, then creates
# the final downloadable ZIP from that stapled app and a basename checksum.
dist: sign
	@$(FAIL_FAST); \
	for TOOL in xcrun ditto shasum codesign spctl mktemp; do \
		command -v "$$TOOL" >/dev/null 2>&1 || { echo "error: required tool missing: $$TOOL" >&2; exit 1; }; \
	done; \
	if [[ -z "$(NOTARY_PROFILE)" ]]; then \
		echo 'error: NOTARY_PROFILE must be nonempty' >&2; \
		exit 1; \
	fi; \
	xcrun --find notarytool >/dev/null; \
	xcrun --find stapler >/dev/null; \
	echo "==> Validating notary profile '$(NOTARY_PROFILE)'"; \
	if ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null; then \
		echo "error: notary profile '$(NOTARY_PROFILE)' is unavailable or invalid; run TEAM_ID=$(TEAM_ID) make notary-login" >&2; \
		exit 1; \
	fi; \
	rm -rf "$(DIST_DIR)"; \
	mkdir -p "$(DIST_DIR)"; \
	TMP_DIR=$$(mktemp -d "$${TMPDIR:-/tmp}/ndi-bar-dist.XXXXXX"); \
	trap 'rm -rf "$$TMP_DIR"' EXIT; \
	SUBMISSION_ZIP="$$TMP_DIR/$(ZIP_NAME)"; \
	NOTARY_JSON="$$TMP_DIR/notary-result.json"; \
	echo '==> Creating temporary notarization archive'; \
	ditto -c -k --sequesterRsrc --keepParent "$(SIGNED_APP)" "$$SUBMISSION_ZIP"; \
	echo '==> Submitting to Apple notary service'; \
	xcrun notarytool submit "$$SUBMISSION_ZIP" --keychain-profile "$(NOTARY_PROFILE)" --wait --output-format json > "$$NOTARY_JSON"; \
	NOTARY_STATUS=$$(/usr/bin/plutil -extract status raw -o - "$$NOTARY_JSON"); \
	if [[ "$$NOTARY_STATUS" != 'Accepted' ]]; then \
		echo "error: notarization status is $$NOTARY_STATUS, expected Accepted" >&2; \
		/usr/bin/plutil -p "$$NOTARY_JSON" >&2; \
		exit 1; \
	fi; \
	echo '==> Stapling and validating notarization ticket'; \
	xcrun stapler staple "$(SIGNED_APP)"; \
	xcrun stapler validate "$(SIGNED_APP)"; \
	codesign --verify --deep --strict --verbose=2 "$(SIGNED_APP)"; \
	spctl --assess --type execute --verbose=4 "$(SIGNED_APP)"; \
	echo "==> Creating final stapled archive $(ZIP_PATH)"; \
	ditto -c -k --sequesterRsrc --keepParent "$(SIGNED_APP)" "$(ZIP_PATH)"; \
	(cd "$(DIST_DIR)" && shasum -a 256 "$(ZIP_NAME)" > "$(CHECKSUM_NAME)" && shasum -a 256 -c "$(CHECKSUM_NAME)"); \
	echo "Release artifact: $(ZIP_PATH)"; \
	echo "Checksum:        $(CHECKSUM_PATH)"
