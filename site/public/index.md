# Lilo: a native Mac browser with Spaces and Chrome extensions

> A free, open-source Arc alternative for Mac, built on WebKit: Spaces with their own sign-ins, Chrome extensions, a terminal and an MCP server for AI agents.

Web page: https://getlilo.app/

**Your internet, in bloom.**

Light on your Mac, quick on the web. Free and open source. Spaces with their own sign-ins, the Chrome extensions you rely on, room for your AI agents, and a battery that lasts the day.

- [Download for Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [Star on GitHub](https://github.com/Alexays/Lilo)

```sh
brew install --cask alexays/tap/lilo
```

Moving in takes five minutes. [See the moving guide](https://getlilo.app/moving/)

Lilo is in beta: expect rough edges, and [tell us what breaks](https://github.com/Alexays/Lilo/issues).

## Built on WebKit. Not on a second Chrome.

Lilo uses the engine already inside macOS, written in Swift. No Chromium bundled, no Electron. Your Mac spends its energy on your pages.

### The engine Safari uses

Apple tunes WebKit for Apple silicon, video decoding and sandboxing. Lilo gets every macOS update for free.

### Easy on the battery

Idle tabs freeze, then sleep. Background Spaces stop working when you are not looking at them.

### Light on memory

Tab memory follows how much RAM your Mac really has, and gives it back under pressure.

### Energy and memory

**Measurements coming soon**

Lilo, Safari and Chrome with the same 20 tabs for 30 minutes on the same Mac. The method ships with the numbers.

## The Chrome Web Store, with an "Add to Lilo" button.

Browse the store you know and install in one click. Lilo runs Manifest V3 extensions on WebKit, keeps them updated, and gives each profile its own set.

- Password managers
- Ad blockers
- Dark mode
- Dev tools
- Writing helpers
- Price trackers

## What you do in Lilo stays on your Mac.

No account, no telemetry, no analytics. The project runs no server, so there is nowhere for your browsing to go. And every line is open for you to check.

One switch away in Settings: HTTPS-Only mode and Global Privacy Control.

### Trackers blocked out of the box

Ads, trackers and cookie banners are filtered with community lists kept up to date. Nothing to install.

### Sign-ins kept apart

Each Space can have its own profile, with its own cookies and storage. Private Spaces forget everything when they close.

### Agents on a short leash

Agents never see your private tabs, and Lilo asks you before one sends, pays, deletes or publishes anything.

### Apple's engine and sandbox

Pages run in WebKit's sandboxed processes and get Apple's security fixes with every macOS update.

## Everything in its Space.

The sidebar you know, with the details that make it yours. Move in from Safari, Chrome, Brave, Edge, Vivaldi, Opera, Arc, Dia, Comet, Chromium, Firefox or Zen in five minutes, straight from your Mac. [How moving works](https://getlilo.app/moving/)

### Spaces with their own sign-ins

Work and Perso side by side in one window, each with its cookies and extensions. Swipe between them.

`⌃1` `⌃2`

### Peek

Links from your pinned tabs open over the page. Keep reading, expand it to a tab, or put it in a split.

`⇧ click`

### Little window

A quick window from any app, for one link or one search. Send it to a Space when it turns into something.

`⌘⌥N`

### Tabs that tidy themselves

Unpinned tabs you stopped using are archived after 12 hours, or when you choose. Find them again in a keystroke.

`⌘⇧K`

### Command bar

Tabs, history, bookmarks and every action in one field, ranked by what you use. Open a result in a split or a Peek.

`⌘T` `⌥↩`

### Your shortcuts

Every shortcut can be remapped. Start from a preset, conflicts are flagged as you type.

### Links land in the right Space

Links opened from Mail or Slack follow your rules: this domain to Work, the rest to the Little window.

### Split view

Up to four tabs side by side, a terminal next to your docs, restored exactly as you left them.

## Your terminal lives in the sidebar.

Terminal tabs sit next to your docs and your localhost, on a native Metal renderer built on libghostty. Split one beside a page, and the sidebar shows its branch and pending changes at a glance.

- **Stays awake while it works.** A long build or an agent run keeps your Mac awake, even with the lid closed, then lets it sleep when the command ends.
- **Tells you when it's done.** A finished or waiting command lights up its Space, so you can browse while it runs.
- **Review before you commit.** The changes view shows every diff of the repo, images included.
- **Talks to your tools.** AppleScript, Shortcuts and Focus filters, plus Web Serial for boards like Arduino and ESP.

## Your agents get their own Space.

Lilo has a built-in MCP server. Claude Code, Codex, Cursor or any MCP client open tabs, click, type, and read pages, the console and the network, in a real browser beside you.

- **Their own Space.** Agents open tabs in a folder of the Agents Space, signed in nowhere by default. Your keyboard, your mouse and your tabs stay yours.
- **You say yes first.** Lilo asks before an agent sends, pays, deletes or publishes. Each agent is approved once, and none ever sees a private Space.
- **One click to connect.** In Settings, Connect adds Lilo to Claude Code, Claude Desktop, Codex or Cursor. Any other client copies the configuration.
- [How agents work](https://github.com/Alexays/Lilo/blob/main/docs/AI-AGENTS.md)

No AI inside Lilo: bring the agent you already use.

## Good to know.

### Is Lilo free?

Yes. Lilo is free and open source under the [MIT license](https://github.com/Alexays/Lilo/blob/main/LICENSE). There is no paid tier and no account to create.

### What is Lilo built on?

WebKit, the engine Safari uses, with a native app written in Swift. No Chromium is bundled. On top of it, Lilo runs Chrome extensions from the Chrome Web Store.

### Which extensions work?

Manifest V3 extensions from the Chrome Web Store install with one click and keep updating. Manifest V2 extensions and blocking `webRequest` are not supported, and a few extensions rely on other features only Chrome has. The [compatibility notes](https://github.com/Alexays/Lilo/blob/main/COMPATIBILITY.md) list exactly what differs.

### Do Netflix, Spotify and other streaming services work?

Lilo plays protected video and music through Apple's FairPlay, the same system Safari uses, so services that support Safari, like Netflix, Prime Video, Disney+, Apple TV+ and Spotify, should play as they do there. YouTube streams in 4K HDR. Widevine is not available in WebKit, so a service that requires it plays at lower quality or not at all, and offline downloads in the browser are not supported.

### Can I bring my stuff from another browser?

Yes. Lilo imports bookmarks, history and sign-ins from Safari, Chrome, Brave, Edge, Vivaldi, Opera, Arc, Dia, Comet, Chromium, Firefox and Zen, open tabs where the browser keeps them, and offers to reinstall your Chrome Web Store extensions. [See what comes with you](https://getlilo.app/moving/).

### What about my passwords?

Lilo keeps no passwords itself and never reads them from other browsers. Setup offers the manager you already use, such as NordPass, Bitwarden, 1Password, Proton Pass, Dashlane or KeePassXC. iCloud Passwords comes as soon as Apple approves it.

### Is there sync, or a mobile app?

No, by design: Lilo has no account and no server, so there is nothing to sync through. It is a Mac app only. Your password manager keeps syncing your passwords everywhere, and importing changes nothing in your other browser, so its own sync to your phone keeps working.

### Does Lilo have AI built in?

No. If you turn it on, the agents you already use, like Claude Code, Codex or Cursor, can drive Lilo over a local MCP server, in their own Space. Each agent is approved once, never sees your private Spaces, and Lilo asks you before it sends, pays or deletes anything. [How agents work](https://github.com/Alexays/Lilo/blob/main/docs/AI-AGENTS.md).

### Where is my data?

On your Mac, kept apart per profile. No account, no telemetry, and the project runs no server, so nothing you do is sent to us. [Read the privacy notes](https://github.com/Alexays/Lilo/blob/main/PRIVACY.md).

### Why only on Mac?

Lilo is built on the WebKit engine that ships with macOS and written in Swift. That is what keeps it light and easy on the battery. It needs macOS 26 or later.

### How can I help?

Star the repo, report what breaks, or send a pull request. The whole interface is a Svelte layer you can change and rebuild in seconds.

## Open source, for good.

Read it, fork it, change the sidebar in Svelte and rebuild in seconds. Your browser stays yours.

- [Download for Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [Star on GitHub](https://github.com/Alexays/Lilo)

Lilo, made on a Mac for Macs. macOS 26 or later.

- [Moving to Lilo](https://getlilo.app/moving/)
- [Privacy](https://github.com/Alexays/Lilo/blob/main/PRIVACY.md)
- [GitHub](https://github.com/Alexays/Lilo)
- [Français](https://getlilo.app/fr/)
