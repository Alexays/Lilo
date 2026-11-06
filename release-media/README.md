# Release media

The website and native What's New show the same media for a release highlight. A highlight names its kind (`film`, `loop` or `image`), and its files live at `assets/<version>/<highlight id>.{mp4,png}`.

- A **film** has sound and plays on request.
- A **loop** is silent and plays while it is in view, unless the reader prefers reduced motion.
- An **image** is a single picture.

`make ui-build` stages only the installed release's files in `lilo-ui/public/release-media/`, so the app never carries the archive.

`assets/0.8.0/tab-share.mp4` shows native Lilo 0.14.1, build 31, illustrating the 0.8.0 tab-sharing feature. It is not footage of a 0.8.0 binary, and its titles stay in English. Its soundtrack is **Week 37 - Schmoovin** by **Abstraction / Tallbeard Studios**, released under CC0 1.0 Universal. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
