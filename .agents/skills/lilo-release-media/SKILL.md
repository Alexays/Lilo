---
name: lilo-release-media
description: Author and quality-gate HyperFrames announcements or screenshots from genuine native Lilo captures.
---

# Lilo release media

Use the exact release notes and changed implementation to choose the story. An interaction gets a HyperFrames film; a finished visual state gets a screenshot; routine fixes stay text-only. Never substitute a screenshot for a failed required film. `make release-media-author` checks known capture capabilities and exact source notes, including pending changes. Unknown visual work fails closed: add its native capture and storyboard in the feature pull request, so release preparation needs no editorial work after merge.

Capture the compiled native app with a disposable profile, owned example.com pages and synthetic call handlers. Extend concrete cases in `LiloTests/Window/ReleaseMediaCaptureTests.swift`. Keep actual app version/build/source commit in every receipt, separately from the release being illustrated. Never recreate browser controls or use the website demo as evidence.

Author literal editable HTML scenes under `release-media/hyperframes/`, with one paused GSAP timeline per composition, registered after synchronous construction. Use local assets, stable timed clip IDs, explicit durations and native state changes. No timers, unseeded randomness or network-fetched UI. Follow the approved 0.8.0 film for readable typography, deliberate transitions and pointer actions. Its share-only variant avoids announcing the address-bar feature in an unrelated release.

Use real source geometry for pointer targets and transparent PNG cutouts. Preserve captured RGB bytes and canvas sizes; change only alpha outside the native interface. Keep the UI’s own surfaces and complete window/page content. Check physical pixel density before enlargement. No CSS blur or 3D tilt on native UI. Titles settle while the product acts; do not add idle motion to satisfy a gate.

Use Make:

1. `make release-media-author`
2. `make release-media-capture RELEASE=x.y.z FIXTURE=a.b.c`
3. `make release-media-import release-media-render RELEASE=x.y.z`
4. `make release-media-check release-media-test release-media-inspect`
5. Review encoded frames at 342px, play the English/French changelog at desktop/mobile widths, and check native What’s New using `make release-media-review RELEASE=x.y.z`. Restore `make ui-build` after the native preview.
6. `make validate` and the release-media CI job must pass.

`make release-media-ci RELEASE=x.y.z` runs selection, fresh native capture, import, render, inspection and publication checks. Tagged CI captures the exact source commit and app version before signing; deployment uses that run’s validated website artifact. A failed audit, missing capability, broken capture, stale hash or failed media check blocks publication. Preserve a catalog publication kill switch; never re-enable it merely to make a workflow green.

Films use lossless PNG capture and 1080p60 H.264/AAC. Strict HyperFrames checks cover structure, runtime, layout, contrast, motion and audio. Encoded checks verify frame count, decode, sound, bounded motion, native/recipe/output hashes, cutout RGB preservation and poster similarity. Announcement reading holds may last up to three seconds; signal checks complement visual review rather than judging artistic quality.

Use the committed CC0 soundtrack and licensed editorial Foley. Music rights and hashes live in `release-media/public/audio/music.license.json`; attribution is optional, so no music credit overlay is needed. Never remove a required credit from a different track. Keep sound controls, explicit play, keyboard access and offscreen pause in both compact players.

See `release-media/README.md` and `docs/RELEASING.md` for production commands and Alexays’s one-time Cloudflare release-environment setup.
