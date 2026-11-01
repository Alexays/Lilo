---
name: lilo-release-media
description: Choose and produce release media from genuine native Lilo captures, using video, a screenshot, or no media according to the change.
---

# Lilo release media

Read the exact release notes and changed implementation before choosing a subject. Routine fixes get `none`; finished visual states such as seasonal icons get a screenshot; a new interaction worth demonstrating gets a short film. Pick one important subject per release. Record the decision and its exact source note in `release-media/backlog.json`.

Use the compiled native app with a disposable profile, owned fixture pages and no real user data. Extend the concrete native cases in `LiloTests/Window/ReleaseMediaCaptureTests.swift` and the literal JSX compositions in `release-media/src/`. Never recreate browser controls in React or the website demo. Preserve old sources and their actual app version separately from the release being illustrated.

Run through Make:

1. `make ui-build project-sync`
2. `make release-media-capture RELEASE=x.y.z` — assert the native feature's result before writing a receipt.
3. `make release-media-import RELEASE=x.y.z`
4. `make release-media-render RELEASE=x.y.z` — lossless PNG, or 1080p60 H.264/AAC MP4 with purposeful, licensed sound.
5. `make release-media-check`
6. Inspect every important encoded state at 342px, then the actual English and French changelog at desktop/mobile widths. Use `make release-media-review RELEASE=x.y.z` for native What’s New playback, seeking, sound and still-image validation. Restore `make ui-build` afterward.

Crop to the feature; check native pixel density before enlarging it. Prefer native states and deliberate framing over a long recording of setup. Keep copy outside the media. Support keyboard controls, sound, replay and explicit play; do no work while offscreen. A screenshot never substitutes for a failed required film.

`make validate` and the release-media CI job must pass. The publication flag stays blocked until the requested quality review is resolved; never change it merely to make the release workflow green.
