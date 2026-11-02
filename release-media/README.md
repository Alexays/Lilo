# Release media playback

`assets/0.8.0/tab-share.mp4` and its PNG poster are the approved 0.8.0 release illustration. The shared `catalog.ts` gives the website and native What's New sheet stable media URLs. Releases absent from `backlog.json` keep their existing text, stories and illustrations.

The film shows native Lilo 0.14.1, build 31, illustrating the 0.8.0 tab-sharing feature. It is not footage of a historical 0.8.0 binary. Both players keep its English imagery labeled with a localized caption and language notice. Playback has sound, standard controls and no autoplay.

The approved files have these SHA-256 digests.

| File | SHA-256 |
| --- | --- |
| `tab-share.mp4` | `aa16aba87dba2611a438190372217cac3ae9e18488dbf31b2c22c77913f176ed` |
| `tab-share.png` | `3e36ede8fd9dd50a1cb6a4b177decc719bfe9e95d0aed489c45b4ac30f36d329` |

`make ui-build` stages only the installed release's assets in `lilo-ui/public/release-media/`. For a local media preview, run `LILO_RELEASE_MEDIA_PREVIEW_VERSION=0.8.0 make ui-build`. `make release-media-test` verifies staging. No renderer or authoring dependency is needed to build or play these committed files.

The soundtrack is **Week 37 - Schmoovin** by **Abstraction / Tallbeard Studios**, from the creator's Music Loop Bundle, version 20261003-01 (2026 Q3). The creator released it under CC0 1.0 Universal. The original notice and provenance metadata are in `public/audio/music.LICENSE.txt` and `public/audio/music.license.json`. Those metadata describe the original track used in the film. The source track and render recipes are separate authoring inputs.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the motion references and license. Native imagery, pointer paths and film timeline are Lilo-specific.
