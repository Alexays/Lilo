# Release media

The backlog has an explicit decision for every published release: **8 videos, 6 screenshots, 17 without media**. `backlog.json` records why and cites the exact original note. Version 0.14.1 is text only; Spaces in 0.11.0 has a film, and the seasonal icons in 0.13.0 have a still.

The source is actual compiled Lilo 0.14.1 (31), illustrating capabilities introduced in those releases. It is not a claim that historical binaries were run. Captures use disposable profiles, synthetic example.com pages and an owned gradient backdrop. Call fixtures register real Media Session handlers with synthetic device-usage input; no microphone, camera or remote call is used. The holiday still arranges genuine bundled artwork. No browser interface is recreated in Remotion or the website demo.

`public/native/` preserves source PNGs and receipts with native point geometry, physical pixel dimensions, tool, app version, commit and SHA-256. `src/` contains short, literal Remotion compositions. `assets/` contains lossless posters, MP4s and their render/quality receipts. Sound is licensed editorial Foley; see `public/audio/README.md`.

Run the capture, import, render and review steps in [the release-media skill](../.agents/skills/lilo-release-media/SKILL.md). Make is the command surface. A visible Retina macOS session is required to capture genuine native windows; a hidden window or insufficient density fails. Remotion renders are evaluation drafts (`isProduction: false`).

The same PNG/MP4 bytes serve both consumers. `site/public/release-media` links to the complete archive using stable lossless URLs. `make ui-build` stages only the installed release's media as a native folder resource, keeping old films out of the app bundle. Historical review uses a build-time preview version; it never changes the binary's reported version. Native media stays on the private chrome origin, with bounded byte-range responses for seeking.

`make release-media-check` verifies all release decisions, exact note references, native and rendered hashes, current recipe/source receipts, MP4 dimensions and frame rate, AAC sound, full decoding, volume peaks and encoded-frame similarity against the lossless poster. CI runs it independently. This technical gate does not certify editorial quality.

Publication remains **blocked**. Every render is unapproved, and `make release-media-publish-check` deliberately fails. The release workflow runs that gate before signing or uploading. It checks approvals, current file hashes and a passing quality receipt bound to the exact render; the full codec checks run independently in CI. After approval, run `make release-media-check` again to bind that receipt to the approved render. Failed capture, rendering, decoding or review must never silently become a screenshot or no media. Historical WebP recordings remain archived unchanged.

The website's normal deployment command also requires that publication gate. Pages remain static Astro output. A small Cloudflare Worker handles byte ranges only for `/release-media/*.mp4`, because the static-assets preview returns a whole file for a range request. This gives the real browser player seeking and replay without a player framework. Its assets binding and selective routing follow the [Cloudflare configuration API](https://developers.cloudflare.com/workers/static-assets/binding/).
