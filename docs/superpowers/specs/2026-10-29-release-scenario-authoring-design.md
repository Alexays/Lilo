# Automatic release scenario authoring

Every prepared release must automatically select its most important visible changes, author native demonstrations, repair failed attempts within a fixed budget, and publish approved media and translated release highlights for the website and offline app. No feature-name registry, hand-written scenario, story file, or per-release catalog edit is required. Failed selection, execution, integrity, or visual checks block release preparation and packaging.

## Approach

The existing native recorder and quality checks remain authoritative. An agent reads the exact prepared notes, current implementation, and available previous-release diff. It accounts for every note, groups the most important visible changes into up to three highlights, and explains why other notes remain text. An independent review must approve that coverage, including any maintenance release with no recording.

An author agent writes declarative JSON scenarios and synthetic HTML fixtures. The fixed XCTest driver can open fixture tabs, click/type/drag in the real chrome and pages, invoke compiled native menu actions, press keys, interact with native controls, wait, and assert observable states. It cannot execute author-supplied Swift, shell commands, or JavaScript against Lilo's chrome. Native assertions and frame capture belong to the driver. Fixture pages may use the real browser APIs to demonstrate website-facing features.

Each silent WebP tells one coherent visual story in 6–12 seconds, with a hard 15-second limit and readable holds. Ranking reasons describe importance and grouping. The movie proves its core visible workflow; it does not replace the feature's complete integration or benchmark suite. Audio configuration can be shown honestly before external consent, without claiming that an unfinished share started or that the silent movie verifies audible delivery.

Generating arbitrary Swift was considered but would allow the generator to alter capture assertions or manufacture UI. Retaining named runners would leave manual authoring in the release path. The generic UI driver gives the author flexibility while keeping execution and quality checks fixed. A feature requiring an unavailable device, permission, or interaction must fail explicitly; it cannot be silently dropped from the frozen selection.

Each scenario gets at most three author/record/review attempts. Failures supply bounded native diagnostics and actual frames. Selection and source notes stay fixed during repair. The author cannot weaken validators or change product code. Independent scenario and visual reviews reject fake chrome, real user data, external services, unsupported claims, blank content, clipping, jumps, and unreadable pacing.

## Artifacts and consumers

A version 3 archive contains the selected plan, authored scenarios, all supported translations, generated website story, recordings, source manifests, and digest-bound approval. Scenario IDs are arbitrary safe slugs. Captures bind both the application input fingerprint and the exact scenario bytes. Generated content lives inside the atomic archive, outside its application input fingerprint, avoiding a generation cycle.

Both release surfaces consume this archive. The app ships only current-release binary assets and translated editorial content. Older version 1/2 archives remain readable as historical content. A current stale archive is regenerated automatically in staging; it is replaced only after the complete release passes. Missing archives fail the release gate even without a manually authored story. An independently approved maintenance decision is the sole no-media path.

## Verification

Regressions cover unseen feature IDs, omitted or falsely downgraded notes, unsafe or weak scenarios, retry exhaustion, missing/stale/changed recipes, changed copy, partial publication, and no-media approval. Run an actual agent-authored current-release capture, verify automatic stories and offline resources, then run make validate and focused browser suites sequentially. Capture requires an unlocked GUI Mac and remains outside normal validation.
