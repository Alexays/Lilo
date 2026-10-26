# Changelog

What changes in each Lilo release, for people using it. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.4.1] - 2026-10-26

### Changed

- The website now includes the interactive Lilo interface with its real app icons, native menus and settings, a feature explorer, local browser and terminal examples, and a Codex demo that controls sample pages through MCP with visible actions and approval prompts. Saved tabs, split views, keyboard customization and profile controls follow the Mac app.
- Cross-site tracking prevention is on by default, as in Safari: sites embedded in others can't follow you from site to site.
- Pages that tell the browser which page comes next (link prefetch) now get it loaded ahead, so following that link opens it at once.

### Fixed

- With tracking prevention on, sites you keep using, such as Google and YouTube, no longer sign you out after a while.
- Lilo no longer quits when an extension runs a script in a tab that was just put to sleep.

[0.4.1]: https://github.com/Alexays/Lilo/compare/v0.4.0...v0.4.1
## [0.4.0] - 2026-10-26

### Added

- Agents learn when a failed click, Enter or write request may already have reached the site, so they check before trying again instead of doing it twice
- A page the content blocker stops from loading offers Visit Anyway, which loads it once without blocking, in place of Try Again

### Changed

- Lilo checks for and downloads updates on its own, then offers a Restart card at the bottom of the sidebar (an icon in a top or bottom tab bar) instead of an alert; ignored, the update installs when Lilo quits

### Fixed

- Importing from Arc puts each profile's Favorites in every one of its spaces, and no longer loses them when a space has the same name as its profile

[0.4.0]: https://github.com/Alexays/Lilo/compare/v0.3.3...v0.4.0
## [0.3.3] - 2026-10-26

### Changed

- Each agent works in its own profile, in an Agents space per profile: one agent switching profile no longer moves the other agents' tabs, and the Agents space menu no longer has a profile picker.
- An agent's permission prompt puts Deny beside Allow Once, with Always Allow on its own row above.

### Fixed

- An active pinned or favorite tab on a tab strip no longer covers the tabs beside it.
- An agent whose MCP server restarts keeps its tabs, and a tab that closed with its conversation says why.
- A long agent script or profile switch is no longer cut off after 90 seconds as if Lilo were frozen.
- The command bar no longer puts a locked folder above the web search when a query only matches scattered letters of one of its tabs, and a folder named with an emoji shows that emoji as its icon.
- Clicking a docked call or video from another space goes back to its space and tab, instead of hiding it.
- Links on image-heavy pages like Mobbin open right away again, instead of sometimes taking up to a minute while the content blocker kept the page busy.

[0.3.3]: https://github.com/Alexays/Lilo/compare/v0.3.2...v0.3.3
## [0.3.2] - 2026-10-26

### Fixed

- The Check now button sits beside Lilo's version in Settings again, instead of stretching across the row below it.
- Moving the tabs from the sidebar to the top or the bottom no longer leaves the new tab bar deaf to clicks and hovers until the window is resized.
- With many tabs on a tab strip, squeezed tabs no longer slide under the Settings tab: the row scrolls instead.

[0.3.2]: https://github.com/Alexays/Lilo/compare/v0.3.1...v0.3.2
## [0.3.1] - 2026-10-26

### Added

- The AI agents step of the setup copies Lilo's configuration for any other MCP agent, as Settings does.

### Fixed

- The address bar keeps its height when its site controls button shows up, as when a site uses the camera or microphone.

[0.3.1]: https://github.com/Alexays/Lilo/compare/v0.3.0...v0.3.1
## [0.3.0] - 2026-10-26

### Added

- Seven clicks on Lilo's version row in Settings add Lilo's own developer tools to the Develop menu, such as its chrome's devtools.

### Changed

- With the tabs on top or at the bottom, Settings opens as a page: its sections sit beside the content in one card, and the tab strip shows an active Settings tab that closes it.

[0.3.0]: https://github.com/Alexays/Lilo/compare/v0.2.4...v0.3.0
## [0.2.4] - 2026-10-26

### Fixed

- Moving the tabs to another edge no longer leaves the tab bar frozen or unclickable until Lilo restarts.
- A permission prompt opened from the address above the page hangs down into the page instead of rising off the top of the window.
- An agent you allowed is no longer asked again after Lilo updates while the agent keeps its connection helper running.

[0.2.4]: https://github.com/Alexays/Lilo/compare/v0.2.3...v0.2.4
## [0.2.3] - 2026-10-25

### Fixed

- Extension icons fill their spot in the toolbar and the extensions list again, instead of showing at a quarter of their size in one corner.
- On a tab strip, every tab scrolls as one row, pinned and favorite ones too, and a pill squeezed to its icon no longer shows a stray close button over its neighbor.

[0.2.3]: https://github.com/Alexays/Lilo/compare/v0.2.2...v0.2.3
## [0.2.2] - 2026-10-25

### Fixed

- An extension's items show once in a page's context menu, not twice.
- The badge of a tab an agent controls stays in view when the window is narrower than the agent's viewport.
- Extensions that talk to each other through a port, such as companion extensions starting together, no longer wait forever for an extension that is not ready, and no longer lose the first messages on a fresh connection.
- An extension page or worker no longer sometimes stops hearing its events, or waits forever on its calls, when it opens at the same time as another part of the extension.
- A content script's port to another extension no longer hands that extension a stray internal message now and then.
- An extension's first notification no longer leaves the extension waiting until you answer macOS's permission prompt.
- An extension disabled, updated or removed just as its popup opens no longer makes Lilo crash later.

[0.2.2]: https://github.com/Alexays/Lilo/compare/v0.2.1...v0.2.2
## [0.2.1] - 2026-10-25

### Fixed

- A page opened from a peek as a tab now keeps its favicon.
- Replaying the onboarding no longer changes the icon of your current Space.
- An AI agent app that Lilo had once asked about, and that reconnects at each try like Claude's local agent mode, is asked again instead of being refused without a prompt until Lilo restarts.

[0.2.1]: https://github.com/Alexays/Lilo/compare/v0.2.0...v0.2.1
## [0.2.0] - 2026-10-25

### Added

- When a page cannot load because the connection timed out, dropped or is offline, the error page offers Show Saved Copy, to read the version Lilo last kept of it.
- Downloads cut off by the network resume on their own from where they stopped, up to three times, instead of waiting for Retry.
- Extensions can message one another, and VPN extensions can answer a proxy's sign-in, as in Chrome.
- Typing the start of a site you visit completes it inline in the command bar, and Return goes there; Fn-Delete drops the completion.
- Pinned tabs and bookmarks have an Edit... item that changes their name and the address they open, for a site that redirects elsewhere; Use Current Page replaces Set as Pinned Page.
- A Space's color can follow the time of day, the page you're on or your wallpaper, chosen in the Space editor and during onboarding.
- Put your tabs on any edge of the window: left, right, top or bottom, with the address with the tabs or above the page. Pick it in Settings, during the setup, from the command bar, or by holding the sidebar's top and dragging it to an edge.
- Extensions can message other extensions from their content scripts, and reach their own pages open in a tab.

### Changed

- The website now includes release notes for every published version.
- On Low Data Mode networks, Lilo no longer refreshes its content blocking lists or checks for extension updates in the background, and these refreshes give way to the pages you load.
- Favicons load the smallest icon that looks sharp instead of the largest one, so a site's icon costs less on a slow connection.
- Viewing a page's source shows what the tab loaded, instead of downloading the page again.
- Extensions start faster and cost less while idle: Lilo prepares an extension again only when it or Lilo changed, opens restored extensions together, loads only the APIs an extension may use, wakes a stopped extension only for what it listens to, and reports each tab change once.
- Extension updates are checked once for every profile, and each new version downloads once.
- An unpacked extension loads from a copy that follows its folder, so Lilo no longer writes into the developer's files.
- The website has simpler navigation, a theme toggle and a new footer with GitHub and Discord icons. Space transitions are animated and the preview also works without JavaScript. Extension links open the Chrome Web Store. Text contrast and keyboard access are improved.
- Each space is its own window to extensions, so switching spaces no longer hides the other spaces' tabs from them, and a window an extension opens is its own floating window, which it can close without touching yours.
- Extensions start faster and answer sooner: less code loads in their background, tab queries take one round trip, and bursts of storage writes go out together.
- Ad blockers that turn off some of their rules no longer make Lilo prepare them again at the next launch.

### Fixed

- A page that times out or whose server name gets no answer is tried again once on its own, and a page left on an error reloads when you switch networks, such as from Wi-Fi to your phone's connection, not only when you come back online. A mistyped address still shows its error right away.
- Try Again on a form that failed to send no longer opens its address without what you filled in: it reloads the page the form was on.
- Search suggestions show while you type on a slow connection, instead of only once you stop typing.
- A favicon that loads too slowly no longer leaves the site without an icon for ten minutes.
- When the extension update service cannot be reached, Lilo checks again 30 minutes later instead of 5 hours later.
- An extension without access to private spaces can no longer reach a private tab.
- Extensions see every open tab, including those not loaded yet, with the tab group, the tab that opened it and when it was last used, as in Chrome.
- Extensions that check whether a page already runs their script, then inject it (translators, screenshot and SEO tools), work again, and ad blockers that register their scripts at run time get the same compatibility as the others.
- Tab groups, history and downloads changes you make reach your extensions, and a download's events reach the extensions of its own profile.
- A tab whose page never loaded, such as a localhost server that was down, shows the error page after a relaunch instead of staying blank.
- The import step of onboarding no longer offers a browser you uninstalled because of the data it left behind.
- The ad blocking icon in onboarding stands out more against its tile.
- Dragging a tab from the sidebar onto the page to open it in split view no longer switches to the next Space.
- A Space's tooltip no longer repeats its name when its profile has the same one.
- In Settings, an agent app Lilo is set up in but that never connected reads Configured, instead of a Set up label that looked like a disabled button.
- Sites show fewer captchas: pages no longer see any trace of Lilo's own web APIs, the user agent states Safari's exact version, and the content blocker lets bot-defense scripts through.
- A right-click no longer leaves a tooltip on screen under the context menu.
- Claude artifacts and other embedded apps that sign in with their own cookies now open, instead of saying the browser isn't supported.
- The site details card under the address bar shows in full over the page when the sidebar is narrow, instead of being cut off at the sidebar's edge.
- The custom color swatch in the Space editor keeps its color wheel once a custom color is picked, so it still reads as the way to pick another.
- The command bar no longer lists an open tab whose title only holds the typed letters scattered apart, so a long search goes to the web instead of switching to an unrelated tab.
- Dropping a tab on the left or right of the page opens it in a split view again, instead of doing nothing.
- Extensions no longer keep Lilo and its web processes busy after launch: restored tabs are seen by extensions again, so their scripts stop retrying in a loop.
- Dashlane's toolbar popup no longer shows an empty vault while the window shows a terminal or another page that is not a website, and extensions that reapply the same blocking rules at each start no longer make Lilo rebuild them.
- Proton Pass fills a login when you pick it in its menu under a field.
- Lilo no longer quits when an extension opens a window just as it appears.
- More Chrome extensions load and run as in Chrome, among them Axure RP, Octotree, Table Capture, Mailvelope and Microsoft Solitaire.
- Extension popups that read their settings when they open, such as Markdown Reader's, show them instead of opening empty.
- Extensions that check the network connection type, such as Lightspeed Insight Agent, start again, and extensions reading managed settings with defaults get those defaults.

[0.2.0]: https://github.com/Alexays/Lilo/compare/v0.1.5...v0.2.0
## [0.1.5] - 2026-10-24

### Changed

- Settings for AI agents, the terminal's sleep and content blocking are clearer: no indented rows, one choice for when the Mac stays awake, statuses as badges, and always-allowed sites as chips you remove in one click.
- Settings name the password manager you already use, with a Change button, instead of always offering to add one.
- The passwords step of the setup shows each password manager's own icon instead of its initial.
- Allow access on a browser macOS protects, such as Safari, opens Full Disk Access with a small Lilo panel beside it: turn Lilo on, or drag its icon into the list. Once access is granted, Lilo comes back and the browser is ready to import.

### Fixed

- Command bar results no longer show a site's initial through its favicon's transparent parts.
- Switching spaces no longer crops the start of the address while it fades in.
- Imported tabs, bookmarks and Arc spaces show their sites' icons right away, instead of an initial until each is opened.
- Importing no longer offers browsers that are not installed, whose folders password managers create for their helpers, and finds the icon of a Beta, Dev or Nightly browser or one installed outside LaunchServices.
- The Agents space no longer shows in Settings > Spaces, link rules, the external links setting or Move to Space, and no longer counts as a space of yours, so your last space cannot be deleted.
- Proton Pass's popup opens at its full size again, instead of a thin strip that changed width as you typed.
- Extensions that read your session on a site they work with, such as ChatGPT's side panel, see that you are signed in.
- Extensions whose package carries unusual file permissions, such as ClickUp and Linkclump Plus, install from the Chrome Web Store.
- Extensions with an empty description, icon list or page override in their manifest, such as BLACKBOX.AI, Genesys Cloud and Twitch Adblock, load without errors.
- Dark Mode - Night Eye saves its settings again.
- Extensions that look for new tab pages among your tabs, such as J2TEAM Security, find them.

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

[0.1.5]: https://github.com/Alexays/Lilo/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Alexays/Lilo/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Alexays/Lilo/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Alexays/Lilo/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Alexays/Lilo/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Alexays/Lilo/releases/tag/v0.1.0
