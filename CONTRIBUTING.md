# Contributing to Lilo

Thanks for wanting to make Lilo better. This guide takes you from a fresh clone to a merged pull
request. Questions are welcome in [Discussions](https://github.com/Alexays/Lilo/discussions);
everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Your first contribution

1. Read [ROADMAP.md](ROADMAP.md), mostly its non-goals: a pull request that implements one is
   closed. If you are unsure whether an idea fits, open a discussion first.
2. Pick an issue, or a bug you hit yourself. Small, focused changes are the easiest to review and
   merge.
3. Set up the project ([Setup](#setup)), make the change, add a test, and run `make validate`.
4. Open a pull request against `main` ([Pull requests](#pull-requests)).

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#where-things-live) tells you which folder holds what,
and [docs/DEBUGGING.md](docs/DEBUGGING.md) how to inspect the interface, read logs and debug
extensions.

## Requirements

| Tool | Version | Needed for |
|------|---------|------------|
| macOS | 26 or later | running Lilo |
| Xcode | 27, selected with `xcode-select`, and its Metal toolchain | building the app (Swift 6, the macOS 27 SDK) |
| Node.js | 22.23.4+ (`.nvmrc` pins 22) | the Svelte interface, extension bridge and Astro website; all `make ui-preview` needs |
| Changie | 1.26.0 (downloaded by Make) | release notes and app versioning |
| SwiftLint, XcodeGen | 0.65.0 and 2.46.0 (downloaded by Make) | `make validate` and `make project-sync` |
| Zig | 0.16.x (`brew install zig`) | only `make vt-build-source`, which compiles libghostty-vt instead of downloading it |

Python 3 comes with Xcode. No Apple Developer account is needed.

## Setup

```bash
git clone https://github.com/Alexays/Lilo.git
cd Lilo
make hooks-install     # enable commit-message checks once per clone
make bootstrap         # checks the tools above, then npm deps, libghostty-vt, interface bundle, extension bridge
make app               # Debug build in build/debug/export/Lilo.app
open build/debug/export/Lilo.app
```

`make bootstrap` says what is missing and how to install it, and is a no-op once everything is
in place. It downloads libghostty-vt, the terminal library, prebuilt for the pinned Ghostty commit
and checked against the sha256 in the `Makefile`; `make vt-build-source` (or `VT_FROM_SOURCE=1`)
compiles it with Zig instead, which is also what happens, with a message, when the download is
not available. `make install-debug` installs the Debug build into `~/Applications`, and
`make install` a Release build into `/Applications`.

Run `sudo DevToolsSecurity -enable` once: otherwise `xcodebuild` eventually fails to launch the test
host with `INTERNAL ERROR: childPID > 0`, once its cached debugger authorization expires.

### Interface only

To work on the sidebar, the command bar, settings or onboarding, Node.js is enough:

```bash
make ui-preview        # opens http://localhost:5173/preview/ with hot reload
```

[`lilo-ui/preview/`](lilo-ui/preview/main.ts) runs the interface in any browser against the fake
host the end-to-end tests use, seeded with sample Spaces, pinned tabs, folders, extensions and
settings. Query parameters pick what it shows: `?world=default|empty|onboarding`,
`&theme=light|dark` (the system's otherwise) and `&open=settings|commandbar`, for example
`/preview/?world=onboarding&theme=dark`. Commands the interface sends are in
`window.__sentCommands`. The preview never ships: the app embeds only the `index.html` build.

### Signing

Without signing setup, every build is ad-hoc signed. It runs on the Mac that built it, but macOS
asks again for camera, microphone and keychain access after each rebuild, and the helper that keeps
the Mac awake with the lid closed stays off.

To sign with a stable identity (a free Apple ID's Personal Team is enough), copy
`Makefile.local.example` to `Makefile.local` and set `LILO_DEBUG_TEAM_ID`. The file is git-ignored
and explains how to find your team ID. Release signing and notarization are in
[docs/RELEASING.md](docs/RELEASING.md).

### Dev data

Only a Release build is the installed Lilo. A Debug build (`make app`, `make install-debug`,
Xcode) and the test host never touch its data:

| Build | Bundle id | Data |
|-------|-----------|------|
| Release | `fr.arouillard.lilo` | `~/Library/Application Support/Lilo` |
| Debug | `fr.arouillard.lilo.debug` | `~/Library/Application Support/Lilo-Debug` |
| `make swift-test` host | `fr.arouillard.lilo.tests` | temporary folders per test |

The bundle id also separates the preferences (`~/Library/Preferences/<bundle id>.plist`), the
WebKit data (`~/Library/WebKit/<bundle id>`) and the launch-at-login item;
`Lilo/App/BuildIdentity.swift` separates the rest (database, agent socket, keychain items, the
power helper's launch daemon). `LILO_APP_SUPPORT_DIR` overrides the data folder, agent socket
included. Tests wipe the WebKit stores they create when the run ends, and the next run removes
what an interrupted one left under `~/Library/WebKit/fr.arouillard.lilo.tests`.

## Development workflow

The [Makefile](Makefile) is the only command surface: `make help` lists every target. The ones
you use daily:

```bash
# Interface work, with hot module reload in the running app
make ui-dev          # terminal 1: Vite dev server on localhost:5173
make run-ui-dev      # terminal 2: builds the app and launches it against the dev server
make ui-preview      # or the interface alone in a browser, without Xcode

# Swift work
make app             # Debug bundle in build/debug/export/Lilo.app
make project-sync    # after adding or renaming a Swift file, or editing project.yml

# Before opening a pull request
make validate
```

- **`project.yml` is the source of the Xcode project.** Never edit `Lilo.xcodeproj` by hand. After
  adding or renaming a Swift file, run `make project-sync` and commit the regenerated project:
  `xcodebuild`, `make swift-test` and CI fail until it is in sync.
- **Generated files are build outputs.** Never hand-edit the extension bundles in
  `Lilo/Extensions/` (`ChromeAPIAugmentation.js`, `ChromeAPIBackgroundPrelude.js`,
  `ChromeAPIGapModules.json`, `ChromeWebStoreShim.js`, `ChromeContentCompat.js`, `ChromeStaticRules.js`), `*.gen.swift`,
  `tabProtocol.gen.ts`, or the git-ignored `Lilo/Generated/NativeStrings.swift` and
  `Lilo/Generated/ChromeUIAssets.swift`. Regenerate them with `make ext-bridge-build`,
  `make bridge-gen` or `make ui-build`.
- **`Package.swift` is for fast local checks only.** Once `make vt-build` and `make ui-build` have
  run, `swift build` and `swift test --filter <TestClass>` work, but `xcodebuild` (through `make`)
  is the official build, and `swift run` lacks the app's Info.plist: use `make run-ui-dev` to launch
  a real bundle.

## Tests and validation

`make validate` is the gate: UI lint, type checks, tests and build; the extension bridge build and
tests; SwiftLint; the Xcode build and the Swift tests; commit hook tests; website checks and tests;
release-note and version sync checks.
Run it once your change is done, and confirm it passes before you open a pull request.

| Command | Runs |
|---------|------|
| `make ui-lint` | ESLint and svelte-check over `lilo-ui/` |
| `make ui-test` | UI unit tests, including the en/fr catalog parity check |
| `make e2e` | Playwright end-to-end tests of the interface, in Chromium |
| `make ext-bridge-test` | extension bridge TypeScript tests |
| `make hooks-test` | commit-message validation and real Git hook/range checks in temporary repositories |
| `make lint-commit-message` | checks a commit header or PR title read from stdin |
| `make lint-commits` | checks non-merge commit headers in `BASE..COMMIT_HEAD` (default `origin/main..HEAD`) |
| `make release-status` | pending release notes, changelog and app version consistency |
| `make release-test` | release preparation and Sparkle build number synchronization tests (CI runs them; `make validate` does not) |
| `make site-check` | Ultracite lint and formatting, Astro templates and TypeScript |
| `make site-fix` | fix website lint and formatting with Oxlint and Oxfmt |
| `make site-test` | website build, release notes, routes, links and metadata |
| `make swift-test` | Swift tests in parallel app instances, the slow ones aside |
| `make swift-test-slow` | the few Swift tests that wait out real clocks, WebKit's or Lilo's (`SLOW_TESTS` in the Makefile) |
| `make check-commits` | builds every commit of `BASE..HEAD` (default `origin/main`) in a throwaway worktree |

Heavier checks, run when your change touches their area:

| Command | Runs |
|---------|------|
| `make ext-smoke` | the 100 most used Web Store extensions against Chrome's recorded behavior, and what a few do on a local page past their popup (network; `TOP=500`, `IDS=a,b`) |
| `make ext-nightly` | unattended `ext-smoke` of the top 500 (`TOP=1000` for all), with a report in `.derived.noindex/ext-smoke/report.txt` and a non-zero exit on a regression |
| `make terminal-bench` | terminal throughput and lock-fairness benchmarks |
| `make startup-bench` | launch times of a Release build against a throwaway profile |
| `make ext-bench` | a Release build with 20 store extensions: restore, worker starts, API latency and idle CPU, failing when idle CPU % goes over `MAX_IDLE_CPU=35,25` (Lilo, its WebKit processes; `MAX_IDLE_CPU=` only measures) |
| `make e2e-energy` | idle energy guard on a Release build (about 3 minutes, see [DEBUGGING.md](docs/DEBUGGING.md#9-measuring-energy)) |

### Where tests go

- **Swift**: `LiloTests/` mirrors the source tree, so the tests of `Lilo/<Folder>/X.swift` go in
  `LiloTests/<Folder>/XTests.swift`. Shared helpers (temporary databases and browser contexts,
  fixtures, async polling) live in `LiloTests/Support/`.
- **Interface**: `*.test.ts` beside the Svelte source in `lilo-ui/src/`, and Playwright specs in
  `lilo-ui/e2e/`.
- **Extension bridge**: `*.test.ts` beside the TypeScript source in
  `Lilo/Extensions/bridge-src/src/`.
- **Commit hooks**: `scripts/commit_hooks.test.sh` exercises the shared validator and real Git
  commits in temporary repositories, without Node dependencies.

Test through the real entry point (the public method, the bridge message, the rendered component)
rather than carving out a helper just to reach it.

### CI

`.github/workflows/build.yml` runs on every push to `main` and every pull request:

- **Release tooling and website** (ubuntu): Changie fragments, version sync, Ultracite and Astro checks, website tests and a Cloudflare deployment dry run.
- **UI** (ubuntu): `make validate-ui` and `make e2e`.
- **Extension bridge** (ubuntu): `make ext-bridge-test`, and a check that the generated bundles
  match `bridge-src`.
- **App** (the GitHub-hosted `xcode-27` macOS image, no signing secrets): a check that
  `Lilo.xcodeproj` matches `project.yml`, SwiftLint, the Debug and Release builds,
  `make swift-test` and `make swift-test-slow`.
- **libghostty-vt** (`.github/workflows/ghostty-vt.yml`, by hand or when `GHOSTTY_SHA` changes on
  `main`): builds the xcframework `make vt-build` downloads and publishes it as the
  `ghostty-vt-<sha>` prerelease, whose notes give the new `VT_SHA256`.
- **Startup benchmark** (informational, pushes to `main`): `make startup-bench RUNS=5 TABS=10` on the
  app the Release build just exported, uploaded as the `startup-bench-<sha>` artifact. It never fails the run.

`.github/workflows/extensions-nightly.yml` runs every night (and by hand) in `Alexays/Lilo` only, on the
`xcode-27` image: `make ext-bench` against its idle CPU budget, then `make ext-nightly TOP=1000`. The
reports are the `extensions-nightly-<sha>` artifact, and the run's summary quotes them.

`build.yml` needs no secrets and only reads the repository, so pull requests from forks run it as is. CI runs
a failed Swift or Playwright test once more and lists the tests that passed only on that retry in
the run's summary; `make validate` and `make e2e` never retry, so a flaky test fails locally.

If your pull request fails on a test your change does not touch, say so in a comment with the failing
test's name: a maintainer reruns the job, and an issue with the failure message (the
`swift-test-results` and `playwright-traces` artifacts hold the details) gets the test fixed. Don't skip
or loosen the test in your pull request.

`.github/workflows/commits.yml` checks commit messages on pushes to `main` and pull requests,
and PR titles when a pull request is opened, updated, reopened or edited. It uses the same shell
validator as the local hook and checks the PR's own commits, excluding GitHub's generated merge
commit. Title edits run only this lightweight workflow. Maintainers should require its
`Conventional Commits` status check in the rules for `main`.

## Code style

[AGENTS.md](AGENTS.md) holds the rules for everyone, human or agent. In short:

- **KISS.** The least code that solves the problem: no speculative abstraction, no single-use
  protocol, no setting with one caller.
- **Surgical diffs.** Touch only what the task needs and match the surrounding style.
- **Placement.** A new file goes where the
  [placement rule](docs/ARCHITECTURE.md#placement-rule) says.
- **Design bar: Apple and Arc.** Native conventions (HIG spacing, SF Symbols, system fonts,
  standard shortcuts and menus), calm motion that respects Reduce motion, no layout jumps, AA
  contrast, every control reachable by keyboard.
- **Efficiency first.** No polling, no redundant renders, nothing at idle. A feature that costs
  CPU, memory or battery when unused is a bug.
- **One engine.** WebKit only, and direct dependencies only.
- **Comments** say what the code cannot: a constraint, a non-obvious why, a deliberate oddity.
  Never what the next line does, or what the code used to do.
- **Formatting** follows `.editorconfig` (4 spaces in Swift and shell, 2 elsewhere) and
  `.swiftlint.yml`, which `make swiftlint` enforces in strict mode.

## Common tasks

### Add or change a user-facing string

Every string is translated into English and French.

1. Add the key under the right namespace in both `lilo-ui/src/lib/i18n/locales/en.json` and
   `fr.json`.
2. In Svelte, use `t("namespace.key")`. In AppKit, write the English string with `.localized`
   and add an `"English": "Français"` row under the `native` namespace of both catalogs.
3. `make ui-test` fails if a key is missing from either catalog.

[docs/I18N.md](docs/I18N.md) covers plurals, placeholders and adding a language.

### Add a Chrome Gap API

Lilo relies on WebKit's native `WKWebExtension` support first. Add a Gap API only when WebKit
lacks a Chrome API and a real, user-visible extension flow needs it.

1. **Swift handler** in `Lilo/Extensions/GapAPI/`, conforming to `GapHandler`. Each receives one
   `GapCall`, already authenticated by `GapBridgeRouter`, carrying the calling extension's id and
   its profile's registry. Never read an extension id from the call's params.
2. **Register it** on the gap router in `WKEngineFactory`. Per-profile dependencies (stores) come
   from `call.registry`, so a call always reaches its own profile. A handler that needs
   window-level collaborators stays app-wide on the router and lets each window attach to it, as
   `OmniboxGapRelay` does.
3. **JS surface** as a module under `Lilo/Extensions/bridge-src/src/augmentation/`, installed by
   `shared/install-gap-apis.ts` in extension pages and service workers. A namespace that needs a
   permission goes in `shared/gap-modules.ts`, so a context whose manifest does not use it never
   evaluates it. Run `make ext-bridge-build` and commit the regenerated bundles.
4. **Update [COMPATIBILITY.md](COMPATIBILITY.md)**, which lists only what differs from Chrome:
   add the API to the "Supported as in Chrome" line when it fully matches, or document its
   differences. `ChromeSurfaceTests` reads that file.
5. **Tests**: Swift tests in `LiloTests/Extensions/`, bridge tests beside the TypeScript source.
6. **Verify** with `make ext-bridge-test` and the smallest Swift check that covers the change. For
   a manual pass, load `test-extensions/extension-probe/` with
   **Develop > Load Unpacked Extension...**: it exercises the MV3 surface (messaging, DNR,
   tabGroups, content-script worlds).

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#gap-api-layer) explains the layer, and
[docs/WEBKIT-GAPS.md](docs/WEBKIT-GAPS.md) what WebKit itself is missing.

### Use a private WebKit API

Guard every private selector with `responds(to:)` and degrade gracefully when it is missing, and
register new private delegate hooks in `PrivateDelegateSelectorTests`. The conventions are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#private-webkit-api).

### Change the tab bridge protocol

Edit `bridge-schema/tab.json`, then run `make bridge-gen` to regenerate
`lilo-ui/src/lib/bridge/tabProtocol.gen.ts` and `Lilo/Generated/TabBridgeSchema.gen.swift`.

`make validate` runs every Swift test but the few that wait out WebKit's own clocks (`make swift-test-slow`, run by CI), and it should take about 30 s on a warm machine. The Swift tests are most of it, so keep each one cheap:

- Wait for a condition with `pollUntil`, never a fixed sleep. When the app itself waits (a settle time, a grace period), shorten it from a `static var` the test base class sets, as `AgentToolTestCase` does with `AgentTools.settleQuiet`, and put it back in `tearDown`.
- Every `WKWebView` launches a WebContent process. Test logic without one when you can, and add a case to an existing web view test that shares your setup rather than a new test.
- Query website data with `WKWebsiteDataStore.testDataTypes`, not `allWebsiteDataTypes()`: Screen Time's type waits on a system service, for seconds when several runs ask at once.
- Size fixtures for the behavior, not for realism, and guard scaling by comparing a run with one twice its size (CPU time, not wall time), as `ImportScaleTests` does.

## Pull requests

1. Fork the repository and branch from `main`.
2. Make focused commits, each building on its own (`make check-commits` checks a branch).
   Run `make lint-commits` to check their messages; `BASE=main` selects a different base.
3. Run `make validate` and confirm it passes.
4. For a change people using Lilo will notice, run `make change`. Choose `Fixed` or `Changed`
   for a patch release, `Added` for a minor release, or `Breaking` for a major release. Write the
   summary for the person using the app and commit the generated `.changes/unreleased/*.yaml`
   file with your code. Documentation, tests and build tooling usually need no fragment.
   `CHANGELOG.md` is updated when a maintainer prepares the release. CI warns on a pull request that
   changes `Lilo/` or `lilo-ui/src/` without a note.
5. Open the pull request. The template asks what it does, how to test it, and for a screenshot or
   recording of any UI change.

Commit messages and pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope): description`, lowercase, imperative, no trailing period, with an optional scope
and `!` before the colon for a breaking change. Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`,
`chore`, `style`. Common scopes: `sidebar`, `tabs`, `spaces`, `commandbar`, `urlbar`, `settings`,
`extensions`, `agent`, `terminal`, `window`, `bridge`, `import`, `ui`.

`make hooks-install` points this clone's Git `core.hooksPath` at the tracked `.githooks/`
directory. It refuses when `core.hooksPath` is already set or `.git/hooks` holds a hook that
would stop running. The native `commit-msg` hook and CI share a shell validator for the
header's type, syntax, lowercase scope, lowercase nonempty description and absence of trailing
whitespace or a final period. Git's `Revert "..."` and `Reapply "..."` headers are accepted.
English wording and imperative style are reviewed by humans. Bodies and footers remain free-form. To check a title locally:

```bash
printf '%s\n' 'fix(sidebar): keep pinned tabs visible' | make lint-commit-message
```

Git-generated merge commits are exempt. Temporary `fixup!`, `squash!` and `amend!` commits are
allowed locally; autosquash them before merging, since CI rejects them. Local hooks can be
bypassed, so CI also checks every non-merge commit introduced by a PR and the PR title.

Code, comments, commit messages and everything on GitHub are written in English. User-facing copy
is translated, see [Add or change a user-facing string](#add-or-change-a-user-facing-string).

## License of contributions

There is no CLA and no DCO. By opening a pull request you agree that your contribution is
licensed under the project's [MIT license](LICENSE).

## Releases

Releases are cut by maintainers, by tagging `vX.Y.Z`. The process is in
[docs/RELEASING.md](docs/RELEASING.md).
