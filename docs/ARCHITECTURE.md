# Architecture

A technical deep-dive into Lilo's internals: where code lives, how the interface talks to Swift, and how Chrome extensions run on WebKit. Setup, commands and the pull request flow are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Where things live

| Path | Holds |
|------|-------|
| `Lilo/Agent/` | AI agent control. `AgentControl` serves MCP on a user-only Unix socket (`lilo-mcp` in `LiloMCP/` pipes an agent's stdio to it) and keeps one tab folder per client in the Agents Space; tabs of a space no window shows render in an off-screen window. Tools drive those tabs with real input, page scripts in an isolated content world, and console and network capture; devtools tools (protocol commands, network mocks, cookies, emulation, profiling) use the tab's Web Inspector without a window (`AgentInspector`). Every tool reaches a tab through `AgentControl.agentTab`, which refuses private browsing outside the agent's own isolated space; consequential clicks, Enter and cookie-carrying requests wait for the user in the consent drawer (`approveConsequentialAction`); `run` executes its program in a throwaway web view whose `tool()` calls come back to `AgentTools.call` |
| `Lilo/App/` | AppDelegate, the main menu and its SF Symbol icons, BrowserContext (app-wide services), keyboard shortcuts and their presets, App Intents (Shortcuts actions, Focus filter), startup metrics, logging, localization, theme and app icon preferences, default-browser and device setup |
| `Lilo/Bridge/` | JS/Swift bridge: router plus the handlers of cross-cutting UI domains (tabs, spaces, settings, profiles, omnibox, search, feature flags, state sync), and the `lilo-chrome://` scheme handler serving the chrome UI |
| `Lilo/Changes/` | Changes tabs: a repository's changed files and their git diff |
| `Lilo/ContentBlocker/` | Filter list download and conversion to WebKit content rules, the cosmetic and scriptlet runtimes, the bundled fallback block list, and the stand-ins served for `$redirect` filters |
| `Lilo/Diagnostics/` | Process Manager snapshots and its bridge handler, lifecycle diagnostics, the hitbox debug overlay |
| `Lilo/Downloads/` | Download manager, backends, dock progress, the downloads bridge handler |
| `Lilo/Engine/` | WKWebView tab implementation, engine factory, data stores, the web API bridges (notifications, geolocation, Web Serial, EyeDropper), find in page, PiP, page translation, the Chrome Web Store masquerade, private WebKit accessors |
| `Lilo/Extensions/` | The generated extension bridge bundles (`Chrome*.js`), the bundled Public Suffix List, and the window's extension behavior (`MainWindowController+Extensions.swift`) |
| `Lilo/Extensions/bridge-src/` | TypeScript source of the generated extension bridge bundles, and its tests |
| `Lilo/Extensions/Core/` | Extension lifecycle: per-profile registry, controller delegate, tab/window adapters, manifest parsing, service-worker preparation, Chrome Web Store installer, native messaging, update checks |
| `Lilo/Extensions/GapAPI/` | Gap API Swift handlers (bookmarks, history, downloads, notifications, sidePanel, tabGroups, sessions, topSites, etc.) |
| `Lilo/Favicons/` | FaviconService (cache, extraction) and FaviconCoordinator (request coalescing) |
| `Lilo/Generated/` | Generated Swift: the tab bridge schema (committed), native strings and embedded chrome UI assets (git-ignored, written by `make ui-build`) |
| `Lilo/Import/` | Importing from other browsers (Safari, Firefox and Zen, Chromium browsers): bookmarks, open tabs and Spaces (Chromium session files, Arc's sidebar), history, cookies (Chromium cookie decryption) and extensions, and its bridge handler |
| `Lilo/LittleWindow/` | Little windows: one page in a small window outside every Space, and the global hot key that opens one |
| `Lilo/Onboarding/` | The first-run onboarding bridge handler |
| `Lilo/PictureInPicture/` | An in-call tab kept in view: docked at the bottom of the sidebar, or floated in an always-on-top panel |
| `Lilo/Power/` | Keep-awake and lid-closed power management, the privileged helper's protocol and its bridge handler |
| `Lilo/Profiles/` | Profile model and manager, cached per-profile context (stores and extension registry) |
| `Lilo/Reader/` | Reader mode: the vendored Readability.js and the reader view it renders into |
| `Lilo/Resources/` | App icons, the AppleScript dictionary (`Lilo.sdef`), localized system prompts and Shortcuts (`*.lproj`), zsh and Bash shell integration for terminal tabs |
| `Lilo/Screenshots/` | Page capture and its hand-off to the capture card and the editor (both in `lilo-ui/src/components/screenshot/`), the screenshot bridge handler and image codec |
| `Lilo/Sessions/` | A window's session restore, and its tab create, close and reopen |
| `Lilo/Spaces/` | Space model and manager, and a window's space create, delete, move and switch |
| `Lilo/State/` | BrowserStateStore (in-memory source of truth), browser commands and changes, the sidebar diff sent to the interface |
| `Lilo/Storage/` | GRDB database, migrations, the history, bookmark, session, settings, site permission, window and zoom stores, the Spotlight bookmark index, persistence coordinator |
| `Lilo/Tabs/` | SpaceTab state model, TabManager, EngineHost, folders (nested up to five levels, lockable), split layouts, the archive of idle tabs, the recent tabs switcher (`Ctrl+Tab`), tab lifecycle policies |
| `Lilo/TabShare/` | Tab sharing: screen capture stream, H.264 encoder, session controller, the `lilo-capture://` frame scheme and the bridge handler |
| `Lilo/Terminal/` | Terminal tabs: libghostty-vt session, Metal renderer, glyph atlas, input handling |
| `Lilo/Window/` | MainWindowController and its extensions, WindowRegistry, chrome event routing, traffic lights, overlay web view, page popups, the extension side panel, AppleScript support |
| `lilo-ui/src/components/` | Svelte components, grouped by area (`sidebar/`, `spaces/`, `urlbar/`, `commandbar/`, `settings/`, `extensions/`, `downloads/`, `screenshot/`, `diagnostics/`, `banners/`, `page/` for what overlays the page, `onboarding/`, and `ui/` for shared controls), each `*Model.ts` beside the component it serves; `DeferredChrome.svelte` is the lazily loaded chunk of everything the first paint does not need |
| `lilo-ui/src/stores/` | UI state (`*.svelte.ts` stores) |
| `lilo-ui/src/lib/` | Shared pure logic, the bridge client and its generated protocol, i18n catalogs |
| `lilo-ui/src/styles/` | Global CSS and the design tokens |
| `lilo-ui/e2e/` | Playwright end-to-end tests |
| `lilo-ui/preview/` | `make ui-preview`: the interface in a browser against the e2e fake host, never embedded in the app |
| `LiloTests/` | Swift unit tests, mirroring `Lilo/` and `LiloMCP/` (`Support/` holds shared helpers) |
| `LiloMCP/` | `lilo-mcp`, the MCP server local agents launch to reach the running Lilo |
| `LiloPowerHelper/` | The privileged helper that keeps the Mac awake with the lid closed |
| `bench/` | The browser MCP benchmark harness ([bench/mcp/README.md](../bench/mcp/README.md)) |
| `bridge-schema/` | The tab bridge schema `make bridge-gen` generates the TypeScript and Swift protocol from |
| `scripts/` | Build, release, benchmark and extension smoke scripts the Makefile runs |
| `test-extensions/` | Extensions loaded by tests and by hand: the MV3 probe and the Chrome contract cases |
| `site/` | The getlilo.app landing page ([site/README.md](../site/README.md)) |
| `.changie.yaml`, `.changes/` | Release-note configuration, pending fragments and prepared release history; release files track the app version |
| `Xcode/Configs/` | Build settings, including the app and build versions synced by `make release-version` (see [RELEASING.md](RELEASING.md#version-bump)) |
| `Vendor/` | Not committed: `GhosttyVt.xcframework`, downloaded by `make vt-build` (or built by `make vt-build-source`) |

### Placement rule

- A feature with its own model, bridge handler or window behavior gets `Lilo/<Feature>/`, holding all of it: its `MainWindowController+<Feature>.swift` and its `*BridgeHandler.swift` included.
- `Lilo/Window/` is window mechanics only: the window controller, event routing, overlay, traffic lights, panels.
- `Lilo/Bridge/` is the bridge's routing and the handlers that cut across features.
- `Lilo/Engine/` is WebKit glue: the tab's web view, the engine factory, data stores, private API accessors.
- Tests mirror source paths: the tests of `Lilo/<Folder>/X.swift` go in `LiloTests/<Folder>/`.
- In `lilo-ui/src/`, UI components go in `components/<area>/` with their `*Model.ts` beside them, state in `stores/`, shared pure logic in `lib/`.

`project.yml` lists `Lilo/` as one source folder, so a new folder needs no project change: `make project-sync` picks it up.

### Glossary

User-facing docs and the interface capitalize these names as below; code identifiers follow their own casing (`SpaceTab`, `littleWindow`).

| Term | Meaning |
|------|---------|
| **Space** | A set of tabs in the sidebar with its own name, emoji and color, signed in as one profile (`Space`, `SpaceManager`). Plural "Spaces". |
| **Private Space** | A Space whose browsing is forgotten when it closes. Agents never see one. |
| **Agents Space** | The Space where AI agents open their tabs, one folder per client. |
| **profile** | A set of website data, history, bookmarks and extensions (`Profile`, `ProfileContext`). Several Spaces can share one. |
| **pinned tab**, **favorite** | Tabs kept across launches: pinned tabs sit at the top of a Space's list, favorites in the tiles above it. |
| **folder** | A group of tabs in the sidebar, nested up to five levels, optionally locked. Extensions see folders as tab groups. |
| **archive** | Where unpinned tabs go once a Space's idle delay passes. |
| **Peek** | A page opened over the current one, from a pinned tab's link to another site or a `Shift`-click. |
| **Little window** | A small window outside every Space for one link or search (`LittleWindowController`). |
| **link rules** | Rules that send a link opened from another app to a Space or a Little window. |
| **split view** | Up to four tabs side by side (`SplitLayout`). |
| **command bar** | The `Cmd+T` field over the page that searches tabs, history, bookmarks, Spaces and actions. |
| **capture card** | The card a screenshot floats as over the page, with edit, save and dismiss. |
| **terminal tab**, **Changes view** | A libghostty-vt terminal in a tab, and the view of a repository's diff. |
| **chrome** (lowercase) | The browser UI layer, the Svelte overlay drawn above the pages (`ChromeEventRouter`, `lilo-chrome://`). |
| **Chrome** (capitalized) | Google Chrome, the browser whose extension APIs Lilo matches. |
| **Gap API** | A Chrome extension API WebKit lacks that Lilo implements itself (see [Gap API layer](#gap-api-layer)). |

## Overlay HUD design

```text
┌──────────────────────────────────────────────────┐
│ NSWindow (transparent titlebar)                  │
│                                                  │
│  z:0  Content WKWebView                          │
│       Renders web pages                          │
│       Offset left by sidebar width (0 if hidden) │
│                                                  │
│  z:1  Chrome WKWebView (full window, overlay)    │
│       Svelte 5 UI - transparent background       │
│       ┌──────────┐                               │
│       │ Sidebar  │  opaque (tabs, spaces, etc.)  │
│       └──────────┘                               │
│       rest of overlay = transparent              │
│       mouse clicks pass through to content view  │
└──────────────────────────────────────────────────┘
```

**ChromeEventRouter** (`Lilo/Window/`) routes mouse and keyboard events to the correct layer. The Svelte UI registers the zones it owns (sidebar, toolbar, popups) in `ChromeInteractiveZoneStore` (`ChromeInteractionRouting.swift`), `ChromeHitClassifier` maps a window point to chrome or content against those zones, and everything else passes through to the content web view.

The chrome web view loads its bundle from `lilo-chrome://ui/index.html`, an app-private custom scheme served by `ChromeUISchemeHandler` (`Lilo/Bridge/`). The assets are compiled into the binary: `make ui-build` turns the Vite output into `Lilo/Generated/ChromeUIAssets.swift`.

## Windows and shared state

`BrowserContext` (`Lilo/App/`) owns everything that exists once per app: the databases, settings, profiles and spaces, the engine factory, downloads, the content blocker, terminal sessions and `BrowserStateStore`. Per-profile data (history, bookmarks, zoom, favicons, session persistence, extension registry) lives in a `ProfileContext`, built on demand and cached: profiles a window shows stay loaded, plus the most recently left one.

Each `MainWindowController` is one window: its overlay and bridge, its own selection (space and active tab) and its content area. Spaces are shared by every window:

- **Shared runtime.** A space shown in several windows has one live `EngineHost`, owned by the store's live-host registry and counted per window; the last window to leave a space parks its runtime into the store.
- **One window per web view.** `WindowRegistry` records which window shows each tab. Showing a tab in another window takes its view; the window that lost it keeps its selection and shows a placeholder offering to take it back. Displayed tabs are never frozen or discarded.
- **Relayed state.** A state mutation in one window reaches every window showing the changed space, each with its own active tab. Space and profile changes reach every window through `BrowserContext`, the single `SpaceManager` and `ProfileManager` delegate.
- **Routing.** App-wide events (extension tab control and permissions, download gap events, factory permission handlers, terminal callbacks) are installed once and resolve the window that shows the tab or page, else the active window.
- **Persistence.** The global `windows` table keeps each window's frame and space; the first window opens before the database from its cached frame, the others reopen behind it.

## Bridge message flow

```text
Svelte UI (JS)                          Swift
──────────────                          ─────
postMessage(action, payload)
    │
    ▼
webkit.messageHandlers
  .lilo.postMessage(msg)
    │
    ▼
BridgeRouter.userContentController()   ◄── WKScriptMessageHandler
    │
    ▼
BridgeHandler.handle(message:webView:) ◄── TabBridgeHandler,
    │                                      ChromeBridgeHandler,
    ▼                                      SettingsBridgeHandler, etc.
bridgeRouter.send(event, data)
    │
    ▼
callAsyncJavaScript(...)               ──► window.__lilo.receive(message)
```

`BridgeRouter` accepts messages only from the chrome web view's main frame loaded over `lilo-chrome://` (debug builds also accept the Vite dev server); see `isTrustedChromeMessage`. In the other direction, frequent events such as per-tab state patches and download progress are coalesced for 16 ms, then delivered together through `window.__lilo.receiveBatch`. At most one chrome call is in flight: what is sent meanwhile waits and ships as one batch when WebKit completes it, so a starved or suspended chrome process never queues stale payloads (a chrome reload forgets the call it will never complete). The tab bridge's message types are generated from `bridge-schema/tab.json` by `make bridge-gen`, into `lilo-ui/src/lib/bridge/tabProtocol.gen.ts` and `Lilo/Generated/TabBridgeSchema.gen.swift`.

## Extension architecture

Lilo uses **WKWebExtension** - Apple's native Chrome extension API for WebKit - combined with a thin custom layer for APIs WebKit doesn't implement natively.

### ProfileExtensionRegistry

Each browser profile owns a `ProfileExtensionRegistry`, which manages a `WKWebExtensionController` scoped to that profile. It is the facade the rest of the app uses: it loads, enables, disables, unloads and restores extensions (each load prepares the files, creates and grants the context, and records the extension in `ExtensionStorage`), keeps what each loaded context shows (action colors, icons, diagnostics, the extensions panel payloads), maps WebKit's windows and tabs to Lilo's, and forwards window events to the controller. The rest lives in modules it owns, each with its own state:

| Module | Owns |
|--------|------|
| `ExtensionLifecycle` | Each extension's lifecycle state and the `runtime` events Chrome sends on each transition; whether an event wakes a worker; the workers' reported listeners and the version an update applied while disabled replaced, kept across launches |
| `BackgroundSupervisor` (`registry.backgrounds`) | Worker loads, timeouts, revives and restarts with backoff, and the health the panel shows |
| `GapEvents` (`registry.gapEvents`) | The channel to each worker and page, the listeners they report, and the events waiting for a worker |
| `ExtensionUpdater` | Periodic and `runtime.requestUpdateCheck` checks, then the download, review and swap of a newer version |
| `ExtensionAccess` | Grants applied at load, the user's site and private access, command shortcuts and declined updates, optional permissions obtained at runtime, and `permissions.addHostAccessRequest`s |
| `ExtensionUserScripts` | `chrome.userScripts` registrations and the `WKUserScript`s they install in the profile's tabs |
| `ExtensionStorage`, `ExtensionFiles` | The installed records and access states (database), and the installed copies on disk |

### Extension lifecycle state machine

`ExtensionLifecycle` is the one place that decides what Chrome tells an extension about its own lifecycle. Lilo sends `runtime.onInstalled` and `runtime.onStartup` itself, never WebKit: WebKit picks them by how soon after its controller a context loads and sometimes drops an update, so the bridge's stand-ins (`runtime.ts`) divert the listeners of WebKit's events to Lilo's. An extension without a state is not loaded (not installed, failed to load, or torn down); otherwise it is:

- `disabled(updatedFrom:)`: installed, not loaded. `updatedFrom` is the version an update applied while disabled replaced.
- `loaded(worker)`: in WebKit, its worker `stopped`, `running` (channel open) or `idle` (it let its channel go, and WebKit unloads it at its next idle check).
- `updating(from:to:)`: loaded with a running worker that heard of a newer version; the update applies once the worker stops, as Chrome delays the update of an extension in use.

| Transition | Events (each once) |
|------------|--------------------|
| load `install` | `onInstalled {install}` (worker only, no wake: WebKit starts a new worker itself), `onExtensionLoaded {install}` (no wake) |
| load `enable` | `onInstalled {update, previousVersion}` if the version changed since the stored record or an update applied while disabled, `onEnabled`, `onExtensionLoaded {enable}` |
| load `update(from:)` | `onInstalled {update, previousVersion}`, `onExtensionLoaded {update, previousVersion}` (no wake) |
| load `startup` (launch restore) | `onStartup`; `onExtensionLoaded {startup}` only to a worker whose listeners are known from an earlier launch |
| load `reload` (after an internal unload) | `onInstalled {update}` only if the version changed |
| newer version found, worker running | `onUpdateAvailable` once per version, then `updating` |
| worker channel `open` / `idle` / `lost` | none; `loaded(running / idle / stopped)`. Leaving `running` while `updating` applies the update; only `lost` makes the supervisor restart the worker |
| unload (disable, reload, update swap, teardown) | none; the worker's channel is detached at once (`GapEvents.forget`), a disable or an uninstall drops what the worker had not received, and a disable lets a waiting update apply |

An event wakes only a loaded extension whose worker is not running, and only if the worker listens to it (until a worker of the installed version has reported its listeners, every event reaches it).

`ExtensionControllerDelegate` is the `WKWebExtensionController` delegate - it receives action updates, permission requests, popup presentation requests, and native messaging from WebKit and forwards them to the appropriate handlers.

`TabExtensionAdapter` and `WindowExtensionAdapter` wrap the app's tab and window models into the types WebKit expects (`WKWebExtensionTab`, `WKWebExtensionWindow`).

**Each space is its own window to extensions.** The registry keeps one `WindowExtensionAdapter` per space a browser window of its profile has shown since launch, in opening order. A position the bridge sends is an index in the extension's `windows.getAll()`, which follows WebKit's order for that context, the window opened or focused last first (`extensionWindows(for:)`, from `openWindows`; private spaces, which WebKit hides from extensions without private access, left out for those). A space shown in two browser windows is one window; floating panels and page popups keep their own adapters. So `windows.create` opens a floating panel for every type: a browser window would show a space, and its id would name the user's window, which an extension removing "its" window would close. With "Prefer a single window" on, a normal one opens its tabs in the current space and returns its window, which records those tabs (`tabIdsOpenedAsWindow`): `windows.remove` closes them only, never the browser window. Spaces map to Chrome's window events:

- **Show a space for the first time:** `windows.onCreated`, then `tabs.onCreated` for its tabs (`bindExtensionRegistry` binds the window before the space's runtime restores).
- **Switch spaces:** a window focus change (`didFocusWindow`, `windows.onFocusChanged`). Window ids stay stable and the space left keeps its tabs, its active tab and their indexes, so `tabs.query({})` lists them; `currentWindow` and `lastFocusedWindow` resolve to the space shown. Showing a space again activates no tab: its active tab never changed.
- **Move a tab to another space:** it keeps its id and moves to that space's window (`didMoveTab` from the source window, `tabs.onDetached` and `onAttached`) when the target shares the profile and privacy and is already a window; otherwise it closes and opens again once the target is shown.
- **Delete a space, or move it to another profile:** `windows.onRemoved`. A closing browser window hands the spaces it showed last to another browser window; they close with the last one.

A background space reports the frame of the browser window that showed it last and the `normal` state, as a Chrome window behind the focused one; focusing it shows it in that browser window, and it cannot be closed. Nothing runs per space at idle: an adapter is a list of tab adapters, its order rebuilt from the space's tree only when its shape, its tabs or its active tab change.

### Native WKWebExtension APIs

WebKit provides native support for:
- Background service workers
- Content script injection with `WKContentWorld` isolation
- Message passing (`chrome.runtime.sendMessage`, `chrome.tabs.sendMessage`)
- `declarativeNetRequest` rules and `webRequest` events
- Manifest-declared permissions
- Action popups

### Gap API layer

For Chrome APIs not natively supported by WebKit, Lilo implements a **Gap API** layer injected into extension page and background contexts.

**JavaScript side** (`Lilo/Extensions/bridge-src/`): TypeScript source that esbuild compiles into five bundles: `ChromeAPIAugmentation.js` (extension pages and popups), `ChromeAPIBackgroundPrelude.js` (service workers), `ChromeContentCompat.js` (content scripts, whose isolated world the page augmentation never reaches), `ChromeWebStoreShim.js` (the Chrome Web Store page), and `ChromeStaticRules.js`, which `ExtensionBackgroundPreparer` runs in JavaScriptCore to rewrite static declarativeNetRequest rulesets as the dynamic rules are. Pages and workers reach Swift the same way: one native port to Lilo (`app.lilo.channel`, answered by `ExtensionControllerDelegate` itself) that carries their calls and the events Lilo pushes. A page opens it on its first gap call or listener; a worker opens it when it starts and lets it go when idle (see Background states).

**Chrome compatibility of WebKit's namespaces** (`src/shared/chrome-compat.ts`): `installGapAPIs` adds the namespaces WebKit lacks; what Lilo changes on the namespaces WebKit provides is one declarative `NamespaceCompat` per namespace: members to `add` where WebKit has none, members that `replace` WebKit's (the bridged badge colors, `tabs.group`), prototype methods to `patch` once (each wraps WebKit's original: permissions, contextMenus, the alarms, action, scripting and i18n arguments WebKit rejects or mishandles, `executeScript` waiting for a loading document as Chrome does, declarativeNetRequest rules and updates, tab group ids, the tab urls and titles WebKit withholds as empty strings, webNavigation frame lookups), the WebKit own properties a view must `serve` instead (`runtime.connectNative` for native messaging, and `runtime.lastError`, which is the error of the Lilo callback running: `callbackify.ts` sets it around the callback and logs Chrome's `Unchecked runtime.lastError` when the callback does not read it), and the WebKit events whose listeners Lilo's events take (`standIns`: `runtime.onInstalled` and `onStartup`, `cookies.onChanged`, and through a wrapper per listener that adds what WebKit leaves out or drops what it withholds, `webNavigation.onCommitted` and `tabs.onCreated` and `onUpdated`), and the description of the namespace's own objects as `members` (the `storage` areas, `storage-area.ts`: while an area has writes in flight, its calls wait for them, so a context's calls are answered in the order it makes them, as in Chrome). Chrome's enum objects and constants come by name from `static-compat.ts` (hand-written, also used alone by the content-script compat) and the generated `chrome-constants.gen.ts`. `globalThis.chrome` becomes a proxy over WebKit's that applies the description and constants to each namespace object the first time it hands it out, and gives each WebKit event prototype the namespace exposes Chrome's `hasListeners` and webRequest filter leniency (WebKit has several event prototypes). It also gives each namespace and sub-namespace (`storage.local`) Chrome's own, enumerable methods, bound so that a detached call works, hands out each WebKit namespace as a view where its events and objects are own and enumerable too (WebKit's are neither, so a copy such as `{ ...chrome.alarms }` lost them), and lets an extension replace a namespace, which WebKit makes read-only. It keeps every namespace object it handed out alive, with its events and member objects (`storage.local`): WebKit holds them weakly and recreates a collected one, with a new prototype and without Lilo's additions or patches. In a page, each namespace method also stops settling its callback and promise once the page's `window.close()` succeeds, and every WebKit event listener is removed then (`closePage`), as Chrome runs nothing of a closed page. Every context's `runtime.onMessage` listeners (content scripts included, through the content-script compat) send an answer without a value as Chrome's `null`, so a `chrome.runtime.sendMessage` or `tabs.sendMessage` callback left with `undefined` gets Chrome's `runtime.lastError`, a page's worded from whether its worker reported a `runtime.onMessage` listener (`message-answers.ts`, `RuntimeBridgeHandler`), a tab's from whether its content scripts answer Lilo's probe, which a context answers while it has a listener. At startup it reads every namespace present, so those `browser` reaches first get all this too. The rules behind this shape:

- Additions and patches go on the prototype of WebKit's namespace (or event) object, which WebKit's `browser` alias shares, so webextension-polyfill users get them too. `browser` itself is never replaced or wrapped, even by a transparent proxy: WebKit finds the namespace object to fire a context's events on through its `browser` global, then `chrome`, which is Lilo's proxy, so the context's events would stop.
- WebKit's own properties cannot be redefined (`defineProperty` silently does nothing), hence the view, which only `chrome` hands out. It is a plain object over the namespace, built once, holding WebKit's native methods bound to their object: a Proxy would cost each read more than WebKit's own property. WebKit's native methods answer nothing called on the view, so the unpatched original a patched member keeps (`__liloUnwrapped`) is bound too. `runtime.connectNative` to Lilo's channel host passes straight through; a port it opens to another host is marked, so Lilo, which accepts every native connection, sends it the host's error for `lastError`. An unmarked port, opened through `browser.runtime`, disconnects on its first message instead.

**Swift side**: `GapEvents` receives each call on the port and hands it to `GapBridgeRouter` with the extension WebKit opened the port for and that extension's profile registry, so a call can never claim another identity or profile. The router checks the manifest permission the API needs, hands the handler one `GapCall`, and the reply goes back on the port, resolving or rejecting the caller's promise:

| Handler | APIs covered |
|---------|-------------|
| `BookmarksBridgeHandler` | `chrome.bookmarks.*` |
| `HistoryBridgeHandler` | `chrome.history.*` |
| `IdentityBridgeHandler` | `chrome.identity.*` |
| `IdleBridgeHandler` | `chrome.idle.*` |
| `NotificationsBridgeHandler` | `chrome.notifications.*` |
| `ManagementBridgeHandler` | `chrome.management.*` |
| `ActionColorBridgeHandler` | `chrome.action` badge colors and `getUserSettings` |
| `DownloadsBridgeHandler` | `chrome.downloads.*` |
| `CommandsBridgeHandler` | `chrome.commands.*` |
| `SidePanelBridgeHandler` | `chrome.sidePanel.*` (options and behavior; each window's `SidePanelController` shows the panel) |
| `RuntimeBridgeHandler` | `chrome.runtime.requestUpdateCheck`; whether the worker listens to `runtime.onMessage`, for the error of a page's unanswered message; messages and ports to another extension, relayed to its `onMessageExternal` and `onConnectExternal` |
| `TabsBridgeHandler` | `chrome.tabs` zoom settings and split views (Lilo split folders) |
| `PermissionsBridgeHandler` | `chrome.permissions` host access requests |
| `CookiesBridgeHandler` | `chrome.cookies.getPartitionKey` |
| `TabGroupsBridgeHandler` | `chrome.tabGroups.*` (backed by Lilo tab folders) |
| `SessionsBridgeHandler` | `chrome.sessions.*` |
| `TopSitesBridgeHandler` | `chrome.topSites.*` |
| `OffscreenBridgeHandler` | `chrome.offscreen.*` (a hidden web view per extension) |
| `CaptureBridgeHandler` | `chrome.tabCapture.*`, `chrome.desktopCapture.*` (stream ids redeemed on the tab-share ferry) |
| `SearchQueryBridgeHandler` | `chrome.search.query` (results URL of the default search engine) |
| `PowerBridgeHandler` | `chrome.power.*` (one IOPM assertion for every extension's request) |
| `SystemBridgeHandler` | `chrome.system.cpu`, `.memory`, `.storage` and `.display` |
| `TtsBridgeHandler` | `chrome.tts.*` (AVSpeechSynthesizer, one queue for every extension) |
| `DebuggerBridgeHandler` | `chrome.debugger.*` (the tab's Web Inspector, the agent's connection, in CDP through `Lilo/Agent/InspectorCDP.js`; a banner with Cancel in every window while attached) |
| `I18nBridgeHandler` | `chrome.i18n.detectLanguage` |
| `UserScriptsBridgeHandler` | `chrome.userScripts.*`; also answers `runtime.sendMessage` from user script worlds |
| `OmniboxBridgeHandler` (`Lilo/Bridge/`) | `chrome.omnibox` suggestions; one instance also serves the address bar on the UI bridge |
| `ExtensionUIBridgeHandler` | `chrome.action.openPopup`; its other actions serve the chrome UI's extension panel |

`GapEvents` holds each worker's port and delivers the events of these APIs: it keeps which events each extension's worker listens to and, apart, which each open page listens to (a context reports an event's first listener and, once removed, its last, so a set shrinks too), keeps each event for a listening worker until the worker received it (it waits while the worker is stopped, and wakes it; only the worker's listeners do, and only they are kept across launches), and pushes it to the open pages that listen to it. Both go out once per main-actor turn, one message per worker or page for the whole burst, and the worker's delivery confirms all of it. A worker's events go out as soon as its port is connected, and the worker holds them until the extension's top-level code has run, one more WebKit call has been answered and no content script registration is in flight, so the listeners registered there hear the event that woke the worker, after the answers to the calls that code made, as in Chrome. A worker that asked for its port to be closed is idle; any other disconnect means it stopped. Each event carries a sequence number: what the worker has not confirmed goes out again on its next port, and the worker drops a number it already heard.

### Side panel

`chrome.sidePanel` pages show in the browser window, never as a tab or a window of their own. Each `MainWindowController` owns a `SidePanelController` (`Lilo/Window/`) that docks one panel right of the content: `contentFrameRect()` gives up the panel's width plus a `SplitDividerView`, which the user drags to resize (one width for every panel, at least 360 points, kept in UserDefaults). The panel is a native `SidePanelView` (header with the extension's icon, name and a close button above a `WKWebView` in the extension's configuration) between the content and the window frame, so AppKit hit-testing reaches it through the overlay like the page; the chrome UI only learns its width (`sidePanelWidthChanged`) to stop its content overlays at the panel's edge.

The controller follows Chrome's side panel coordinator: the window has one extension-wide entry and each tab may have its own tab-specific one; a tab switch shows the new tab's open panel, else the shown extension's or the window's extension-wide panel, else hides the panel. `SidePanelBridgeHandler` keeps the options (session-only, per extension and Lilo tab), the persisted `openPanelOnActionClick` behavior, and resolves `open` and `close` to a window and tab; a toolbar click consults it before the popup and `action.onClicked`. `onOpened` (after the panel's first load) and `onClosed` go out through `GapEvents` with the window's position and the tab's index, which the JS resolves to WebKit ids. Only the panel on screen has a web view: a hidden one is released, so a closed or backgrounded panel costs nothing. `open` needs a user gesture, a page's transient activation or a recent action click, command or extension menu item, which the registry records.

`WebstoreInstallHandler` stays off this router on purpose: the Chrome Web Store is an https origin with no extension identity, so its `chrome.webstorePrivate` shim talks to a separate, origin-locked `liloWebstore` message handler, and every install still goes through the native permission review.

### Extension loading flow

```text
1. ProfileExtensionRegistry.load(from: url)
   └─ Copies extension to permanent location if needed (an APFS clone);
      an unpacked folder loads from Lilo's clone of it, cloned again
      when one of its files changed
   └─ ExtensionBackgroundPreparer wraps the service worker with
      ChromeAPIBackgroundPrelude.js and puts ChromeContentCompat.js
      first in each content script list (rewrites manifest.json)
   └─ Rewrites the static declarativeNetRequest rulesets into the form
      WebKit applies, with ChromeStaticRules.js (stamped in _lilo/)
   └─ For the publicSuffix permission, puts the bundled Public Suffix
      List in the prelude and in _lilo/ for pages (the API is synchronous)
   └─ Skips the preparation when the stamp in _lilo/ matches Lilo's
      build, the prelude and compat sources, and the manifest and worker
      files
   └─ Creates WKWebExtension + WKWebExtensionContext (at launch, every
      extension's at once, then loaded back to back in stored order)
   └─ Sets uniqueIdentifier (WebKit keys chrome.storage by it) and
      baseURL chrome-extension://<id>/ (a custom scheme registered at
      launch), stable across sessions so restored tabs and origin
      storage follow the id
   └─ ExtensionAccess pre-grants manifest-declared permissions and host
      patterns
   └─ controller.load(context)
   └─ ExtensionLifecycle sends the runtime events of the load (see the
      state machine above) through GapEvents

2. Background content startup
   └─ A new install or update starts its worker, which hears
      runtime.onInstalled once its top-level code has run; otherwise on
      demand (popup, event or API use): context.loadBackgroundContent()

3. Content script injection
   └─ Handled natively by WKWebExtension on navigation
   └─ ChromeAPIAugmentation.js injected into extension page contexts,
      not into the web pages they frame (augments window.chrome with
      app-facing APIs)
```

### Extension lifecycle

- **Install safety:** Chrome Web Store installs are HTTPS-only. A CRX3 package must carry a verifying proof from its own key (matching the requested id and the signed `crx_id`) and, like Chromium, the Web Store's publisher proof (`kPublisherKeyHash`). Downloads are capped at 256 MB and extraction at 1 GB; ZIP extraction rejects absolute or parent-directory paths and any symlink, strips group/other write bits, and works in a fresh UUID temp directory. A package is copied into the profile's extensions directory (staged, then swapped in) and never loaded from the temp copy. Extensions never run on the Web Store (its match patterns are denied to every context).
- **Extension ids:** a store install keeps its Web Store id (the folder name under the profile's managed extensions directory). An unpacked extension with a manifest `key` gets the id Chrome derives from it, so native hosts' `allowed_origins` match; any other unpacked extension gets a path-derived `extension-...` id. An installed extension keeps its id across reinstalls, updates and launches, and with it its `chrome.storage`.
- **Permission model:** Extension installs are gated by an install-time review that reads `manifest.json` and lists, in the chosen language, the requested permissions (a generic line for unknown ones) and the hosts of `host_permissions`, `content_scripts` and `externally_connectable` matches. After approval, manifest permissions, host permissions, content-script and `externally_connectable` matches are pre-granted at load time because WebKit hides APIs and skips content scripts without a grant. Optional permissions and optional hosts are granted only through `permissions.request`; those grants (and removals) are persisted next to the site-access choice and restored on every load.
- **Data separation:** each profile's extension controller uses the profile's own website data store, so extension pages, workers and `chrome.cookies` see that profile's cookies and storage. `chrome.storage` lives in WebKit's per-profile `WebExtensions/<profile id>` directory and is removed with the extension (enabled or disabled) and with the profile.
- **Updates:** Web Store extensions installed by Lilo (enabled or disabled) are checked against Google's update service every 5 hours, counted across launches and never earlier than 90 s after launch. A check covers every open profile: their ids are batched into shared requests (25 per request), and a version several profiles need, or one waiting for a running worker to stop, is downloaded once and cloned into each profile. A newer version is applied silently when it grants nothing new (permissions, or match patterns no current one covers); when it grows, the extension is disabled and a "needs new permissions" prompt lists only the additions. A declined version is remembered and not offered again; a disabled extension is not prompted from the background. A package that fails to load is rolled back to the previous files.
- **Background states:** a worker load that WebKit leaves unanswered times out after 10 s. A failed load before a toolbar click or command restarts the worker once; if that fails the extension shows as degraded with the error. Workers that WebKit unloads when idle are left stopped and start again on their next event; a gap event wakes a stopped worker only if that worker reported listening to it (until a worker of the installed version has run once, every gap event its permissions allow wakes it; the listeners it reported are kept across launches). Each worker opens its channel to Lilo when it starts. WebKit checks a worker 30 s after its last WebKit event and every 30 s after that, and keeps it while it has a port active in the last 2 minutes, so a worker with no gap call, reply or event for 20 s asks Lilo to close its channel: WebKit then unloads it at its next check, 30 s after it started when nothing else happened, as in Chrome. Its next gap call opens a new channel. A gap event for a worker without its channel loads it if stopped (which restarts WebKit's idle count of a running one) and, if WebKit still runs it, broadcasts `lilo-reconnect` from its background page, which shares its origin, so the worker opens its channel and receives the event. There is no periodic ping, so idle workers do not stay resident. Every extension is granted `nativeMessaging` for the channel; native hosts still require it declared or granted at Lilo's prompt. A worker whose channel disconnects without its asking while WebKit still holds its background is restarted with exponential backoff, at most 5 times without the worker connecting before it is marked failed. A stored extension that fails to load at launch stays listed with its error; enabling it retries.

### Extension preparation
- **Installed extension contents:** Vendor files stay immutable. An unpacked extension loads from an APFS clone of the developer's folder in the profile's `UnpackedExtensions` directory, never written in place; the clone is made again when a file of the folder changed. Lilo writes only its own files (`lilo-background-wrapper.js` and `lilo-background-prelude.js`, next to the vendor service worker, plus metadata under `_lilo/`) and patches `manifest.json` to point MV3 `background.service_worker` at the wrapper (with `preferred_environment: "service_worker"` when the manifest also keeps Firefox's `scripts` or `page`, which WebKit would otherwise run). The prelude reports the vendor worker's URL as the worker's `location`.
- **Background compatibility:** `ChromeAPIBackgroundPrelude.js` is generated from the TypeScript shared static compatibility layer and imported by the wrapper before the vendor service worker. This keeps constants like `chrome.tabs.TabStatus` available in service-worker contexts without injecting the full page bridge. The gap namespaces a manifest may leave out (`bridge-src/src/shared/gap-modules.ts`, from bookmarks to tts, plus Lilo's `declarativeNetRequest` rule rewriting) are separate chunks in `ChromeAPIGapModules.json`: the preparer puts in the prelude only those the manifest's permissions, optional permissions or keys may install, and a context evaluates one only when it installs its namespace. A chunk also carries Chrome's generated constants for its namespaces, installed even when WebKit provides the namespace itself. The page bundle carries every chunk and evaluates the same way.
- **Update behavior:** A load prepares the extension again only when the stamp `_lilo/prepared.txt` no longer matches: Lilo's build, the prelude (with the user scripts switch) and content compat sources, and the size and date of `manifest.json` and the vendor worker. If Lilo updates its polyfills/augmentations, installed extensions receive the refreshed `lilo-background-prelude.js` the next time they load. A background WebKit runs as a page (an MV3 `background.scripts` or `background.page` with no service worker, which Chrome does not run) gets the page augmentation as the extension's other pages do. When the manifest points at Lilo's wrapper, metadata recovers the original target and the wrapper is regenerated against it; when it names a vendor worker (a fresh package, or an unpacked extension edited in place), that worker is adopted. The manifest is written once per preparation, and only when it changed. The content-script compat is prepended to isolated-world entries only, never to `world: "MAIN"` ones.
- **Context split:** `ChromeAPIAugmentation.js` is for document contexts with `window.webkit.messageHandlers`; `ChromeAPIBackgroundPrelude.js` is for background contexts and must remain service-worker-safe. The bridge build fails if the background prelude or a gap module chunk contains `window`, `document`, `webkit`, or `messageHandlers`. `ChromeContentCompat.js` is for content-script (isolated-world) contexts - `ExtensionBackgroundPreparer.prepareContentScriptCompat` prepends it to each JS `content_scripts` entry of the patched manifest (it does its work once per world, so further entries matching a frame only parse it) so APIs WebKit omits there (notably `chrome.storage.managed`) exist before the vendor content scripts run, and writes it in every extension: the `scripting` patches prepend it to the isolated-world scripts registered or executed at run time, and leave it out of `getRegisteredContentScripts`.
- **Chrome-accepted manifests:** the same pass rewrites the `manifest.json` entries Chrome accepts and WebKit rejects into their WebKit equivalent: an empty `_execute_action` command (WebKit adds that command itself), an empty `content_security_policy` object, `web_accessible_resources` entries that only name other extensions, a missing `description`, an empty `content_scripts` list, shortcut keys with whitespace around them, and `externally_connectable` entries WebKit cannot read (`<all_urls>`, ports, nothing granted).
- **Diagnostics:** `WKWebExtensionContext.errors` are logged with extension label, reason, domain, code, message, and userInfo. Runtime state is tracked separately so UI/bridge consumers can see `loaded`, `backgroundLoaded`, `degraded`, or `failed` without scraping logs.

### Chrome Web Store integration
- **Status:** best-effort. The live store's own install and remove buttons, relabeled "Add to Lilo" and "Remove from Lilo", install and uninstall into Lilo through a shim of the private store API; the URL-bar install button is the fallback.
- **Chrome masquerade (store-scoped only):** On `chromewebstore.google.com` (and the legacy `chrome.google.com/webstore` path) the tab presents a full Chrome User-Agent and a shimmed `navigator.userAgentData` (incl. `getHighEntropyValues`), so the store renders its normal UI instead of an unsupported-browser state. Every other origin keeps the Safari user agent (no Lilo token). See `ChromeMasquerade`, `WKWebViewTab.policy(for:)`, and what users see in [COMPATIBILITY.md](../COMPATIBILITY.md#user-agent-and-the-chrome-web-store).
- **Injection scope:** the store is a normal https tab, which does NOT receive the extension-context `ChromeAPIAugmentation.js`. The store shim is a separate bundle `ChromeWebStoreShim.js`, injected into regular-tab content controllers (`WKEngineFactory.cachedContentController`), limited to `chromewebstore.google.com` by the private match-pattern `WKUserScript` initializer, and self-guarded to the store hostname when that initializer is missing.
- **`chrome.webstorePrivate` (store-scoped JS shim):** `beginInstallWithManifest3`, `completeInstall`, `getExtensionStatus`, `shouldShowEnterprisePromotionBanner`, plus stubs (`getBrowserLogin`, `getWebGLStatus`, `getIsLauncherEnabled`, `isInIncognitoMode`, `getMV2DeprecationStatus`, `getReferrerChain`, `getFullChromeVersion`). Note `getFullChromeVersion` must return BOTH `version` and `version_number` (the store reads `version_number`). Also shims `chrome.management` (`getAll`/`get`/`uninstall` + `onInstalled`/`onUninstalled` events) reflecting the real native registry, and a minimal `chrome.runtime`. Methods are dual-mode (callback or promise). Defined in `bridge-src/src/augmentation/webstorePrivate.ts` - best-effort, iterate as the live store calls new methods.
- **Native transport:** the shim routes through the `liloWebstore` `WKScriptMessageHandlerWithReply` (`WebstoreInstallHandler.swift`), kept SEPARATE from the hardened `GapBridgeRouter` (the store is an https origin with no extension identity). Actions: `install` (reuses the shared `ChromeWebStoreInstaller` CRX3 pipeline + native consent prompt), `list` (real installed extensions, so the button reflects state on reload), `uninstall` (`registry.unload`). The handler verifies the frame origin natively.
- **Install consent:** `__MSG_*__` placeholders in the manifest `name` are resolved from `_locales/<default_locale>/messages.json` so the dialog shows the real name.

## File organization

```text
Lilo/Extensions/
├── Core/        - per-profile registry (WKWebExtensionController) and its modules:
│                  lifecycle, background supervisor, updater, access, user scripts;
│                  the controller delegate, tab/window adapters, manifest parsing,
│                  service-worker preparation, Web Store installer, native messaging,
│                  storage
├── GapAPI/      - GapBridgeRouter plus one *BridgeHandler.swift per Gap API
│                  (see the Gap API layer table above)
├── ChromeAPIAugmentation.js       - generated; injected into extension page/popup contexts
├── ChromeAPIBackgroundPrelude.js  - generated; loaded before extension service workers
├── ChromeAPIGapModules.json       - generated; the gap modules a worker's prelude takes per manifest
├── ChromeWebStoreShim.js          - generated; injected into the Chrome Web Store
├── ChromeContentCompat.js         - generated; content-script compatibility layer
├── ChromeStaticRules.js           - generated; static declarativeNetRequest ruleset rewriting
├── public-suffix-list.dat         - bundled Public Suffix List behind chrome.publicSuffix
└── bridge-src/  - TypeScript source for the generated .js files above (built via esbuild.mjs)
```

The five `Chrome*.js` files are build artifacts of `bridge-src/` and are checked into git so the Xcode build works without a Node toolchain; CI fails if they drift from `bridge-src/`. Never hand-edit them - regenerate with `make ext-bridge-build`.

```text
Lilo/ContentBlocker/
├── FilterListService.swift        - filter list download, caching and rule application
├── FilterListConverter.swift      - filter list syntax to WebKit content rules and script tables
├── GenericCosmetics.js            - hand-written; generic cosmetic filtering
├── ProceduralCosmetics.js         - hand-written; procedural cosmetic filtering
├── Scriptlets.js                  - hand-written; scriptlet injection for filter-list rules
├── content-blocker-rules.json     - bundled fallback block list until filter lists download
└── BlockerResources/              - stand-in resources the content blocker's built-in extension
                                     serves for `$redirect` filters (empty scripts, media, ad SDK stubs)

Lilo/Reader/
├── ReaderMode.swift               - injects the two scripts below into the page
├── Readability.js                 - vendored Mozilla Readability (see THIRD-PARTY-NOTICES.md)
└── ReaderView.js                  - hand-written; reader mode rendering and controls
```

The cosmetic, scriptlet and reader `.js` files are ordinary source files edited in place (Readability.js excepted: it is vendored third-party code, attributed in [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)); the tests of the cosmetic and scriptlet runtimes live in `Lilo/Extensions/bridge-src/src/`. Bundled resources are looked up by name (`Bundle.appResourceURL`), so the folder a resource sits in does not matter at runtime.

## Page-world APIs

Web pages get what Lilo adds to WebKit (notifications, geolocation, Web Serial, EyeDropper, tab sharing, media and freeze control) through `Lilo/Engine/PageWorld.swift`, and only through it. A page, and every bot detector on it, compares what it sees with what the user agent claims: Safari, whose pages have no `window.webkit`, no unknown global and no built-in function that prints its source. Any such trace reads as a tampered browser and sites answer it with captchas, so:

- Bridge handlers are registered in `PageWorld.bridgeWorld`, never in the page world: one page-world handler gives every page `window.webkit`, which cannot be deleted.
- A page module is a function source passed to `PageWorld.install`. It reaches native code through `lilo.post` / `lilo.send`, and native code reaches it through `lilo.on` and `PageWorld.push`, evaluated in `bridgeWorld`. The two worlds talk over DOM events whose types are random per launch.
- A module patches WebKit's own prototypes with `lilo.methods` / `lilo.accessors` and defines new interfaces with `lilo.nativeClass` / `lilo.global`: functions print as native code (in every same-origin frame), members keep WebIDL's descriptors, and no own property lands on `window`, `navigator` or `document`.
- `LiloTests/Engine/PageWorldTests.swift` compares a tab with the same engine settings without Lilo's scripts and fails on any added, missing or reshaped property, any function that prints its source and any `window.webkit`. A deliberate new global (a Chrome API pages use) goes in its `addedGlobals`.

## Private WebKit API

Some features have no public WebKit API: process identifiers and page suspension (tab lifecycle, process manager), page muting, Picture-in-Picture, the Web Inspector, WebKit feature flags (`about:config`), and a set of private `WKUIDelegate`/`WKNavigationDelegate` hooks (window frame, print headers and footers, pointer lock, process termination reasons). Lilo reaches them at runtime only, never through private headers or linked private symbols:

- **Selectors** looked up with `NSSelectorFromString` (classes with `NSClassFromString`) and called through `method(for:)` cast to a `@convention(c)` function type.
- **KVC** on private keys, such as `value(forKey: "_displayCaptureState")` or private `WKPreferences` keys like `developerExtrasEnabled`.
- **Private delegate methods** implemented under their exact Objective-C name with `@objc(_webView:...)`, so WebKit finds them.

Conventions:

- Guard every selector call with `responds(to:)` and degrade gracefully: when WebKit drops a selector the feature turns off (`nil`, `false`, or a no-op), it never crashes.
- KVC has no such guard (a missing key raises an Objective-C exception), so keep it to long-standing keys and prefer a guarded selector for anything new.
- Keep `WKWebView` reflection in `Lilo/Engine/WebViewPrivateAccessors.swift` where possible: add a typed accessor there rather than a new `unsafeBitCast` at the call site.
- `evaluateJavaScript` runs as a user gesture, so the page counts as interacted with and may then hold its own navigations behind a beforeunload panel. Script Lilo runs on its own (a bridge's reply, a freeze, the agent's console hook) goes through `WebViewPrivateAccessors.evaluateWithoutUserGesture` instead.
- A renamed private delegate hook fails silently: WebKit simply stops calling it. `LiloTests/Engine/PrivateDelegateSelectorTests.swift` checks that `WKWebViewTab` implements every hook and that WebKit still declares each one, so add new hooks to its lists.

Main users:

| File | Private surface |
|------|-----------------|
| `Lilo/Engine/WKWebViewTab.swift` | private UI and navigation delegate hooks, `_close` / `_tryClose`, diagnostics through `WebViewPrivateAccessors` |
| `Lilo/Engine/WebViewPrivateAccessors.swift` | typed wrappers: process pids and state, page suspend/resume, muting, PiP state, scripts run without a user gesture (the chrome bridge) |
| `Lilo/Engine/WKEngineFactory.swift` | shared process pool and prewarming, tracking prevention toggle and statistics clearing, user-script removal, match-pattern `WKUserScript` initializer (Web Store shim), private preferences |
| `Lilo/Engine/WKFeatureFlags.swift` | experimental and internal feature flags |
| `Lilo/Engine/WebInspectorSupport.swift` | showing the Web Inspector and its panels |
| `Lilo/Engine/PiPController.swift`, `CaptureUsageObserver.swift`, `ContextMenuBuilder.swift` | PiP toggle, display-capture state, context-menu hit-test URLs |
| `Lilo/TabShare/TabShareFrameSchemeHandler.swift` | registering `lilo-capture://` as a secure scheme |
| `Lilo/Extensions/Core/ProfileExtensionRegistry.swift` | background web view launch for extension service workers |
| `Lilo/Extensions/Core/BackgroundSupervisor.swift` | in-place restart of an extension service worker WebKit wrongly believes loaded |
| `Lilo/Extensions/GapAPI/UserScriptsBridgeHandler.swift` | a tab's frame tree (`_frames:`) and frame identifiers (`WKFrameInfo._handle`) for `userScripts.execute` and user script message senders |
| `Lilo/Window/MainWindowController+Setup.swift` | `_setRelatedWebView:`, so every window's chrome shares one web content process |
| `Lilo/Window/OverlayWebView.swift` | `_simulateMouseMove:` / `_simulateMouseExit:` to drive page hover under the overlay |

## Testing

Three suites cover the three codebases, each beside or mirroring its source: Swift tests in `LiloTests/` (mirroring `Lilo/`, with shared helpers in `Support/`), interface tests beside the Svelte source and Playwright specs in `lilo-ui/e2e/`, and extension bridge tests beside `Lilo/Extensions/bridge-src/src/`. Extension behavior is also checked against Chrome itself: `ChromeContractTests` replays the cases of `test-extensions/extension-contracts/` against answers recorded from Chrome for Testing, `ChromeSurfaceTests` compares the API surface with Chrome's and with [COMPATIBILITY.md](../COMPATIBILITY.md), and `make ext-smoke` runs the most used store extensions against their recorded Chrome behavior.

The commands, and where a new test goes, are in [CONTRIBUTING.md](../CONTRIBUTING.md#tests-and-validation).
