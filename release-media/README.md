# Release media

The website and native What's New show the same media for a release highlight. A highlight names its kind (`film`, `loop` or `image`), and its files live at `assets/<version>/<highlight id>.{mp4,png}`.

- A **film** has sound and plays on request.
- A **loop** is silent and plays while it is in view, unless the reader prefers reduced motion.
- An **image** is a single picture.

`make ui-build` stages only the installed release's files in `lilo-ui/public/release-media/`, so the app never carries the archive.

## Making media

`make changelog-draft` writes a plan per highlight under `plans/<version>/`: a template and the steps that show the change in the real app. `make changelog-media RELEASE=x.y.z` runs them, renders the result with HyperFrames and GSAP, and names the media in the story and What's New.

- The capture is one test, `ReleaseMediaCaptureTests`, which drives the compiled app with a disposable profile and example.com pages. A close-up needs no screen recording permission; a whole window does.
- `templates.mjs` has four templates: `image`, `hero`, `compare` and `flow`. A film has no sound and no words, so it needs no translation and loops without a cut.
- Films ship at 1080p and 30 fps. An image renders at 3840 by 2160.

A plan that fails leaves its highlight text-only and says why, and a person fixes the plan or leaves it. Looking at the result is the review: the checks only prove a film plays.

`assets/0.8.0/tab-share.mp4` shows native Lilo 0.14.1, build 31, illustrating the 0.8.0 tab-sharing feature. It is not footage of a 0.8.0 binary, and its titles stay in English. Its soundtrack is **Week 37 - Schmoovin** by **Abstraction / Tallbeard Studios**, released under CC0 1.0 Universal. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
