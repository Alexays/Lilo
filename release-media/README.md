# Author the 0.8.0 announcement

The approved 0.8.0 film and PNG play from committed assets. Native builds, release preparation, signing, and website deployment do not run the authoring tools.

This optional workflow supports the 0.8.0 tab-sharing announcement. Other catalog versions have explicit deferred-backfill decisions. Their existing website illustrations keep their legacy paths. The fixture registry contains only tab sharing. The native tests capture its search and switch workflow, the announcement's address-bar change, and bundled What's New playback.

## Capture and render

Use a Retina macOS desktop with screen-recording access, Node, and FFmpeg. The render target installs the pinned HyperFrames dependencies. Captures use a disposable profile, synthetic example.com pages and call handlers, and an owned backdrop. Native receipts identify the actual app version, build, source commit, geometry, and PNG hashes. The illustrated release does not imply a historical binary.

1. Run `make release-media-author RELEASE=0.8.0` to check the exact source notes and catalog decision.
2. Run `make release-media-capture RELEASE=0.8.0` to capture tab sharing and the address setting.
3. Run `make release-media-import RELEASE=0.8.0` to verify and import every source receipt before replacing the previous import.
4. Run `make release-media-render RELEASE=0.8.0` to stage the literal HTML compositions and encode the film and poster.
5. Run `make release-media-check release-media-inspect RELEASE=0.8.0` to measure the encoded result and extract compact review sheets.
6. Run `make release-media-test release-media-publish-check RELEASE=0.8.0` to exercise refusal checks and verify the exact committed bytes.
7. Run `make release-media-review RELEASE=0.8.0` to review bundled native playback. Run `make ui-build` afterwards to restore the installed release's bundle.
8. Run `make validate` before submitting code changes.

The 26-second full announcement lives in `hyperframes/0.8.0`. The share-only variant reuses its search, switch, and ending scenes. Every composition uses local fonts, native captures, and deterministic paused GSAP timelines.

## Verify the result

Native cutouts preserve captured RGB bytes and canvas dimensions. Only alpha changes outside the interface. Complete windows retain their actual page content. Strict HyperFrames checks cover structure, runtime, layout, contrast, motion, and audio.

Films use 1920 by 1080 pixels at 60 fps, H.264 CRF16, and stereo AAC at 48 kHz and 192 kbps. Encoded checks verify frame count, full decode, source and recipe hashes, cutout pixels, loudness, true peak, bounded frame changes, and poster SSIM of at least 0.98. Reading holds may last up to three seconds. Compact visual review remains necessary.

Each `quality.json` binds to the exact `render.json`, source receipts, recipes, and output hashes. Changing a selected composition or the shared renderer invalidates the receipt. An unrelated fixture does not. A fresh checkout needs fresh staging inputs before encoded quality generation. Publication verification uses Node alone and remains an explicit target. No ordinary release or deployment command invokes it.

Automatic authoring retains fail-closed checks for unsupported visual changes and preserves a catalog publication kill switch. This extraction includes only the tab-sharing capability. Extend capture and composition coverage before authoring another feature.

## Sound and rights

The committed soundtrack is Week 37-Schmoovin by Abstraction/Tallbeard Studios under CC0. Its creator waiver, source URL, and checksums live under `public/audio/music.*`. Attribution is optional. Editorial click and transition sounds retain their CC0 provenance in `public/audio/README.md`. They do not represent sounds made by Lilo. Dependency, font, logo, and motion references remain in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
