# Automatic Release Scenario Authoring Plan

Use superpowers:executing-plans for inline implementation and one fresh final review.

**Spec:** docs/superpowers/specs/2026-10-29-release-scenario-authoring-design.md

**Goal:** zero per-release scenario/story authoring, with release-blocking quality gates.

## Constraints

- Use Make; keep recording and agents outside ordinary validation.
- Use production native UI and isolated synthetic fixtures; never let the author modify product code or gates.
- Preserve historical output and prior approved output on any failure.
- Bind generated plans, scenarios, translations and media to approval.

## Review Focus

- Important features cannot disappear during repair or via a missing story.
- An empty selection must require independent maintenance approval.
- Arbitrary safe feature IDs work through recording, encoding, website, and offline app resources.
- Scenario or translation changes invalidate approval; stale current outputs rebuild automatically.
- Repairs are bounded and cannot relax assertions, alter product code, or publish partial output.

## Task 1: Scenario and release contracts

Interface: validated release plan, observable native action/assertion scenarios, schema-3 archive and approval.

- [x] Add failing tests for unseen IDs, exact note coverage, invalid fixtures/actions, missing semantic checkpoints, and tampering.
- [x] Add schemas and validation; generalize the encoder without weakening historical verification.
- [x] Run make release-media-test. Expected: all contract/integrity regressions pass.

## Task 2: Generic native execution

Interface: make release-media-record SCENARIO=file.json runs one authored scenario and emits native frames, assertions, diagnostics, and scenario digest.

- [x] Add the opt-in generic driver and adapt recorder identity; retain old proof runners as references.
- [x] Expose real native menu/UI, page/chrome input, movement and observable assertions.
- [x] Run make project-sync and a JSON-authored scenario. Expected: real output with matching scenario fingerprint; deliberate bad assertions fail.

## Task 3: Autonomous orchestration and consumers

Interface: make release-media-proof selects, authors, repairs, reviews and atomically publishes every prepared release.

- [x] Add bounded attempt orchestration, independent coverage/scenario/visual reviews, and diagnostic feedback.
- [x] Generate translated editorial content and website stories inside the approved archive.
- [x] Generalize app resources and story consumers; remove story-existence and fixed-name release bypasses.
- [x] Run orchestration regressions and actual 0.8.0 generation. Expected: no manually authored scenario/story is needed; all failure paths retain the prior archive and block release.

## Task 4: Validate and finish

- [x] Run make validate, native capture and browser integration; verify approved reuse and offline assets.
- [x] Update guides and a change fragment, obtain a fresh whole-change review, fix material findings, and commit.

## Review and verification record

One fresh whole-change review identified four Important issues: recovery from a corrupt prior archive, website publication bypass, a playback test coupled to current highlights, and visibility assertions accepting off-screen or transparent elements. Timeout descendants and an insufficient final hold were regraded from Minor to Important. Each was reproduced and fixed in the same review pass; no minors remain deferred.

Actual native runs additionally exposed keyboard-layout input, stale hover state, cached-layout seeding and offline custom-scheme fetch failures. Reproducing native scenarios and the real chrome-origin fetch/decode test cover those fixes. Automatic generation also exposed over-prescribed storyboards and procedural text in public copy; concise selection fields, explicit editorial audits and higher reasoning effort address those authoring defects. The complete 0.8.0 archive passed independent source-bound approval after automatic translation and pacing repairs.

## Decisions

- use a generic declarative UI driver, rather than generated executable Swift — the author cannot modify product code or validators; unavailable native capabilities block the release. Cost if wrong: the fixed driver needs extension for unsupported future interactions.
- generated release translations travel with versioned editorial data, like prepared notes — routine UI control copy remains in all catalogs; this removes per-release catalog edits. Cost if wrong: release text follows the archive lifecycle rather than catalog tooling, so independent translation review is required.
- validate static website archive metadata directly from eager JSON imports; the mandatory release gate validates source/media files and the resource copier validates media digests — Astro bundles change import.meta.url paths, so filesystem paths derived from glob keys are unsuitable. The mandatory release gate verifies all files before packaging; website asset imports fail on missing files. Cost if wrong: development website builds may consume source-stale output if the separate publication gate is bypassed.
- keep the UI build a plain JSON consumer, without importing the authoring/Sharp toolchain — fresh UI builds and CI must not acquire website dependencies. The release gate validates the complete archive before packaging; binary copying checks media hashes. If a consumer bypasses packaging gates it can build development UI from stale source, as before.
- run the single fresh code review before the final expensive media run, while selection/copy are being exercised — this lets source-affecting fixes settle before capture. Final generated artifacts still require independent visual audit, full gate and browser tests; the reviewer judges code rather than the final image aesthetics. Cost if wrong: final integration fixes rely on their reproducing regressions and the full gate rather than a second fresh review.
- final media aesthetics/translations/selection were pending review — independent generated-artifact reviews and executor playback/browser/offline checks remain mandatory; no image approval is inferred from the code review. Cost if wrong: a visual defect missed by independent automated review could pass; native/binary checks alone cannot establish aesthetics.
- final full validation/browser/offline playback were not run by reviewer — executor will run all before completion; review remains read-only and GUI-free. Cost if wrong: the final execution evidence comes from the implementer rather than a second reviewer.
- constrain native menu capabilities and fixture networking mechanically — model safety review remains necessary, but must not be the sole boundary against shell/process actions or external page resources. Cost: unsupported native flows block until the fixed driver safely supports them.
- make the authoring context explicit about the silent WebP medium and honest walkthrough scope — source evidence supports capability claims while native assertions prove the real visible interaction, so a configuration demonstration may stop before external consent without pretending an operation started. Cost: audio walkthroughs demonstrate the real controls, not audible delivery; future unsupported visible flows still block. The existing frozen-selection/semantic/visual gates remain unchanged. Prompt-only correction is verified by full contract tests and a fresh autonomous production run, without a test that merely matches prompt wording.
- give feature selection the same short-story budget as scenario authoring, and keep ranking reasons about importance rather than a mandatory exhaustive QA inventory — every clip must still prove its core real visible workflow with native assertions, while full notes retain details that the clip cannot honestly demonstrate. Cost: the movie does not replace the feature’s complete integration/benchmark suite. This corrects the planning input rather than mutating a frozen failed recipe; a new source-bound run is required.
- run autonomous authors and audits with high reasoning effort instead of the CLI’s implicit none — actual independent reviews missed user-facing procedure text and over-prescribed unsupported internal assertions. Cost: longer and more expensive generation; all fixed quality gates and attempt limits remain mandatory.

## Autonomous 0.8.0 proof

Job `build/release-media/0.8.0-a0kYHZ` selected two sharing highlights while accounting for all 17 notes. Its 15-language editorial passed after idiom repairs. The audio configuration clip passed on its first attempt. Visual review rejected the tab-sharing clip twice: the first preview was not held clearly, then the filtered search result disappeared too quickly. The third authored recipe retained all 15 assertions, fixed both holds and passed native execution, encoding and visual review. No scenario or translation was manually edited.

Approved output: `share-system-audio` (9,745 ms) and `tab-sharing-controls` (14,286 ms), both 1120×720. Current-source release and website-publication integrity checks passed before the consumer verification.

## Final verification

- `TZ=UTC make validate TEST_WORKERS=4` passed against the committed approved archive, including all UI/website checks, the app build, SwiftLint, bridge/hook checks and release status. Native results: 2,390 passed, 0 failed, 11 opt-in tests skipped.
- `make release-media-test`: 30/30 passed.
- `make e2e E2E_ARGS='whatsNew.spec.ts --workers=2'`: 21/21 passed. The playback test waits for the real Blob image before comparing pixels.
- The owned-port website browser matrix passed 30/30 across Chromium/WebKit, English/French and desktop/mobile widths, with keyboard, appearance, no-JavaScript, Reduce Motion and cached-replay checks.
- Native offline tests passed 5/5. Every current recording was fetched from the real chrome origin and decoded twice through fresh Blob URLs. The built app contains exactly four approved binary assets with matching bytes, and editorial matches all 15 approved languages.
- `make release-media-check RELEASE=0.8.0` and `make release-media-publish-check` passed. Repeating `make release-media-proof RELEASE=0.8.0` reused the approval without starting a model or recorder.

No review findings remain deferred. Work is committed on `codex/native-release-media-proof`; publishing and integration remain separate operations.
