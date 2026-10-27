# Lilo Roadmap

Lilo is a macOS WebKit browser with a Swift backend and a Svelte chrome overlay. The project bias is KISS: keep WebKit as the only engine, keep the Makefile as the contributor command surface, and add abstractions only when current code needs them.

Architecture lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); contributor setup and validation in [CONTRIBUTING.md](CONTRIBUTING.md); extension support in [COMPATIBILITY.md](COMPATIBILITY.md).

## Shipped

- Tabs, Spaces, profiles, private Spaces, session restore
- Sidebar with tab folders nested up to five levels, pinning, drag-to-reorder, and auto-archive of idle unpinned tabs
- A profiles page in Settings and a New Space panel (name, icon, color, profile)
- Peek (a link from a pinned tab, or a Shift-click, opens over the page) and page popups in a window of their own
- Little window with a global shortcut, and link rules that send links from other apps to a Space or a Little window
- Import from Arc, Chromium browsers, Firefox, Zen and Safari: bookmarks, tabs and Spaces, history, cookies, extensions
- Fully custom keyboard shortcuts, with the Lilo and Arc presets, and a `Ctrl+Tab` switcher in recent order
- Onboarding with browser import and password manager install
- Chrome MV3 extensions (WKWebExtension + Gap APIs) with native Web Store install, optional permissions granted at Lilo's prompt, and an Extensions popover to pin, manage and add them
- Content blocking (EasyList/EasyPrivacy/uBO lists, cosmetic and procedural filtering, scriptlets), paused per site on every layer
- Command palette with ranking and ghost completion
- Reader mode, screenshots (a floating capture card and a markup editor), Picture-in-Picture, media controls in the sidebar
- Tab lifecycle and memory management, process manager and diagnostics
- Downloads (speed/ETA, quarantine, notifications), find in page, share menu, QR codes
- Privacy controls (GPC, HTTPS-Only, clear browsing data, website data manager)
- Terminal tabs (libghostty-vt core, native Metal renderer, zsh and Fish shell integration), a Changes view of the working tree's diff, and keep-awake while a command runs
- Split view, page translation, tab sharing in screen-share calls (`getDisplayMedia`)
- Multiple windows over shared Spaces, with per-window selection and windows restored on relaunch
- Accessibility: VoiceOver across the sidebar tree, panels, Changes view and terminal, full keyboard reach, Reduce motion and Increase contrast
- Localization (English, French)
- Signed, notarized DMG, a Homebrew cask, and signed updates through Sparkle
- AppleScript dictionary, Shortcuts actions and a Focus filter, bookmarks in Spotlight, Screen Time
- Opt-in AI agent control over local MCP, with Claude in Chrome's tool set (no AI built in): an Agents Space, agent icons in the bottom bar, and an approval gate for consequential actions
- Web Serial API (`navigator.serial`) and EyeDropper API

## Next

- A launch that feels instant: the sidebar on screen in under 300 ms (about 410 ms today)
- Published energy and memory measurements against Safari, Chrome and Arc, with the method
- Releases built by CI from a tag, instead of on the maintainer's Mac
- Terminal tabs: shell integration for more shells
- Password managers: the iCloud Passwords helper needs an entitlement from Apple (see [COMPATIBILITY.md](COMPATIBILITY.md#icloud-passwords-extension))
- More locales

## Non-goals

- No Chromium or CEF abstraction unless the project explicitly changes engine strategy.
- No AI built into Lilo: no models, no assistant, no data sent anywhere. No telemetry, sync protocols, or data collection either: Lilo stays a simple, fast, local browser.
- No generic plugin framework for single-use features.
- No broad Chrome API claims without matching WebKit, Swift handler, JS bridge, and tests.
- No Windows or Linux port.

## How priorities are set

Lilo has a solo maintainer who daily-drives the browser; what breaks or hurts daily use gets fixed first. PRs are welcome, but ones that implement a non-goal will be closed: open a discussion first if unsure.
