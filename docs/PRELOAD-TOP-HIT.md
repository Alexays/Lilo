# Preload top hit

While you type in the command bar of a blank tab, Lilo can start loading the top result out of sight,
and Return then swaps that page into the tab instead of starting the load. Safari ships this as
"Preload Top Hit", Chrome as omnibox prerendering. In Lilo it is a setting, **Settings > General >
Search > Preload top hit**, on by default.

## Why

Some sites spend most of their load on the server. A signed-in video home page streams its `<head>`
in about 100 ms, then the server pauses 1.1 to 1.5 s while it builds the personalized feed, then
sends the body. Lilo's side of the load (HTML end to largest contentful paint, about 450 ms) is
already on par with an anonymous load. What is left is the server's pause, and only starting earlier
hides it: the time between the top hit becoming clear and Return is spent loading.

## How it works

1. The command bar store (`lilo-ui/src/stores/commandBar.svelte.ts`) checks the top row after each
   result update and posts `preloadTopHit { url }` when it changes, `url: ""` to drop it. Closing
   the bar drops it too, after the `navigate` that Return sent.
2. `SearchBridgeHandler` hands it to `TabManager.preloadTopHit`, which builds an engine with the
   tab's data store and profile (`WKEngineFactory.createTab`, warm pool first) and loads the URL.
   The engine has no delegate and no view in the window: the tab, the sidebar, history and the
   address bar see nothing of it.
3. Return sends the usual `navigate`. `TabManager.load(_:inTab:)` sees a preload for that URL and
   that tab, tears down the blank engine, adopts the preloaded one under the tab's id, points the
   tab's extension adapter at it, and `WKWebViewTab.replayPreloadedNavigation` tells the window
   what the page did so far (start, commit, finish), so the tab state, the zoom, the site's
   permissions and the history visit are what a normal load would have left.

## Decisions

- **Confidence rule.** Only a row whose page is what Return opens and that the user goes to often:
  the host autofill row or a history row, `http(s)`, whose address (scheme and `www.` aside) starts
  with what is typed, with at least 3 visits (an open tab or a bookmark counts as 2). Never a
  search, a suggestion, a typed URL history does not know, a tab to switch to, an action, or a page
  found by its title.
- **One at a time.** A new top hit tears the previous preload down before starting; the same top
  hit asked again is a no-op.
- **Cancellation.** The top hit changing to a row the rule rejects, the bar closing, and the target
  tab being discarded all drop the preload. Low Power Mode or a hot Mac never starts one.
- **Blank tabs only.** A swapped-in web view brings its own back list, so a tab already showing a
  page would lose its history. For such a tab Lilo only warms the connection to the top hit
  (`_preconnectToServer:`), which costs nothing visible.
- **Profile and data store.** The tab's own (`TabManager.dataStore`, `profileId`): cookies, cache
  and extensions are the ones the page will have in the tab. A private space preloads in its
  ephemeral store and, as for any page there, records no history.
- **History.** Nothing is recorded until Return: the visit is recorded by the replayed finish (or
  the real one if the page is still loading). A preload dropped without Return leaves no trace in
  history.
- **Extensions.** Content scripts run in the preloaded page as it loads, since they belong to the
  web view's configuration, as Chrome runs them in a prerendered page. Until Return the page is no
  extension tab: WebKit fires no `webNavigation` event for that load. Once swapped in, the tab keeps
  its id, so there is no `onTabReplaced`, and `tabs.onUpdated` reports its URL, title and status.
  `COMPATIBILITY.md` lists the difference.
- **A failed preload** (offline, refused) is not swapped in: Return loads the URL in the tab, which
  shows the error page as usual.
- **JavaScript blocked for the site** by an extension's content setting: no preload, since that
  setting is applied per navigation by the window, which the preload does not have.

## Cost

One extra page, in its own web content process, for as long as the bar is open with a confident
top hit: for a heavy site a few hundred MB and its CPU while it loads, and the page's bytes when the
guess is wrong. A preload never outlives the bar, and nothing runs when the setting is off.

## Benchmark

`make preload-bench` (`LiloTests/Tabs/TopHitPreloadBenchmarkTests.swift`) serves a page from
localhost the way the signed-in home page above loads (750 KB of head in 100 ms, a 1.3 s pause,
1.6 MB of body), then measures Return to the first frame showing the feed, through the same bridge
messages the command bar sends. The lead is the time the preload gets before Return: what typing
leaves after the top hit turns confident and the 100 ms search debounce, at 180 ms a keystroke.

| Run (median of 7) | Return to first paint | Return to LCP |
|---|---|---|
| No preload | 1450 ms | 1437 ms |
| Lead 150 ms (fast "yo" + Return) | 1300 ms | 1288 ms |
| Lead 440 ms ("y", then "ou" + Return) | 999 ms | 991 ms |
| Lead 980 ms ("yo", then "utube" + Return) | 460 ms | 450 ms |
| Lead 2000 ms (a pause before Return) | 24 ms | not reported |

WebKit reports no largest contentful paint for a page that loaded entirely while hidden, as the
spec asks; the first-paint column is the frame showing the feed, measured in the page.

A real signed-in page cannot run in a test without the user's cookies, so the numbers come from the
reproduction. The gain is the lead, capped by the server's time: once the preload has the whole
page, Return costs only the swap and a frame.

## Not done

- Tabs with a page (Cmd+L): would need the back list carried over, which WebKit has no API for.
- Return with Cmd (new tab) does not use the preload.
- Icons WebKit offered before Return are dropped; the tab shows the site's cached icon instead.
