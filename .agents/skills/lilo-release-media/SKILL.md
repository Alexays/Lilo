---
name: lilo-release-media
description: Author and quality-check the 0.8.0 tab-sharing announcement from genuine native Lilo captures.
---

# Lilo release media

This optional workflow supports the approved 0.8.0 announcement. Playback consumes its committed MP4 and PNG without media-production tools. Ordinary builds, releases, signing, and deployment remain independent from this workflow.

Use the exact release notes and preserve the catalog's editorial decision. The native capture cases cover tab sharing, the address setting, and bundled playback review. Add genuine native capture and composition coverage before supporting another product feature. Do not recreate browser controls or use the website demo as evidence.

Capture the compiled native app with a disposable profile, synthetic example.com pages and call handlers, and an owned backdrop. Keep the actual app version, build, and source commit in every receipt. Keep these fields separate from the illustrated release.

Author literal editable HTML scenes under `release-media/hyperframes/`. Use local assets and deterministic paused GSAP timelines. Native cutouts preserve RGB bytes and canvas dimensions. Change only alpha outside the interface. Keep complete windows and real page content. Do not apply CSS blur or 3D tilt to native pixels.

Use these explicit Make targets.

1. Run `make release-media-author RELEASE=0.8.0`.
2. Run `make release-media-capture RELEASE=0.8.0`.
3. Run `make release-media-import release-media-render RELEASE=0.8.0`.
4. Run `make release-media-check release-media-inspect RELEASE=0.8.0`.
5. Review the encoded compact frames and both localized players. Run `make release-media-review RELEASE=0.8.0` for actual bundled playback, then restore `make ui-build`.
6. Run `make release-media-test release-media-publish-check RELEASE=0.8.0` and `make validate`.

Keep the committed CC0 soundtrack and licensed editorial sounds. Preserve their rights files and hashes. Preserve the catalog publication kill switch. Never rewrite passing receipts to hide changed inputs. Regenerate render and quality receipts through the actual tools.

See `release-media/README.md` for requirements and the encoded quality contract.
