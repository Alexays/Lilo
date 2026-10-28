# In-app What’s New

Date: 2026-10-28
Status: Approved by the user on 2026-10-28

## Intent

Make an update feel worth noticing. People should leave knowing one or two useful things that changed, with the full release notes available when they want detail. The experience should feel like a small, friendly moment in Lilo and return them to their restored browsing session.

The user chose automatic presentation once after an update, chose the compact welcome sheet (option A in the visual comparison), and approved this design for implementation.

## Approaches considered

- **Compact welcome sheet, chosen.** Two or three short visual highlights above an expandable list of complete changes. The browsing session remains underneath. This keeps the introduction brief and works for frequent releases.
- **Full update page.** A large editorial layout, similar in footprint to Settings, provides more space for a hero and feature stories. It asks for a longer reading session and was not selected.

The choice follows the useful pattern in [Linear’s changelog](https://linear.app/changelog) and [Raycast’s changelog](https://www.raycast.com/changelog): lead with benefits and visuals, then retain the detailed changes. The [Arc example](https://arc.net/e/6433CE8D-2D3F-4FF2-AD51-6EF0CBAD197F) informs the friendly tone. These are references, not dependencies.

## Scope and constraints

- In-app presentation, automatic presentation state, a Help menu entry, and bundled release content.
- Keep the existing Sparkle download, restart card, install-on-quit behavior, and restored tabs.
- Use the existing Swift host and Svelte chrome. No additional web view or dependency is needed.
- No website changes, notifications, telemetry, runtime AI, remote media, or release-feed polling.
- Automatic visual capture and writing assistance during release preparation belong to the separate public changelog work. This view consumes prepared content; it does not invent highlights.
- Respect the repository’s localization, accessibility, Reduce Motion, bundle budgets, and zero idle work requirements. Do not edit generated files or `CHANGELOG.md`.

## The sheet

The sheet centers in the browser content area, leaving the app frame and the restored session visible. It is approximately 560 points wide on a typical window, shrinks to available width, and scrolls inside the available height. Its footer stays reachable in a short window. It works with left, right, top, and bottom tabs and a hidden sidebar.

1. **Header:** installed version, a localized release date when available, a short release headline, and one sentence of introduction. The title is the accessible dialog name. A close button has a translated accessible label.
2. **Highlights:** normally two, never more than three. Each has a small local illustration, a benefit-led heading, and one or two sentences. The initial visual comparison used unread badges and more reliable video calls from Lilo 0.6.0. Highlight text must always match the installed release.
3. **Everything in this update:** a disclosure with the total change count. Expanding it reveals every change in the installed release, grouped under its Changie headings. This is a complete list, not the shortened example list used in the mockup.
4. **Footer:** a short reminder that the sheet can be reopened from Help, plus **Back to browsing**. Escape and the close button have the same effect. Clicking outside can dismiss it. Closing never opens or replaces a tab.

No carousel, next-step sequence, confetti, automatic video, persistent unread badge, or per-release preference is needed. At most a brief entrance fade/scale runs when opening; Reduce Motion removes the movement. Illustrations are static and decorative; the accompanying copy communicates the change.

## When it appears

Presentation is app-wide, not per window or profile. Native code owns the durable marker and the decision; a web view’s local storage does not.

- After the first usable window has received and applied its restored chrome state, the host can request automatic presentation. This stays off the first-paint path.
- A fresh installation does not show the sheet over onboarding or immediately after onboarding finishes. It records the installed version as its starting point.
- An established installation with no marker sees the current sheet once when upgrading to the release introducing this feature. `SettingsStore.shouldShowOnboarding` already distinguishes an established installation from first-run setup.
- Subsequently, a numerically newer marketing version can open automatically once. Reopening windows, reloading the chrome, relaunching the same version, rebuilding the same marketing version, and downgrading do not open it again.
- If multiple windows restore together, only the initial eligible window receives the automatic presentation. An app-scoped reservation prevents duplicate requests while the UI chunk loads.
- A request is marked presented only after the sheet has mounted successfully and acknowledged its installed version. If loading fails or the window closes before that, a later launch can try again.
- Startup recovery and onboarding take priority. The sheet must not replace or obscure a required startup decision. Use existing readiness/dismissal events to defer it where needed, with no timer or polling loop.
- Debug builds support the Help menu entry and preview/test fixtures; they do not announce updates automatically during development.

The marker is a highest-presented version. Validating and updating it is synchronous on the main actor. Invalid or unavailable installed versions suppress automatic presentation gracefully.

## Reopening and focus

Add **What’s New** to the native Help menu, beside Lilo Help. It targets the active regular browser window and reopens the installed release even after its automatic presentation has been consumed. This does not reset the automatic marker. The menu entry uses the existing native localization catalogs.

The sheet is a modal dialog within the existing chrome overlay. Opening moves native keyboard focus into chrome, focuses the dialog or its first useful control, and prevents keyboard/pointer interaction with controls behind it. Tab and Shift-Tab cycle through its controls. Escape closes only this surface. Closing restores the previous appropriate focus, including the native page/terminal when the sheet opened automatically. VoiceOver has the title, version, headings, notes disclosure, and buttons in reading order.

Mandatory native sheets or permission decisions retain their existing priority. An automatic request waits for a safe presentation opportunity instead of displacing them. A manual Help action must not create a second copy of an already open sheet.

## Release content

The complete changes continue to come from `.changes/vX.Y.Z.md`, selected using the app/package marketing version during the existing UI build. Only the installed release is bundled; the sheet does not collect every release skipped during an upgrade. It works offline and makes no request to the public site or Sparkle feed.

Use a small, explicit table of optional curated highlights keyed by exact release version. Each highlight references the shared English/French catalogs and an existing local illustration. Headline, description, labels, buttons, dates, and accessibility strings follow the selected app language. Only the current release’s highlight data is included in the loaded view; no generic content-management system is needed.

Canonical Changie entries currently exist in English. Display those original entries verbatim in the complete-notes disclosure, with a translated label that makes the source language clear in French. Curated headlines and benefit copy are translated in both catalogs. Translating the entire historical changelog is outside this feature.

Future releases with no curated highlights use a compact, truthful maintenance layout: version, a translated neutral introduction, and the full notes expanded. They never reuse an older release’s illustrations or feature claims. A release author may omit highlights deliberately for a fixes-only update.

If prepared notes are absent or unreadable in a development build, the manual sheet shows the installed version and a translated unavailable message; automatic presentation is suppressed. A malformed highlight entry must not prevent the complete notes from being available. Keep release text as plain text with limited inline links if useful; do not inject raw release HTML into privileged chrome.

Release authoring documentation should explain where to add the optional highlight entries and translations. This chat does not alter public site templates, `.changie.yaml`, `scripts/release.py`, or the release workflow. A shared authoring format can replace the small local table in later coordinated work.

## Implementation boundaries

The builder chooses exact file names, the smallest bridge event/command shape, and whether the version decision needs a small dedicated value type. A feature with its own native model/handler belongs under `Lilo/WhatsNew/`, with mirrored tests, according to the placement rule. The Svelte sheet and its pure release-content helpers belong together in an appropriate component area.

Load the sheet and its content only when requested, using the existing deferred chrome architecture. Keep automatic eligibility to one startup decision and event-driven deferral. Closed views have no mounted illustration work, active timers, observers that do work at idle, or background fetching. The build embeds text/SVG assets; avoid adding a screenshot pipeline here.

Add only the bridge and window integration needed for presentation, acknowledgment, dismissal/focus, and the Help action. Regenerate the Xcode project after adding Swift files. Keep the first-frame UI budget unchanged; justify any modest total-bundle budget adjustment with the measured new optional chunk.

## Verification

- Cheap native tests cover first install, existing-install adoption, newer/same/older versions, acknowledgment, malformed versions, and one reservation across multiple windows. No WebKit process is needed for the version-decision tests.
- Pure UI tests cover parsing all notes, ordered groups and counts, exact-version highlight selection, malformed/missing content, and English/French catalog parity.
- Focused UI end-to-end tests cover automatic open, Escape and Continue dismissal, focus trapping/restoration, Help-event reopening, full-note expansion, a small viewport, both sidebar/tab-strip layouts, and Reduce Motion. Existing fake-host/preview infrastructure supplies made-up data.
- Inspect the real chrome preview in light and dark appearances. Verify no clipped French copy or unreachable controls in a short window.
- Run `make project-sync` when needed and `make validate` for the implementation. Add a user-visible release fragment with the completed change.

Baseline before implementation: `make validate` currently exposes an existing daylight-saving-sensitive assertion in `spaceColor.test.ts`; an isolated run with `TZ=UTC` passes the UI checks but failed `TabExtensionEventsTests.testANavigationReportsItsURLOnce`. These failures predate product changes in this chat and must be reported separately from feature validation.

## Approval

The user approved the compact-sheet design, including its lifecycle and original-language complete notes, and requested implementation.
