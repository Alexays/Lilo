# In-app What’s New Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present the approved compact release-highlights sheet once after updates and reopen it from Help.

**Architecture:** A small app-wide native state object owns the version marker and reserves one automatic presentation. The existing chrome bridge requests a lazy Svelte dialog, which acknowledges a successful mount and restores native focus on dismissal. Vite bundles the installed release’s Changie notes and exact-version optional highlights, with no runtime fetch.

**Tech Stack:** Swift 6, AppKit, Svelte 5, TypeScript, Vite 6, existing XCTest and Playwright infrastructure.

**Spec:** `docs/superpowers/specs/2026-10-28-in-app-whats-new-design.md`

## Global Constraints

- The Makefile is the command surface; run `make validate` before claiming the implementation works.
- No website changes, notifications, telemetry, runtime AI, remote media, or release-feed polling.
- No additional web view or dependency is needed.
- Keep the first-frame UI budget unchanged; justify any modest total-bundle budget adjustment with the measured new optional chunk.
- Curated headlines and benefit copy are translated in both catalogs; canonical Changie entries remain original English.
- The sheet is approximately 560 points wide, has no more than three highlights, and respects Reduce Motion.
- Fresh installs, repeated launches, chrome reloads, and downgrades do not announce an update.
- Use made-up data in tests; regenerate the Xcode project after adding Swift files.

## Review Focus

- A failed lazy load or closed window must not consume the durable presentation marker; native tests reserve without acknowledging and instantiate a later launch.
- Two restored windows must not each present; native tests make two reservations against one shared state.
- A new release without curated content must show only its own complete notes; pure tests select an unknown version and an exact-version mismatch.
- Long notes, French copy, and a short tab-strip window must keep dismissal reachable; end-to-end tests measure dialog/footer bounds and expand notes.
- Onboarding, recovery, and native sheets must retain priority; UI tests queue automatic events behind a recovery banner, and native integration defers while an attached sheet exists.

---

### Task 1: Bundle truthful release content

**Files:**
- Create `lilo-ui/src/components/whatsnew/releaseNotes.ts`, `releaseNotes.test.ts`, `releaseHighlights.json`.
- Create `lilo-ui/releaseNotesPlugin.ts` and `lilo-ui/src/releaseNotes.d.ts`.
- Modify `lilo-ui/vite.config.ts` and the Makefile’s `UI_SOURCES` prerequisites.

**Interfaces:**
- `ReleaseNotes` contains `version`, `date`, ordered `groups: { kind, entries: string[] }[]`, and optional curated headline/description keys and `highlights`.
- `parseReleaseNotes(markdown: string, version: string): ReleaseNotes` reads exactly the requested version and every entry without executing HTML.
- `releaseHighlightsForVersion(registry: unknown, version: string)` validates the exact-version optional record and limits recognized illustrations to three highlights.
- `virtual:lilo-release` exports one `ReleaseNotes` value assembled during the UI build from the package version and `.changes/v{version}.md`.

- [ ] Write pure failing tests for the installed section, ordered groups, all entries and continuations, missing/mismatched versions, malformed data, invalid dates, and exact-version highlight selection.
- [ ] Run `TZ=UTC make ui-test`; expect failures confined to the new content tests.
- [ ] Implement the pure parser and build plugin. Watch package version, prepared release files, and the optional registry. Bundle only the selected release. Supply the two approved 0.6.0 highlights; leave later versions without claims until authored.
- [ ] Run `TZ=UTC make ui-test` and `make ui-build`; inspect the optional chunk size and unchanged first-frame budget.

### Task 2: Own presentation and native focus

**Files:**
- Create `Lilo/WhatsNew/WhatsNewState.swift`, `WhatsNewBridgeHandler.swift`, `MainWindowController+WhatsNew.swift`, and `LiloTests/WhatsNew/WhatsNewStateTests.swift`.
- Modify `Lilo/App/BrowserContext.swift`, `Lilo/App/MainMenu.swift`, `Lilo/Window/MainWindowController.swift`, `MainWindowController+Setup.swift`, `MainWindowController+Input.swift`, and any existing menu-validation integration needed to keep the dialog modal.
- Modify `lilo-ui/src/lib/bridge/protocol.ts` and `actions.ts`; regenerate `Lilo.xcodeproj` with `make project-sync`.

**Interfaces:**
- `WhatsNewState(defaults: UserDefaults)` owns the highest-presented version and an in-memory reservation.
- `reserveAutomatic(version: String, freshInstall: Bool) -> Bool` seeds fresh installs and accepts one numerically newer valid release per launch.
- `acknowledge(version: String)` persists only a valid current presentation and never lowers the marker.
- Chrome commands: `requestWhatsNew`, `whatsNewPresented { version }`, and `dismissWhatsNew`.
- Host event: `openWhatsNew { version: string, automatic: boolean }`.
- `MainWindowController.showWhatsNew(_:)` is the Help menu action. Native focus is captured/moved when the UI acknowledges its mounted dialog and restored on dismissal.

- [ ] Write failing cheap native tests for fresh install, adoption, newer/same/older versions, malformed versions, multiple windows, pending acknowledgment, and acknowledgment that cannot lower the marker.
- [ ] Run `make project-sync` and `make swift-test`; expect the new state interface to be missing before implementation.
- [ ] Implement the state, bridge handler, native Help action, one startup request, event-driven native-sheet deferral, and native focus/accessibility ownership. Debug skips automatic presentation. Block tab/page shortcuts behind the open dialog.
- [ ] Register the handler alongside the existing onboarding/settings handlers and localize the native Help entry in both catalogs.
- [ ] Regenerate the project and run `make swift-test`. Keep pre-existing baseline failures separate; do not weaken unrelated checks.

### Task 3: Present the compact dialog and verify the feature

**Files:**
- Create `lilo-ui/src/stores/whatsNew.svelte.ts` and `lilo-ui/src/components/whatsnew/WhatsNewHost.svelte`, `WhatsNewSheet.svelte`, `WhatsNewArt.svelte`.
- Modify `lilo-ui/src/stores/init.ts`, `lilo-ui/src/components/DeferredChrome.svelte`, and both i18n catalogs.
- Add `lilo-ui/e2e/whatsNew.spec.ts`; extend `lilo-ui/preview/main.ts` with an opt-in What's New preview.
- Add release-authoring documentation in `docs/RELEASING.md` and a Changie fragment.

**Interfaces:**
- The deferred store captures `openWhatsNew` before the lazy view exists and makes duplicate opens idempotent.
- `WhatsNewHost` requests automatic eligibility once after mount and holds automatic requests behind onboarding/recovery/permission state. It imports the sheet only when needed.
- `WhatsNewSheet` consumes Task 1 content and Task 2 bridge actions. A native HTML dialog supplies inert background controls and keyboard cycling inside the existing chrome web view; the registered full-window hit zone captures pointer input.
- Missing notes suppress automatic presentation; manual opening displays the localized fallback. Missing highlights expand the complete notes by default. No raw HTML rendering is used.

- [ ] Write end-to-end tests for opening/acknowledgment, duplicate events, complete-note expansion, Continue/Escape, focus trapping/restoration, automatic recovery deferral, French copy, all tab placements, a hidden sidebar, short viewport, and Reduce Motion.
- [ ] Implement the dialog using existing theme tokens, a scrollable body and reachable footer, translated labels/headlines, and two static decorative illustrations matching the approved mockup.
- [ ] Run `make ui-lint`, `TZ=UTC make ui-test`, `make ui-build`, and `make e2e`; verify the content and interaction tests pass without changing existing behavior.
- [ ] Inspect the production chrome preview in light/dark and French at a short size. Adjust only demonstrated issues.
- [ ] Document optional exact-version highlight authoring and add the release fragment with the pinned Changie tool from the Makefile.
- [ ] Run `make project-sync`, `make validate`, and, if the known local DST fixture still fails, `TZ=UTC make validate`. Report any remaining baseline failure by name.
- [ ] Obtain one independent whole-change review, fix substantive findings, and rerun only checks justified by those fixes.
- [ ] Commit only this feature’s files, approved design/plan, regenerated project, and release fragment using Conventional Commits. Leave inherited website edits untouched.

## Execution

The user explicitly approved this design and requested implementation. Execute natively in this existing worktree, then obtain the independent whole-change review above. No additional approval round is needed for routine implementation choices.
