# AGENTS.md

Rules for coding agents (and humans) working in Lilo. Bias toward small, KISS changes - [ROADMAP.md](ROADMAP.md) lists the non-goals.

## Build & verify

- The **Makefile is the only command surface.** Don't invent build steps; `make help` lists everything.
- **`make validate` is the gate** - UI lint/tests, SwiftLint, the Xcode build, Swift tests, and the extension bridge. Run it before claiming a change works. It should stay around 30 s warm: write tests that keep it there ([CONTRIBUTING.md](CONTRIBUTING.md#tests)). (CI additionally runs `make e2e` and `make swift-test-slow`, checks that `Lilo.xcodeproj` and the generated extension bridge bundles are in sync, and builds Release.)
- `swift build` / `swift test` are fine for fast local checks once `make vt-build` and `make ui-build` have produced `Vendor/` and the generated sources; `xcodebuild` (via `make`) is the official path. Run directly, it takes `-derivedDataPath .derived.noindex/xcode` as `make` does, so a worktree's build goes with the worktree.
- After **adding or renaming a Swift file**, run `make project-sync` and commit the regenerated `Lilo.xcodeproj` - `xcodebuild` and CI fail until it is synced.

## House style

- **KISS.** Minimum code that solves the problem. No speculative abstraction, no single-use protocols, no config knobs with one caller. If it could be half the size, rewrite it.
- **Surgical diffs.** Touch only what the task needs and match the surrounding style. Don't refactor code that isn't part of the task.
- **Placement.** A new file goes where the [placement rule](docs/ARCHITECTURE.md#placement-rule) says; tests mirror source paths.
- **Design bar: Apple and Arc.** Every screen and interaction must feel like a first-party macOS app with Arc's polish: native conventions (HIG spacing, SF Symbols, system fonts, standard shortcuts and menus), calm motion that respects Reduce motion, no layout jumps, nothing clipped or misaligned, AA contrast, every control reachable by keyboard. If it would look out of place in an Apple app, it is not done.
- **Efficiency first.** Do the least work possible: no polling, no redundant renders or recomputation, no resending unchanged data, nothing at idle. A feature that costs CPU, memory or battery when unused is a bug.
- **Comments** only for what the code cannot say: a constraint, a non-obvious why, a deliberate oddity. Never restate the next line or record history. Code, comments and commit messages are in English; user-facing copy is translated.
- **No real user data** in tests, fixtures, docs, commits or release notes: a URL, page title, folder name or account seen while debugging is replaced by a made-up equivalent (`example.com` hosts, generic names) that reproduces the same case.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) (`fix(sidebar): ...`), one logical change each.
- One web engine (WebKit), direct dependencies only. Terminal tabs use libghostty-vt from a pinned Ghostty commit: `make vt-build` downloads it prebuilt and checksum-pinned, `make vt-build-source` compiles it with Zig.

## Gotchas

- **Localization** - user-facing strings live in `lilo-ui/src/lib/i18n/locales/*.json`; add every key to **all catalogs** (the `make ui-test` parity check fails otherwise). Native AppKit strings use `.localized` under the `native` namespace. See [docs/I18N.md](docs/I18N.md).
- **Extension Gap APIs** - add one only when WebKit lacks the Chrome API *and* a real extension flow needs it. A Swift handler must be paired with JS augmentation, and [COMPATIBILITY.md](COMPATIBILITY.md) must be updated: it describes only what still differs from Chrome. See [CONTRIBUTING.md](CONTRIBUTING.md#add-a-chrome-gap-api).
- **Page-world APIs** - anything a web page can see goes through `PageWorld` (handlers in its bridge world, modules patching WebKit's prototypes): a global, a page-world handler or a function printing its source flags Lilo as a bot. `PageWorldTests` fails on any such trace. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#page-world-apis).
- **Private WebKit API** - guard every private selector with `responds(to:)` and degrade gracefully when it is missing; register new private delegate hooks in `PrivateDelegateSelectorTests`. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#private-webkit-api).
- **Release notes** - a change people using Lilo will notice gets a note from `make change`, committed with the code under `.changes/unreleased/`; without a prompt, run the Makefile's `$(CHANGIE)` as `new --interactive=false -k <Kind> -b <text>`. Never edit `CHANGELOG.md`: `make release-version` generates it from the notes. A feature release (`x.y.0`) also needs its What's New highlights and its website story, or `make release-version` refuses it. See [docs/RELEASING.md](docs/RELEASING.md).
- **CSS `:has()`** is fine, but not always the best tool: a broad one makes WebKit recheck its whole container on each change inside. When Svelte state already knows the condition, a class is simpler and cheaper.
- **Generated files** (`ChromeAPIAugmentation.js`, `ChromeAPIBackgroundPrelude.js`, `ChromeAPIGapModules.json`, `ChromeWebStoreShim.js`, `ChromeContentCompat.js`, `ChromeStaticRules.js`, `*.gen.swift`, `tabProtocol.gen.ts`, plus the git-ignored `Lilo/Generated/NativeStrings.swift` and `Lilo/Generated/ChromeUIAssets.swift`) are build outputs - never hand-edit them; regenerate via `make ext-bridge-build` / `make bridge-gen` / `make ui-build`.

For website changes, read [site/AGENTS.md](site/AGENTS.md) for Astro-specific rules.

Architecture deep-dive: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Setup, tests and the pull request flow: [CONTRIBUTING.md](CONTRIBUTING.md).
