# Changelog

What changes in each Lilo release, for people using it. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Settings name the password manager you already use, with a Change button, instead of always offering to add one.
- The passwords step of the setup shows each password manager's own icon instead of its initial.
- Allow access on a browser macOS protects, such as Safari, opens Full Disk Access with a small Lilo panel beside it: turn Lilo on, or drag its icon into the list. Once access is granted, Lilo comes back and the browser is ready to import.

### Fixed

- Switching spaces no longer crops the start of the address while it fades in.
- Imported tabs, bookmarks and Arc spaces show their sites' icons right away, instead of an initial until each is opened.
- Importing no longer offers browsers that are not installed, whose folders password managers create for their helpers, and finds the icon of a Beta, Dev or Nightly browser or one installed outside LaunchServices.
- The Agents space no longer shows in Settings > Spaces, link rules, the external links setting or Move to Space, and no longer counts as a space of yours, so your last space cannot be deleted.

## [0.1.4] - 2026-10-24

### Changed

- The setup asks how you will use Lilo with a third choice between browsing and developing: with your AI agents, which turns them on and walks you through connecting them, without the terminal.
- The passwords step of the setup lists one password manager per row, so each description reads on one line.
- In the setup, Use Lilo is a secondary button: Continue stays the one main action.

### Fixed

- A permission request, such as an AI agent asking to connect, slides a hidden sidebar out so it can be answered, and an agent's connection request waits ten minutes instead of two.
- A Space without pinned tabs no longer leaves an empty band between its name and its tabs.
- An AI agent that reconnects while you are on your way to answer, as Claude Desktop's local agent mode does, is no longer refused behind your back: its request stays up, and once you allow it, its next connection is let in.
- An AI agent whose app macOS will not let Lilo identify is asked about instead of refused without a word; its approval lasts until it disconnects.
- Setting Lilo as the default browser no longer reports a failure after you accept macOS's prompt.
- An app downloaded with Lilo no longer opens on "(null) downloaded this file": macOS names Lilo as where it came from.
- Extensions an import reinstalls open their welcome pages in the background, instead of taking the window and the keyboard from the setup.
- The welcome after an import names what came over (bookmarks, open tabs, history and extensions), not only the pages of history.
- The setup's welcome screen names the Return key, as on a Mac.

## [0.1.3] - 2026-10-24

### Added

- Lilo offers to move itself to Applications when it runs from the disk image, then relaunches from there and ejects the disk image.
- Pin any number of extensions: the ones that do not fit in the address bar fold into the extensions menu.
- An extension's details link to its Chrome Web Store page.
- Importing from Chrome pins the extensions Chrome had pinned, in its toolbar order.
- Settings > Extensions has a profile picker, to see and manage the extensions of any profile from any window.
- Saving a capture asks where to save it when downloads do.
- AI agents can mock requests by their body, such as one GraphQL operation, and replace text on a page to anonymize it, with a guard that refuses a screenshot while a forbidden name still shows.
- AI agents can screenshot the whole page, lazy content and inner scrollers included, or one element with a margin, at the screen's full resolution, and save it to a file.
- Shift Command 2 captures a selected area of the page.
- The emoji picker of a space searches and names emoji in the browser's language.
- Rename a pinned tab from its menu or by double-clicking its title: the name stays across page title changes, navigations and relaunches, and an empty name brings the page title back.
- A pinned tab away from its page shows a slash and the page it is on after its name; clicking its icon takes it back, and Set as Pinned Page makes the current page its new one.

### Fixed

- Extensions such as Okta no longer ask for access on every page of the sites they declare, and a request never shows a page's full address.
- The Claude extension signs in: claude.ai can hand it the sign-in code again.
- Adblock Plus blocks again, extensions whose messaging rules name a hosting domain install, and FireShot captures the page.
- A crash when an extension scripts a tab at the moment Lilo puts it to sleep.
- The site details card fits a narrow sidebar and shows while a permission request waits.
- Full screen: no more white band at the top, and the sidebar shows whole or stays hidden, as its setting says.
- AI agents no longer time out while Lilo waits for you to allow them: they are told to ask you.
- An agent asking to connect is no longer hidden behind an extension's permission request.
- The Chrome Web Store no longer asks you to switch to Chrome.
- A disabled extension keeps its logo, and logos no longer sit on a colored tile in Settings.
- The space editor's color picker and eyedropper work on the first try.
- Removing a pinned tab or a bookmark can be undone from the toast, with Command Z from the sidebar, or with Reopen Closed Tab: it comes back where it was, with its name.
- Importing a browser's second profile installs its extensions into that profile, not only the profile on screen.
- Opening profile management from the space editor keeps the space's unsaved edits, and its footer wraps in a narrow window.
- Light accent colors keep white labels readable.
- The import lists browsers macOS does not let Lilo read, with how to grant access.
- Update checks always fetch the latest release.
- Onboarding: a double click no longer skips a step, the import step has a Back button, and each step puts the keyboard on its main button rather than on an extension to install or a setting to toggle.
- Onboarding: the arrow keys move between the usage and theme choices, the welcome screen keeps VoiceOver out of the window behind it, the welcome toast is spoken, and each Connect button names its app.
- Onboarding: the welcome screen's petals turn into your first space's icon.
- Onboarding: the import keeps "Choose what to import" in view in a small window, and the Full Disk Access link lines up when it wraps.

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

[Unreleased]: https://github.com/Alexays/Lilo/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/Alexays/Lilo/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Alexays/Lilo/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Alexays/Lilo/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Alexays/Lilo/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Alexays/Lilo/releases/tag/v0.1.0
