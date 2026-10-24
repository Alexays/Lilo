<div align="center">

# Lilo

**Your internet, in bloom.**

Light on your Mac, quick on the web. Free and open source.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](LICENSE)
[![Status: public beta](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#install)

[Website](https://getlilo.app) ·
[Install](#install) ·
[Build from source](#build-from-source) ·
[Documentation](docs/README.md) ·
[Contributing](CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/lilo-dark.png">
  <img src="docs/assets/lilo-light.png" alt="Lilo with the Work Space open: sidebar with pinned sites, folders and tabs, beside a web page and a terminal tab" width="900">
</picture>

</div>

Lilo is a native macOS browser for people who live in a sidebar, and for the AI agents that work
beside them: Spaces with their own sign-ins, the Chrome extensions you rely on, terminal tabs beside
your pages, a built-in MCP server, and a battery that lasts the day. If you are leaving Arc, it
imports your Spaces, pinned tabs and folders in a few clicks.

> **Status: public beta.** Lilo is usable every day, but it is still a beta: expect rough edges and
> an interface that still moves, and please [report what breaks](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](ROADMAP.md) lists priorities and non-goals.

## For AI agents

Lilo has a built-in MCP server. Turn it on, and the agents you already run (Claude Code, Claude
Desktop, Codex, Cursor or any MCP client) drive a real WebKit browser beside you. Lilo ships no AI
of its own.

- **Their own Space.** Agents open their tabs in a folder of the Agents Space, in a throwaway
  profile wiped after each session. They never take your keyboard, your mouse or your tabs, and
  never see a private Space. An agent can borrow one of your profiles once you allow it.
- **You say yes first.** Lilo asks before an agent sends, pays, deletes or publishes (Allow Once,
  Always Allow on the site, or Deny), and before it hands a page one of your files. Each client is
  approved once, tied to the program behind it rather than the name it gives.
- **One click to connect.** In Settings > AI agents, turn on "Let AI agents use Lilo", then press
  Connect next to Claude Code, Claude Desktop, Codex or Cursor: Lilo adds itself to that client's
  MCP servers. Any other client copies the configuration from "Other agents".

Then ask your agent something like:

```text
Open localhost:3000/checkout in Lilo, pay with the test card and find out why the order fails.
Check the console and the network.
```

The tools cover:

- **Tabs and navigation** in the agent's folder, and isolated tabs that share no cookie or sign-in.
- **Input**: click, type, keys, scroll, drag, form filling, file and image uploads.
- **Page reading**: the accessibility tree with element refs, text search, the page text.
- **Screenshots** of a full page or one element, and GIF recordings.
- **Console and network**: messages, requests with their full responses, HAR export, cookies.
- **Network mocks and emulation**: mocked, failed or delayed requests; user agent, color scheme,
  reduced motion, print media, extra headers, init scripts; viewport size.
- **Performance**: load and paint metrics, memory, and timeline profiles.
- **Web Inspector**: WebKit's own inspector protocol, commands and events.
- **Scripting**: JavaScript in the page, `fetch` from a tab with its cookies, and `run` or
  `browser_batch` to chain many calls in one round trip.
- **Profiles**: list them, borrow one after you allow it, or reset the throwaway one.

[docs/AI-AGENTS.md](docs/AI-AGENTS.md) has the details: what is asked, what is not, and the errors
that need you.

## Why Lilo

- **Native.** Swift, AppKit and the WebKit engine already on your Mac. No bundled Chromium, no
  Electron: lower memory use, longer battery life, and Apple's security updates with every macOS
  release.
- **Organized.** A vertical sidebar with Spaces, pinned tabs and folders. Each Space can have its
  own profile, so work and personal sign-ins live side by side in one window.
- **Compatible.** Chrome Web Store extensions install with one click on "Add to Lilo".
- **Private.** No account, no telemetry, no analytics, no server: nothing you do is sent to the
  project. Ads and trackers are blocked out of the box.
- **Yours.** MIT licensed. The whole interface is a Svelte layer over WebKit that you can change
  and rebuild in seconds.

## Features

**Browsing**

- **Spaces and profiles**: Spaces with an emoji and a color, each signed in as its own profile;
  swipe between them. Private Spaces forget everything when they close.
- **Sidebar**: pinned tabs, favorites, folders nested up to five levels (lockable), drag to
  reorder, audio and now-playing controls.
- **Command bar** (`Cmd+T`): tabs, history, bookmarks, Spaces and every action in one field,
  ranked by what you use.
- **Recent tabs** (`Ctrl+Tab`): switch through your last tabs, from every Space, in the order you
  used them.
- **Peek**: a link from a pinned tab to another site, or any `Shift`-clicked link, opens over the
  page.
- **Little window** (`Cmd+Option+N`, from any app): a small window for one link or search, sent to
  a Space when it turns into something.
- **Tabs that tidy themselves**: unpinned tabs you stop using are archived after a delay you choose
  per Space; `Cmd+Shift+K` clears them, and the archive is one keystroke away.
- **Link rules**: links opened from other apps go to the Space or the Little window a rule picks.
- **Split view**: up to four tabs side by side, restored on relaunch.
- **Shortcuts**: every shortcut can be remapped, starting from the Lilo or Arc preset.
- **Import**: bookmarks, open tabs and Spaces, history, cookies and extensions from Safari,
  Firefox, Zen and Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), read straight from your Mac.

**Extensions and the web**

- **Chrome extensions**: Manifest V3 through WebKit's native extension runtime, plus small Swift
  handlers for the APIs WebKit lacks ([COMPATIBILITY.md](COMPATIBILITY.md)).
- **Password managers**: setup offers the one you use (1Password, Bitwarden, Dashlane, KeePassXC,
  NordPass, Proton Pass).
- **Streaming**: protected video and music through FairPlay; YouTube in 4K HDR.
- **Content blocking**: EasyList, EasyPrivacy and uBlock Origin lists, kept up to date, with
  cosmetic filtering and scriptlets.
- **Screenshots**: a capture floats as a card over the page, ready to edit with markup, save or
  dismiss.
- **And more**: reader mode, Picture-in-Picture (calls float in an always-on-top panel), page
  translation, Web Serial, AppleScript, Shortcuts actions and a Focus filter.

**For people who build**

- **Terminal tabs**: libghostty-vt terminals on a native Metal renderer, beside your pages
  (`Cmd+D` beside, `Cmd+Shift+D` below), with the branch and pending changes in the sidebar.
- **Changes view**: every diff of the repository, images included.
- **Stays awake while it works**: a long command keeps the Mac awake, even with the lid closed,
  then lets it sleep.
- **Agents over MCP**: the built-in MCP server, see [For AI agents](#for-ai-agents).

## Install

Either:

- download the DMG from [Releases](https://github.com/Alexays/Lilo/releases/latest), or
- install with Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo updates itself through signed Sparkle updates.

### Requirements

- macOS 26 or later. Global Privacy Control needs macOS 27.

## Build from source

With Xcode 27, Node.js 22.6+ and Zig 0.16 installed ([full prerequisites](CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

No Apple Developer account is needed. Source builds are ad-hoc signed by default;
[CONTRIBUTING.md](CONTRIBUTING.md#signing) explains the trade-offs and how to sign with a free
Apple ID.

## Documentation

- [docs/](docs/README.md): architecture, debugging, localization, releasing, AI agents
- [COMPATIBILITY.md](COMPATIBILITY.md): what still differs from Chrome for extensions and sites
- [PRIVACY.md](PRIVACY.md): every request Lilo makes on its own
- [ROADMAP.md](ROADMAP.md): what is shipped, what is next, and the non-goals

## Contributing

Pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the development
workflow and the pull request checklist. Questions go to
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](SUPPORT.md)), and
vulnerabilities are reported privately ([SECURITY.md](SECURITY.md)). Everyone taking part follows
the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

MIT, see [LICENSE](LICENSE). Bundled third-party components are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
