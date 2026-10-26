SHELL := /bin/bash
# Prerequisites list steps in the order they must run.
.NOTPARALLEL:

# Optional, git-ignored local overrides (e.g. code-signing identity for `make install`).
# Without a signing identity the debug app is ad-hoc signed, so macOS re-prompts for the
# WebCrypto keychain item on every rebuild. Copy Makefile.local.example to enable.
-include Makefile.local

UI_DIR := lilo-ui
BRIDGE_DIR := Lilo/Extensions/bridge-src
UI_DEPS := $(UI_DIR)/node_modules/.package-lock.json
BRIDGE_DEPS := $(BRIDGE_DIR)/node_modules/.package-lock.json
SITE_DEPS := site/node_modules/.package-lock.json
CHANGIE_VERSION := 1.26.0
CHANGIE := $(CURDIR)/build/changie-$(CHANGIE_VERSION)/changie
CHANGIE_OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
CHANGIE_ARCH := $(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
CHANGIE_ARCHIVE := changie_$(CHANGIE_VERSION)_$(CHANGIE_OS)_$(CHANGIE_ARCH).tar.gz
# Pinned so a new release's rules or project output never break validate or the xcodeproj sync check.
SWIFTLINT_VERSION := 0.65.0
SWIFTLINT_SHA256 := d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6
SWIFTLINT := $(CURDIR)/build/swiftlint-$(SWIFTLINT_VERSION)/swiftlint
XCODEGEN_VERSION := 2.46.0
XCODEGEN_SHA256 := 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN := $(CURDIR)/build/xcodegen-$(XCODEGEN_VERSION)/bin/xcodegen
# What validate's UI and bridge builds read, and the stamps they leave once built from them.
UI_SOURCES := $(shell find $(UI_DIR)/src) $(addprefix $(UI_DIR)/,index.html package-lock.json svelte.config.js tsconfig.json vite.config.ts) \
	scripts/embed_chrome_ui.py scripts/generate_native_strings.py
BRIDGE_SOURCES := $(shell find $(BRIDGE_DIR)/src $(BRIDGE_DIR)/scripts) $(addprefix $(BRIDGE_DIR)/,esbuild.mjs package-lock.json tsconfig.json)
UI_STAMP := build/.ui-build.stamp
BRIDGE_STAMP := build/.ext-bridge-build.stamp
CHROME_UI_ASSETS := Lilo/Generated/ChromeUIAssets.swift
NATIVE_STRINGS := Lilo/Generated/NativeStrings.swift
GHOSTTY_SHA := 83edd491e3024ae5e50393d62877b8897da1cccd
# GhosttyVt.xcframework built from GHOSTTY_SHA by .github/workflows/ghostty-vt.yml, whose release
# notes give the sha256 for VT_SHA256. Deferred, so the $(shell) runs only when vt-build does.
VT_URL = https://github.com/Alexays/Lilo/releases/download/ghostty-vt-$(shell printf %.12s $(GHOSTTY_SHA))/GhosttyVt.xcframework.zip
VT_SHA256 := 33b7d83fcdc8ada0ab3a377bd9f0cb0880ad40401cf12acb9bbde99d7ba606f2
GHOSTTY_DIR := build/ghostty
VT_STAMP := Vendor/.ghostty-sha
DMGBUILD_VERSION := 1.6.5
DMGBUILD_DIR := build/dmgbuild-$(DMGBUILD_VERSION)
# Inside the checkout, so a worktree's build goes with the worktree instead of staying in ~/Library.
XCODEBUILD := xcodebuild -project Lilo.xcodeproj -scheme Lilo -destination 'platform=macOS' -derivedDataPath $(CURDIR)/.derived.noindex/xcode
# They wait out real clocks (a worker's 30 s unload, a controller's first 5 s, a terminal's 5 s between
# line counts): about 100 s together.
SLOW_TESTS := GapRouterStoreProviderTests/testAnIdleWorkerUnloadsOnChromesScheduleAndHearsLaterEvents \
	GitDiffTests/testTerminalLineCountsRunOncePerIntervalButFollowADirectoryChangeAtOnce \
	ProfileExtensionRegistryTests/testReEnabledOrReloadedWorkerHearsNeitherOnInstalledNorOnStartup \
	ProfileExtensionRegistryTests/testWorkersRestoredLateHearOnStartupOnly \
	WebKitGapTests/testLifecycleEventsDependOnTheControllerAge \
	WebKitGapTests/testWebSocketStallsTheWorkerLoad
DEBUG_TEAM_ID := $(or $(LILO_DEBUG_TEAM_ID),$(LILO_TEAM_ID))
DEBUG_SIGNING := $(if $(DEBUG_TEAM_ID),DEVELOPMENT_TEAM=$(DEBUG_TEAM_ID) CODE_SIGN_IDENTITY="$(or $(LILO_DEBUG_CODE_SIGN_IDENTITY),Apple Development)" CODE_SIGN_STYLE=Manual)
# The test host is its own app: its camera, microphone and keychain grants and its background
# permission never touch the installed Lilo's, and a stable signature keeps them across builds.
# One run at a time per machine, whatever the worktree: each already fills every performance core, and
# concurrent runs' WebKit processes saturate runningboardd until the whole Mac stalls.
TEST := lockf -k $(or $(TMPDIR),/tmp/)lilo-swift-test.lock $(XCODEBUILD) -configuration Debug LILO_BUNDLE_ID_SUFFIX=.tests $(DEBUG_SIGNING) test
# CI (which sets CI) runs a failed test once more and lists it in the job summary; locally a flake fails.
TEST_RETRY := $(if $(CI),-retry-tests-on-failure -test-iterations 2)
TEST_WORKERS = $(shell sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)

.PHONY: help validate validate-ui swiftlint project-sync ui-build ui-watch ui-dev ui-lint ui-test e2e e2e-energy \
	swift-test swift-test-slow blocker-coverage blocker-bench terminal-bench ext-bridge-build ext-bridge-test ext-smoke ext-nightly top-extensions top-manifests chrome-surface \
	chrome-contracts chrome-smoke public-suffix-list app install install-debug xcode-build xcode-build-release \
	run-ui-dev release release-notarize release-archive dmg dmg-background bridge-gen vt-build vt-build-source vt-zip bootstrap ui-preview check-commits startup-bench ext-bench energy-sample energy-compare \
	logs logs-stream site-dev site-dev-stop site-preview site-generate site-check site-fix site-test site-lock site-deploy site-deploy-check emoji-data password-manager-icons \
	hooks-install hooks-test lint-commit-message lint-commits \
	changie change release-status release-version release-test

## List the targets
help:
	@awk '/^## /{d=substr($$0,4);next} d&&/^[a-z0-9-]+:/{sub(/:.*/,"");printf "  make %-20s %s\n",$$0,d} {d=""}' Makefile

## Enable the tracked Git hooks for this clone
hooks-install:
	@current=$$(git config core.hooksPath || true); \
	[ "$$current" = .githooks ] && exit 0; \
	if [ -n "$$current" ]; then echo "core.hooksPath is already $$current; chain .githooks/commit-msg from it instead" >&2; exit 1; fi; \
	for hook in "$$(git rev-parse --git-path hooks)"/*; do \
		case "$$hook" in *.sample) continue ;; esac; \
		if [ -f "$$hook" ]; then echo "$$hook would stop running; move it into .githooks first" >&2; exit 1; fi; \
	done; \
	git config --local core.hooksPath .githooks

## Validate a Conventional Commit header from stdin
lint-commit-message:
	@scripts/lint_commit_message.sh

## Validate non-merge commit headers in BASE..COMMIT_HEAD (origin/main..HEAD by default)
lint-commits:
	@scripts/lint_commits.sh "$(or $(BASE),origin/main)" "$(or $(COMMIT_HEAD),HEAD)"

## Test commit-message validation and the native Git hook
hooks-test:
	@scripts/commit_hooks.test.sh

## Check the prerequisites, then fetch and build what a fresh clone needs (npm deps, libghostty-vt, UI bundle, bridge)
bootstrap:
	@scripts/bootstrap.sh "$(UI_DEPS) $(BRIDGE_DEPS)" "vt-build $(UI_STAMP) $(BRIDGE_STAMP) $(SWIFTLINT) $(XCODEGEN)"

# The app embeds the UI and bridge builds, rebuilt only when their sources changed; swift-test builds the app.
# The lint and the JS tests run beside the other steps, their output shown on failure.
## Run UI and website checks, Swift lint/tests, the app build, bridge and hook checks and release version checks
validate: $(UI_DEPS) $(BRIDGE_DEPS) $(SITE_DEPS) $(SWIFTLINT) $(CHANGIE)
	@logs=$$(mktemp -d); checks=; \
	for group in ui-lint ui-test "site-check site-test" "hooks-test ext-bridge-test swiftlint release-status"; do \
		name=$${group%% *}; $(MAKE) -k --no-print-directory $$group > "$$logs/$$name.log" 2>&1 & checks="$$checks $$!:$$name"; \
	done; \
	$(MAKE) --no-print-directory $(BRIDGE_STAMP) & bridge=$$!; \
	$(MAKE) --no-print-directory $(UI_STAMP); ui=$$?; wait $$bridge; bridge=$$?; \
	[ $$ui -eq 0 ] && [ $$bridge -eq 0 ] && $(MAKE) --no-print-directory swift-test; swift=$$?; \
	failed=0; for check in $$checks; do wait $${check%%:*} || { failed=1; cat "$$logs/$${check#*:}.log"; }; done; \
	/bin/rm -rf "$$logs"; [ $$swift -eq 0 ] && [ $$failed -eq 0 ]

$(UI_STAMP): $(UI_DEPS) $(UI_SOURCES)
	@$(MAKE) --no-print-directory ui-build
	@mkdir -p $(@D) && touch $@

$(BRIDGE_STAMP): $(BRIDGE_DEPS) $(BRIDGE_SOURCES)
	@$(MAKE) --no-print-directory ext-bridge-build
	@mkdir -p $(@D) && touch $@

## Run the CI UI validation sequence (lint + test + build)
validate-ui: ui-lint ui-test ui-build

## Run Swift lint only
swiftlint: $(SWIFTLINT)
	@'$(SWIFTLINT)' lint --config .swiftlint.yml --strict

## Regenerate Lilo.xcodeproj from project.yml
project-sync: $(CHROME_UI_ASSETS) $(NATIVE_STRINGS) $(XCODEGEN)
	@'$(XCODEGEN)' generate --spec project.yml

$(SWIFTLINT):
	@set -eu; work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; \
	curl -fLsS --retry 3 'https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip' -o "$$work/swiftlint.zip"; \
	echo '$(SWIFTLINT_SHA256)  '"$$work/swiftlint.zip" | shasum -a 256 -c - >/dev/null; \
	unzip -q "$$work/swiftlint.zip" swiftlint -d "$$work"; \
	mkdir -p '$(@D)'; mv "$$work/swiftlint" '$@'; touch '$@'

# The binary reads its setting presets from ../share beside it.
$(XCODEGEN):
	@set -eu; work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; \
	curl -fLsS --retry 3 'https://github.com/yonaskolb/XcodeGen/releases/download/$(XCODEGEN_VERSION)/xcodegen.zip' -o "$$work/xcodegen.zip"; \
	echo '$(XCODEGEN_SHA256)  '"$$work/xcodegen.zip" | shasum -a 256 -c - >/dev/null; \
	unzip -q "$$work/xcodegen.zip" -d "$$work"; \
	rm -rf '$(CURDIR)/build/xcodegen-$(XCODEGEN_VERSION)'; mkdir -p build; \
	mv "$$work/xcodegen" '$(CURDIR)/build/xcodegen-$(XCODEGEN_VERSION)'; touch '$@'

$(UI_DEPS): $(UI_DIR)/package-lock.json
	@npm --prefix $(UI_DIR) ci

$(BRIDGE_DEPS): $(BRIDGE_DIR)/package-lock.json
	@npm --prefix $(BRIDGE_DIR) ci

$(SITE_DEPS): site/package.json site/package-lock.json
	@npm --prefix site ci

$(CHANGIE): scripts/changie-checksums.txt
	@set -eu; work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; \
	archive='$(CHANGIE_ARCHIVE)'; \
	checksum=$$(awk -v file="$$archive" '$$2 == file { print $$1 }' scripts/changie-checksums.txt); \
	[ -n "$$checksum" ] || { echo "Unsupported Changie archive: $$archive" >&2; exit 1; }; \
	curl -fLsS --retry 3 "https://github.com/miniscruff/changie/releases/download/v$(CHANGIE_VERSION)/$$archive" -o "$$work/$$archive"; \
	(cd "$$work" && printf '%s  %s\n' "$$checksum" "$$archive" | shasum -a 256 -c -); \
	tar -xzf "$$work/$$archive" -C "$$work" changie; \
	mkdir -p '$(@D)'; mv "$$work/changie" '$@'; touch '$@'

## Download the pinned Changie release tool and verify its checksum
changie: $(CHANGIE)

## Record a user-visible change for the next release
change: $(CHANGIE)
	@$(CHANGIE) new

## Show pending releases and check the app's versions agree
release-status: $(CHANGIE)
	@python3 scripts/release.py status --changie '$(CHANGIE)'

## Collect release notes, bump the app and build versions, and refresh the website
release-version: $(CHANGIE)
	@python3 scripts/release.py version --changie '$(CHANGIE)'
	@$(MAKE) --no-print-directory site-generate

## Test app version and Sparkle build number synchronization
release-test: $(CHANGIE)
	@CHANGIE='$(CHANGIE)' python3 scripts/release_test.py

## Build the embedded Svelte UI bundle and the Swift sources generated from lilo-ui
ui-build: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run build
	@python3 scripts/embed_chrome_ui.py
	@python3 scripts/generate_native_strings.py

# Built once when missing so a fresh clone compiles; ui-build, which validate's UI stamp runs on any
# UI source change, refreshes both.
$(CHROME_UI_ASSETS):
	@$(MAKE) --no-print-directory ui-build

$(NATIVE_STRINGS):
	@python3 scripts/generate_native_strings.py

## Regenerate the Space emoji picker's dataset from Unicode and CLDR (downloads them)
emoji-data:
	@python3 scripts/generate_emoji_data.py

## Regenerate the setup's password manager icons from their Chrome Web Store packages (downloads them; needs Pillow)
password-manager-icons:
	@python3 scripts/generate_password_manager_icons.py

## Rebuild the UI bundle (build/chrome-ui) on change; use ui-dev for live reload in the app
ui-watch: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run watch

## Start the Vite dev server on localhost:5173
ui-dev: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run dev

## Open the interface in a browser against a fake host, with hot reload and no Xcode (lilo-ui/preview/)
ui-preview: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run dev -- --open /preview/

## Run ESLint + svelte-check
ui-lint: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run lint

## Run lightweight UI regression tests
ui-test: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run test

## Run the chrome UI end-to-end tests (Playwright)
e2e: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run test:e2e || { echo 'If Chromium is missing, install it with: npx --prefix $(UI_DIR) playwright install chromium' >&2; exit 1; }

# Not part of e2e: it takes about three minutes and drives the app with System Events keystrokes.
## Leave a Release build idle with tabs and a hidden terminal; fail on idle git, worker or snapshot work (IDLE=45 TABS=3 TERMINAL=1)
e2e-energy:
	@scripts/energy_idle_check.sh --idle $(or $(IDLE),45) --tabs $(or $(TABS),3) $(if $(filter 0,$(TERMINAL)),--no-terminal)

# RESULT_BUNDLE=path writes an .xcresult bundle (used by CI to upload results on failure).
# Test classes run in parallel app instances, one per performance core: more only adds load and timing flakes.
## Run Swift unit tests (LiloTests) but the slow ones
swift-test: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(TEST) -only-testing:LiloTests -skip-testing:LiloTests/TerminalBenchmarkTests -skip-testing:LiloTests/RealExtensionSmokeTests \
		$(addprefix -skip-testing:LiloTests/,$(SLOW_TESTS)) -parallel-testing-enabled YES -maximum-parallel-testing-workers $(TEST_WORKERS) \
		$(TEST_RETRY) $(if $(RESULT_BUNDLE),-resultBundlePath '$(RESULT_BUNDLE)')

## Run the Swift tests that wait out real clocks, which swift-test skips
swift-test-slow: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(TEST) $(addprefix -only-testing:LiloTests/,$(SLOW_TESTS)) -parallel-testing-enabled YES \
		$(TEST_RETRY) $(if $(RESULT_BUNDLE),-resultBundlePath '$(RESULT_BUNDLE)')

## Report what the converter keeps of the default filter lists, by kind and skip reason (network; OUT=build/blocker-coverage.txt)
blocker-coverage: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@out="$(abspath $(or $(OUT),build/blocker-coverage.txt))"; mkdir -p "$$(dirname "$$out")"; /bin/rm -f "$$out"; \
	log=$$(mktemp); TEST_RUNNER_LILO_BLOCKER_COVERAGE="$$out" $(TEST) -only-testing:LiloTests/FilterListCoverageTests > "$$log" 2>&1 \
		|| { cat "$$log"; /bin/rm -f "$$log"; exit 1; }; /bin/rm -f "$$log"; cat "$$out"

## Report what an image load costs a page with and without the default filter lists (network; OUT=build/blocker-bench.txt)
blocker-bench: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@out="$(abspath $(or $(OUT),build/blocker-bench.txt))"; mkdir -p "$$(dirname "$$out")"; /bin/rm -f "$$out"; \
	log=$$(mktemp); TEST_RUNNER_LILO_BLOCKER_BENCH="$$out" $(TEST) -only-testing:LiloTests/ContentBlockerBenchmarkTests > "$$log" 2>&1 \
		|| { cat "$$log"; /bin/rm -f "$$log"; exit 1; }; /bin/rm -f "$$log"; cat "$$out"

## Run the terminal throughput and lock-fairness benchmarks
terminal-bench: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(TEST) -only-testing:LiloTests/TerminalBenchmarkTests

## Build the extension bridge JS artifacts from bridge-src
ext-bridge-build: $(BRIDGE_DEPS)
	@npm --prefix $(BRIDGE_DIR) run build

## Run extension bridge unit tests
ext-bridge-test: $(BRIDGE_DEPS)
	@npm --prefix $(BRIDGE_DIR) test

## Install the most used Chrome Web Store extensions and the MV3 probe in parallel runs, and check they run and what a few do on a page (network; TOP=100 IDS=a,b SHARDS=6)
ext-smoke: vt-build ext-bridge-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@node scripts/ext-smoke.mjs --top '$(or $(TOP),100)' --ids '$(IDS)' --shards '$(or $(SHARDS),6)'

## Unattended ext-smoke of the top 500 (TOP=1000 for every listed one); report in .derived.noindex/ext-smoke/report.txt, non-zero exit on a regression
ext-nightly:
	@$(MAKE) --no-print-directory ext-smoke TOP=$(or $(TOP),500)

## Rebuild top-extensions.json from the Chrome Web Store user counts (TOP=500)
top-extensions:
	@node scripts/top-extensions.mjs $(or $(TOP),500)

## Rebuild top-manifests.json, the top extensions' manifests TopManifestTests loads (network)
top-manifests:
	@node scripts/top-manifests.mjs

## Regenerate the Chrome API surface ChromeSurfaceTests checks (from chrome-types)
chrome-surface: $(BRIDGE_DEPS)
	@node $(BRIDGE_DIR)/scripts/chrome-surface.mjs

## Record how Chrome answers test-extensions/extension-contracts, for ChromeContractTests (Chrome for Testing)
chrome-contracts:
	@node scripts/record-chrome-contracts.mjs

## Record what Chrome does with the ext-smoke extensions, the reference ext-smoke compares against (IDS=a,b for some)
chrome-smoke:
	@node scripts/record-chrome-smoke.mjs $(IDS)

## Refresh the bundled Public Suffix List behind chrome.publicSuffix
public-suffix-list:
	@node $(BRIDGE_DIR)/scripts/public-suffix-list.mjs

## Build the debug app bundle under build/debug
app: vt-build ui-build ext-bridge-build
	@scripts/build-app.sh debug

## Install the release app to /Applications/Lilo.app, replacing the DMG's copy
install: vt-build ui-build ext-bridge-build
	@scripts/build-app.sh release install

## Install the debug app to ~/Applications/Lilo.app
install-debug: vt-build ui-build ext-bridge-build
	@scripts/build-app.sh debug install

## Run the Debug xcodebuild directly
xcode-build: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(XCODEBUILD) -configuration Debug \
		$(DEBUG_SIGNING) build

## Run the Release xcodebuild directly
xcode-build-release: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(XCODEBUILD) -configuration Release build

# The full app bundle is required: `swift run` lacks Info.plist and the bundle resources.
## Launch the app against the local Vite dev server
run-ui-dev: app
	@LILO_UI_DEV_SERVER=http://localhost:5173 ./build/debug/export/Lilo.app/Contents/MacOS/Lilo

## Build the UI bundle and create release artifacts
release: vt-build $(UI_STAMP) $(BRIDGE_STAMP)
	@scripts/build-app.sh release

## Build the UI bundle and notarize the release artifacts
release-notarize: vt-build $(UI_STAMP) $(BRIDGE_STAMP)
	@scripts/build-app.sh release notarize

# CI's release path: the UI is built or restored beforehand and the committed bridge bundles are checked
# against bridge-src on main, so neither needs npm here.
## Archive and export the release app from the UI already built (CI)
release-archive: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@scripts/build-app.sh release

# dmgbuild writes the window layout into .DS_Store itself, so no Finder or AppleScript is involved.
## Package an exported app into build/Lilo.dmg (APP=build/release/export/Lilo.app)
dmg:
	@app="$(or $(APP),build/release/export/Lilo.app)"; \
	if [ ! -d "$$app" ]; then echo "make dmg: $$app not found; run make release first or pass APP=/path/to/Lilo.app" >&2; exit 1; fi; \
	set -e; \
	[ -x $(DMGBUILD_DIR)/bin/dmgbuild ] || { python3 -m venv $(DMGBUILD_DIR) && $(DMGBUILD_DIR)/bin/pip install -q --disable-pip-version-check dmgbuild==$(DMGBUILD_VERSION); }; \
	$(DMGBUILD_DIR)/bin/dmgbuild -s scripts/dmg/settings.py -D app="$$app" Lilo build/Lilo.dmg

## Render scripts/dmg/background.html to the DMG background PNGs
dmg-background:
	@swift scripts/dmg/render.swift

## Regenerate tab bridge TS+Swift from bridge-schema/tab.json
bridge-gen:
	@node scripts/generate_bridge_protocol.mjs

# A no-op once the stamp matches GHOSTTY_SHA. It builds from source when VT_FROM_SOURCE=1, and when
# the download fails (release not published yet, no network) or does not match VT_SHA256.
## Download the prebuilt libghostty-vt (Vendor/GhosttyVt.xcframework) for the pinned Ghostty commit
vt-build:
	@[ "$$(cat $(VT_STAMP) 2>/dev/null)" = "$(GHOSTTY_SHA)" ] && exit 0; \
	[ "$(VT_FROM_SOURCE)" = 1 ] && exec $(MAKE) --no-print-directory vt-build-source; \
	zip=build/GhosttyVt-$(GHOSTTY_SHA).zip; mkdir -p build Vendor; \
	if ! curl -fsSL --retry 2 -o "$$zip" "$(VT_URL)"; then \
		/bin/rm -f "$$zip"; \
		echo "make vt-build: no prebuilt libghostty-vt at $(VT_URL), building it from source instead." >&2; \
		exec $(MAKE) --no-print-directory vt-build-source; \
	fi; \
	if ! echo "$(VT_SHA256)  $$zip" | shasum -a 256 -c --status; then \
		echo "make vt-build: $(VT_URL) has sha256 $$(shasum -a 256 "$$zip" | cut -d' ' -f1), not VT_SHA256, building it from source instead." >&2; \
		/bin/rm -f "$$zip"; exec $(MAKE) --no-print-directory vt-build-source; \
	fi; \
	/bin/rm -rf Vendor/GhosttyVt.xcframework && unzip -q "$$zip" -d Vendor && /bin/rm -f "$$zip" && echo $(GHOSTTY_SHA) > $(VT_STAMP)

## Build libghostty-vt from the pinned Ghostty commit with Zig 0.16, instead of downloading it
vt-build-source:
	@if ! zig version 2>/dev/null | grep -q '^0\.16\.'; then \
		echo "Building libghostty-vt from source requires Zig 0.16.x (found: $$(zig version 2>/dev/null || echo none)). Install it with: brew install zig" >&2; exit 1; \
	fi; \
	set -e; \
	mkdir -p $(GHOSTTY_DIR) Vendor; \
	git -C $(GHOSTTY_DIR) init -q; \
	git -C $(GHOSTTY_DIR) remote add origin https://github.com/ghostty-org/ghostty.git 2>/dev/null || true; \
	git -C $(GHOSTTY_DIR) fetch -q --depth 1 origin $(GHOSTTY_SHA); \
	git -C $(GHOSTTY_DIR) checkout -q --detach FETCH_HEAD; \
	(cd $(GHOSTTY_DIR) && zig build -Demit-lib-vt -Doptimize=ReleaseFast); \
	/bin/rm -rf Vendor/GhosttyVt.xcframework; \
	/bin/cp -R $(GHOSTTY_DIR)/zig-out/lib/ghostty-vt.xcframework Vendor/GhosttyVt.xcframework; \
	echo $(GHOSTTY_SHA) > $(VT_STAMP)

# Fixed timestamps and file order, so one build always zips to the same bytes.
## Build libghostty-vt from source and zip it to build/GhosttyVt.xcframework.zip, the asset vt-build downloads
vt-zip: vt-build-source
	@/bin/rm -f build/GhosttyVt.xcframework.zip; \
	/usr/bin/find Vendor/GhosttyVt.xcframework -exec touch -h -t 200001010000 {} +; \
	(cd Vendor && /usr/bin/find GhosttyVt.xcframework | LC_ALL=C sort | zip -qX -y ../build/GhosttyVt.xcframework.zip -@); \
	shasum -a 256 build/GhosttyVt.xcframework.zip

## Build every commit of BASE..HEAD with SwiftPM in a throwaway worktree (BASE=origin/main)
check-commits:
	@scripts/check_commits.sh $(BASE)

## Time launches of a Release build against a throwaway profile (RUNS=10 TABS=0; APP=path times that app, unbuilt)
startup-bench:
	@scripts/bench_startup.sh $(or $(RUNS),10) --tabs $(or $(TABS),0) $(if $(OUT),--out $(OUT)) $(if $(APP),--app '$(abspath $(APP))')

# Extensions download once into build/ext-bench; the bench takes about 5 minutes. The idle budget sits well above
# a healthy build and well below a busy loop in a worker or the bridge; MAX_IDLE_CPU= measures without one.
MAX_IDLE_CPU ?= 35,25
## Time a Release build with 20 store extensions: restore, preparation, worker starts, API latency, idle CPU; fails over the idle CPU budget % of Lilo,WebKit (RUNS=5 IDLE=60 MAX_IDLE_CPU=35,25)
ext-bench:
	@scripts/bench_extensions.sh $(or $(RUNS),5) --idle $(or $(IDLE),60) $(if $(OUT),--out $(OUT)) $(if $(MAX_IDLE_CPU),--max-idle-cpu $(MAX_IDLE_CPU))

# SUDO=1 samples with powermetrics, SUDO=0 falls back to top; GIT=1 (needs sudo) also counts git runs.
## Sample the running Lilo's CPU, wakeups and energy (DURATION=120 LABEL=run OUT=~/lilo-energy GIT=0 SUDO=1)
energy-sample:
	@$(if $(filter 0,$(SUDO)),,sudo )scripts/energy_sample.sh -d $(or $(DURATION),120) -l $(or $(LABEL),run) -o $(or $(OUT),$$HOME/lilo-energy) $(if $(filter 1,$(GIT)),--git)

## Diff two energy-sample summaries (BEFORE=before AFTER=after OUT=~/lilo-energy)
energy-compare:
	@OUT=$(or $(OUT),$$HOME/lilo-energy); scripts/energy_sample.sh compare "$$OUT/$(or $(BEFORE),before).summary.tsv" "$$OUT/$(or $(AFTER),after).summary.tsv"

# --info --debug are required: os_log info/debug messages are memory-only and absent from `log show` without them.
## Dump the app log to lilo-log.txt (SINCE=15m OUT=path)
logs:
	@OUT="$${OUT:-$$PWD/lilo-log.txt}"; \
	log show --last "$${SINCE:-15m}" --info --debug --style compact --predicate 'subsystem == "fr.arouillard.lilo"' > "$$OUT" && \
	echo "$$(grep -c . "$$OUT") lines written to $$OUT"

## Follow the app log live
logs-stream:
	@log stream --level debug --style compact --predicate 'subsystem == "fr.arouillard.lilo"'

## Serve getlilo.app with Astro and live reload on localhost:8787
site-dev: $(SITE_DEPS)
	@npm --prefix site run dev

## Stop Astro when it has started its dev server in the background
site-dev-stop: $(SITE_DEPS)
	@npm --prefix site run dev -- stop

## Preview the built website with Cloudflare's headers and redirects on localhost:8787
site-preview: site-generate
	@npm --prefix site run preview

## Build getlilo.app with Astro, Markdown copies and FAQ metadata
site-generate: $(SITE_DEPS)
	@npm --prefix site run build

## Check website lint, formatting, Astro templates and TypeScript
site-check: $(SITE_DEPS)
	@npm --prefix site run check

## Fix website lint and formatting with Ultracite
site-fix: $(SITE_DEPS)
	@npm --prefix site run fix

## Build and test the website's release notes, routes and metadata
site-test: site-generate
	@npm --prefix site run test

## Update the website's dependencies and lockfile after changing package.json
site-lock:
	@npm --prefix site update

## Check the Cloudflare deployment without publishing
site-deploy-check: site-generate
	@npm --prefix site run deploy:check

## Deploy getlilo.app to Cloudflare (requires authentication)
site-deploy: $(SITE_DEPS)
	@npm --prefix site run deploy
