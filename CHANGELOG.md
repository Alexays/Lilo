# Changelog

What changes in each Lilo release, for people using it. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.13.1] - 2026-10-30

### Changed

- The About window shows Lilo's tagline in your language, with links to the website and GitHub.

### Fixed

- In a Space with no tabs open, clicking New Tab or pressing Command-T brings the command bar back after you close it, and the New Tab row no longer shows a close button that does nothing.
- Files a site sends as a download, such as a Google Docs export to PDF, are downloaded instead of loading invisibly in the page.
- Command-Shift-V pastes without formatting, as in Chrome and as Google Docs suggests, alongside Option-Shift-Command-V.
- File pickers only offer the types a site accepts, such as images for a photo upload.
- A page that prints from a frame, like a receipt or a shipping label, prints that frame instead of the whole page.
- Escape stops a page that is loading, as in Chrome and Safari.
- Command-E searches for the selected text, as in Safari, and Find Next goes on from it.
- Retrying a download that cannot resume sends the site's cookies, so a download that needs you signed in can finish.

[0.13.1]: https://github.com/Alexays/Lilo/compare/v0.13.0...v0.13.1
## [0.13.0] - 2026-10-30

### Added

- Lilo's app icon dresses up for Halloween, Christmas, New Year, Valentine's Day, Lunar New Year, Easter, the summer solstice and its own birthday, in a version drawn for each icon. Turn it off in Settings > Appearance > Seasonal icon.

### Fixed

- With the address above the page, an extension's side panel fills the window's height beside the page instead of starting under the bar.
- In a split, the bar above the page takes the color of the pane you focus, matching its address field.
- A site an extension shows inside its pages keeps the cookies it sets, so it stays signed in instead of failing a moment later.
- On a site with a sticky header, such as X, the bar above the page takes the header's color instead of a dark one the site declares over a light page.
- A site an extension shows inside its pages gets its cookies on its live connections too, so answers it streams over a WebSocket arrive.
- A site an extension shows inside its side panel loads again instead of being stopped by a security check.
- A site an extension frames in its side panel, an offscreen document or a tab can run the workers its own security policy allows, so a chat assistant's side panel gets its answers again.

[0.13.0]: https://github.com/Alexays/Lilo/compare/v0.12.0...v0.13.0
## [0.12.0] - 2026-10-30

### Added

- With Lilo's developer tools unlocked, Safari's Develop menu lists each extension's background and side panel, so you can inspect them.

### Changed

- Lilo checks for updates every hour instead of once a day, so the card offering to restart into a new version shows up soon after a release.
- When a call page offers no microphone or camera control of its own, such as Google Meet, the call card says its button mutes in Lilo: the page's own button does not follow it.
- The edge between the page and an extension's side panel lights up in the Space's color when you point at it, as the sidebar's edge does.
- The bar above the page, or the tabs on top, takes the site's color, gradients and images included, and slides with the page as one card. The window keeps a border all around, the traffic lights stay in the same place in every layout, and with the sidebar on the left its toggle sits just before the back arrow.

### Fixed

- A call's picture-in-picture window docked in the sidebar, such as Google Meet's, keeps its shape and shows all its controls instead of being cropped.
- A site an extension shows inside its side panel or pages gets its own cookies, as in Chrome, so it no longer loads signed out.
- The recently archived tabs menu shows each site's favicon instead of a letter.
- A site an extension shows inside its popup or an offscreen document gets its own cookies too, so it no longer loads signed out.
- A site an extension shows in its side panel keeps the local storage it has in your tabs, instead of starting empty on every load.

[0.12.0]: https://github.com/Alexays/Lilo/compare/v0.11.1...v0.12.0
## [0.11.1] - 2026-10-30

### Changed

- Screen, window and tab shares stay sharp and move at up to 30 frames per second in Google Meet calls, instead of 5.
- The Agents space shows its mascot next to its name at the top of the sidebar, instead of a robot emoji.
- A private space an agent opens for its isolated tabs shows a ghost of its mascot instead of sunglasses.
- Sharing a screen or window in a call stays sharp on a Retina screen and smooth at 24 frames per second on every site, for far less CPU than before.
- The call card shows when you share your screen or a window, with a button to stop sharing.
- Background tabs stay loaded much longer: they are paused instead of unloaded when the window is hidden, each other space keeps its recently used tabs, tabs with unsaved form input are never unloaded, and the Balanced setting unloads tabs only when memory runs low.

### Fixed

- A Space made of grain shows its grain around the page too, not only on the sidebar.
- With scroll bars always shown, a category in the emoji picker scrolls to its own emoji instead of a section above it.
- A call keeps running at full speed when you leave its tab or Lilo, so a screen share or a big Google Meet call no longer slows down in the background.
- Pages an AI agent drives in the background run their timers at full speed, so what the agent measures there matches a page you are looking at.
- Google Meet no longer sees everyone speaking at full volume: its speaking indicators calm down and a call with several people uses less CPU.

[0.11.1]: https://github.com/Alexays/Lilo/compare/v0.11.0...v0.11.1
## [0.11.0] - 2026-10-29

### Added

- Each Space can be made of glass, with Liquid Glass tinted by its color, or of grain, its color under a fine film grain: pick it on the window preview under Appearance, in the Space editor or during setup.
- Picture in picture also opens when you switch to another app while a video plays, and closes when you come back to Lilo, as when you leave and return to its tab.

### Changed

- Capturing a selected area no longer adds anything to the page that a site could detect, and Escape cancels it wherever keyboard focus is.
- Closing find in page leaves the last match selected, as in Safari, instead of clearing the selection. Opening find with text selected in a text field or a frame now fills in that text too, and, outside private spaces, shares it with other apps' Find like Use Selection for Find.

### Fixed

- Restart on the update card installs the update and relaunches Lilo instead of spinning forever, and its close button hides the card again.
- A mouse's back and forward buttons, like those of a Logitech MX or M series mouse, now go back and forward in the tab's history.
- Middle-clicking a tab in the sidebar closes it, as in the tab bar.
- Cmd-Shift-clicking a link opens it in a new tab in front, Cmd-clicking or middle-clicking Back or Forward opens that page in a new tab, Option-clicking a link downloads it, and Cmd-Left and Cmd-Right go back and forward outside text fields, as in Safari and Chrome.
- A site that asks for a client certificate now works, Lilo shows the certificates from your keychain to choose from, as Safari does.
- The card a screenshot leaves at the bottom of the page takes clicks again, so its Edit, Save and close buttons work.
- The Agents Space's tooltip shows the agents' mascot instead of a robot.
- The return button of a video's picture in picture window brings its tab back when the tab is in another Space.
- A video in Picture in Picture stays open when paused, instead of closing after a few minutes in the background.
- The recently archived tabs menu is no longer clipped by the sidebar and stays within the window.
- Extension side panels and their resize handles are now visible instead of being hidden behind the window frame.

[0.11.0]: https://github.com/Alexays/Lilo/compare/v0.10.1...v0.11.0
## [0.10.1] - 2026-10-29

### Fixed

- Middle-clicking or Cmd-clicking something a site opens on its own, like X's trending list, now opens it in a background tab, as in Chrome.
- A page can open a window a few seconds after a click, as in Chrome, so buttons like Google Meet's chat with a guest open their window.

[0.10.1]: https://github.com/Alexays/Lilo/compare/v0.10.0...v0.10.1
## [0.10.0] - 2026-10-29

### Added

- After a long enough absence, Lilo opens on a clean window: no tab selected, pinned and bookmarked tabs back on their home page, and the tabs it archived meanwhile offered back with Undo. The new Open to an empty window setting does this on every launch.
- The tabs Lilo archived in the last day wait next to New Tab, or in the tab bar, ready to come back in one click.

### Fixed

- With the tabs at the top or bottom, the History page shows as the active tab with its own close button, as Settings does.
- Middle-clicking or Cmd-clicking a link that opens in a new tab now opens that tab in the background.
- A tab whose page hangs no longer keeps a process spinning once closed, nor for long in the background, and no longer blocks the next pages of the same site.
- The picture-in-picture back button brings Lilo to the front from another app, a call in Meet's companion mode floats when you switch apps, and Meet's picture-in-picture opens even when Meet is slow to answer.

[0.10.0]: https://github.com/Alexays/Lilo/compare/v0.9.0...v0.10.0
## [0.9.0] - 2026-10-29

### Added

- Use Lilo in German, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Japanese, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Italian, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Korean, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Traditional Chinese, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Polish, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Turkish, including menus, system prompts, Shortcuts, and emoji search.
- Use Lilo in Dutch, including menus, system prompts, Shortcuts, and emoji search.
- With the address in a toolbar over the page, tabs on the left or the top, View > Hide Toolbar (Option-Command-T) hides that toolbar on its own, and hiding the sidebar or the tab strip now leaves the toolbar in place.
- Google Meet opens its compact picture-in-picture view (speaker, mute, camera, hang up): in the sidebar while Lilo is in front, in a floating window over other apps, automatically when you leave the call tab. Other sites can open document picture-in-picture windows too.
- Browse your whole history in a History page (⌘Y), each day's visits grouped by site: filter by period, site or terminal, search, and delete what you pick.

### Changed

- Agents now wear Lilo's violet instead of coral: their cursor, the frame around the tab they control, the Agents space and their folders. The cursor is a rounded pointer trailed by a little round mascot that carries the agent's name, looks where it goes and blinks. Agents also go by readable names: the Claude app's agent mode is Claude, and gemini-cli-mcp-client reads Gemini CLI.
- The What's New sheet now fades out when you close it instead of disappearing at once.

### Fixed

- An agent's page sized smaller than the window keeps rounded corners inside its frame.
- With the address hidden, the sidebar header sits on the traffic lights' line, and the page buttons on the Space row no longer cut its name short.
- A call in Google Meet's companion mode now gets its call card and stays alive in a background tab.
- Fix a rare crash in a terminal that prints for a long time.
- Fix a crash when an extension signs in with a very long timeout.
- An asleep tab's favicon stays legible when the icon brings its own background, as LinkedIn's does.
- The command bar no longer matches a tab from letters scattered across its title and its address: each word you type has to match one of them.

[0.9.0]: https://github.com/Alexays/Lilo/compare/v0.8.0...v0.9.0
## [0.8.0] - 2026-10-28

### Added

- Calls can share sound with a window or the screen: "Share audio too" in the share picker sends what your Mac plays, without sending the call's own voices back to it.
- While a call shares a tab, its call card shows what is shared, shares the shown tab instead in one click without interrupting the call's stream, and stops the share. A shared tab also gets back to full frame rate as soon as it is scrolled or typed in.
- Hide the address bar from Settings > Appearance while keeping the command bar and permission requests available.
- The website's 0.7.0 release notes have English and French highlights, a short recording of Peek in Lilo on real pages, and the full list of changes one click away.
- After an update, a small What’s New sheet introduces the highlights and complete release notes. Reopen it anytime from the Help menu.
- Use Lilo in Ukrainian, including menus, system prompts, Shortcuts, and emoji search.

### Changed

- The tab share picker shows tab previews, suggests the tabs likely to be shared first, groups the others by Space, searches by title or address and works from the keyboard. The tab asking to share is no longer offered.
- A shared tab reaches the call one frame per change, at a steady 30 frames per second while it scrolls, instead of being sampled on its own clock.
- Calls always use WebKit's echo cancellation again, and the Full-quality mic with headphones setting is gone: without echo cancellation, WebKit made your voice quiet and choppy.

### Fixed

- Shared tabs are sent at full resolution on Retina screens, and shared screens and windows ask the call to keep their resolution over their frame rate, so shared text stays sharp.
- A tab shared from a Mac's built-in Retina screen reaches the call at 30 frames per second instead of 15, and costs a fraction of the CPU it did.
- The call preview docked in the sidebar fills its frame again, so its rounded corners are no longer cut at the top and bottom.
- An extension that puts its own browser object in place, as AiPrice does over webextension-polyfill, finds what it added there, as in Chrome, and gets its context menus back.
- An extension page's runtime.sendMessage no longer fails with "Tab not found" when its tab closes as it sends (Wappalyzer, Lightning Autofill), as Chrome runs nothing more of a closed page.
- On a Mac without a real GPU, such as a virtual machine, pages can read back what they draw on a canvas (getImageData no longer throws).
- Closing a tab no longer logs "Unchecked runtime.lastError ... Tab not found" for the content scripts that were messaging their extension (Immersive Translate, Adblock Ad Blocker Pro), as Chrome runs nothing more of a closed tab's page.
- Extensions see a running screen saver as a locked screen, as in Chrome, so a Dashlane business account's automatic logout after inactivity no longer logs you out while the screen saver runs.

[0.8.0]: https://github.com/Alexays/Lilo/compare/v0.7.0...v0.8.0
## [0.7.0] - 2026-10-28

### Added

- Extensions can find printers and devices on the local network (chrome.mdns, chrome.system.network), rename downloads as they start (downloads.onDeterminingFilename), and send cookies with XMLHttpRequest as in Chrome
- Try Peek, background tabs, Split View and Little windows from links in the website demo's local example pages.
- A call card in the sidebar mutes the microphone, turns the camera off and leaves the call of a Meet-like tab from anywhere, and ⇧⌘M mutes the call's microphone during a call.
- Record a performance session from Help > Diagnostics: Lilo saves a trace of its timings, hangs, dropped frames and per-process CPU, memory and energy to Downloads, ready to open in Perfetto or attach to a bug report.
- Settings > Privacy > Browsing Data shows how much history, cookies, cache and site data the profile stores, and clears them; History > Clear Browsing Data… (⇧⌘⌫) opens it.
- Use Lilo in Spanish, including the browser interface, native menus and dialogs, setup, Shortcuts and emoji search.
- Use Lilo in Simplified Chinese, including menus, dialogs, system prompts, Shortcuts and emoji search.
- Brazilian Portuguese across the browser interface, native menus and dialogs, system prompts, Shortcuts, and emoji search.
- Add Russian across the browser interface, native menus and dialogs, system prompts, Shortcuts, and emoji search.
- Settings > General > Search > Preload top hit starts loading a site you visit often while you type its address in a new tab, so Return shows it already loaded.
- A new setting, Keep calls in the sidebar, under Settings > Audio and video: turn it off to send a call you leave to the floating window instead of the sidebar.

### Changed

- Simplify the website example pages with Space initials and plain labels instead of decorative emoji and arrow marks.
- Polished the website demo with locally bundled profile artwork, Space icons and consistent preview controls.
- Error pages show the error code, and for a rejected certificate the reason macOS gives with the certificates involved.
- Refresh every website page with a shared layout, consistent installation controls, browser-language selection, and terminal and agent demos that replay while visible.
- Lilo's built-in page scripts do a little less work in every frame, and reader mode no longer leaves anything a page can detect.
- New windows open faster and use less memory: their sidebar and toolbar share one process.
- Audio and video has its own page in Settings: picture-in-picture and autoplay under Playback, the microphone and devices under Calls.
- Tab rows show playing sound and microphone, camera or screen capture as a badge on the favicon, click the sound badge to mute, and the close button no longer shifts the title. The call card can mute the call's sound, and the top and bottom tab strips open it from a microphone icon.
- The browsing data settings show their sizes and sites faster, no longer waiting on Screen Time.
- Extensions start faster at launch, no longer listing every installed font once each.
- With extensions installed, the sidebar appears about half a second sooner at launch, and the first page always loads with their blockers active.

### Fixed

- Extensions whose pages wait for their background worker, such as MultiPassword, no longer show an empty popup when another extension started before them
- An extension worker that answers a page on a port of its own, as Postman Interceptor does, now reaches that page when it is open in a tab
- Extensions that clear their own data with browsingData no longer erase every site's cookies and storage
- An extension update that asks for new access, such as debugger or proxy, waits for your approval before it installs
- Extensions behave more like in Chrome: proxy sign-ins prompt at once when no extension answers, sockets keep their messages while idle, downloads land in the subfolders they name, idle detection reports a locked screen, and Stylus, Language Learning with Netflix and other extensions no longer fail at startup
- Extensions that save encryption keys from their worker, such as 2FAS Auth, no longer freeze
- Keep the website demo self-contained with interactive local example pages and centered preview windows.
- Keep website demo link menus open after a right-click in WebKit, including repository folders.
- Keeper's popup opens instead of loading forever, and so do other extensions that connect to their own pages without naming themselves
- A tab moved out of an agent's folder fills the window again, instead of keeping the agent's page size and running past the window's edge.
- Extensions behave more like in Chrome: aborted requests stop, cookies go only to their path, url filters ignore case, and a website can no longer pass itself off as another one to an extension's worker
- Sidebar tooltips no longer hide under the docked picture in picture, and clicking Lilo in the Dock while the floating picture in picture shows on another app brings back the browser window.
- Ad blockers with very large static rule lists (Pie Adblock) can update their rules again: the rules past WebKit's limit leave the compiled set instead of failing every update.
- Control-D or exit in a terminal closes its tab instead of leaving it open on the ended shell
- Middle-clicking a link opens it in a new background tab instead of navigating the current tab.
- Ad blockers built on uBO Lite (Adblock Ad Blocker Pro and others) apply their rules again: a rule limited to some request methods no longer stops every other rule from loading, and their cosmetic filters turn on as in Chrome.
- Submitting a form inside an embedded frame no longer clears the unsaved-changes warning of a form still being edited on the page.
- A link opened in a background tab comes right after the current tab in Control-Tab, instead of last.
- Extensions that follow a page's frames through webRequest (Dashlane) reach the frames of a page again: a frame's requests name it and its parent as Chrome does.
- An extension's popup and other pages keep their connection to its background: Lilo relays these ports as Chrome does, so a popup no longer opens blank when WebKit dropped its port (Okta), and port messages are faster in bursts.
- The sidebar's tab list no longer shifts sideways when its scrollbar appears.
- With headphones on, calls get your full-quality microphone instead of the muffled, quieter voice WebKit's echo cancellation leaves. Settings > Audio and video turns it off.
- An extension page that sends its tab to a website, through a link or a redirect, now opens that website instead of staying blank (RSS Feed Reader's options).
- Extensions that message a page as soon as it loads (Requestly) now reach their content script, as in Chrome.
- Content scripts can ask an event whether it has listeners (hasListeners), as in Chrome (Brisk Teaching).
- Ad blockers that use session rules, like uBlock Origin Lite and AdGuard, no longer recompile all their filters at every launch, which took seconds of CPU.
- Extensions get Chrome's wording for a disconnected port and for a page they may not script ("Attempting to use a disconnected port object", "Cannot access contents of the page"), which they test before reconnecting or asking for access.
- Extensions get Chrome's wording for a missing tab or menu item ("No tab with id", "Receiving end does not exist"), which many test before retrying.
- A content script runs once on a page its extension's host permission and its own matches both cover (RoEarn, RoSeal, TubeBuddy threw "Can't create duplicate variable"), the manifest an extension reads no longer lists Lilo's own content script (Lightning Autofill's options), and a content script's runtime.sendMessage and connect work detached (AdScrubber).
- A content script file that several of an extension's manifest entries list runs once per page, as in Chrome (AdBlock's welcome page threw redeclaring its functions).
- An extension that checks runtime.lastError through browser, as AdBlock does for its context menus, no longer gets "Unchecked runtime.lastError" errors reported against it.
- action.setBadgeText takes no text, as in Chrome, where a tab's badge then shows the global text again (Jungle Scout).
- An extension page closing as it sends a message no longer reports "Tab not found" errors, as Chrome runs nothing more of a closed page (Immersive Translate, Wappalyzer, Table Capture).
- An extension with more static rules than WebKit applies keeps every rule of the rulesets its manifest turns on, which the rulesets it leaves off now give up first (AdGuard blocked no ads).
- A page or content script that goes away while it waits on Lilo no longer fails its calls with "Lilo is unreachable", as Chrome settles nothing more of a closed page (LastPass logged each call a closing tab cut).

[0.7.0]: https://github.com/Alexays/Lilo/compare/v0.6.0...v0.7.0
## [0.6.0] - 2026-10-27

### Added

- AI agents can wait for a text, an element or an enabled button to show on a page, and each click tells them what it landed on.
- Tabs and bookmarks of messaging sites like Slack, Gmail or Google Chat show their unread count, or a dot when a page sent a notification you have not seen yet.

### Fixed

- AI agents can attach files on sites that hide their file picker under a button, such as X.
- Quitting Lilo no longer signs you out of sites that save your sign-in as their page closes, such as Discord.
- Dragging a tab onto a folder in the top or bottom tab strip no longer makes the strip jump under the pointer.
- Text an agent types no longer reaches a page's keyboard shortcuts when no field has focus, and two conversations of the same agent app no longer share their tabs.
- Agents see the buttons and fields of apps like X when they list a page's controls, find text drawn by web components, learn when you allowed an action, and get clearer messages when a page reloads under them or keeps changing.
- Reordering folders in the top or bottom tab strip no longer leaves the drop spot stuck at the start of the row.
- In the top or bottom tab strip, terminal tabs show their terminal icon and tabs slide into place as you reorder them, as in the sidebar.
- Lilo no longer asks again to let an AI agent in after it is updated while the agent keeps running.
- Dragging in the top or bottom tab strip shows the sidebar's section colors, so you can see whether a tab lands in favorites, pinned or today.
- Sites that take a wide sidebar for open developer tools, such as Discord, no longer hide your sign-in while the sidebar is shown.
- A tab Lilo unloads in the background keeps what its page saves as it closes, such as your Discord sign-in.
- Video calls stay smooth after a page stops responding for a moment.
- A video call keeps running when the lid closes while Lilo holds the Mac awake.

[0.6.0]: https://github.com/Alexays/Lilo/compare/v0.5.0...v0.6.0
## [0.5.0] - 2026-10-27

### Added

- AI agents can insert long or multi-line text in one go, and a long agent call keeps sending progress, so the agent's app does not give up on it.

### Fixed

- AI agents now type text exactly as written, without your Mac's smart quotes or dashes, and Lilo asks you before an agent posts or replies on a site. A click from an agent also waits for the request it starts, so a post or payment is not cut off when the agent moves on.
- Text an agent types with line breaks no longer lands out of order in editors such as X's, an agent's tab shown at a size the agent set no longer lets its other pages show around it, and an agent restarted through Claude Desktop keeps its tabs.
- Full-page screenshots of sites that keep an invisible frame the size of the window, such as LinkedIn, now capture the whole page.

[0.5.0]: https://github.com/Alexays/Lilo/compare/v0.4.1...v0.5.0
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
