# Changelog

What changes in each Lilo release, for people using it. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Lilo offers to move itself to Applications when it runs from the disk image, then relaunches from there and ejects the disk image.
- Pin any number of extensions: the ones that do not fit in the address bar fold into the extensions menu.
- An extension's details link to its Chrome Web Store page.
- Saving a capture asks where to save it when downloads do.
- Shift Command 2 captures a selected area of the page.
- The emoji picker of a space searches and names emoji in the browser's language.
- A French version of the website.

### Fixed

- A crash when an extension scripts a tab at the moment Lilo puts it to sleep.
- The site details card fits a narrow sidebar and shows while a permission request waits.
- Full screen: no more white band at the top, and the sidebar shows whole or stays hidden, as its setting says.
- AI agents no longer time out while Lilo waits for you to allow them: they are told to ask you.
- An agent asking to connect is no longer hidden behind an extension's permission request.
- The Chrome Web Store no longer asks you to switch to Chrome.
- A disabled extension keeps its logo, and logos no longer sit on a colored tile in Settings.
- The space editor's color picker and eyedropper work on the first try.
- Opening profile management from the space editor keeps the space's unsaved edits, and its footer wraps in a narrow window.
- Light accent colors keep white labels readable.
- The import lists browsers macOS does not let Lilo read, with how to grant access.
- Update checks always fetch the latest release.

## [0.1.2] - 2026-10-24

### Added

- A colored icon on every settings group.
- AI agents: Connect shows its progress until Lilo answers.

### Fixed

- A crash when an extension injects a script into a tab Lilo had put to sleep, common right after importing extensions from Chrome.

## [0.1.1] - 2026-10-24

### Fixed

- Update checks: 0.1.0 could not start its updater ("Unable to check for updates"). If you installed 0.1.0, replace it once with this version; later versions arrive on their own.

## [0.1.0] - 2026-10-24

First public release: a native macOS browser for people who live in a sidebar, with Spaces that keep their own sign-ins, Chrome Web Store extensions, terminal tabs, and an Arc import. Requires macOS 26 or later.

[Unreleased]: https://github.com/Alexays/Lilo/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/Alexays/Lilo/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Alexays/Lilo/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Alexays/Lilo/releases/tag/v0.1.0
