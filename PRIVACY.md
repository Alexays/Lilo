# Privacy

Lilo is a local browser. It has no account, no sync, no telemetry and no analytics, and the project
runs no server: nothing you do in Lilo is sent to its developers.

## What stays on your Mac

History, bookmarks, sessions, settings, site permissions, downloads and extension data live in
SQLite databases and WebKit data stores under `~/Library/Application Support/Lilo`, separated per
profile. Private Spaces use non-persistent WebKit data stores that are discarded when they close.
Bookmarks are also indexed in Spotlight, on this Mac only, so they show up in Spotlight searches.
Lilo stores no passwords: HTTP basic-auth credentials go to the macOS keychain.

Features that keep their own data, all on this Mac:

- **Auto-archive:** unpinned tabs left idle past a Space's delay (12 hours by default, or never) move
  to the Space's archive, which keeps their URL and title for 30 days, at most 200 per Space.
  Private Spaces are never written to disk.
- **Terminal tabs** run your shell as you. Lilo saves each terminal's screen and scrollback
  under `Terminals/` to restore it on relaunch, and deletes a saved screen not reopened for 30 days.
  Terminals of private Spaces are not saved.
- **Link rules** (Settings, links opened from other apps) are matched on your Mac to choose the Space
  or Little window a link opens in.
- **Peek and Little windows** open pages in the profile of the Space they belong to, like any tab.
  The Little window shortcut works from any app through a system hot key: Lilo needs no
  Accessibility permission and sees no other keystrokes.
- **Downloads** are stamped with macOS quarantine (the file's source URL, agent "Lilo"), so
  Gatekeeper checks them when you first open them.
- **Diagnostics** (Help > Diagnostics) are built on demand: "Copy report" puts startup metrics and
  tab lifecycle counts on your clipboard, for you to paste where you choose. Lilo sends no crash
  report; macOS keeps its own under `~/Library/Logs/DiagnosticReports`.

## Import from other browsers

Import reads, on your Mac, the data of Chrome, Arc, Brave, Edge, Vivaldi, Dia, Comet, Opera,
Chromium, Firefox, Zen and Safari: bookmarks, open tabs and Spaces, history, cookies and the list of
installed extensions. It never reads passwords or payment data. Chromium cookies are decrypted with
the browser's "Safe Storage" keychain item, which macOS asks you to allow; Safari needs Full Disk
Access. Imported extensions are installed again from the Chrome Web Store by id: their data stays in
the other browser.

## AI agents

Lilo has no AI of its own. Agent control is off until you turn on Settings > AI agents > "Let AI
agents use Lilo". Agents connect through `lilo-mcp`, a local MCP server in the app bundle, over a
Unix socket (`agent.sock` in Lilo's support folder) that only your user account can reach; nothing
listens on the network.

- **Each client is approved once:** Lilo asks the first time it connects, and ties the approval to
  the program behind it (its code signature, or its path when unsigned). Settings lists approved
  clients and can revoke them.
- **Agents work in their own Agents Space**, in a separate "Agents" profile with none of your
  cookies, sign-ins or history, wiped at launch and when the last agent leaves. An agent can move it
  to one of your profiles only after you allow that profile.
- **What agents can read:** the pages of their own tabs (text, accessibility tree, screenshots,
  console, network, cookies of the sites those tabs show). They never see your other tabs, and never
  see or act on a private Space. Their `fetch` tool never returns `Set-Cookie` or `Authorization`.
- **Approval gate:** unless you turn it off, Lilo asks before an agent clicks or presses Enter on
  something that sends, pays, buys, orders, deletes, transfers, publishes or signs up (Allow once,
  Always allow on the site, Deny), and before it sends a request other than GET or HEAD with your
  cookies. Sites you always allow are listed in Settings. Handing a page one of your files always
  asks, whatever the setting.

The gate is a safety net, not a sandbox: code an agent runs in a page can act without asking. See
[docs/AI-AGENTS.md](docs/AI-AGENTS.md).

## Requests Lilo makes on its own

Besides the pages you open, Lilo contacts these services:

| What | Where | When | How to turn it off |
|---|---|---|---|
| Filter lists for content blocking | `easylist.to`, `ublockorigin.github.io`, and for the regional lists of your languages `easylist-downloads.adblockplus.org` and `raw.githubusercontent.com` | Every four hours at most | Disable content blocking in Settings (takes effect at the next launch); turn off Regional lists in Settings |
| Search suggestions | Your search engine's suggestion endpoint (Google, Bing, DuckDuckGo, Brave) with what you type in the address bar | While typing | Turn off search suggestions in Settings |
| Extension installs and updates | `clients2.google.com` (Chrome Web Store), with the ids and versions of your store extensions | On install, and an update check every five hours while store extensions are installed | Remove store extensions; turning off automatic extension updates only stops installing new versions |
| Google sign-in for extensions (`chrome.identity.getAuthToken`) | `accounts.google.com`, with the extension's OAuth client id and scopes | Only when an extension asks you to sign in, in a panel you see | Remove the extension, or close the panel |
| App updates (Sparkle) | `github.com` (the latest release's `appcast.xml`, then the update itself), with Lilo's version in the User-Agent; no system profile | Once a day, after you agree when Lilo asks | Decline the prompt, or turn off automatic updates in Settings |

The Chrome Web Store sees Lilo as Chrome, so its install button (relabeled "Add to Lilo") works (see
[COMPATIBILITY.md](COMPATIBILITY.md#user-agent-and-the-chrome-web-store)). Local and debug builds
never check for app updates.

## Requests WebKit and macOS make

Lilo uses the WebKit framework that ships with macOS, and with it these system services:

- **Fraudulent website warnings** (Safe Browsing) check visited addresses against Google's or
  Tencent's lists through Apple's privacy-preserving proxy.
- **Link tracking protection** strips known tracking parameters using a list macOS keeps up to date.
- **Page translation** runs on device with Apple's Translation framework.
- **Screen Time** receives the sites you visit outside Private Spaces, to report usage and enforce
  the limits set in System Settings > Screen Time.

## Tracking prevention and GPC

WebKit's cross-site tracking prevention (Intelligent Tracking Prevention) is off by default in
Lilo, because it signs you out of sites it misclassifies as trackers. Lilo's content blocker blocks
known trackers instead; turn tracking prevention on in Settings > Privacy. It keeps its statistics
on your Mac only, and turning it off clears them, not the sites' data.

With it off, third-party cookies work as in Chrome: a site embedded in another (an iframe, an image,
a script) receives the cookies it set while you visited it directly and can set new ones, so it can
recognize you across the sites that embed it. Embedded apps that sign in with their own cookies,
such as claude.ai artifacts, need them. WebKit blocks those cookies only together with tracking
prevention: turn it on to block them.

The content blocker lets bot-defense and captcha vendors through (PerimeterX/HUMAN, DataDome, Arkose
Labs, hCaptcha, Cloudflare Turnstile): sites rely on their scripts to tell people from bots, and with
them blocked they show a captcha on every visit. They can still see your visits to the sites using them.

Lilo sends the Global Privacy Control signal (`Sec-GPC`, `navigator.globalPrivacyControl`) by
default, on macOS versions whose WebKit supports it; turn it off in Settings > Privacy.

## Tab sharing

When a page asks to share your screen, Lilo's picker lists your tabs. The tab you pick is captured
inside Lilo and handed to that page only, video only; the sidebar marks the shared tab. "Share a screen or window instead" opens the macOS
picker. Extensions using `chrome.tabCapture` or `chrome.desktopCapture` go through the same pickers.

## Extensions

Extensions you install run with the permissions they request, which Lilo shows before installing.
What an extension does with your data is governed by that extension's own privacy policy.

## Contact

Questions about privacy: open a [discussion](https://github.com/Alexays/Lilo/discussions).
Security issues: see [SECURITY.md](SECURITY.md).
