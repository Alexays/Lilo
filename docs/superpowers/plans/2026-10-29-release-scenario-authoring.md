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

- [ ] Add failing tests for unseen IDs, exact note coverage, invalid fixtures/actions, missing semantic checkpoints, and tampering.
- [ ] Add schemas and validation; generalize the encoder without weakening historical verification.
- [ ] Run make release-media-test. Expected: all contract/integrity regressions pass.

## Task 2: Generic native execution

Interface: make release-media-record SCENARIO=file.json runs one authored scenario and emits native frames, assertions, diagnostics, and scenario digest.

- [ ] Add the opt-in generic driver and adapt recorder identity; retain old proof runners as references.
- [ ] Expose real native menu/UI, page/chrome input, movement and observable assertions.
- [ ] Run make project-sync and a JSON-authored scenario. Expected: real output with matching scenario fingerprint; deliberate bad assertions fail.

## Task 3: Autonomous orchestration and consumers

Interface: make release-media-proof selects, authors, repairs, reviews and atomically publishes every prepared release.

- [ ] Add bounded attempt orchestration, independent coverage/scenario/visual reviews, and diagnostic feedback.
- [ ] Generate translated editorial content and website stories inside the approved archive.
- [ ] Generalize app resources and story consumers; remove story-existence and fixed-name release bypasses.
- [ ] Run orchestration regressions and actual 0.8.0 generation. Expected: no manually authored scenario/story is needed; all failure paths retain the prior archive and block release.

## Task 4: Validate and finish

- [ ] Run make validate, native capture and browser integration; verify approved reuse and offline assets.
- [ ] Update guides and a change fragment, obtain a fresh whole-change review, fix material findings, and commit.
