# Public changelog pilot implementation plan

> For agentic workers: use superpowers:executing-plans to implement this plan in this session. Steps use checkbox syntax for tracking.

**Goal:** Present three translated highlights for 0.7.0 and generate a six-second Peek recording through one reusable scenario.

**Architecture:** Keep the generated changelog and add optional validated JSON stories. Astro renders the stories, optimized posters and a WebP player; a separate Playwright capture command writes versioned media before release builds.

**Tech stack:** Astro 7.4.2, TypeScript, Zod, Playwright 1.64.1, Python's existing output tests, Make.

**Spec:** `docs/superpowers/specs/2026-10-28-public-changelog-pilot-design.md`

## Global constraints

- Keep Changie and its generated changelog authoritative.
- English and French receive the same treatment.
- Reading the story or opening the full notes needs no JavaScript.
- Rebuilding the website never updates archived media.
- Expose capture through Make; keep capture outside `make validate`.
- Use Humanizer for authored prose, existing site tokens and shared layouts. Sharp 0.35.5 is a direct capture dependency, matching Astro's existing encoder.

## Review focus

- A story references a note from another release: reject it before publishing.
- A later release has no story: preserve its normal notes and ordering.
- Existing media is present: preserve it unless replacement is explicitly requested.
- French, dark appearance or a narrow viewport: display readable text and the correct screenshot.
- JavaScript is disabled: keep the complete archive and disclosure usable.

### Task 1: Story content and rendering

Files: `site/src/content/releases/0.7.0.json`, `site/src/lib/release-stories.ts`, `site/src/lib/changelog.ts`, `site/src/components/ReleaseStory.astro`, `site/src/components/Changelog.astro`, `site/src/lib/i18n.ts`, `site/tests/changelog.test.ts`, `site/tests/test_site.py`.

Interface: `parseReleaseStories(markdown: string, entries: unknown[])` returns a map of validated stories by version; the page joins it to existing parsed releases. Source notes belong to that version. Story media is resolved by version, scenario, locale and appearance.

- [x] Add an output regression that expects three translated story sections and a full-notes disclosure; run `make site-test` and observe the missing-story failure.
- [x] Implement the JSON content, validation, static component and page integration. Add focused invalid-source, missing-locale and duplicate-story tests.
- [x] Preserve ordinary releases, complete Markdown output, version anchors and EN/FR links. Review the authored copy with Humanizer.

### Task 2: Capture and release preparation

Files: `site/captures/peek.spec.ts`, `site/playwright.capture.config.ts`, `site/package.json`, `Makefile`, `site/src/assets/releases/0.7.0/*`, `site/README.md`, `docs/RELEASING.md`.

Interface: `make site-release-capture RELEASE=0.7.0` creates missing captures; `RECAPTURE=1` explicitly replaces them. The scenario uses the public demo's actual UI and local sample pages, and records its revision and source digest.

- [x] Add the owned capture server and one Peek scenario with assertions on the open preview and preserved source tab. Save files only after every locale/appearance succeeds.
- [x] Capture the pilot, inspect the actual images, and verify a normal second run leaves their hashes unchanged.
- [x] Invoke missing-story captures during `make release-version`, without adding capture to normal builds or validation. Document the lifecycle and command.

The final review added `site/captures/release-capture.ts` and `site/tests/release-capture.test.ts`. The capture runner checks complete and incomplete archives before starting a server. Its source digest includes the prepared working tree's new files and deletions. Both regressions were observed failing before the fixes, then passed with the full website suite.

### Task 3: Browser checks and completion

Files: `site/tests/changelog.spec.ts`, `site/playwright.config.ts`, one Changie fragment.

- [x] Test the disclosure, demo link, mobile bounds, appearance selection and reading without JavaScript in the actual browser.
- [x] Run `make site-fix`, `make site-check site-test`, and focused `make site-e2e` checks. Inspect English/French desktop/mobile screenshots.
- [x] Add the user-visible release fragment, then run `make validate` and inspect all failures.
- [x] Review the whole diff with a fresh reviewer, address material findings, and leave one logical, reviewable change.

Final verification passed: `make validate`; 77 website Node tests and 15 Python output tests; six focused browser tests; one capture scenario producing all four images. A normal repeat preserved every capture's SHA-256. The two review findings have regression coverage. The rendered English and French pages were also inspected in Lilo at desktop and mobile widths, using light and dark appearances. Changes remain in this worktree for review; nothing was deployed.

### Task 4: Animated recording and contextual actions

The user requested an automated WebP recording and a secondary action appropriate to each feature. Replace the pilot's still-only presentation with one recorded Peek interaction and optional per-highlight actions.

Files: `site/captures/recording.ts`, `site/captures/peek.spec.ts`, `site/captures/release-capture.ts`, `site/src/components/ReleaseRecording.astro`, `site/src/components/ReleaseStory.astro`, the story JSON, localization, tests, Make and dependency metadata.

- [x] Add a failing output regression for a recording player with a contextual action.
- [x] Encode actual UI frames as a single-play WebP with a still poster, and preserve complete/incomplete archive checks.
- [x] Put optional actions in metadata. Keep the pilot's demo link inside the player controls and omit actions for native-only highlights.
- [x] Verify frame timing, viewport playback, Reduce Motion, stop/replay, appearance changes, no-JavaScript rendering and archived assets.
- [x] Review the completed change, run `make validate`, and refresh the local preview.

Recording verification passed: `make validate`; 79 website Node tests and 16 Python output tests; 11 browser tests in Chromium and the same 11 in WebKit; one capture scenario producing four recordings and four posters. Rendered screenshots verify natural completion and cached replay. The archived outputs stayed unchanged on a normal repeat. English and French were inspected in Lilo at desktop and mobile widths, including French at 320 px. The local preview runs on port 8793; nothing was deployed.

### Task 5: Native recording and a lighter player

The user rejected the footer control bar and requested a capture in their own installed Lilo with real pages. Use a small icon control over the image, remove the timer and footer strip, and move the optional demo link into the feature text. Preserve keyboard labels, Reduce Motion and playback cleanup.

Native Peek is disabled for MCP-controlled tabs. Public pages were inspected with Lilo MCP, then native Peek was captured through the visible installed Lilo in a separate private recording space using computer use. Keep these authentic frames together as one recording for both site languages and appearances. The recorded browser keeps its actual language and appearance. Archive its real app version, public source URLs and frame digest; never claim that it was captured from this worktree's app build. Import and encode reviewed native frames through Make, with explicit archive replacement.

- [x] Observe the minimal-player output regression failing, implement the overlay and move the action link.
- [x] Add the reviewed native-frame import, encode the actual capture, and preserve archive protection.
- [x] Check both language layouts and playback, run `make validate`, review, and refresh the preview.

Native recording verification passed: 82 Node tests, 16 Python output tests, 11 Chromium and 11 WebKit browser tests. Manual Lilo inspection covered both locales on desktop/mobile and the user's 668px viewport. A fresh review found no issues and independently verified the native frames, privacy, six-second timing, single playback and source digest. The first full gate failed at an unchanged native LocalPort test; an unchanged rerun of `make validate` passed. The local preview uses the new shared native recording and minimal overlay. No deployment, push or merge.
