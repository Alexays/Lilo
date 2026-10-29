---
name: lilo-release-media
description: Use when preparing Lilo release highlights, changelog media or in-app What's New, especially when choosing between a native screenshot and a Remotion movie.
---

# Lilo release media

Explain the most important shipped improvements with real Lilo pixels. Read the exact prepared release notes, relevant implementation and existing release media before selecting stories. Select a few user benefits; avoid turning every QA assertion into a shot.

Choose the medium before capture:

- Use motion when an interaction, change over time or relationship makes the benefit clearer. A story can combine tightly cropped native stills and short native clips.
- Use a carefully framed native screenshot when the finished state is enough. Maintenance releases can use a contextual native product still; do not pretend that a screenshot proves an invisible performance improvement.
- A failed required capture or render never becomes a still to get past the gate.

All product UI must come from the compiled native Lilo app, with a disposable profile and synthetic content. Never use the website's Svelte demo or recreate product controls in React. Preserve the actual app version/build and capture evidence. Historical sources remain immutable. Do not depend on a person's unlocked Mac as a CI fallback.

Read [motion direction](references/motion-direction.md) and Remotion's [official skills](https://www.remotion.dev/docs/ai/skills). Author ordinary React compositions; avoid a scenario DSL, feature registry, universal slideshow template or another authoring service. Use a short native test with existing fixture helpers for a new capture flow.

For the 0.8.0 feedback proof, run from the repository root:

```sh
make release-motion-studio
make release-motion-capture release-motion-import
make release-motion-render
make release-motion-test release-motion-check
make release-motion-native-check
make release-motion-native-review
make release-motion-native-preview
make site-preview SITE_PREVIEW_PORT=8792
```

`release-motion-render` currently renders the 0.8.0 compositions. Fresh capture uses the real current Lilo binary to demonstrate the features introduced in 0.8.0; `remotion-source.json` records its actual version/build separately from the story version. The original 0.8.0 archive stays immutable. Add ordinary compositions and genuine release sources for another release; never relabel a binary.

Studio and the two previews are persistent servers; run each in its own terminal. The CI proof lives in `.github/workflows/release-media-proof.yml`. The native preview reads the checked-in 0.8.0 presentation, not a custom `OUT` directory. Leave its `approved` flag false while visual feedback is pending; file checks alone must not flip it.

New movies are H.264 MP4 plus a useful feature-state PNG poster. Stills are PNG. Remotion runs at build time; both consumers use the same files. Keep translated editorial outside the movie rather than introducing another caption/translation system.

Capture fresh sources after blur feedback. Do not decode and enlarge a lossy historical WebP. The proof records window footage at verified native density and 4x snapshots of the actual compiled native chrome. Request ScreenCaptureKit's best independent-window resolution and record actual pixel/content scales; output dimensions alone do not prove density. A crop must not exceed its genuine captured pixel count at output resolution. Keep stills lossless through the website image pipeline. Use actual native region bounds, without inventing or redrawing controls.

MP4 cards expose play/pause, seeking, mute and fullscreen through the platform player. Keep the player available when paused or ended. Autoplay is muted; sound is explicitly enabled by the viewer. The proof adds original editorial sound design, not purported Lilo UI sounds or a recording of a person's desktop. Check the AAC stereo track and decoded audio levels; silence or clipping blocks release.

Inspect representative frames, transitions and the full movie in the actual compact website and native sheet. Check active labels, crop boundaries, sharpness, meaningful result holds, EN/FR, keyboard, Reduce Motion, hidden/offscreen stopping and cached replay. Run `make validate` plus focused browser and native checks. Capture, semantic, render, asset or visual failure blocks publication. The 0.8.0 proof intentionally remains unapproved until visual feedback is accepted; passing file checks alone does not approve it.
