# WebKit extension gaps

The `WKWebExtension` limitations Lilo works around or cannot fix, so each workaround can go once a macOS or WebKit update fixes the limitation under it. [COMPATIBILITY.md](../COMPATIBILITY.md) says what extensions see; this register says why, where the workaround lives, and what to remove when WebKit changes.

Missing namespaces and members (`tabGroups`, `offscreen`, `sidePanel` and so on) are not listed here: `ChromeSurfaceTests` tracks them against Chrome's schemas (`chrome-surface-gaps.txt`), and Lilo's Gap APIs fill them ([ARCHITECTURE.md](ARCHITECTURE.md#extension-architecture)).

Status of each gap:

- **Checked**: a test of [WebKitGapTests.swift] reproduces the gap and asserts WebKit's current behavior, mostly in a bare `WKWebExtensionController` without any of Lilo. When it fails, WebKit changed: its message names the workaround to remove. They run with `make swift-test`, except the two that wait out WebKit's clocks (gaps 7 and 33), which run with `make swift-test-slow`.
- **Contract**: `ChromeContractTests` covers it (`LiloTests/Extensions/chrome-contract-differences.txt` lists the differences Lilo keeps and fails once one matches Chrome).
- **Manual**: no automated check (it would crash the test host, it is timing dependent, or it is not reduced to a minimal case). Its repro reproduces it by hand.

Most gaps carry a repro (after the check) for a bug report on bugs.webkit.org or Feedback Assistant. Only gap 19 is filed upstream (webkit.org/b/267514). Observed on macOS 27.0.1 (26A434). Gap numbers are stable, since code and tests cite them; a number that goes is not reused.

Code locations below name the file and the symbol to look for (`chrome-compat.ts` `serve` is the `serve` member of a namespace description in that file).

Still open, with no workaround in Lilo: gaps 1, 14, 35, 36, 71, 74, 80 and 84. Workarounds that leave part of the gap open, mostly for extensions reaching WebKit's `browser` instead of `chrome`: gaps 3, 4, 8, 9, 22, 34, 42, 43, 44, 46, 60, 81 (`XMLHttpRequest`), 82, 87, 89 and 92. Every other gap is fully worked around.

---

## Namespace objects and events

### 2. Events reach a context only through its own `browser` or `chrome`

- **Gap:** WebKit finds a context's listeners through the global `browser`, else `chrome`, and skips the context when neither is its own namespace object: no `runtime.onMessage`, `onConnect`, port message or `storage.onChanged`. With `chrome` being Lilo's proxy, an extension assigning `browser` (`var browser = chrome`, webextension-polyfill) would lose every event. Chrome lets extensions wrap or replace either.
- **Lilo:** never wraps `browser`. Changes go on the prototypes `browser` shares with `chrome` ([chrome-compat.ts] `apply`), WebKit's own members are served only through `chrome`'s view (gap 3), and `browser` stays WebKit's object whatever an extension assigns (`installChromeCompat`, the `browser` accessor), in content scripts too ([content-compat-entry.ts]).
- **Impact:** an extension reading back the `browser` it assigned gets WebKit's (Web PKI, Stands, buykers). Without it, Proton Pass, whose content script hides both globals behind proxies once loaded, never got the worker's `tabs.sendMessage`: its inline menu closed without filling the field.
- **Check:** `testEventsSkipAContextWhoseBrowserAndChromeAreReplaced`, `testEventsStopOnceNeitherGlobalIsTheNamespace`. Repro: in an MV3 worker, keep `chrome.storage` and `chrome.action`, listen to `storage.onChanged`, set `globalThis.browser = {}` and `globalThis.chrome = {}`, then set a key. Expected: the listener runs. Actual: never.

### 3. `runtime.connectNative`, `lastError` and `onInstalled` are own, fixed properties

- **Gap:** they are own properties of each WebKit `runtime` object; `Object.defineProperty` on them does not throw and changes nothing. Chrome lets a polyfill redefine them.
- **Lilo:** `chrome.runtime` is a view whose `lastError`, `connectNative`, `connect` and `sendMessage` are Lilo's ([chrome-compat.ts] `serve`, `view`). `lastError` is the error of the Lilo callback running ([callbackify.ts] `liloLastError`), and `Unchecked runtime.lastError` is logged when it goes unread. Lilo's events take the listeners of WebKit's `onInstalled`, `onStartup` and `onConnect` (`standIns`, [chrome-event.ts] `eventStandIns`).
- **Impact:** through `browser.runtime` (webextension-polyfill), the `lastError` of refused native ports and of Lilo's callbacks is missing.
- **Check:** `testRuntimeMembersAreOwnPropertiesNothingRedefines`. Repro: `Object.defineProperty(browser.runtime, 'connectNative', { value: 1, configurable: true })`, then read it. Expected: redefined, or a `TypeError`. Actual: no error, original kept.

### 87. The worker's `extension.getBackgroundPage` cannot be removed

- **Gap:** WebKit gives the worker's `extension` namespace `getBackgroundPage`, which Chrome leaves out of workers. It is an own property of WebKit's object that, as gap 3's, `delete` and `Object.defineProperty` report removed and keep.
- **Lilo:** the worker's `chrome.extension` reads it as `undefined` ([chrome-compat.ts] `serve`); `browser` stays WebKit's object (gap 2), so `browser.extension` keeps it.
- **Impact:** a worker telling its context with `extension.getBackgroundPage && extension.getBackgroundPage() === window` reads `window`, which no worker has, and fails to load. AI Exporter does so through `browser`, which WXT picks when it exists.
- **Check:** `testWorkerKeepsGetBackgroundPageWhateverRemovesIt`. Repro: in an MV3 worker, `delete browser.extension.getBackgroundPage`, then read `typeof browser.extension.getBackgroundPage`. Expected: `undefined`, as in Chrome. Actual: `function`.

### 13. Events lack `hasListeners`

- **Gap:** WebKit events have `addListener`, `removeListener` and `hasListener` only.
- **Lilo:** tracks listeners on each WebKit event prototype and adds `hasListeners` ([chrome-leniency.ts] `chromeEvent`).
- **Impact:** extensions calling it threw (Brisk Teaching).
- **Check:** `testEventsLackHasListeners`. Repro: `typeof browser.runtime.onMessage.hasListeners` is `"undefined"`, `"function"` in Chrome.

### 17. Namespace objects recreated once collected

- **Gap:** WebKit holds its namespace, member (`storage.local`) and event objects weakly: once collected, the next read gets a new object with a new prototype, without Lilo's additions. Chrome's stay the same objects.
- **Lilo:** the `chrome` proxy keeps every object it handed out alive with its events and members, and reads every namespace of `browser` at startup ([chrome-compat.ts] `kept`, `handedOut`); the content script compat keeps the namespaces it fills ([static-compat.ts]).
- **Impact:** without it, gap 31's ordering vanished with `storage.local` (CS2 Trader read its defaults before they were written), and Lilo's members (`hasListeners`, `i18n.detectLanguage`, `action.setBadgeTextColor`) vanished.
- **Check:** Manual: a collection cannot be forced in an extension context. Repro: set `Object.getPrototypeOf(browser.i18n).x = 1`, drop every reference, allocate a few million objects, read `browser.i18n.x`. Expected: `1`. Actual: `undefined`.

### 32. Namespace members differ from Chrome's in shape

- **Gap:** WebKit methods sit on the prototype and return `undefined` when called detached; events and sub-namespaces are own but not enumerable, so `{ ...chrome.alarms }` lacks them; namespaces are read-only properties of `browser`; `runtime.lastError` is `null` without an error. Chrome's are own, enumerable, work detached, are writable, and `lastError` is `undefined`.
- **Lilo:** `chrome` gives each namespace and sub-namespace own bound members ([chrome-compat.ts] `ownMembers`), hands out a view where every member is own and enumerable (`view`), hands back a namespace an extension assigns (the proxy's `set`), and serves `lastError` as `undefined` without an error (`serve`).
- **Impact:** chrome-promise finds no `storage.local.get` (Steam Inventory Helper), a detached `getMessage` or `getManifest` returns nothing (Chrono Download Manager), a copy of `chrome.alarms` has no `onAlarm` (Online Security), replacing `chrome.storage` throws (Distill), `lastError` reads as an error (eJOY). Through `browser`, WebKit's shape stays.
- **Check:** `testNamespacesDifferFromChromeInShape`. Repro: `const { getManifest } = browser.runtime; getManifest()` returns `undefined`; `Object.keys(browser.storage.local)` is empty; `Object.getOwnPropertyDescriptor(browser, 'alarms').writable` is false.

### 52. Event listener methods throw on a listener that is not a function

- **Gap:** WebKit throws "The 'listener' value is invalid, because a function is expected."; Chrome ignores the call and `hasListener` answers `false`.
- **Lilo:** ignores it in the patches of every event prototype ([chrome-leniency.ts] `chromeEvent`).
- **Impact:** IE Tab's worker removes a listener it never set, and threw.
- **Check:** `testEventListenerMethodsThrowOnANonFunction`. Repro: `browser.storage.onChanged.removeListener(undefined)` throws.

## runtime and messaging

### 88. A worker's message names its sender by the extension's origin

- **Gap:** a message from the worker reaches a page's `runtime.onMessage` with a sender whose `url` is the extension's origin. Chrome's is the worker script's url.
- **Lilo:** gives every `runtime.onMessage` listener the worker's script url, from the manifest, for such a sender ([message-answers.ts] `chromeSender`). A port the worker opens keeps WebKit's sender.
- **Impact:** Aircall's offscreen document answers only a sender whose `url` names its background script, so its popup's first request was never answered.
- **Check:** `testWorkerMessageSenderURLIsTheExtensionOrigin`. Repro: the worker calls `browser.runtime.sendMessage('ping')`; a page's listener reads `sender.url`. Expected: the worker's script url. Actual: the extension's origin.

### 79. Pages an extension's `externally_connectable` names get `browser.runtime` only

- **Gap:** WebKit gives those web pages `browser.runtime.sendMessage` and `connect`, and no `chrome`. Chrome gives them `chrome.runtime`, with callbacks and `lastError`.
- **Lilo:** a page-world script, installed for the pages a loaded extension's `externally_connectable` names, defines `chrome.runtime` over `browser.runtime` where WebKit exposes it ([ExtensionUserScripts.swift] `externallyConnectableRuntimeSource`); other pages keep no `window.chrome`. User-visible side: COMPATIBILITY.md, "runtime".
- **Impact:** claude.ai's OAuth page hands the Claude extension its code with `chrome.runtime.sendMessage(id, { type: 'oauth_redirect' })`, and showed "Authorization failed" without it.
- **Check:** Manual: needs a page on an origin the extension names. Repro: an extension with `"externally_connectable": { "matches": ["https://example.com/*"] }`, then `typeof chrome` on that page. Expected: `object`. Actual: `undefined`.

### 4. A refused native connection sets no `runtime.lastError`

- **Gap:** when the app refuses a native connection (`connectUsing` completes with an error), WebKit disconnects the port with no `lastError` and records an extension error in the context's `errors`. Chrome sets `lastError` (`Specified native messaging host not found.`) during `onDisconnect`.
- **Lilo:** accepts every native connection, even to a missing host ([ExtensionNativeMessaging.swift]). `chrome.runtime.connectNative` marks its ports (`?lilo` suffix) and posts a first message; Lilo answers a marked port with Chrome's error, which the wrapper raises as `lastError` ([chrome-leniency.ts] `nativeMessagingAsChrome`). A `browser.runtime.connectNative` port, which Lilo cannot wrap (gaps 2 and 3), disconnects on its first message without `lastError`.
- **Impact:** without it, an extension telling an absent host from a broken one (Claude) logs an error at every start, and every extension trying a missing host (Xunlei, Free Download Manager, 1Password) records an extension error. Through `browser.runtime`, a port to a missing host that never sends never disconnects.
- **Check:** `testRefusedNativeConnectionSetsNoLastError`. Repro: refuse in `webExtensionController(_:connectUsing:for:completionHandler:)`; in the worker, log `browser.runtime.lastError` in `connectNative('x').onDisconnect`. Expected: the error. Actual: `undefined`.

### 7. `runtime.onInstalled` and `onStartup` depend on the controller's age

- **Gap:** WebKit takes any context loaded in its controller's first 5 seconds for a launch restore (`onStartup`, no `onInstalled`), and a later one for an install, even a re-enable or reload. About one update in five gets no `onInstalled update`. Chrome: `install` for a new extension, `update` for a new version, nothing on re-enable or restart, `onStartup` on profile start.
- **Lilo:** its own events take the listeners of WebKit's ([runtime.ts] `runtimeLifecycle`), and the extension lifecycle sends them on the loads Chrome fires them for ([ExtensionLifecycle.swift] `loaded`).
- **Impact:** without it, a re-enabled extension reopens its welcome page, and an update can miss its migration.
- **Check:** `testLifecycleEventsDependOnTheControllerAge` (slow, 6 s) for the 5 s window; Manual for the dropped update (intermittent). Repro: load an extension in a new controller at once and another 6 s later. Expected: both hear `onInstalled install`. Actual: the first hears only `onStartup`.

### 18. Messages sent on a port before it is connected are dropped

- **Gap:** WebKit drops what the app sends on a `WKWebExtension.MessagePort` before the port's first message arrives, and what a worker sends on a port still connecting. Chrome queues them.
- **Lilo:** holds a native port's error until its first message ([ExtensionNativeMessaging.swift]), and Lilo sends a worker its events once the worker's first message on its port arrived ([GapEvents.swift] `adopt`). Its channel's message handler is set before `connectUsing` completes: the completion delivers the messages the context sent meanwhile, and a port without a handler loses them ([ExtensionControllerDelegate.swift]).
- **Check:** Manual. Repro: call `port.sendMessage` at once in `connectUsing`. Expected: delivered. Actual: never delivered.

### 22. `sendMessage` with no response sets no error

- **Gap:** WebKit resolves `undefined` and gives callbacks no `lastError` whether no listener exists or none responds. Chrome rejects with `Could not establish connection. Receiving end does not exist.` without a listener, sets `The message port closed before a response was received.` when none responds, and delivers a valueless response as `null`.
- **Lilo:** every context's `runtime.onMessage` listeners send a valueless response as `null`, so `undefined` means no answer ([message-answers.ts] `answerAsChrome`). Callbacks of `chrome.runtime.sendMessage` and `tabs.sendMessage` then get Chrome's `lastError` (`lastErrorWithoutAnswer`). A page sends the probe (`listensProbe`), which the other pages answer while one listens, then asks Lilo whether its worker listens (`workerListensToMessages`) to pick the error, and its promise rejects when none does ([chrome-compat.ts] `pageNoAnswer`); a worker's message always gets "Receiving end does not exist". `tabs.sendMessage` left without an answer sends a probe the tab's content scripts, and the extension's pages it shows, answer while one listens (`listensProbe`, `tabNoAnswer`), and rejects when none does. `browser.runtime.sendMessage` and content script callbacks keep WebKit's answer (Lilo serves no `lastError` in content scripts).
- **Impact:** Video Downloader Professional reads its response when `lastError` is unset and throws; AdGuard's popup reads the answer of a message its worker does not listen for yet (its listener comes after an asynchronous setup, in Chrome too).
- **Check:** `testSendMessageCallbackWithoutResponseSetsNoLastError`; the `runtime.sendMessage callback without listener` contract checks Lilo's answer. Repro: from an extension page with nothing listening, `await browser.runtime.sendMessage(1)`. Expected: rejects. Actual: resolves.

### 42. No cross-extension messaging

- **Gap:** WebKit throws `cross-extension messaging is not supported` in pages, and records an extension error in a worker. Chrome reaches the other extension's `onConnectExternal` / `onMessageExternal`, or fails with "Receiving end does not exist" when it is not installed.
- **Lilo:** `chrome.runtime.connect` and `sendMessage` to another id go to native ([runtime.ts] `crossExtensionMessaging`), which checks the target's `externally_connectable.ids` and reported listeners and relays them as gap events to its `onMessageExternal` and `onConnectExternal` stand-ins (`externalEvents`, which also keep WebKit's for web pages) and the port's messages (`RuntimeBridgeHandler`), which close with the pages holding them (`GapEvents` `pageChannel`). A worker hears every port until it reports its listeners, and declines one it has no listener for (`portDecline`), which then fails as unreceived unless a page took it. `browser.runtime` goes there through WebKit's own methods (`crossExtensionPatches`). Content scripts have no channel to Lilo: theirs go to their worker as a marked message or port, which it relays (`relayExternalMessaging`, `relayForContentScripts`, `onConnect`). User-visible side: COMPATIBILITY.md, "runtime".
- **Impact:** without Lilo, an extension talking to a companion extension (Sider) logs an error at every start.
- **Check:** Manual. Repro: `browser.runtime.connect('abcdefghijklmnopabcdefghijklmnop')` from an extension page throws.

### 82. `tabs.connect` does not reach the extension's pages a tab shows

- **Gap:** WebKit's `tabs.connect` reaches the tab's content scripts only: a tab showing one of the extension's pages never fires its `runtime.onConnect`, and the port stays open. Chrome connects those pages too. `tabs.sendMessage` does reach them.
- **Lilo:** `tabs.connect` asks for the tab's url as it opens WebKit's port; when the tab shows one of the extension's pages, the port goes over a marked `runtime.connect` instead, with what was posted meanwhile, and only the extension's top pages at the tab's url take it; the others hold it unanswered, as letting go before every process took it would drop it ([runtime.ts] `tabsConnect`, `onConnect`). Pages framed in a web page are not reached. User-visible side: COMPATIBILITY.md, "runtime".
- **Impact:** an extension whose worker connects to its own page opened in a tab (a popup or dashboard) got no answer.
- **Check:** Manual (`testTabsMessagesReachTheExtensionsPagesATabShows` checks Lilo's answer). Repro: a tab shows the extension's page, whose `onConnect` listener answers each message; the worker runs `tabs.connect(tabId).postMessage(1)`. Expected: an answer. Actual: none, and no disconnect.

### 43. A port message sent before the port connects arrives twice

- **Gap:** WebKit queues messages per channel and target world, and on connect fires the target world's queue, then the source world's (`WebExtensionContext::runtimeConnect`, `fireQueuedPortMessageEventsIfNeeded`). Between extension pages and the worker, both the main world, every queued message arrives twice. Chrome delivers each once.
- **Lilo:** a `chrome.runtime.connect` port is Lilo's at both ends: its name carries a mark the `onConnect` stand-in removes, each message its sender and number, and a repeat is dropped ([runtime.ts] `messagesOnce`, `onConnect`). A `browser.runtime.connect` port stays WebKit's.
- **Impact:** popups that post at once got two answers (Web PKI, Web Signer and Certisign WebSigner threw) or their state twice (uVPN's popup stayed empty).
- **Check:** `testPortMessagesSentBeforeTheConnectionArriveTwice`. Repro: the worker counts the messages of each `onConnect` port; a page runs `runtime.connect().postMessage('once')`. Expected: 1. Actual: 2.

### 44. Extension pages are not clients of the extension's worker

- **Gap:** WebKit registers the worker with its own directory as scope and counts no extension page as a client: `navigator.serviceWorker.ready` never resolves outside that directory, `clients.matchAll()` finds none, and a page's `postMessage` to the worker is lost. Chrome registers it for the whole extension.
- **Lilo:** on extension pages, `ready` resolves with the extension's registration and `postMessage` to the worker goes over a `BroadcastChannel`; the worker gets a `message` event whose source is a `WindowClient` answering that page ([worker-messages.ts]). `clients.matchAll()` still finds no page (COMPATIBILITY.md, "Background worker").
- **Impact:** without it, MultiPassword's offscreen document never reaches its worker, which never starts.
- **Check:** `testExtensionPagesAreNotClientsOfTheWorker`. Repro: worker at `worker/background.js`; a root page posts to the active registration's worker. Expected: scope is the root, the page is a client, the message arrives. Actual: scope `worker/`, no client, no message.

### 92. A page in its worker's process can find no registration

- **Gap:** `navigator.serviceWorker.getRegistrations()` in an extension page WebKit runs in the process that loaded the worker can answer nothing for the page's whole life, while pages in other processes find the activated registration at the same moment. In `make ext-smoke` it happens whenever another extension ran before in the same profile, never for the first one. WebKit's web process answers that call from its own table of the origins with registrations once the table is imported, without asking the network process (`WebSWClientConnection::mayHaveServiceWorkerRegisteredForOrigin`): that process's table is the likely cause, not confirmed. Chrome finds the registration.
- **Lilo:** while `ready` finds no registration, the page asks the worker over its channel whether it runs; once it answers, `ready` resolves with a stand-in whose `active` worker carries the page's messages ([worker-messages.ts] `workerStandIn`). The stand-in has no `pushManager`, `showNotification` or `update`.
- **Impact:** MultiPassword's offscreen document, which WebKit runs in its worker's process, never reached the worker, which then answered none of its popup's requests: the popup rendered nothing.
- **Check:** Manual: depends on an earlier extension, not reduced to a minimal case. Repro: `make ext-smoke IDS=inomeogfingihgjfjlpeplalcfajhgai,cnlhokffphohmfcddnibpohmkdfafdli SHARDS=1` with the stand-in removed. Expected: MultiPassword's offscreen document finds the registration a tab opened at the same time finds. Actual: it finds none.


### 93. `runtime.connect` throws when no context listens

- **Gap:** `chrome.runtime.connect()` from a context of an extension none of whose other contexts has an `onConnect` listener throws `Invalid call to runtime.connect(). No runtime.onConnect listeners found.`. Chrome returns a port that disconnects with `Could not establish connection. Receiving end does not exist.` as `runtime.lastError`.
- **Lilo:** the bridge catches that error and returns such a port: it takes messages until it disconnects, on the next task, and throws after ([runtime.ts] `unansweredPort`).
- **Impact:** Keeper's worker connects to its own pages at startup, before any is open (webext-redux), and logged the error.
- **Check:** `runtime.test.ts` ("hands out a port that disconnects with lastError when no context listens"). Repro: in a worker with no page open, `chrome.runtime.connect({ name: 'x' })`. Expected: a port whose `onDisconnect` fires with `lastError` set. Actual: the call throws.
### 60. A port nobody received yet disconnects when the first process answers

- **Gap:** WebKit sends a `runtime.connect` to each process with an `onConnect` listener and disconnects the port as soon as one answers with no receiver counted yet (`WebExtensionContext::runtimeConnect`). A worker that listens to `onConnect` itself gets such an answer from its own process, so its port to a page in another process nearly always disconnects. An extension page runs in its background's process unless its configuration differs, as one enabling element fullscreen does. Chrome disconnects only when no frame listens.
- **Lilo:** a `chrome.runtime.connect` port is Lilo's at both ends, so while it connects, the context takes its `onConnect` listeners off WebKit's event and puts them back after: WebKit then asks only the other processes ([chrome-event.ts] `unheard`, [runtime.ts] `crossExtensionMessaging`). A port another context opens to it while its listeners are off misses it: in a stress run, a page connecting while the worker connected about once a millisecond lost 5 to 11 of 1000 ports. A `browser.runtime.connect` port stays WebKit's. Lilo's tabs enable element fullscreen, so an extension page in a tab runs in a process of its own; enabling it in the extension configuration too keeps the port, but broke other extensions in `make ext-smoke` (Manus and ExpressKeys hung, Proton Pass, Ginger and Toggl Track failed).
- **Impact:** without it, Postman Interceptor's worker answered its popup on a port it opens back, which failed when the popup was in a tab.
- **Check:** `testWorkerPortToAPageInAnotherProcessDisconnects`. Repro: the worker listens to `onConnect` and, on a message, `runtime.connect()`s back to a page in a web view with no related web view. Expected: stays connected. Actual: disconnects.

### 70. A port message can reach a worker before earlier calls' answers

- **Gap:** a message the app sends on a native port can reach the worker before the answer to a call the worker made earlier and WebKit answered at once. Chrome dispatches the waking event after those answers.
- **Lilo:** once the worker's top-level code has run, the prelude waits for the content script registrations in flight and one more call's answer (`permissions.getAll`) before it dispatches the events Lilo sent meanwhile ([background-entry.ts] `__liloWorkerReady`, [chrome-leniency.ts] `registrationsSettled`, [ipc.ts] `workerReady`). Storage reads the worker made meanwhile answer after those events, as Chrome's storage, slower than its other answers, does ([storage-area.ts] `ordered`).
- **Impact:** Glasp's early `onInstalled` overlapped its top-level menu rebuild and `menus.create` found its id used (4 runs in 10); Tactiq's `onInstalled` unregistered scripts its startup was still registering; Custom Cursors' startup read its cursors before its `onInstalled` set their defaults.
- **Check:** Manual: timing dependent, not reduced to a minimal case. Repro: a module worker calls `browser.contextMenus.removeAll().then(...)` at top level, then posts on a native port the app answers at once. Expected: `removeAll` settles first. Actual: `onMessage` sometimes runs first.

### 89. Ports opened in two processes can share a channel id

- **Gap:** each web process numbers the ports it opens with its own counter, and the extension context keys its ports by that number alone. An extension page in a process of its own and the worker, or a content script and the worker, can draw the same number. A message sent to one of the two ports then reaches both, and a second native port with a number already open is not registered: its messages go to the first one, and once it is released the first one stops receiving. Chrome's port ids are unique.
- **Lilo:** each context names itself with a random tag in its channel's first message and in the high bits of its call ids, and Lilo stamps everything it sends on a port with the tag of the context it adopted the port for ([ipc.ts] `tag`, [GapEvents.swift] `owners`). A context drops what is not stamped with its tag. Lilo keeps a channel WebKit did not register, so the first one of its number stays registered (`twins`); on that first port, it skips the calls of another context and answers its first message with `collided`, and that context opens a new channel and sends its pending calls there again. It leaves the first one open: a page disconnecting a port of a number another port still holds makes WebKit forget its other ports, which then never disconnect. `chrome.runtime` ports drop what Lilo stamps ([message-answers.ts] `messagesOnce`).
- **Impact:** without it, intermittently and mostly under load, a page never heard its events and the worker's calls timed out. Still open: a `browser.runtime` port that shares the worker's channel number receives what Lilo sends the worker, and disconnects when the idle worker's channel closes.
- **Check:** Manual: timing dependent. Repro: stream WebKit's `Extensions` debug log and open extension pages in tabs (a process each) while the worker has its channel open, until a page's "Added 1 port for channel N in native world" repeats the worker's N. Expected: the page's messages reach its port. Actual: "Removed 1 port for channel N in native world" follows at once and neither port receives anything more.

### 91. A content script in a frame of an offscreen document cannot message

- **Gap:** WebKit finds a content script's sender by its tab (`WebExtensionContext::runtimeSendMessage` and `runtimeConnect`) and fails with "Tab not found" for a frame of an extension view that is no tab, such as an offscreen document's iframe. Chrome injects the content scripts there and delivers their messages with a sender that has no `tab`.
- **Lilo:** the content script sends its messages and opens its ports through the extension page at the top of its frame, which sends them as its own ([frame-messaging.ts]): each request carries a key Lilo writes into the extension's content-script compat and `_lilo/frame-key`, which the frame's page cannot read, so no web page messages as the content script. An extension whose `web_accessible_resources` cover either file gets no key, and keeps the gap.
- **Impact:** without Lilo's relay, ProWritingAid's offscreen prefetch frame logs the error at each worker start.
- **Check:** Manual: not reduced to a test. Repro: an offscreen document frames a web page whose all-frames content script calls `chrome.runtime.sendMessage`. Expected: the worker hears it. Actual: `runtime.lastError` "Tab not found".

## Pages and web views

### 5. A suspended web view crashes WebKit's in-flight `scripting.executeScript`

- **Gap:** if the app suspends a page (`_suspendPage:`) while an extension's `executeScript` on it runs, WebKit raises `The WKWebView is suspended` inside its own call and the app crashes; the app cannot cancel WebKit's in-flight calls. Chrome ends such a call with an error.
- **Lilo:** never suspends a page that closed itself: `_close` only for a page not frozen ([WKWebViewTab.swift], the `_close` call), and code holding a raw web view skips suspended ones ([EngineFreezer.swift] `CompositeFreezer.suspendedWebViews`).
- **Impact:** gap 6 cannot be fixed by suspending the page; any freeze of a page an extension scripts is a crash risk.
- **Check:** Manual: reproducing it crashes the test host. Repro: an extension loops `scripting.executeScript` on a tab; the page calls `window.close()` and the app calls `_suspendPage:` in `webViewDidClose`. Expected: the call rejects. Actual: `NSInternalInconsistencyException`.

### 6. A page that called `window.close()` still runs answers for a run loop turn

- **Gap:** WebKit delivers `webViewDidClose` a run loop turn after the API answers and port disconnects it already sent the page, so a closing page still runs a `storage` callback or an `onDisconnect`. Chrome runs nothing more.
- **Lilo:** once WebKit accepts `window.close()` (or Lilo's popup close calls `__liloPageClosing`), WebKit's API callbacks and promises settle no more and every WebKit event listener is removed ([augmentation-entry.ts], [chrome-compat.ts] `closePage`, `closingGuard`).
- **Impact:** without it, intermittent work in closing pages (Google Dictionary's storage callback, DuckDuckGo's `onDisconnect`).
- **Check:** Manual: timing dependent. Repro: `chrome.storage.local.get(null, () => console.log('ran')); window.close();` with the app closing the web view in `webViewDidClose`. Expected: no callback. Actual: it runs first.

### 23. A worker in a deferred-launch web view dies 5 s after load

- **Gap:** with `_setDelaysWebProcessLaunchUntilFirstLoad:` on, the background web view takes the keep-awake activity on the placeholder process, which drops it once the real process starts; WebKit then terminates the worker about 5 s after load while still reporting it loaded.
- **Lilo:** turns deferred launch off for the controller's configuration ([ProfileExtensionRegistry.swift]).
- **Check:** Manual. Repro: set the SPI to `YES` on the controller's web view configuration, load an extension, wait 10 s, message its worker. Expected: an answer. Actual: none, while the context reports the background loaded.

### 24. `removeAllUserScripts` drops extension content scripts for good

- **Gap:** `WKUserContentController.removeAllUserScripts()` also removes the content scripts WebKit installed for extensions, and WebKit never adds them back to a controller it already knows.
- **Lilo:** removes its own scripts one by one with `_removeUserScript:` ([WKEngineFactory.swift] `reinstallFilterUserScripts`, `prepareExtensionRegistry`); `removeAllUserScripts` is only the fallback without the SPI.
- **Check:** Manual. Repro: load an extension with a content script, call `removeAllUserScripts()`, add an app script back, reload. Expected: the content script runs. Actual: never again in that web view.

### 72. `navigator.credentials` forgets what a page set on it

- **Gap:** nothing keeps `navigator.credentials` once the page drops it; after a collection `navigator` hands out a new one without the page's properties. Chrome keeps one object for the page's life.
- **Lilo:** a document-start script keeps it on the navigator under a symbol ([WKEngineFactory.swift] `installUserScripts`).
- **Impact:** password managers hook passkeys by setting `navigator.credentials.get` and `create` from a `MAIN` world content script (1Password, Proton Pass, Keeper, NordPass); the hook went at the first collection.
- **Check:** `testNavigatorCredentialsForgetsWhatAPageSetOnIt`. Repro: `navigator.credentials.get = function hooked() {}`; allocate until a collection; read `navigator.credentials.get.name`. Expected: `hooked`. Actual: `get`.

### 75. An action popover that finishes closing after its context unloaded crashes

- **Gap:** WebKit's action popover calls back into its action when it finishes closing (`-[_WKWebExtensionActionPopover popoverDidClose:]`, then `WebExtensionAction::closePopup`), which dereferences the unloaded context: an extension unloaded while its popup shows or closes crashes the app once the popover goes. Chrome closes the popup with the extension.
- **Lilo:** closes the extension's popups without animation before it unloads the context ([ExtensionControllerDelegate.swift] `closeActionPopups`, [ProfileExtensionRegistry.swift] `unload`).
- **Impact:** a popup calling `runtime.reload()` or `management.uninstallSelf()`, or an extension disabled, updated or removed while its popup closes, crashed Lilo.
- **Check:** Manual: reproducing it crashes the test host (`testUnloadClosesTheExtensionsPopupFirst` covers the workaround). Repro: show an extension's action popover, close it, and unload its context before the close animation ends. Expected: nothing. Actual: a crash in `WebExtensionAction::closePopup`.

### 90. An action freed before its popup's color scheme check answers takes a write

- **Gap:** once the app's `presentActionPopup` delegate call completes, WebKit evaluates a script in the popup to read its color scheme, and the answer calls `WebExtensionAction::setPopupPopoverAppearance` on the action it captured without holding it. An action freed meanwhile (its context unloaded) takes a one-byte write into freed memory. The allocator trusts freed memory to be zeroed, so a later object allocated there finds a pointer of 1 among its fields, and the app crashes far from the cause, mostly in the share-extension lookup WebKit runs at each web process launch. Chrome has no such check.
- **Lilo:** evaluates a script of its own in the popup right after presenting it and holds the action until it answers, after WebKit's ([ExtensionControllerDelegate.swift] `presentActionPopup`).
- **Impact:** an extension unloaded, updated or disabled just as its popup opened corrupted the heap; the test host crashed in `-[EXConcreteExtension _initWithPKPlugin:identity:]` or `__NSDictionaryI` code, releasing the address 1, in about half the CI runs.
- **Check:** Manual: the corruption crashes only when the freed bytes are reused as a pointer. Repro: under lldb, break on `WebKit::WebExtensionAction::setPopupPopoverAppearance` and `-[WKWebExtensionAction dealloc]`, then run `testUnloadClosesTheExtensionsPopupFirst` without the workaround. Expected: the call comes before the dealloc. Actual: it comes after, its `this` 8 bytes past the freed action.

## Worker and JavaScript engine

### 14. `importScripts` runs pending promise callbacks

- **Gap:** WebKit runs promise callbacks while `importScripts` loads a script not loaded yet. Chrome runs them once the worker's top-level code is done.
- **Lilo:** the prelude skips the import of a script holding only whitespace, which runs nothing either way (`shared/empty-imports.ts`; the preparer lists them). Otherwise documented (COMPATIBILITY.md, "Background worker"). Lilo's wrapper imports the vendor worker before any of its code runs, so it adds no checkpoint; the worker's own imports cannot be loaded ahead without running them early.
- **Impact:** Tampermonkey clears its startup flag in `(async () => { await null; ... })()` and imports its empty `/test.js` before registering its listeners, which it would then refuse.
- **Check:** `testImportScriptsRunsPendingPromiseCallbacks`. Repro: `Promise.resolve().then(() => log('callback')); importScripts('a.js'); log('after');`. Expected: `imported, after, callback`. Actual: `callback, imported, after`.

### 15. Packaged `.wasm` is not served as `application/wasm`

- **Gap:** WebKit types resources through the system type registry, which gives `application/octet-stream`, so `WebAssembly.instantiateStreaming` rejects the extension's own modules.
- **Lilo:** `instantiateStreaming` and `compileStreaming` compile the extension's own responses from their bytes ([wasm-mime.ts]).
- **Impact:** without it, extensions fell back to slower compiles on every worker start (Dashlane).
- **Check:** `testPackagedWasmHasNoWasmMIMEType`. Repro: `fetch('module.wasm')` from a worker. Expected: `application/wasm`. Actual: `application/octet-stream`.

### 33. A WebSocket freezes the worker

- **Gap:** the worker runs on its process's main thread, where WebKit's WebSocket constructor waits for that same thread and never returns: the worker runs nothing more, and `loadBackgroundContent` never completes for one that opens a socket at startup.
- **Lilo:** the worker's `WebSocket` runs over URLSession ([web-socket.ts], [WebSocketBridgeHandler.swift]); differences in COMPATIBILITY.md, "Background worker".
- **Impact:** NeatDownloadManager never loaded; Keeper's worker stopped answering its content scripts.
- **Check:** `testWebSocketStallsTheWorkerLoad` (slow). Repro: a worker runs `new WebSocket('ws://127.0.0.1:10007/')` with nothing listening; call `loadBackgroundContent`. Expected: completion, then `error`. Actual: neither.

### 35. `in` rejected in an arrow function body inside a `for` initializer

- **Gap:** JavaScriptCore keeps the initializer's no-`in` rule inside an arrow function's body: `for (var f = (e) => { return 1 in e; }, i = 0; i < 1; i++);` throws `SyntaxError: Unexpected keyword 'in'`. V8 parses it, as the spec's [~In] restriction ends at the body.
- **Lilo:** none: the extension's own code does not parse.
- **Impact:** PreMiD's module worker, whose bundler emits such a loop, fails to load.
- **Check:** `testArrowFunctionInForInitializerRejectsIn` (JavaScriptCore alone).

### 36. No `SharedArrayBuffer` in extension contexts

- **Gap:** `SharedArrayBuffer` exists only in cross-origin isolated contexts, which extension contexts are not. Chrome gives extension pages and workers `SharedArrayBuffer` and `Atomics.wait` anyway. WebKit ignores the manifest's `cross_origin_embedder_policy` and `cross_origin_opener_policy` keys, which make Chrome's extension pages cross-origin isolated.
- **Lilo:** none: the engine decides which globals exist. WebKit serves extension resources itself, so Lilo cannot add the `Cross-Origin-Embedder-Policy` and `Cross-Origin-Opener-Policy` headers that would isolate a page, and JavaScriptCore's `useSharedArrayBuffer` option is process wide, so it would reach web pages too.
- **Impact:** SQLite's OPFS database needs it: Distill Web Monitor's offscreen document cannot open its store. Paperpile's worker loads `webidl-conversions`, which reads `SharedArrayBuffer.prototype` unguarded, and its error reporter logs the `ReferenceError`.
- **Check:** `testExtensionContextsLackSharedArrayBuffer`. Repro: a worker of an extension whose manifest sets `cross_origin_embedder_policy` to `require-corp` and `cross_origin_opener_policy` to `same-origin` reads `typeof SharedArrayBuffer` and `crossOriginIsolated`. Expected: `function`, as in Chrome. Actual: `undefined` and `false`.

### 74. An assignment across an `await` checks its binding before the `await`

- **Gap:** JavaScriptCore checks that a `let` or `const` binding is initialized when it starts an assignment, so `x = await f()` in a function called before `let x` runs throws `ReferenceError: Cannot access 'x' before initialization.` even though `let x` has run once the `await` is done. V8 checks when it stores the value, as the spec's PutValue does.
- **Lilo:** none: the extension's own code throws.
- **Impact:** Buyhatke's content script modules call such a function at their top level (`ot()` assigns `de`, declared further down), and fail.
- **Check:** `testAssignmentAcrossAnAwaitChecksItsBindingFirst` (JavaScriptCore alone). Repro: `(function () { (async () => { v = await 1; })().catch(console.log); let v; })()` logs the error; V8 logs nothing.

### 80. Storing a `CryptoKey` in IndexedDB stalls the service worker

- **Gap:** an MV3 worker that puts a `CryptoKey` in IndexedDB never sees the transaction complete, and nothing in the worker runs again (not even its timers). An extension page stores the same key at once, as Chrome's worker does.
- **Lilo:** no key reaches WebKit's clone. The worker's `crypto.subtle`, and its pages', keep each key's material: the material it imports, or an export of the key it generates, unwraps or derives (made extractable for that, while `extractable`, `exportKey` and `wrapKey` still answer as the caller asked). An IndexedDB `put`, `add` or cursor `update` stores a key given as the value or one of its fields as that material, and a read gives back a stand-in, a `CryptoKey` to `instanceof`, that `crypto.subtle` imports once on first use. Pages store and read keys the same way, so each reads what the other stored. The material sits unwrapped in the extension's database, as Chrome stores it; a key nested deeper throws `DataCloneError` in the worker, and a page stores it as WebKit does. WebKit itself cannot be worked around: it wraps a `CryptoKey` in every structured clone, and a worker waits for the wrap, its thread blocked, on its loader's main thread (`WorkerGlobalScope::serializeAndWrapCryptoKey`, `unwrapCryptoKey` alike), so a `postMessage` of a key from the worker still stalls it.
- **Impact:** Keeper stores its vault keys this way once signed in, and 2FAS Auth its signing keys during its first setup: without Lilo's storage, their worker stops, Keeper's popup loads forever and 2FAS's pairing page shows no QR code.
- **Check:** `crypto-key-storage.test.ts`, `crypto-key-storage-page.test.ts`, and `testPreparedWorkerStoresCryptoKeysInIndexedDB`, a worker storing and using keys as Keeper and 2FAS do. The stall itself is manual: the test host's worker stores a key without stalling where the app's stalls. Repro, in the app without Lilo's storage: in an MV3 worker, `crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])`, then `put` its `privateKey` in an object store and set the action title in `oncomplete` and in a 3 s `setTimeout`. Expected: a title. Actual: neither ever runs.

## Manifest and permissions

### 11. Permission names WebKit does not know reject; `privacy` is dropped

- **Gap:** `permissions.contains`, `request` and `remove` reject the whole call over one unknown name (`'tabGroups' is not a valid permission`), so an optional permission WebKit does not know can never be granted; `requestedPermissions` leaves out `privacy` though the manifest names it.
- **Lilo:** retries without unknown names and origins and answers for them from the manifest and the grants Lilo keeps ([chrome-leniency.ts] `permissionsPatches`). A `request` naming one goes to Lilo, which prompts once for the whole request, grants on the context what WebKit knows and keeps the rest per profile until uninstall ([PermissionsBridgeHandler.swift], `ExtensionStorage.AccessState.gapPermissions`). Lilo's `privacy` stub is installed when the manifest names it ([install-gap-apis.ts]).
- **Impact:** extensions checking optional features threw at startup (OneTab, Speechify, Stylus); Figma's code capture could not get its optional `pageCapture`.
- **Check:** `testPermissionsRejectNamesWebKitDoesNotKnow`, `testRequestedPermissionsDropPrivacy`. Repro: `browser.permissions.contains({ permissions: ['tabGroups'] })` rejects instead of resolving `false`.

### 16. Manifest entries Chrome accepts are rejected

- **Gap:** WebKit reports a manifest error for an empty `_execute_action` command, an MV3 `_execute_browser_action` or `_execute_page_action` command without a description (Chrome ignores them in MV3), a content script whose only `file://` patterns omit the host's slash (`file://*`, Chrome's `file:///*`), an empty `content_security_policy` object, a missing or empty `description`, an empty `content_scripts` list, shortcut keys with whitespace (`"Ctrl + Shift + Y"`), `web_accessible_resources` match patterns with schemes it does not grant (an entry naming only `extension_ids` included), and `externally_connectable` entries that are empty, use `<all_urls>`, a pattern with a port (its patterns have no port) or a wildcard on a public suffix of the list's private section (`*://*.netlify.app/*`), which Chrome accepts.
- **Lilo:** rewrites them at install ([ExtensionBackgroundPreparer.swift] `acceptAsChrome`): a blank description, trimmed keys, empty entries and MV3's MV2 action commands dropped, `file://` patterns with Chrome's empty host, `<all_urls>` becomes `*://*/*`, ports are removed (widening `:3000` to every port), `externally_connectable` wildcards on a public suffix of the bundled list are dropped, and `web_accessible_resources` keep only the patterns WebKit takes. User-visible side: COMPATIBILITY.md, "Extension manifest".
- **Impact:** without it, popular extensions failed to load (Dark Mode, Stylus, Proton VPN, Read Aloud, 7TV, AIPRM, axe DevTools, Norton Password Manager, Passbolt, Axure RP, Lightning Extension and others).
- **Check:** `testManifestEntriesChromeAcceptsAreRejected`. Repro: load a manifest with `"commands": { "_execute_action": {} }` (or each other entry) and read `WKWebExtension.errors`. Expected: none. Actual: one error each.

### 76. Host permissions match their path

- **Gap:** WebKit matches a `host_permissions` pattern's path, so `https://*/` grants the root page of each host only. Chrome ignores a host permission's path: `https://*/` reaches every page. WebKit then asks the app for each other page the extension reaches (gap 77).
- **Lilo:** rewrites the path of `host_permissions` and `optional_host_permissions` to `/*` at install ([ExtensionBackgroundPreparer.swift] `acceptAsChrome`). User-visible side: COMPATIBILITY.md, "Extension manifest".
- **Impact:** Okta Browser Plugin (`https://*/`) reached no page but the root, and Lilo asked for access to each page it touched, an OAuth URL with its query included.
- **Check:** `testHostPermissionsMatchTheirPath`. Repro: `WKWebExtension.MatchPattern(string: "https://*/").matches(URL(string: "https://example.com/a")!)`. Expected: true, as a host permission. Actual: false.

### 77. WebKit asks the app for pages an extension reaches without access

- **Gap:** when an extension reaches a page its grants do not cover but its manifest could (a `tabs` or `webNavigation` permission is enough), WebKit asks the controller delegate for the page's full URL (`promptForPermissionToAccess`), from `tabs`, `scripting`, `cookies` and a failed CORS fetch. Chrome never asks: the call fails, and only `permissions.request` prompts.
- **Lilo:** refuses without asking ([ExtensionControllerDelegate.swift] `promptForPermissionToAccess`). User-visible side: COMPATIBILITY.md, "permissions".
- **Check:** `testURLPermissionPromptIsRefusedWithoutAsking` (Lilo's side).

## tabs, scripting and webNavigation

### 1. Manifest content scripts run in pages already open

- **Gap:** WebKit injects an extension's manifest content scripts at once into every matching page already open when it is installed or enabled. Chrome waits for their next load.
- **Lilo:** none (COMPATIBILITY.md, "scripting and tabs").
- **Impact:** a content script asking its worker about its page can find no record of it (Avira Browser Safety).
- **Check:** `testContentScriptsRunInPagesAlreadyOpen`. Repro: open `https://example.com/`, then load an extension whose content script matches it and sets a `data-` attribute. Expected: an option to wait for the next load. Actual: the script runs at once.

### 8. `webNavigation.getAllFrames` and `getFrame` reject where Chrome resolves

- **Gap:** WebKit rejects with `Tab not found.`, `Frame not found.` or `Main frame not found.`, and lists the initial empty document with an empty URL before the first commit. Chrome resolves `null` (or `[]`), with no frame before the first commit.
- **Lilo:** both answer as Chrome, a discarded tab reporting its main frame ([webNavigation.ts] `webNavigationPatches`). The initial empty document stays.
- **Impact:** extensions probing tabs this way (ad blockers, page tools) threw at startup.
- **Check:** `testWebNavigationRejectsAMissingTab`; Contract `webNavigation on a tab before its first commit`. Repro: `browser.webNavigation.getAllFrames({ tabId: 987654 })` rejects with `Tab not found.`

### 9. Withheld tab `url` and `title` are empty strings

- **Gap:** WebKit reports them as `""` in returned tabs and tab events, and ignores the `tabs` permission (only host access reveals them). Chrome leaves them out, and reveals them with `tabs`.
- **Lilo:** for an extension that may not hold `tabs`, drops the empty `url` and `title` from tabs and windows methods and from `tabs.onCreated` and `onUpdated` ([tabs.ts] `tabURLPatches`, `windowURLPatches`, `tabURLStandIns`). With `tabs`, tabs and windows methods read them from Lilo, an empty tab as `chrome://newtab/` ([tabs.ts] `tabRevealedURLPatches`, `windowRevealedURLPatches`): one more call per result holding such a tab. Tab events keep WebKit's `""`.
- **Impact:** `new URL(tab.url)` throws where Chrome code checks for a missing url (Eye Dropper), or on Lilo's empty new tab (Easy Auto Refresh's worker).
- **Check:** `testTabsWithoutHostAccessReportEmptyURLAndTitle`. Repro: with no host permissions, `browser.tabs.query({})`. Expected: no `url` or `title`. Actual: `""`.

### 29. `scripting.registerContentScripts` throws without match patterns

- **Gap:** WebKit throws, so a `.catch()` on the call misses it. Chrome rejects (`Script with ID 'a' must specify at least one match.`).
- **Lilo:** rejects with Chrome's error ([chrome-leniency.ts] `scriptingPatches`).
- **Impact:** DotVPN threw registering a script for an empty domain list.
- **Check:** `testRegisterContentScriptsThrowsWithoutMatches`. Repro: `browser.scripting.registerContentScripts([{ id: 'a', js: ['a.js'], matches: [] }])` throws.

### 45. `scripting` reaches the extension's own pages

- **Gap:** WebKit injects into the extension's own pages. Chrome refuses: `Cannot access contents of the page. Extension manifest must request permission to access the respective host.` (the url instead, with `tabs`).
- **Lilo:** `executeScript`, `insertCSS` and `removeCSS` refuse a tab showing one of the extension's pages ([chrome-leniency.ts] `refuseOwnPages`), from the URLs the target documents name in the injection gap 50 already runs (`targetURLs`).
- **Impact:** Jetwriter's popup shown in a tab scripts the active tab, takes itself for a site and closes.
- **Check:** `testExtensionPagesAreScriptedAndFollowedAsWebPages`. Repro: from an extension page in a tab, `scripting.executeScript` on that tab. Expected: rejects. Actual: runs.

### 47. `webNavigation` follows an extension page's whole load

- **Gap:** WebKit reports every event of an extension page in a tab. Chrome reports only its `onCommitted`.
- **Lilo:** `onBeforeNavigate`, `onDOMContentLoaded`, `onCompleted` and `onErrorOccurred` skip extension pages ([webNavigation.ts] `webNavigationStandIns`).
- **Impact:** TikTok Pixel Helper scripted each loading page, its own included (gap 45).
- **Check:** `testExtensionPagesAreScriptedAndFollowedAsWebPages`. Repro: listen to `onDOMContentLoaded`, open an extension page in a tab. Expected: no event. Actual: one.

### 50. `scripting.executeScript` injects at once into a loading document

- **Gap:** WebKit injects at once, `injectImmediately` or not. Chrome waits for `document_idle` unless asked.
- **Lilo:** first runs an injection of its own that waits for `DOMContentLoaded`, then the extension's ([chrome-leniency.ts] `scriptingPatches.executeScript`): one more injection per call, which also checks gap 45.
- **Impact:** Cuponomia's script, injected as its install page starts loading, found no `document.body`.
- **Check:** `testExecuteScriptInjectsIntoALoadingDocumentAtOnce`. Repro: a `document_start` content script messages the worker, which runs `executeScript({ target: { tabId }, func: () => document.readyState })`. Expected: `interactive`. Actual: `loading`.

### 78. `tabs.captureVisibleTab` asks the tab for an empty snapshot

- **Gap:** when the tab takes its own snapshots (`takeSnapshot(using:for:)`), WebKit hands it a configuration whose rect is empty: it reads the bounds of no web view. The snapshot is empty and `captureVisibleTab` resolves `data:,`.
- **Lilo:** snapshots the web view's bounds for an empty rect ([TabExtensionAdapter.swift] `takeSnapshot`).
- **Impact:** FireShot's full-page capture failed (`Cannot create an ImageBitmap from an empty buffer`).
- **Check:** `testCaptureVisibleTabSnapshotsTheVisiblePage` (Lilo's side). Repro: implement `takeSnapshot(using:for:completionHandler:)` on a `WKWebExtensionTab` and call `chrome.tabs.captureVisibleTab()`. Expected: the configuration's rect is the page's. Actual: `CGRectZero`.

## contextMenus, alarms, action, i18n

### 10. `contextMenus` rejects the MV2 action contexts

- **Gap:** WebKit rejects an item with `browser_action` or `page_action` in `contexts`; Chrome takes them as `action`.
- **Lilo:** maps them to `action` ([chrome-leniency.ts] `withActionContexts`).
- **Impact:** Stylish created no menu.
- **Check:** `testContextMenusRejectMV2ActionContexts`.

### 25. `contextMenus` rejects URL patterns Chrome accepts

- **Gap:** WebKit's `create` and `update` throw on `documentUrlPatterns` and `targetUrlPatterns` with other schemes (`ftp:`, `urn:`, `data:`, `about:`, `blob:`, `javascript:`, `mailto:`, `ws:`, `chrome:`) or explicit ports (`ftp:` target patterns pass), and on a null `parentId`.
- **Lilo:** retries without each rejected pattern (a list left empty matches nothing) and leaves a null `parentId` out ([chrome-leniency.ts] `withChromeMenuProperties`). User-visible side: COMPATIBILITY.md, "contextMenus".
- **Impact:** BlockSite, ZeroOmega, Wayback Machine and BTRoblox threw at startup.
- **Check:** `testContextMenusRejectURLPatternsChromeAccepts`. Repro: `contextMenus.create({ id: 'a', title: 'A', documentUrlPatterns: ['ftp://*/*'] })` throws.

### 26. `contextMenus.create` throws without a title

- **Gap:** WebKit throws (`missing required keys: 'title'`). Chrome returns the id, creates nothing and sets `All menu items except for separators must have a title` as `lastError`.
- **Lilo:** answers as Chrome, logging an unchecked `lastError` without a callback ([chrome-leniency.ts] `contextMenusPatches.create`).
- **Check:** `testContextMenusRejectAMissingTitle`.

### 46. `menus.update` refuses an ancestor as the new parent

- **Gap:** WebKit checks the new parent against the item's ancestors (`isAncestorOrSelf` walks up instead of down), so it refuses the current parent: `Parent menu item cannot be itself or another ancestor.` Chrome refuses only a cycle.
- **Lilo:** retries without `parentId` ([chrome-leniency.ts] `contextMenusPatches.update`): a move up to a further ancestor is not applied.
- **Impact:** Stands logs an error for every child item when it refreshes its menu.
- **Check:** `testMenusUpdateRefusesTheCurrentParent`. Repro: create `parent` and `child` under it, then `menus.update('child', { parentId: 'parent' })` rejects.

### 27. `alarms.create` takes no callback and returns nothing

- **Gap:** WebKit takes a trailing callback for the alarm info and throws, and returns `undefined`. Chrome calls the callback, or returns a promise.
- **Lilo:** calls WebKit's without the callback, then the callback or a promise ([chrome-leniency.ts] `alarmsPatches`).
- **Impact:** Ace Script threw at startup.
- **Check:** `testAlarmsCreateTakesNoCallback`.

### 28. `action` methods reject a null `tabId`

- **Gap:** WebKit throws (`'tabId' is expected to be a number, but null was provided`); Chrome reads it as no tab.
- **Lilo:** passes no `tabId` instead ([chrome-leniency.ts] `actionPatches`).
- **Impact:** MyLOFT threw setting its global icon.
- **Check:** `testActionRejectsANullTabId`.

### 20. Badge colors are not exposed to the app

- **Gap:** `WKWebExtension.Action` exposes `badgeText` but no background or text color.
- **Lilo:** the color calls go through a Gap API ([ActionColorBridgeHandler.swift], `action` replaced in [chrome-compat.ts] with [action.ts]).
- **Check:** `testActionHasNoBadgeBackgroundColor`.

### 30. `i18n.getMessage` returns `undefined` off its namespace

- **Gap:** WebKit returns `undefined` unless called on `browser.i18n`. Chrome answers whatever its `this`.
- **Lilo:** calls it on its namespace ([chrome-leniency.ts] `i18nPatches`).
- **Impact:** Mate Translate got no text for its menus and pages.
- **Check:** `testGetMessageOffItsNamespaceReturnsUndefined`. Repro: `browser.i18n.getMessage.call(browser, '@@extension_id')` returns `undefined`.

## webRequest and cookies

### 12. `webRequest` filters with unknown types or schemes throw

- **Gap:** `addListener` throws on types like `webbundle` and patterns like `ws://*/*`. Chrome accepts them.
- **Lilo:** retries without the rejected type or pattern, and skips a filter left empty ([chrome-leniency.ts] `chromeEvent.addListener`).
- **Impact:** AdBlock, Adblock Plus and Privacy Badger threw at startup.
- **Check:** `testWebRequestFiltersRejectUnknownTypesAndSchemes`.

### 19. `cookies.onChanged` fires without its details

- **Gap:** WebKit fires it without `changeInfo` (`cookie`, `removed`, `cause`). Filed: webkit.org/b/267514.
- **Lilo:** diffs the cookie store and fires Chrome's `changeInfo` on an event that takes the listeners of WebKit's, through `chrome` and `browser` ([cookies.ts], [CookieChangeTracker.swift]). User-visible side: COMPATIBILITY.md, "cookies.onChanged".
- **Check:** Manual.

### 81. An extension's requests leave out `SameSite` cookies

- **Gap:** WebKit takes an extension page or worker for another site than the hosts it requests, so a `fetch` with `credentials: "include"` to a host the extension may access carries the cookies without `SameSite` only, never the `Lax` or `Strict` ones. Chrome sends an extension's request to a host it may access every cookie, as a first party.
- **Lilo:** such a `fetch` from an extension page or worker, or an extension page's asynchronous `XMLHttpRequest` with `withCredentials`, goes through Lilo, which sends it with the profile's cookies for the URL, each redirect included, and stores the cookies the response sets ([credentialed-fetch.ts], [CredentialedFetchBridgeHandler.swift]); a host the extension may not access, a same-origin request and `redirect: "manual"` stay WebKit's. User-visible side: COMPATIBILITY.md, "Background worker".
- **Impact:** ChatGPT's side panel reads its session from `chatgpt.com/api/auth/session` and showed "Log in to ChatGPT" to a signed-in user.
- **Check:** Manual (`testCredentialedFetchesCarryTheSiteCookiesAsInChrome` checks Lilo's answer). Repro: a tab of `http://127.0.0.1:<port>/` sets `lax=1; SameSite=Lax`; an extension with `host_permissions` for it fetches the same server with `credentials: "include"`. Expected: `Cookie: lax=1`. Actual: no cookie.

### 83. `cookies.set` checks a cookie not `secure` over http

- **Gap:** WebKit checks the host access of a cookie set without `secure: true` for its http URL, whatever the scheme of `url`: an extension whose host permissions name https only fails with `Host permissions are missing or not granted.` Chrome checks `url` itself and sets the cookie.
- **Lilo:** a `set` for an https URL with no `secure` that fails so is retried with `secure: true` ([cookies.ts] `setOverHTTPS`). User-visible side: COMPATIBILITY.md, "cookies".
- **Impact:** Microsoft Solitaire Collection's worker could not set its bing.com cookies.
- **Check:** `testCookiesSetChecksAccessOverHTTPForACookieNotSecure`. Repro: with `host_permissions: ["https://example.com/*"]`, `chrome.cookies.set({ url: 'https://example.com/', name: 'a', value: '1' })`. Expected: the cookie. Actual: the error; with `secure: true`, the cookie.

## declarativeNetRequest and content blockers

### 21. Content blocker regexes are a subset, ASCII only

- **Gap:** WebKit compiles each rule into one content blocker regex without alternation, `\w`, `{n}` or an inner `$`, rejects a whole list over one non-ASCII `url-filter` or domain, and cannot turn off one static rule. Chrome takes RE2 and IDN domains.
- **Lilo:** rewrites a `regexFilter` into that subset where it means the same, and keeps a rule it cannot express inert under its id, the original stored beside it for `get*Rules` ([dnr-rules.ts] `webKitRegex`, `webKitRule`, `toWebKit`). `webKitRule` also maps a redirect to an extension URL onto `extensionPath` and drops modified headers WebKit does not know. Filter lists skip non-ASCII domains and filters ([FilterListConverter.swift] `applyDomainOption`).
- **Check:** `testContentRuleListsRejectAlternationAndNonASCII`. Repro: compile `[{"trigger":{"url-filter":"a|b"},"action":{"type":"block"}}]`, or `"url-filter":"exämple"`. Expected: compiles. Actual: fails.

### 37. `updateEnabledRulesets` counts rulesets that do not change

- **Gap:** WebKit checks enabled count, minus ids to disable, plus ids to enable, in unsigned arithmetic: disabling a disabled ruleset with none enabled wraps around ("exceeds the limit"), as does enabling an enabled one among 50.
- **Lilo:** sends only the ids that change the enabled set ([dnr-rules.ts] `updateEnabledRulesets`).
- **Impact:** Google Analytics Debugger's ruleset toggles failed.
- **Check:** `testUpdateEnabledRulesetsCountsRulesetsThatDoNotChange`.

### 38. Concurrent rule updates remove from stale rule ids

- **Gap:** WebKit drops `removeRuleIds` it does not find among the last rules it loaded, which a pending update has not changed yet, so a second call removing and re-adding rule 1 fails ("Rule 1 does not have a unique ID"); concurrent updates also compile over each other.
- **Lilo:** runs a context's updates one after the other, merging calls made while one runs into a single update, since WebKit recompiles every rule on each ([dnr-rules.ts] `queued`, `updateRules`). It also keeps out of the update the rules removed and added back unchanged: WebKit deletes its rules database whenever removals empty it, which Dashlane's worker, replacing all its rules at each start, caused every minute.
- **Impact:** I don't care about cookies' rule updates failed.
- **Check:** `testConcurrentDynamicRuleUpdatesRemoveFromStaleRuleIds`.

### 39. Content blockers cap an extension at 150000 rules, one per request domain

- **Gap:** WebKit compiles all of an extension's rules into one content rule list of at most 150000 rules, expanding a rule into one per request domain and excluded request domain. Past the cap nothing applies and `updateEnabledRulesets` fails with "Failed to apply rules.". Chrome counts a rule once.
- **Lilo:** at preparation, keeps all static rulesets under 120000 WebKit rules (room for 30000 dynamic ones) by turning the most expanded rules inert, largest first ([dnr-rules.ts] `webKitStaticRulesets`, run by [ExtensionBackgroundPreparer.swift] `prepareStaticRulesets`). User-visible side: COMPATIBILITY.md, "declarativeNetRequest".
- **Impact:** SBlock (313000 domains in two rules), Adblock Ad Blocker Pro (299000 expanded rules).
- **Check:** `testRulesetOverWebKitsRuleCapDoesNotApply`.

### 40. Turning every ruleset off fails during the first compile

- **Gap:** with no rule left, WebKit deletes the compiled rule list file and fails when it does not exist yet, so disabling the last ruleset while its first compile runs fails with "Failed to apply rules.".
- **Lilo:** retries such an update every 250 ms for up to a minute while no dynamic or session rule exists ([dnr-rules.ts] `updateEnabledRulesets`).
- **Check:** `testTurningOffEveryRulesetFailsDuringTheFirstCompile`.

### 51. `declarativeNetRequest` rejects resource types Chrome knows

- **Gap:** WebKit rejects a rule naming `object`, `csp_report`, `webtransport` or `webbundle`, and the whole update with it.
- **Lilo:** drops them from the rule, which stays inert when none is left ([dnr-rules.ts] `NON_WEBKIT_TYPES`); WebKit never loads such requests anyway.
- **Impact:** AdGuard's session rules failed and its engine did not start.
- **Check:** `testDeclarativeNetRequestRejectsResourceTypesChromeKnows`.

### 73. `declarativeNetRequest` rejects empty exclusion lists

- **Gap:** a rule with an empty `excludedInitiatorDomains` or `excludedDomains` passes WebKit's validation and then fails the compile of every rule ("Unable to load declarativeNetRequest rules."); an empty `excludedRequestMethods` is rejected outright. Chrome takes all three empty, excluding nothing.
- **Lilo:** drops the empty lists from the rule WebKit gets, the original stored beside it for `get*Rules` ([dnr-rules.ts] `EXCLUSIONS`, `webKitRule`).
- **Impact:** I don't care about cookies' dynamic rules (`excludedInitiatorDomains: []` in most of its 1625 rules) all failed.
- **Check:** `testDeclarativeNetRequestRejectsEmptyExclusions`. Repro: in an MV3 worker, `chrome.declarativeNetRequest.updateSessionRules({ addRules: [{ id: 1, action: { type: 'block' }, condition: { urlFilter: 'a', excludedInitiatorDomains: [] } }] })`. Expected: resolves. Actual: rejects.

### 84. Session rules recompile every rule at each launch

- **Gap:** WebKit compiles an extension's session, dynamic and enabled static rules into one content rule list, and reuses the stored list only when the SHA-1 of the translated rules matches its last compile (`WebExtensionContext::compileDeclarativeNetRequestRules`, `LastLoadedDeclarativeNetRequestHash` in `WebExtensionContextCocoa.mm`). Session rules are kept in memory (`declarativeNetRequestSessionRulesStore`), so the compile at load (`loadDeclarativeNetRequestRules` in `WebExtensionContext::load`) misses the session rules the last run ended with and recompiles every rule, then the worker adding them back compiles again. The hash is read when a compile starts: an update made while the load compile runs compares with the previous run's hash and can reuse the previous run's list, and whichever finishes last is applied. Chrome indexes each static ruleset once.
- **Lilo:** none for the compiles themselves. It sends no rule update that changes nothing, merges the calls made while one runs (gap 38), and keeps its preparation stamp when it rewrites a ruleset for `updateStaticRules`, so an unchanged extension without session rules compiles nothing at launch.
- **Impact:** at every launch, AdGuard compiles its 54 MB list three times (at load, for its 722 session rules, then for its stealth rule), uBlock Origin Lite its 28 MB list and Tampermonkey its list once, for seconds of CPU each.
- **Check:** Manual. Repro: an MV3 extension with an enabled static ruleset whose worker adds one session rule at start; quit and relaunch twice. Expected: its `DeclarativeNetRequestContentRuleList.data` stays as is on the second relaunch. Actual: rewritten on every launch.

## storage

### 31. A storage read misses the writes still in flight

- **Gap:** a `get` issued before an earlier `set` completes does not see it. Chrome orders them.
- **Lilo:** while an area has writes in flight, its calls wait for them ([storage-area.ts] `ordered`). Content scripts and other contexts are not ordered (COMPATIBILITY.md, "storage").
- **Impact:** CS2 Trader read no defaults and created an alarm with a NaN period.
- **Check:** `testStorageReadsMissWritesInFlight`. Repro: `storage.local.set({ key: 1 }); storage.local.get('key')` gives `{}`.

### 34. `storage` stores values as JSON

- **Gap:** WebKit stores `Infinity` and `NaN` as `null` and a `Date` as its ISO string; Chrome drops the number and stores `{}`. WebKit also reads the enumerable keys `items` inherits and throws over a function among `items`' keys; Chrome reads the own keys only and leaves functions out.
- **Lilo:** leaves out an object's non-finite numbers and functions before WebKit gets the value, in one pass that copies only the objects it changes ([storage-area.ts] `asChromeStores`), and makes inherited keys non-enumerable while WebKit reads `items` (`ownKeysOnly`); a `Date` stays its ISO string (COMPATIBILITY.md, "storage").
- **Impact:** LetyShops' cache entry with `expired: Infinity` read back expired; Dark Mode - Night Eye, which adds its storage methods to `Object.prototype`, failed every `set`.
- **Check:** `testStorageStoresNonFiniteNumbersAsNull`, `testStorageRejectsAFunctionOfItemsAndStoresInheritedKeys`. Repro: in a worker, `Object.prototype.x = () => 1; chrome.storage.local.set({ a: 1 })` throws `The 'items[`x`]' value is invalid`.

### 41. `storage` sizes a replaced value outside Latin-1 twice

- **Gap:** WebKit sizes the stored total in characters but a replaced value holding a non-Latin-1 character in UTF-16 bytes, in unsigned arithmetic: replacing it with a smaller one can wrap around ("Exceeded storage quota").
- **Lilo:** a `set` failing so that would fit removes its keys and sets them again, restoring them on failure ([storage-area.ts] `setWithinQuota`): `onChanged` fires twice (COMPATIBILITY.md, "storage").
- **Impact:** Cuponomia's `set` calls failed the quota.
- **Check:** `testStorageSetMiscountsAValueOutsideLatin1`. Repro: `set({ key: '\u2019'.repeat(1000) })`, then `set({ key: 'x' })` rejects.

### 71. Deleting an extension's storage anywhere drops its writes in flight

- **Gap:** `WKWebExtensionController.removeData` posts a distributed notification naming the extension's unique identifier; every controller of every process holding a context with that identifier drops its storage store, and its `set` calls in flight fail (`Failed to calculate storage size`).
- **Lilo:** none. Lilo identifies an extension by its Chrome id, so an uninstall in one profile or another Lilo process (a test host) reaches the same extension in the others.
- **Impact:** lost writes in rare overlaps; parallel smoke runs of one extension can fail each other.
- **Check:** Manual: needs a second process or profile.

### 86. Storage answers settle together in one task

- **Gap:** WebKit can settle the promises of several storage calls in one task, so the second's callbacks run before the code awaiting the first has run on. Chrome settles each answer in a task of its own.
- **Lilo:** a page's or worker's storage answer that settles while another one's task has not ended waits for a task of its own, in the order they came ([storage-area.ts] `ownTask`).
- **Impact:** Markdown Reader's popup waits for a `storage.local.get()` before it mounts, and found its preferences, read just before, not loaded yet: it threw on every run of `make ext-smoke`.
- **Check:** `testStorageAnswersSettleInOneTask`. Repro: `let state = 'pending'; storage.local.get('a').then(async () => { await null; await null; state = 'done'; }); await storage.local.get('b'); state` is sometimes `pending`, always `done` in Chrome.

[WebKitGapTests.swift]: ../LiloTests/Extensions/WebKitGapTests.swift
[RealExtensionSmokeTests.swift]: ../LiloTests/Extensions/RealExtensionSmokeTests.swift
[action.ts]: ../Lilo/Extensions/bridge-src/src/augmentation/action.ts
[cookies.ts]: ../Lilo/Extensions/bridge-src/src/augmentation/cookies.ts
[runtime.ts]: ../Lilo/Extensions/bridge-src/src/augmentation/runtime.ts
[tabs.ts]: ../Lilo/Extensions/bridge-src/src/augmentation/tabs.ts
[webNavigation.ts]: ../Lilo/Extensions/bridge-src/src/augmentation/webNavigation.ts
[augmentation-entry.ts]: ../Lilo/Extensions/bridge-src/src/augmentation-entry.ts
[background-entry.ts]: ../Lilo/Extensions/bridge-src/src/background-entry.ts
[content-compat-entry.ts]: ../Lilo/Extensions/bridge-src/src/content-compat-entry.ts
[callbackify.ts]: ../Lilo/Extensions/bridge-src/src/shared/callbackify.ts
[chrome-compat.ts]: ../Lilo/Extensions/bridge-src/src/shared/chrome-compat.ts
[chrome-event.ts]: ../Lilo/Extensions/bridge-src/src/shared/chrome-event.ts
[chrome-leniency.ts]: ../Lilo/Extensions/bridge-src/src/shared/chrome-leniency.ts
[dnr-rules.ts]: ../Lilo/Extensions/bridge-src/src/shared/dnr-rules.ts
[frame-messaging.ts]: ../Lilo/Extensions/bridge-src/src/shared/frame-messaging.ts
[install-gap-apis.ts]: ../Lilo/Extensions/bridge-src/src/shared/install-gap-apis.ts
[ipc.ts]: ../Lilo/Extensions/bridge-src/src/shared/ipc.ts
[message-answers.ts]: ../Lilo/Extensions/bridge-src/src/shared/message-answers.ts
[static-compat.ts]: ../Lilo/Extensions/bridge-src/src/shared/static-compat.ts
[storage-area.ts]: ../Lilo/Extensions/bridge-src/src/shared/storage-area.ts
[wasm-mime.ts]: ../Lilo/Extensions/bridge-src/src/shared/wasm-mime.ts
[web-socket.ts]: ../Lilo/Extensions/bridge-src/src/shared/web-socket.ts
[worker-messages.ts]: ../Lilo/Extensions/bridge-src/src/shared/worker-messages.ts
[ExtensionBackgroundPreparer.swift]: ../Lilo/Extensions/Core/ExtensionBackgroundPreparer.swift
[ExtensionControllerDelegate.swift]: ../Lilo/Extensions/Core/ExtensionControllerDelegate.swift
[TabExtensionAdapter.swift]: ../Lilo/Extensions/Core/TabExtensionAdapter.swift
[CookieChangeTracker.swift]: ../Lilo/Extensions/Core/CookieChangeTracker.swift
[ExtensionLifecycle.swift]: ../Lilo/Extensions/Core/ExtensionLifecycle.swift
[ExtensionNativeMessaging.swift]: ../Lilo/Extensions/Core/ExtensionNativeMessaging.swift
[ProfileExtensionRegistry.swift]: ../Lilo/Extensions/Core/ProfileExtensionRegistry.swift
[ExtensionUserScripts.swift]: ../Lilo/Extensions/Core/ExtensionUserScripts.swift
[ActionColorBridgeHandler.swift]: ../Lilo/Extensions/GapAPI/ActionColorBridgeHandler.swift
[PermissionsBridgeHandler.swift]: ../Lilo/Extensions/GapAPI/PermissionsBridgeHandler.swift
[WebSocketBridgeHandler.swift]: ../Lilo/Extensions/GapAPI/WebSocketBridgeHandler.swift
[GapEvents.swift]: ../Lilo/Extensions/GapAPI/GapEvents.swift
[FilterListConverter.swift]: ../Lilo/ContentBlocker/FilterListConverter.swift
[EngineFreezer.swift]: ../Lilo/Engine/EngineFreezer.swift
[WKEngineFactory.swift]: ../Lilo/Engine/WKEngineFactory.swift
[WKWebViewTab.swift]: ../Lilo/Engine/WKWebViewTab.swift
[credentialed-fetch.ts]: ../Lilo/Extensions/bridge-src/src/shared/credentialed-fetch.ts
[CredentialedFetchBridgeHandler.swift]: ../Lilo/Extensions/GapAPI/CredentialedFetchBridgeHandler.swift
