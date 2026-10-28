# Native Release Media Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the current session, with a fresh final review.

**Goal:** Generate native Peek, address-bar, and tab-sharing recordings, with release-blocking quality checks and shared assets.

**Architecture:** A dedicated XCTest capture command renders production Lilo in temporary storage and records only its own window. TypeScript tooling chooses supported scenarios from release notes, validates and encodes timestamped frames, stages a versioned archive, and checks the archive before release packaging. Both existing release surfaces consume that archive.

**Tech Stack:** Swift/XCTest, ScreenCaptureKit, existing Sharp, Node, Svelte, Astro, Make.

**Spec:** docs/superpowers/specs/2026-10-28-native-release-media-design.md

## Global Constraints

- Capture outside make validate; all commands exposed through Make.
- Preserve old archives; require RECAPTURE=1 to replace an archive.
- Use real native UI, temporary profiles, and made-up page content.
- Failed quality checks block release; generated media is never hand-edited.
- No runtime recording, AI, polling, or remote media dependency.

## Review Focus

- Wrong app version or stale archive must not satisfy a release gate.
- A failed final scenario must not publish earlier partial outputs.
- Missing permissions or invisible native content must fail rather than create black media.
- Static or sparsely sampled frames must not pass a smooth recording gate.
- Closing or hiding a media player must release playback work and preserve keyboard focus.

### Task 1: Native recorder and three real scenarios

**Files:** LiloTests/Window/ReleaseCaptureTests.swift; LiloTests/Support/ReleaseWindowRecorder.swift; Makefile; project.yml/generated project.

**Interface:** make release-media-record OUT=<staging directory> records timestamped PNG frames, semantic checkpoints, app identity, and one JSON manifest per scenario.

- [x] Add an opt-in test-host capture scenario and a current-process ScreenCaptureKit recorder; demonstrate missing-output failure before implementation.
- [x] Render production chrome in an isolated BrowserContext; verify readiness before recording.
- [x] Drive Peek, address placement, and real tab sharing; assert each intended result and capture motion continuously.
- [x] Run make project-sync and make release-media-record; inspect output frames.

### Task 2: Automated selection, encoding, and fail-closed quality

**Files:** site/captures/native-proof.ts; site/captures/recording.ts; site/tests/release-capture.test.ts; Makefile.

**Interface:** make release-media-proof RELEASE=x.y.z generates and verifies a staged archive; make release-media-check RELEASE=x.y.z validates the published archive.

- [x] Write regressions for motion/timestamp/geometry/checkpoint failures, altered files, wrong version, incomplete archive, and no partial publication; observe failures.
- [x] Add a structured agent selection plan with exact source-note references and three supported scenarios; unsupported plans fail.
- [x] Encode bounded batches with actual frame timing; validate decoded media, file digests, semantic assertions, and recording density.
- [x] Gate release preparation and final packaging with required capture checks, preserving idempotent archives.

### Task 3: Consume the same archive in website and app

**Files:** site release story schema/player; lilo-ui release notes plugin/sheet; ChromeUISchemeHandler; project.yml; tests and catalogs.

**Interface:** Per-highlight optional recording metadata references versioned local media; current-release app resources are copied during UI build.

- [x] Add regression coverage for multiple feature recordings and offline bundle resources.
- [x] Render the 0.8.0 share/address clips on both surfaces with translated controls and Reduce Motion.
- [x] Preserve the 0.7.0 archive and show the new Peek recording separately as proof output.

### Task 4: Verify, document, and review

- [ ] Run make validate and focused browser tests; inspect actual recording previews.
- [x] Document commands, one-time capture setup, proof scope, failure behavior, and future scenario authoring.
- [x] Add a release note, review the full diff with a fresh reviewer, resolve material findings, and report verified outputs.
