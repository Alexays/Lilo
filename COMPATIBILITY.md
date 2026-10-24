# Lilo Compatibility Tracker

Web APIs and browser features that are missing in Lilo (WKWebView-based) or differ from Chrome. What works as in Chrome only gets named, never described.

---

## Chrome extensions

### API differences

MV3 only, on WebKit's `WKWebExtension` runtime plus Lilo's Gap APIs ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#extension-architecture)). This section lists only what is missing or differs from Chrome; anything not listed behaves as in Chrome.

- **Supported as in Chrome:** `action` (badge colors included), `alarms`, `bookmarks`, `commands`, `contextMenus`, `cookies`, `history`, `idle`, `management`, `offscreen`, `omnibox`, `permissions`, `power`, `runtime` messaging, `scripting`, `search`, `sessions`, `storage` (`local`, `session`, `sync`), `system.cpu`, `system.display`, `system.memory`, `system.storage`, `topSites`, `chrome_url_overrides.newtab`.
- **Missing:** `webRequest` blocking (observe-only, so `webRequest.onActionIgnored` never fires and `handlerBehaviorChanged` has nothing to flush), MV2 extensions. `declarativeNetRequest.updateStaticRules` and `getDisabledRuleIds` work by rewriting the ruleset file, since WebKit cannot turn off one static rule.
- **Missing namespaces:** `accessibilityFeatures`, `readingList` (Lilo has no reading list), `ttsEngine`, `webAuthenticationProxy`.
- **Missing members:** `runtime.getPackageDirectoryEntry`. `ChromeSurfaceTests` checks this list, event methods and `browser.*` included, against Chrome's API schemas (`make chrome-surface` refreshes them).
- **Events that never fire:** `runtime.onConnectNative` (Lilo never starts a native host that connects first), `declarativeNetRequest.onRuleMatchedDebug` (WebKit does not say which rule matched a request), and `bookmarks.onChildrenReordered`, `onImportBegan` and `onImportEnded` (nothing in Lilo sorts or imports the bookmarks extensions see).
- **runtime:** messages to other extensions are not delivered: `chrome.runtime.connect` and `sendMessage` to another extension's id fail as in Chrome when that extension is not installed, even if it is (`browser.runtime` throws). A message posted before the port connects on a port `browser.runtime.connect` opened, between extension pages and the worker, arrives twice; on one `chrome.runtime.connect` opened, it arrives once. `onExtensionLoaded` reports `startup` after a Lilo update, never `browser_update`, and never `reload`. A web page an extension's `externally_connectable` names gets `chrome.runtime` with `sendMessage`, `connect` and `lastError` only (claude.ai hands the Claude extension its sign-in this way). An update waits for a running worker to stop, as in Chrome, but not for the extension's open pages.
- **Private spaces and profiles:** an extension runs in private spaces and sees their tabs only once allowed there (Chrome's incognito access); their downloads and closed tabs are never exposed. Each profile has its own extensions, cookies and storage; an extension whose profile is not the active one can only `downloads.search`, and `chrome.sessions` never lists another profile's tabs.
- **Background worker:** every extension is granted `nativeMessaging`, for the worker's channel to Lilo; native hosts still require it declared or granted on request. After a call or event of an API Lilo adds (bookmarks, notifications, idle...), an idle worker unloads 20 to 50 s later instead of 30 s. WebKit runs the pending promise callbacks while `importScripts` loads a script the worker had not loaded yet, where Chrome runs them once the worker's top-level code is done: an extension that marks the end of its startup with a promise callback and imports a script before its listeners takes the rest of its startup for late. Lilo skips the import of an empty script, which covers Tampermonkey. The worker's `WebSocket` is Lilo's (WebKit's freezes the worker): it sends no cookies, its `Origin` is the extension's, `bufferedAmount` stays 0, no extension is negotiated, and a socket closes when the worker that opened it stops. The worker is registered for its own directory, not the extension root, and extension pages are not its clients: `navigator.serviceWorker.ready` never resolves in a page outside that directory, `clients.matchAll()` finds no page and a page's `postMessage` to the worker is lost (MultiPassword's worker never starts its services). Storing a `CryptoKey` in IndexedDB from the worker never completes and stalls it: 2FAS Auth never finishes setting up, so its pairing page shows no QR code and its toolbar button does nothing (extension pages store keys as in Chrome).
- **Extension manifest:** `web_accessible_resources` entries naming `extension_ids` grant nothing. An `externally_connectable` match pattern naming a port matches every port of its host. An `externally_connectable` wildcard on a public suffix of the list's private section (Modjo's `*://*.netlify.app/*`) is dropped, so those sites cannot message the extension: WebKit refuses the pattern, where Chrome accepts it. `runtime.getManifest()` returns the manifest Lilo loads: `background.service_worker` names Lilo's wrapper; `host_permissions` and `optional_host_permissions` end in `/*` (Chrome ignores their path, so Okta's `https://*/` reaches every page); an empty `_execute_action` command, `content_security_policy` or `content_scripts`, those `web_accessible_resources` entries and an `externally_connectable` entry with no `matches` nor `ids` are left out; a missing or empty `description` reads `" "`; shortcut keys lose the whitespace around them; and `externally_connectable` reads `*://*/*` for `<all_urls>` and patterns without their port.
- **Tabs and windows:** `tabs.highlight` only activates the first tab: Lilo has no multi-tab selection, so `highlighted` is the active tab. `tabs.setZoom` changes the tab only, never its origin. Split views are Lilo's split folders: tabs carry no `splitViewId`, and splitting two tabs of a group takes them out of it. `windows.onBoundsChanged` fires up to half a second after a move or resize ends. `tabs.discard` requires a tab id and never discards the tab on screen; a discarded tab's `goBack`/`goForward` fail. An opener (`openerTabId`) is kept for the session only, and only tabs opened by extensions have one. `activeTab` is granted by a click on the extension's action or its own command, never by page clicks or keystrokes. `windows.create` with `type: "popup"` or `incognito` opens a floating panel showing the first URL only; with the "Prefer a single window" setting on, a normal `windows.create` opens its URLs as tabs of the current window and returns that window. A page popup (`window.open` asking for one) is a `popup` window holding one tab, but `windows.getAll` and `tabs.query` leave it out until it is opened as a tab. With the `tabs` permission, a tab's `url` and `title` show in what `tabs` and `windows` methods return, an empty tab reading as Chrome's `chrome://newtab/`, but tab events leave them empty for hosts the extension may not access; without it they are left out, as in Chrome.
- **debugger:** tabs only: no background page, worker or other target, so `getTargets` lists tabs as `page` targets whose `id` is Lilo's tab id. The Chrome DevTools Protocol is translated to WebKit's Web Inspector protocol for `Runtime` (`evaluate`, `callFunctionOn`, `awaitPromise`, `getProperties`, object release, console and exception events), `Page` (`navigate`, `reload`, `captureScreenshot`, `printToPDF`, `getLayoutMetrics`, frame and resource trees, new-document scripts, load and frame events), `Network` (events, `getResponseBody`, extra headers, cache, user agent, `getCookies`), `DOM` (document, queries, attributes, HTML, `resolveNode`, `requestNode`, `getBoxModel`, `getContentQuads`, `focus`, search, mutation events), `Input` (mouse, keys, `insertText`) and `Emulation` (user agent, media and media features, script execution, device scale factor); every other method fails with CDP's method-not-found error, as on an older Chrome (no `Fetch`, `Debugger`, `Target`, `Overlay`, `CSS`, `Log` or `Performance`). `captureScreenshot` encodes `webp` as PNG and ignores `clip.scale`; `printToPDF` returns the whole page on one PDF page and ignores its options; `setDeviceMetricsOverride` applies only `deviceScaleFactor`; network events have no `ExtraInfo` companions and report no encoded sizes for responses; `callFunctionOn` drops `unserializableValue` arguments; a node's `backendNodeId` is its `nodeId`. The agent's devtools tools and the Web Inspector share the tab's protocol connection, so emulation one of them sets applies to all.
- **Tab groups:** backed by Lilo tab folders; tabs are matched across windows by window position and index.
- **declarativeNetRequest:** `MAX_NUMBER_OF_DYNAMIC_RULES` and `MAX_NUMBER_OF_SESSION_RULES` are both 30000, one cap WebKit shares between them. `testMatchOutcome` (with `declarativeNetRequestFeedback`) re-evaluates the rules WebKit applies with Chrome's matching; rules conditioned on response headers never match there. WebKit compiles each rule into one regex without alternation, `\b`, back-references or `$` inside the pattern: a `regexFilter` is rewritten into that subset where it means the same (`\w`, `{n,m}`, alternation of single characters, `(X|$)` at the end, `(^|X)` at the start), and a rule whose filter cannot be, that redirects to a non-HTTP URL other than the extension's own pages (a `data:` URL), or that only modifies headers WebKit does not know (custom `X-` headers) is kept under its id, returned by `getDynamicRules` and `getSessionRules`, but never matches; `isRegexSupported` answers `syntaxError` for such a filter. A rule modifying both known and unknown headers modifies the known ones only. A `regexFilter` rule ignores its `requestDomains`. Static rulesets are rewritten so in their files when Lilo prepares the extension: one reading its own ruleset file finds each changed rule's original under `liloChromeRule`. WebKit expands a rule into one content blocker rule per request domain and holds 150000 per extension, so past 120000 for all its static rulesets together, the rules with the most request domains never match, largest first (the largest host lists of SBlock and Adblock Ad Blocker Pro). Turning every ruleset off right after an install waits until WebKit has compiled the extension's rules once (seconds for large rulesets).
- **runtime.getContexts:** popup windows from `windows.create` are reported as tabs, and `documentIds` filters match nothing.
- **Objects and errors:** `ChromeContractTests` replays calls recorded from Chrome (`make chrome-contracts`) and lists in `LiloTests/Extensions/chrome-contract-differences.txt` where Lilo answers differently: WebKit's `Tab` objects lack `autoDiscardable`, `discarded`, `frozen`, `groupId`, `lastAccessed` and `splitViewId`; alarms lack `persistAcrossSessions`; bookmark nodes lack `syncing`, `dateAdded` and `folderType` on folders; `management` info lacks `homepageUrl`, `isApp`, `mayDisable`, `optionsUrl` and `versionName`; `permissions` answers the names WebKit does not know (`tabGroups`, `offscreen`, `debugger`...) from the manifest and the grants Lilo keeps, and `request` asks no user gesture for them; `runtime.sendMessage` and `tabs.sendMessage` resolve instead of rejecting when no one receives the message; a `chrome` callback left without a response gets Chrome's `runtime.lastError`, worded from whether the worker listens for a page's message, and as a missing receiver for a worker's (where a listening page that does not respond gets Chrome's other wording) and for `tabs.sendMessage` (likewise for a content script that does not respond), and a `browser.runtime` or content script callback gets none; and most error messages are worded differently. `storage` keeps a `Date` as its ISO string, where Chrome stores `{}`. Through `browser` (WebKit's object, where Chrome's shares `chrome`'s namespaces), `runtime.lastError` is `null` without an error, a copy of a namespace (`{ ...browser.alarms }`) lacks its events, and a namespace cannot be replaced; an extension assigning `browser` (`var browser = chrome`, webextension-polyfill) keeps WebKit's, through which WebKit delivers the context's events.
- **cookies.onChanged:** fires once Lilo has read the changed cookie store; changes made while it reads (a page load's burst of cookies) are reported as their net result, except those of a context that listens, whose `cookies.set` and `remove` settle once their change is reported. It reports a `cause` of `explicit`, `overwrite` or `expired` only (never `evicted` or `expired_overwrite`); setting a cookie again with the same value and attributes fires nothing.
- **scripting and tabs:** `insertCSS` and `removeCSS` given `frameIds` (`frameId` for `tabs`) apply to the main frame only; `matchOriginAsFallback` is not supported. WebKit injects an extension's manifest content scripts into the pages already open when it is installed or enabled, as Safari does; Chrome waits for their next load, so an extension whose content script asks its worker about such a page may find nothing (Avira Browser Safety logs an error).
- **contextMenus:** `documentUrlPatterns` and `targetUrlPatterns` WebKit does not take (`ftp:`, `urn:`, `data:`, `about:`, `blob:`, `javascript:`, `mailto:`, `ws:` and `chrome:` schemes, explicit ports, and invalid patterns Chrome reports as `Invalid url pattern`) are dropped, so an item never shows for such a page or link; an item left with none shows nowhere. The callback of a `create` without a title (and of a `scripting.registerContentScripts` without match patterns) runs without `runtime.lastError`. An `update` moving an item under one of its ancestors other than its parent leaves it where it is.
- **storage:** extension pages and workers get answers in the order they make their calls, as in Chrome. A `get` may still miss a `set` not completed yet when another context made it, or in a content script, where Chrome answers calls in the order they arrive.
- **devtools.inspectedWindow:** `eval` ignores `contextSecurityOrigin` and `useContentScriptContext`; `reload` ignores `userAgent` and `injectedScript`.
- **webNavigation:** `onHistoryStateUpdated` and `onReferenceFragmentUpdated` fire for main frames only. Lilo cannot tell how a navigation started: `onCommitted` reports `transitionType` `link` for a main frame and `auto_subframe` for a subframe, and `onCommitted`, `onHistoryStateUpdated` and `onReferenceFragmentUpdated` report no `transitionQualifiers` but `forward_back` for a history traversal within a document. `onCreatedNavigationTarget` reports `sourceFrameId` 0, and nothing for a page popup window. `getAllFrames` and `getFrame` report a tab's initial empty document, with an empty URL, until its first navigation commits, and an empty URL for a frame the extension has no host permission for.
- **Side panel:** docked on the right of the content (`getLayout` always reports `right`). A panel a tab switch hides is released and reloads when its tab shows it again, where Chrome keeps the page. `open` accepts a call from a page with a user gesture, or one that follows within 5 seconds a click on the extension's action, its keyboard command or its context menu item (Chrome: only from that event's listener, before any `await`). `setOptions` for a tab id unknown to Lilo is ignored. `onClosed` for a panel whose tab or window closed reports no `tabId` and `windowId` -1.
- **action:** `getUserSettings` reports `isOnToolbar: true` for an extension pinned to the address bar; the pins are shared by every profile, and only the active profile's extensions hear `onUserSettingsChanged`. An import from Chrome pins the imported extensions Chrome had pinned, in its toolbar order, after the ones already pinned.
- **permissions:** a host access request names a tab (`documentId`s are unknown to Lilo) and shows as an Allow button in the extensions menu. As in Chrome, Lilo never asks the user for a site an extension reaches without access (WebKit would ask for the page's full URL): the call fails, and only `permissions.request` prompts. A namespace Lilo adds (`pageCapture`, `tabGroups`, `debugger`...) whose permission is only optional shows in a page or worker once it learns of the grant, from its own `permissions.request`, `contains` or `getAll` (a worker learns it once its top-level code has run). Granting or removing such a permission, or an optional `nativeMessaging`, fires no `permissions.onAdded` or `onRemoved`.
- **pageCapture:** the MHTML is written from WebKit's web archive of the page, so its parts are the resources WebKit kept, each URL once, without `Content-ID` headers.
- **instanceID:** Lilo has no push backend: `getToken` and `deleteToken` fail with Chrome's `Instance ID is currently disabled.` and `onTokenRefresh` never fires (`getID`, `getCreationTime` and `deleteID` work as in Chrome).
- **cookies.getPartitionKey:** main frames only: another `frameId` or a `documentId` fails.
- **omnibox:** a `deletable` suggestion is deleted with Command-Delete.
- **Downloads:** `blob:` URLs are rejected. Lilo marks no download dangerous, so `acceptDanger` always fails; `setUiOptions` hides the download button of the sidebar. Past 200 tracked downloads, completed ones and those interrupted over a day ago stop being tracked for `onChanged`: resuming such an interrupted download fires no `onChanged` for its first change.
- **Notifications:** remote `iconUrl`s are not shown (base64 `data:` URLs and the extension's own files are).
- **Identity:** `getProfileUserInfo` is always empty: Lilo has no browser Google account. `getAuthToken` runs Google's OAuth consent in a sign-in panel where the user signs in (Lilo has no browser Google account), then caches the token in the keychain; Google may refuse a client registered only for Chrome. `launchWebAuthFlow` also completes on a redirect to a loopback host.
- **publicSuffix:** the Public Suffix List is the one bundled with Lilo, refreshed with its releases. `getDomain` with `encoding: "display"` shows a label in Unicode when it uses a single script (or one of the Chinese, Japanese and Korean mixes with Latin) and is not made only of Cyrillic letters that read as Latin ones; Chrome's IDN spoof checker applies more rules, so a few labels it keeps as punycode show in Unicode here.
- **tts:** `lang` is checked for a language tag's shape only, and the `end` event's `charIndex` counts UTF-16 code units where Chrome counts UTF-8 bytes.
- **i18n.detectLanguage:** uses the system language recognizer (up to three languages, `isReliable` above 80%), so results can differ from Chrome's.
- **Extension-controlled settings** (`proxy`, `fontSettings`, `contentSettings`): when several extensions set the same one, the extension loaded last wins (Chrome: the one installed last).
- **browsingData:** WebKit keeps site data per site (registrable domain), so `origins` and `excludeOrigins` clear or spare a whole site, storage included, and then ignore `since`; a non-zero `since` also clears what extension pages stored in that period. `formData` clears WebKit's search field history. `settings` reports Chrome's default selection (Lilo keeps no clear-data choices).
- **contentSettings:** Lilo applies the rules of `camera`, `microphone`, `location`, `notifications` and `javascript`; the other types keep and report their rules, which pages do not follow. With no rule, `get` reports Lilo's own site permission, else Chrome's default. `incognito_session_only` rules apply to private spaces and last until cleared.
- **fontSettings:** pages follow the standard and fixed families of the default script (`Zyyy`) and the three sizes; other families and scripts are kept and reported only, and extension pages keep WebKit's fonts.
- **proxy:** applied to the profile's tabs and extensions once the extension has loaded, with one server for all traffic (`singleProxy`, else `proxyForHttps`, `proxyForHttp`, `fallbackProxy`); an `http` proxy gets `CONNECT` for plain http too. `pac_script`, `auto_detect` and `direct`, and `socks4` or `quic` servers, leave the system proxy settings in charge while `get` reports them. `bypassList` keeps host and domain entries (`<local>`, `<-loopback>` and IP ranges are dropped). Private spaces never use an extension's proxy: incognito scopes are kept and reported only. Proxy authentication challenges do not reach `webRequest.onAuthRequired`. `onProxyError` fires for a page that cannot connect while a proxy applies (`net::ERR_PROXY_CONNECTION_FAILED` or `net::ERR_TUNNEL_CONNECTION_FAILED`), never for PAC errors.
- **privacy:** a stub: settings report Chrome's defaults as `not_controllable`, `set`/`clear` have no effect and `onChange` never fires.
- **storage.managed:** always empty (read-only stub).
- **storage:** a `set` replacing a value with characters outside Latin-1, which WebKit miscounts against the quota, is applied as a removal then a set: `onChanged` fires for both.
- **gcm:** Lilo has no Google push backend: `register`, `unregister` and `send` fail with Chrome's `GCM is currently disabled.` and `onMessage`, `onMessagesDeleted` and `onSendError` never fire.
- **declarativeContent:** Lilo has no page actions and shows every action on every page: `onPageChanged` keeps its rules, until the worker or page that added them stops, but they never act (`ShowAction`, `SetIcon` and `RequestContentScript` included).
- **printerProvider:** the macOS print panel lists no extension printers, so its events never fire.
- **management:** Lilo runs no apps: `launchApp`, `createAppShortcut` and `setLaunchType` fail with Chrome's errors for a non-app, and `generateAppForLink` fails after Chrome's checks.
- **User scripts:** `runAt: "document_idle"` runs at document end; `includeGlobs`/`excludeGlobs` are checked by a guard around the code, and the `js` sources of one registration run as one script. A page learns the "Allow user scripts" switch on its next load (a worker restarts in place). User script messages carry `frameId`, and their sender's `tab`, for main frames only; a message nobody answers fails after 5 minutes. `userScripts.execute` rejects `documentIds`, and in a `MAIN` world whose page CSP refuses `eval` a promise result reports null. A world's `csp` is stored, not applied: WebKit has no content security policy for script worlds, and its isolated worlds are not bound by the page's own either.
- **tabCapture and desktopCapture:** streams are video only, from the tab-share ferry (at most 30 fps and 1920 pixels wide): WebKit exposes no per-tab or system audio tap, so a `getUserMedia` asking for audio alone with `chromeMediaSource` rejects with `NotSupportedError`, an audio request beside video gets the video track only, and `chooseDesktopMedia` always reports `canRequestAudioTrack: false`. Other `mandatory` and `optional` constraints are ignored. `desktopCapture` shows Lilo's tab picker when `tab` is a source (with a "screen or window" choice when those are too), else the system content-sharing picker; `cancelChooseDesktopMedia` cannot close the system picker once shown, and its pick is then dropped. `onStatusChanged` fires `pending` and `active` together when the stream starts, and `getCapturedTabs` lists only streams already started.
- **Extension frames:** a web page framed inside an extension page gets none of Lilo's additions.

### Tested store extensions

Measured on 2026-10-23 with `make ext-smoke TOP=30` (the 30 most used extensions of `top-extensions.json`, the password managers onboarding proposes, and the new tab pages in the list), against Chrome 156's recording (`make chrome-smoke`): each one installs from the store, its worker starts and its popup renders. The password managers also opened a local login form, signed out, to check their content scripts reach it. Errors Chrome reports too do not count. `ext-smoke` also checks, on a local sign-in page and signed out, that Dark Reader's theme applies and its shortcut turns it off for the site, that Grammarly, Quillbot, LastPass, Dashlane, Proton Pass, Keeper, DeepL and Immersive Translate mark the page, that DeepL and AdBlock add their context menu entries, that Adblock Plus blocks an ad request, that the toolbar buttons of WhatFont, SelectorGadget and Zygon Copilot act on the page and Claude's opens its side panel. `top-extensions.json` also lists extensions picked by hand outside the most used (`extra`), which `ext-smoke` runs every time. Nothing here was signed in, so signed-in features (autofill, translation, grammar suggestions) are not verified.

On 2026-10-24, past their popups and signed out: ColorZilla's eyedropper samples the page, Wappalyzer lists a local page's technologies, FireShot captures a whole page, Okta and 2FAS Auth leave a login form alone (as in Chrome), and Google Docs Offline and Application Launcher for Drive start their workers without errors. Lilo's own content blocker and Adblock Plus block side by side without breaking the page, a request either one blocks failing once; each keeps its own allowlist, so a site paused in Adblock Plus is still filtered by Lilo's blocker until it is allowed there too.

Of all 500 extensions of `top-extensions.json` (`make ext-smoke TOP=500`, on 2026-10-24), 478 run cleanly. `RealExtensionSmokeTests` lists 20 of the 22 others with their cause (`knownFailures`, `intermittent`): most fail in Chrome too, or lose a race Chrome runs too. Loom and Browsec VPN shipped a version Chrome's recording predates, so all their errors count until `make chrome-smoke` records them again.

| Extension | Status | Differs from Chrome |
| --- | --- | --- |
| Adobe Acrobat, McAfee WebAdvisor, Thunder download support, AdBlock, Chrome Remote Desktop, Grammarly, Adblock Plus, Google Translate, Microsoft Single Sign On, Cisco Webex, uBlock Origin Lite, 360 Internet Protection, Claude, NordVPN, VeePN, Honey, Malwarebytes Browser Guard, Adblock for Youtube, GoFullPage, Online Security, Teleparty, Authenticator, Foxit PDF Creator, Zotero Connector, 1clickVPN, Screencastify | works | nothing measured |
| Momentum, Bonjourr | works | nothing measured (new tab override) |
| NordPass, Dashlane | works | nothing measured: both mark or decorate the login form |
| Proton Pass | works | nothing measured: it injects its form UI into the login form |
| Bitwarden | works | nothing measured: signed out, it changes the login form in neither browser |
| KeePassXC-Browser | works | its desktop app, reached over native messaging, was not tested |
| 1Password | works with limits | a tab activated while its core starts (within about 150 ms) logs "WASM is not initialized": Chrome reports a loading new tab with no url, which 1Password skips, where Lilo reports its target, as WebKit's own access checks on that tab need it; the login form gets its menu on focus, as in Chrome |
| AdGuard AdBlocker | works with limits | its popup sometimes renders nothing: it can message its worker before the worker has set up the handler, a race Chrome runs too |
| Keeper, Okta Browser Plugin, ColorZilla, Wappalyzer, WhatFont, SelectorGadget, FireShot, Zygon Copilot, Dust, Google Docs Offline, Application Launcher for Drive | works | nothing measured |
| Modjo Everywhere | works with limits | its worker logs that Firebase Messaging is unsupported (Lilo has no push backend), so it gets no push notifications; `*.netlify.app` pages cannot message it |
| 2FAS Auth | does not work | its worker stalls storing its keys in IndexedDB (a WebKit gap), so pairing never starts |
| Endpoint Verification | does not work | it reads `chrome.enterprise.reportingPrivate`, a private API Chrome gives this Google extension only, to report the device to Google Workspace; Lilo cannot provide it, so access policies that require a verified device refuse Lilo |
| Tampermonkey | works | nothing measured: as in Chrome, its scripts need "Allow user scripts" |

### User agent and the Chrome Web Store

Lilo presents itself as Chrome where extensions expect it (`ChromeMasquerade`), and as Safari everywhere else:

- **Web pages** get WebKit's Safari user agent, with no Lilo token, so sites serve their Safari variant.
- **The Chrome Web Store** (`chromewebstore.google.com`) gets a Chrome user agent and `navigator.userAgentData`, and a `chrome.webstorePrivate` shim, so its install button works; Lilo relabels it "Add to Lilo" and hides the store's prompts to switch to Chrome. The packages and update checks Lilo downloads from `clients2.google.com` send the same Chrome user agent.
- **Extension code** (extension pages, the background worker and content scripts' isolated world) reads Chrome's `navigator.userAgent`, `appVersion`, `vendor` and `userAgentData`; the page around a content script keeps the Safari one.
- **What it means for you:** extensions install and update from the store as in Chrome, and sites never see a Chrome identity. The store and its terms are made for Chrome, and Google does not endorse Lilo: Google could change the store or its update service so that installs or updates from Lilo stop working.

### Password managers

- **Approach:** Lilo ships **no built-in password manager** by design: credential storage and autofill are left to extensions and the system. Onboarding offers to install one from the store. The managers tested are in [Tested store extensions](#tested-store-extensions); signed-in autofill is not verified.
- **Native messaging:** `chrome.runtime.connectNative` and `sendNativeMessage` follow Chrome's stdio protocol (`ExtensionNativeMessaging`) for extensions that declare `nativeMessaging` in `permissions`, or in `optional_permissions` once `permissions.request` got it granted. A host that restricts which browser may launch it still refuses Lilo (see [iCloud Passwords extension](#icloud-passwords-extension)).
- **Host manifests** (`<name>.json`, `type: stdio`, absolute `path`) are read from `NativeMessagingHosts` under `~/Library/Application Support/` + `Lilo`, `Google/Chrome`, `Google/Chrome Beta`, `Google/Chrome Dev`, `Google/Chrome Canary`, `Chromium`, `Microsoft Edge`, `BraveSoftware/Brave-Browser`, `Arc/User Data` and `Vivaldi`, then `/Library/Google/Chrome/NativeMessagingHosts`, `/Library/Application Support/Chromium/NativeMessagingHosts` and `/Library/Microsoft/Edge/NativeMessagingHosts`. Lilo's own folder comes first; the first manifest whose `allowed_origins` lists `chrome-extension://<id>/` wins. Firefox manifests are not read. The host gets that origin as `argv[1]`.
- **Failures:** a `chrome.runtime.connectNative` port to a host that is missing, refused or exits disconnects with Chrome's error as `runtime.lastError`. One opened through WebKit's `browser.runtime` disconnects without it, and only once it sends its first message (a port that never sends stays open).
- **Dashlane** logs `Unable to find "argon2.wasm" in the extension's resources` in its worker: Emscripten resolves the binary against the worker's own directory instead of using the bytes Dashlane fetches from `assets/argon2/`. It is not a WebKit gap, and Lilo does not revive a worker for it: only a background whose content failed to load is revived (`errorsWarrantBackgroundRevive`).
- **Packaged `.wasm`:** WebKit serves extension resources without the `application/wasm` type, which `WebAssembly.instantiateStreaming` and `compileStreaming` reject. For the extension's own responses, Lilo compiles from the bytes instead (`shared/wasm-mime.ts`), in pages and in the worker.

## Web APIs

### Web Serial API (`navigator.serial`)
- **Status:** Implemented (`Lilo/Engine/SerialBridge.swift`)
- **WebKit support:** None - Chrome/Edge only; Lilo polyfills it
- **How:** a page-world polyfill for secure top-level documents (`requestPort` with USB vendor and
  product filters, `getPorts`, `open` with baud rate, data bits, stop bits, parity and hardware flow
  control, `readable`/`writable` streams, `setSignals`, `getSignals`, `forget`) over a native bridge
  to the serial devices IOKit lists. `requestPort` shows a native picker; a port reaches only the
  origin the user picked it for, for the session. A reloaded or closed page releases its ports.
- **Limits:** no `connect` event when a device is plugged in (`disconnect` fires when it goes);
  cross-origin iframes get no `navigator.serial`; reads are not flow-controlled by the page.

### EyeDropper API (`window.EyeDropper`)

- **Status:** Implemented (`Lilo/Engine/EyeDropperBridge.swift`)
- **WebKit support:** None - Chrome/Edge only; Lilo polyfills it in secure contexts
- **How:** `open()` shows the system color sampler (the loupe of the macOS color panel) and resolves
  with `{ sRGBHex }`; Escape rejects with `AbortError`.

### File System Access API (`showOpenFilePicker`, `showSaveFilePicker`, `showDirectoryPicker`)

- **Status:** Not implemented, on purpose for now
- **WebKit support:** None - Chrome/Edge only (WebKit ships only the origin-private file system)
- **Impact:** apps feature-detect it and fall back to file inputs and downloads, which work. A partial
  polyfill would switch those apps onto a path with missing pieces (handles that do not survive
  IndexedDB, directory writes), which is worse than the fallback.

### Passkeys / WebAuthn

- **Status:** Basic `navigator.credentials.create()` / `.get({publicKey})` and security keys work
  out of the box - WKWebView drives WebAuthn through WebKit's own system passkey sheet, scoped to
  the live page origin. No app code, entitlement, or Team ID is required.
- **Not pursued:** A custom `ASAuthorizationPlatformPublicKeyCredentialProvider` integration would
  only duplicate WebKit. `com.apple.developer.associated-domains` (`webcredentials:`) governs the
  app's *own* domains and cannot scope arbitrary websites - it is not how a browser hosts WebAuthn.

### DRM - FairPlay (works) vs Widevine/PlayReady (impossible)

- **FairPlay Streaming (`com.apple.fps`, `1_0`, `2_0`, `3_0`): supported, no configuration needed.**
  Measured in a WKWebView configured like Lilo's tabs: `requestMediaKeySystemAccess` is granted for
  `cenc`, `sinf` and `skd` init data with H.264 and 10-bit HEVC, and `createMediaKeys` works. The
  legacy `window.WebKitMediaKeys` is also present. ClearKey is granted.
- **No persistent-license sessions:** offline downloads in streaming web apps are not available.
- **Widevine / PlayReady: rejected (`NotSupportedError`), and not fixable.** WebKit on Apple
  platforms implements EME only against FairPlay and exposes no API to register another CDM;
  `libwidevinecdm` plugs into Chromium's CDM host only. Getting Widevine would mean embedding a
  second engine for DRM origins, a deliberate non-goal.
- **Codecs (MSE and ManagedMediaSource):** H.264, HEVC Main/Main10, Dolby Vision, VP9 profiles 0
  and 2 (10-bit), AV1, Opus and Vorbis in WebM, AAC, E-AC-3. 4K HDR decoding is smooth.
- **User agent:** a plain Safari identity (no `Lilo` token), so services serve their Safari/FairPlay
  variant (see [User agent and the Chrome Web Store](#user-agent-and-the-chrome-web-store)).
- **Streaming services** (from their public support pages for Safari, not yet hand-tested in Lilo):
  - *Expected to work:* Netflix (4K unverified), Prime Video, Disney+, Max, Apple TV+, Spotify web
    player, Apple Music web, Crunchyroll, YouTube (4K HDR), YouTube Music, Twitch.
  - *Reduced quality:* Canal+ (720p reported in Safari), Tidal (no lossless, which needs Widevine).
  - *Unknown:* Deezer, YouTube purchased and rented movies.

### Picture-in-Picture - `<video>` PiP (works) vs Document PiP (deliberate non-goal)

- **Single-`<video>` Picture-in-Picture: supported.** WebKit's element PiP works
  (`video.webkitSetPresentationMode('picture-in-picture')` / `requestPictureInPicture()`), and Lilo
  auto-enters it when a tab with active media is backgrounded (`PiPController`). This pops *one* video
  out into the system PiP window (no page controls) - fine for YouTube/Netflix-style single-stream PiP.
- **Document Picture-in-Picture (`window.documentPictureInPicture`): not supported, by choice.**
  WebKit ships no implementation. A polyfill (a same-origin child window in a floating panel) is
  feasible, but its main user, Google Meet, gates that path on a Chromium identity
  (`navigator.userAgentData.brands` listing `"Chromium"`) and then relies on Chromium-only media
  APIs (`MediaStreamTrackGenerator`). Tested on a live call with a full Chrome identity, camera and
  microphone broke and the PiP window never opened. Lilo keeps the Safari identity, Meet falls back
  to single-`<video>` PiP, and the sidebar pip dock and floating tab panel keep a backgrounded call
  tab visible.

### Screen sharing - tab capture (Lilo frame ferry)

- **Tab sharing is supported via a Lilo shim.** WebKit's capture pipeline only enumerates screens
  and OS windows (tab capture is a Chromium-only `getDisplayMedia` surface), so Lilo intercepts
  `getDisplayMedia` in the page world: a chrome picker lists the open tabs, and picking one
  returns a real `MediaStream` built page-side from a canvas fed by a native frame ferry
  (`TabShareSessionController`: 30 fps snapshots of the shared tab's engine, H.264-encoded in
  hardware and decoded page-side with WebCodecs; identical frames are skipped, so static content
  costs almost nothing). A backgrounded
  shared tab stays attached under the active view at full content size (the inspector-retention
  pattern), so it keeps its desktop layout and keeps rendering; the sidebar capture indicator
  marks it as shared.
- **Caveats vs Chrome:** the ferried stream is video-only (no tab audio: WebKit exposes no
  per-page audio tap) and capped at 30 fps / 1920 pixels wide.
- **Picking "share a screen or window instead"** runs WebKit's own `getDisplayMedia` and its
  system picker (the pick itself is the consent; no Screen Recording permission), invoked by
  native with a fresh user gesture since the async tab picker has left the page's one.
- **Extensions** (`chrome.tabCapture`, `chrome.desktopCapture`) ride the same ferry (see
  tabCapture and desktopCapture under [API differences](#api-differences)). A desktop pick uses the
  system `SCContentSharingPicker` directly, and an `SCStream` feeds the ferry while the stream lives.
- **Note:** utilities that keep a transparent full-screen overlay window (LanguageTool for
  Desktop, some capture/window-manager tools) swallow the system window picker's hit-testing:
  the picker opens but no window can be selected, in every browser including Safari. Quit the
  overlay app while sharing.

---

## Known Limitations (WebKit/macOS level - no fix possible in Lilo)

### iCloud Passwords extension

- **Symptom:** The "iCloud Passwords" Chrome extension fails to connect to its native helper in Lilo.
- **Root cause:** The native-messaging host `com.apple.passwordmanager`
  (`/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app`)
  carries **parent launch constraints** in its code signature, independent of the manifest's
  `allowed_origins`. Its parent must either match a fixed list of known browsers' signing
  identifier and team identifier pairs, or hold the
  `com.apple.developer.web-browser.public-key-credential` entitlement. Lilo has neither, so the
  extension cannot reach its helper.
- **Fix:** Not possible in Lilo code: it needs that entitlement, requested from Apple ("macOS
  Browsers Passkeys" request).

### Passkey conditional mediation (autofill)

- **Symptom:** `navigator.credentials.get({ mediation: "conditional" })` /
  `PublicKeyCredential.isConditionalMediationAvailable()` (passkey suggestions in username fields)
  may report unavailable from a third-party WKWebView host.
- **Root cause:** WebKit's conditional-mediation support outside Safari. There is no app-side remedy;
  explicit (non-conditional) passkey flows still work.

### Apple Pay on the web

- **Symptom:** checkout pages offer no Apple Pay button; `window.ApplePaySession` and
  `window.PaymentRequest` are undefined in Lilo's pages (checked on macOS 27).
- **Root cause:** WebKit does not expose Apple Pay or the Payment Request API to a third-party
  WKWebView host on macOS. There is no app-side remedy; sites fall back to card entry.

### AirPods audio quality during WebRTC calls
- **Symptom:** AirPods switch to HFP (hands-free, 16kHz) mode during Google Meet/WebRTC calls, degrading audio quality
- **Root cause:** macOS Bluetooth stack switches to HFP when any app requests microphone access from AirPods; this happens at the OS level
- **Chrome comparison:** Chrome ships its own libwebrtc audio stack and manages audio devices differently, partially mitigating this
- **Fix:** Not possible at the WKWebView app layer; would require a custom WebRTC stack or macOS-level audio routing override (not exposed by Apple)
