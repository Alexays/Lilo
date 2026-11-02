# Release media

HyperFrames produces the MP4 announcements and PNG screenshots shared by the public changelog and native What’s New. The archive covers 31 releases: eight interaction films, six screenshots and seventeen text-only maintenance releases. Each media decision names exact source notes in `backlog.json`.

## Native sources and authoring

All UI imagery comes from compiled native Lilo with disposable profiles, owned example.com pages and synthetic call handlers. Receipts under `public/native/<version>` identify the actual app version/build, source commit, geometry and PNG hashes. Historical releases are illustrated using that recorded app version; the historical release binary is not implied.

`make release-media-author` checks published and pending notes. It selects a supported meaningful visual workflow, chooses a screenshot for a finished visual state, and leaves routine fixes text-only. Unknown visual features fail closed. The feature implementation must include its native capture and literal HyperFrames storyboard; the release step does not invent UI. The reusable capture capabilities are in `pipeline.mjs`, with their concrete tests in `LiloTests/Window/ReleaseMediaCaptureTests.swift`.

Literal HTML scenes live in `hyperframes/`. The 26-second 0.8.0 story is the approved full announcement. Future tab-sharing-only releases use its 18.6-second variant, which does not claim the address-bar change is new. Each film has deliberate pointer actions, native state changes, readable titles and an ending. New compositions use local fonts/assets and deterministic paused GSAP timelines.

Isolated interface pieces are RGBA PNG cutouts. Only alpha changes; all captured RGB bytes and canvas dimensions remain unchanged. The gate independently compares the processed assets with their original native sources. Complete browser windows retain their real page content. Native pixels receive no CSS blur or 3D tilt.

## Make workflow

- `make release-media-author`: select/check the story from release notes.
- `make release-media-capture RELEASE=x.y.z FIXTURE=a.b.c`: run the selected genuine native workflow; omit arguments to capture the archive.
- `make release-media-import RELEASE=x.y.z`: verify and import the native receipts, including secondary captures.
- `make release-media-render RELEASE=x.y.z`: generate the MP4 or screenshot; omit RELEASE to render the archive.
- `make release-media-check release-media-test release-media-inspect`: verify encoded media, run refusal tests and extract compact review sheets.
- `make release-media-publish-check`: require current passing receipts for every published asset.
- `make release-media-ci RELEASE=x.y.z`: select, capture, import, render, inspect and quality-gate the release automatically.

`make release-version` invokes this pipeline and builds the site. Tagged CI repeats the native capture on macOS from the exact tag, then passes one verified artifact to signing and website deployment. A failed or missing check blocks publication. The complete signing/deployment setup is in [RELEASING.md](../docs/RELEASING.md).

## Quality contract

Films use 1920×1080, 60 fps, lossless PNG capture, H.264 CRF16 and stereo AAC 48k/192k. HyperFrames structural/runtime/layout/contrast/motion/audio checks run in strict mode. Encoded QA checks frame count, full decode, native/source/recipe/render hashes, transparent cutouts, loudness and true peak, bounded frame changes and poster SSIM ≥0.98. The announcement contract permits reading holds up to 3 seconds, requires at least 20% changing frames and bounds deliberate scene transitions. These signal checks complement compact visual review; they do not judge the music artistically.

Each `quality.json` binds to the exact `render.json`, source receipts, recipes and PNG/MP4 hashes. Deployment checks use Node alone. Quality generation requires the local CLI/browser, Sharp and FFmpeg. A fresh checkout regenerates staging inputs; verified local renders can be reused when those inputs remain present and unchanged. No boolean manual-approval field bypasses the gate. Setting `backlog.json` publication to `blocked` remains a kill switch that automatic authoring preserves.

## Sound

The soundtrack is **Week 37–Schmoovin** by Abstraction/Tallbeard Studios, licensed CC0. Attribution is optional; films have no music credit overlay. The original audio, creator’s waiver, source URL and checksums are committed under `public/audio/music.*`. `make release-media-music` verifies the cached file or retrieves the creator-provided free download. CI uses committed assets and needs no music account or download.

Editorial click/transition sounds retain their CC0 provenance in `public/audio/README.md`. They explain visible actions and are not represented as sounds made by Lilo itself. License notices for dependencies and referenced motion techniques remain in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
