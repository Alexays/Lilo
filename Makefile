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
# They wait out WebKit's own clocks (a worker's 30 s unload, a controller's first 5 s): about 90 s together.
SLOW_TESTS := GapRouterStoreProviderTests/testAnIdleWorkerUnloadsOnChromesScheduleAndHearsLaterEvents \
	ProfileExtensionRegistryTests/testReEnabledOrReloadedWorkerHearsNeitherOnInstalledNorOnStartup \
	ProfileExtensionRegistryTests/testWorkersRestoredLateHearOnStartupOnly \
	WebKitGapTests/testLifecycleEventsDependOnTheControllerAge \
	WebKitGapTests/testWebSocketStallsTheWorkerLoad
DEBUG_TEAM_ID := $(or $(LILO_DEBUG_TEAM_ID),$(LILO_TEAM_ID))
DEBUG_SIGNING := $(if $(DEBUG_TEAM_ID),DEVELOPMENT_TEAM=$(DEBUG_TEAM_ID) CODE_SIGN_IDENTITY="$(or $(LILO_DEBUG_CODE_SIGN_IDENTITY),Apple Development)" CODE_SIGN_STYLE=Manual)
# The test host is its own app: its camera, microphone and keychain grants and its background
# permission never touch the installed Lilo's, and a stable signature keeps them across builds.
TEST := $(XCODEBUILD) -configuration Debug LILO_BUNDLE_ID_SUFFIX=.tests $(DEBUG_SIGNING) test
# CI (which sets CI) runs a failed test once more and lists it in the job summary; locally a flake fails.
TEST_RETRY := $(if $(CI),-retry-tests-on-failure -test-iterations 2)
TEST_WORKERS = $(shell sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)

.PHONY: help validate validate-ui swiftlint project-sync ui-build ui-watch ui-dev ui-lint ui-test e2e e2e-energy \
	swift-test swift-test-slow blocker-coverage terminal-bench ext-bridge-build ext-bridge-test ext-smoke ext-nightly top-extensions chrome-surface \
	chrome-contracts chrome-smoke public-suffix-list app install install-debug xcode-build xcode-build-release \
	run-ui-dev release release-notarize dmg dmg-background bridge-gen vt-build vt-build-source vt-zip bootstrap ui-preview check-commits startup-bench energy-sample energy-compare \
	logs logs-stream site-dev site-generate site-deploy emoji-data password-manager-icons \
	hooks-install hooks-test lint-commit-message lint-commits

## List the targets
help:
	@awk '/^## /{d=substr($$0,4);next} d&&/^[a-z0-9-]+:/{sub(/:.*/,"");printf "  make %-20s %s\n",$$0,d} {d=""}' Makefile

## Check the prerequisites, then fetch and build what a fresh clone needs (npm deps, libghostty-vt, UI bundle, bridge)
bootstrap:
	@scripts/bootstrap.sh "$(UI_DEPS) $(BRIDGE_DEPS)" "vt-build $(UI_STAMP) $(BRIDGE_STAMP)" \
	hooks-install hooks-test lint-commit-message lint-commits

# The app embeds the UI and bridge builds, rebuilt only when their sources changed; swift-test builds the app.
# The lint and the JS tests run beside the other steps, their output shown on failure.
## Run UI lint/tests/build, Swift lint/tests, the app build, bridge and hook checks
validate: $(UI_DEPS) $(BRIDGE_DEPS)
	@log=$$(mktemp); $(MAKE) -k --no-print-directory hooks-test ui-lint ui-test ext-bridge-test swiftlint > "$$log" 2>&1 & js=$$!; \
	$(MAKE) --no-print-directory $(BRIDGE_STAMP) & bridge=$$!; \
	$(MAKE) --no-print-directory $(UI_STAMP); ui=$$?; wait $$bridge; bridge=$$?; \
	[ $$ui -eq 0 ] && [ $$bridge -eq 0 ] && $(MAKE) --no-print-directory swift-test; swift=$$?; \
	wait $$js; js=$$?; [ $$js -eq 0 ] || cat "$$log"; /bin/rm -f "$$log"; \
	[ $$swift -eq 0 ] && [ $$js -eq 0 ]

$(UI_STAMP): $(UI_DEPS) $(UI_SOURCES)
	@$(MAKE) --no-print-directory ui-build
	@mkdir -p $(@D) && touch $@

$(BRIDGE_STAMP): $(BRIDGE_DEPS) $(BRIDGE_SOURCES)
	@$(MAKE) --no-print-directory ext-bridge-build
	@mkdir -p $(@D) && touch $@

## Run the CI UI validation sequence (lint + test + build)
validate-ui: ui-lint ui-test ui-build

## Run Swift lint only
swiftlint:
	@command -v swiftlint >/dev/null || { echo 'Install swiftlint with: brew install swiftlint' >&2; exit 1; }
	@swiftlint lint --config .swiftlint.yml --strict

## Regenerate Lilo.xcodeproj from project.yml
project-sync: $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@command -v xcodegen >/dev/null || { echo 'Install xcodegen with: brew install xcodegen' >&2; exit 1; }
	@xcodegen generate --spec project.yml

$(UI_DEPS): $(UI_DIR)/package-lock.json
	@npm --prefix $(UI_DIR) ci

$(BRIDGE_DEPS): $(BRIDGE_DIR)/package-lock.json
	@npm --prefix $(BRIDGE_DIR) ci

$(SITE_DEPS): site/package-lock.json
	@npm --prefix site ci

## Build the embedded Svelte UI bundle and the Swift sources generated from lilo-ui
ui-build: $(UI_DEPS)
	@npm --prefix $(UI_DIR) run build
	@python3 scripts/embed_chrome_ui.py
	@python3 scripts/generate_native_strings.py

# Built once when missing so a fresh clone compiles; make ui-build refreshes it.
$(CHROME_UI_ASSETS):
	@$(MAKE) --no-print-directory ui-build

$(NATIVE_STRINGS): $(UI_DIR)/src/lib/i18n/locales/fr.json
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

## Run the Swift tests that wait out WebKit's clocks, which swift-test skips
swift-test-slow: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@$(TEST) $(addprefix -only-testing:LiloTests/,$(SLOW_TESTS)) -parallel-testing-enabled YES \
		$(TEST_RETRY) $(if $(RESULT_BUNDLE),-resultBundlePath '$(RESULT_BUNDLE)')

## Report what the converter keeps of the default filter lists, by kind and skip reason (network; OUT=build/blocker-coverage.txt)
blocker-coverage: vt-build $(CHROME_UI_ASSETS) $(NATIVE_STRINGS)
	@out="$(abspath $(or $(OUT),build/blocker-coverage.txt))"; mkdir -p "$$(dirname "$$out")"; /bin/rm -f "$$out"; \
	TEST_RUNNER_LILO_BLOCKER_COVERAGE="$$out" $(TEST) -only-testing:LiloTests/FilterListCoverageTests > /dev/null; cat "$$out"

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

## Unattended ext-smoke of the top 500; report in .derived.noindex/ext-smoke/report.txt, non-zero exit on a regression
ext-nightly:
	@$(MAKE) --no-print-directory ext-smoke TOP=$(or $(TOP),500)

## Rebuild top-extensions.json from the Chrome Web Store user counts (TOP=500)
top-extensions:
	@node scripts/top-extensions.mjs $(or $(TOP),500)

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
release: vt-build ui-build ext-bridge-build
	@scripts/build-app.sh release

## Build the UI bundle and notarize the release artifacts
release-notarize: vt-build ui-build ext-bridge-build
	@scripts/build-app.sh release notarize

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

## Time launches of a Release build against a throwaway profile (RUNS=10 TABS=0)
startup-bench:
	@scripts/bench_startup.sh $(or $(RUNS),10) --tabs $(or $(TABS),0) $(if $(OUT),--out $(OUT))

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

## Serve the getlilo.app landing page locally (wrangler dev)
site-dev: $(SITE_DEPS)
	@npm --prefix site run dev

## Regenerate the landing page's Markdown copies, llms-full.txt and JSON-LD from its HTML
site-generate:
	@python3 site/generate.py

## Deploy the landing page to Cloudflare (needs npx wrangler login once)
site-deploy: $(SITE_DEPS)
	@npm --prefix site run deploy
