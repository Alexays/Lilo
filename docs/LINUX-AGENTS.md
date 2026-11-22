# Linux agents

Lilo is a macOS app and stays one: [ROADMAP.md](../ROADMAP.md) rules out a Windows or Linux port.
This page is about the development loop only.
A coding agent in a Linux sandbox or cloud box can do most of the work on the web side (the UI, the extension bridge, the websites, the documentation, the release tooling) and cannot do the Swift side.

## What runs on Linux

`make linux-checks` runs every check that needs no Xcode: the same list `make validate` reads (the `VALIDATE_CHECKS` variable in the Makefile is the one source for both, so they cannot drift), plus `release-test` and `release-media-test`, minus the app build and the Swift tests.
CI already runs the same targets on `ubuntu-latest`, so what passes there passes in a Linux sandbox.
Measured on Debian 13 (6 cores, 11 GB) against `c24fc63c`:

| Target | Checks | Result |
|--------|--------|--------|
| `ui-lint`, `ui-test` | svelte-check, lint and unit tests of `lilo-ui` | 0 errors, 654 of 654 |
| `ext-bridge-test` | the extension bridge unit tests | 587 of 587 |
| `site-check`, `site-test` | getlilo.app type check and tests | 0 errors, 86 of 86 |
| `docs-check`, `docs-test` | docs.getlilo.app build, links and audits | no broken links, 4,503 audits |
| `hooks-test`, `perf-summary-test`, `release-status` | commit hooks, perf summary, release notes and versions | pass |
| `swiftlint` | Swift lint | 0 violations in 321 files |

These also pass on Linux but sit outside `linux-checks` because they are heavier or need a browser or network download: `e2e` (run `npx playwright install --only-shell chromium` first, as CI does), `site-e2e`, `site-deploy-check`, `docs-deploy-check`, `bridge-gen`, `ui-build` and `vt-build`.

`make swiftlint` on Linux downloads the static `swiftlint_linux_amd64.zip` (pinned checksum in the Makefile) and runs the same rules as macOS except `statement_position` and `vertical_whitespace_closing_braces`, which need SourceKit: it prints a warning and skips them.
The macOS CI job runs all of them.
The dynamic binary in the same zip covers both rules but crashes without a Swift toolchain, so it is not the default.
The Linux download is amd64 only; on arm64 the target stops with `Unsupported SwiftLint platform`.

## What needs macOS

| Target | Why |
|--------|-----|
| `app`, `install*`, `xcode-build*`, `run-ui-dev` | `xcodebuild`, AppKit, WebKit and Metal exist only on macOS. |
| `swift-test`, `swift-test-slow` | the tests run in the app host. |
| `release*`, `dmg*` | signing, notarization and Sparkle. |
| `ext-smoke*`, `ext-e2e*`, every `*-bench`, `energy-*`, `agent-call` | they drive the built app. |
| `project-sync` | XcodeGen has no Linux build. |
| `validate` | it ends in `swift-test`; on Linux run `linux-checks`. |

`make chrome-surface` and `make public-suffix-list` rewrite committed generated files from the network: they are regenerators, not checks, and leave the tree dirty.

## Several agents on one box

Give each agent its own git worktree outside the repository and install its dependencies there:

```bash
git worktree add ~/.worktrees/<ticket>/<keywords> -b <branch> origin/main
cd ~/.worktrees/<ticket>/<keywords>
make linux-checks
```

- Never share a `node_modules` between worktrees, and never run two `npm ci` in the same tree.
- Budget about 4 GB free per worktree: the four npm trees are about 2.3 GB installed. Each target installs only the trees it needs.
- Builds, `site-test` and `docs-test` are the heavy ones: on a small box run them one at a time.
- Scope the run to the diff as [AGENTS.md](../AGENTS.md) says; `make linux-checks` is the full pass before a push.

## Swift on Linux

No toolchain compiles, runs and tests an AppKit and WebKit app on Linux as of November 2026.
195 of the app's 323 Swift files import AppKit or WebKit, and `swift build` stops at the GhosttyVt binary target, which has no Linux slice.
Darling cannot run `xcodebuild`, GNUstep is not Apple's AppKit, and the Xcode and Apple SDKs Agreement does not allow the Apple toolchain on non-Apple hardware.
Cross-compilers such as `xtool` can build for Apple platforms from Linux but cannot run or test the result.

A Linux agent's loop for a Swift change is therefore: edit, `make swiftlint`, push the branch, read the macOS jobs' result in CI.
A self-hosted or rented Mac only becomes worth it if the five concurrent macOS jobs of a free GitHub plan really queue pull requests.

## Measurements

Wall time per target on an Apple M1 with 8 GB under load from other work (dependencies installed, load average 11 to 13), so an order of magnitude only:

| Target | Seconds |
|--------|---------|
| `ui-lint` / `ui-test` | 5.4 / 2.7 |
| `site-check` / `site-test` | 10.9 / 5.8 |
| `docs-check` / `docs-test` | 4.5 / 7.1 |
| `hooks-test` / `perf-summary-test` | 2.5 / 0.1 |
| `ext-bridge-test` | 2.4 |
| `swiftlint` | 0.5 warm cache, 9 cold |
| `release-status` | 1.2 |
| `make linux-checks`, one run | 77 |

`linux-checks` runs its targets one after another, where `make validate` runs groups in parallel.
Both numbers are single samples.
Not measured: per-target timings on Linux, cold dependency installs, and a Mac reached over SSH.
