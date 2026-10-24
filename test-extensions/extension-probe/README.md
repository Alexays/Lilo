# Lilo MV3 Compat Probe

A self-contained Chrome MV3 extension that measures **how much of the MV3 surface actually works in
Lilo on this machine**. It is a test fixture, not a product: load it, open the toolbar popup, read
the matrix.

## Load it

1. In Lilo, choose **Develop > Load Unpacked Extension...** (or **Load unpacked extension...** in the Extensions settings).
2. Pick this folder (`test-extensions/extension-probe`).
3. Click the toolbar action (puzzle/MV3 Probe): the popup renders the report. Same report at
   **Open options page** (opens in a tab) and in the **Lilo Probe** DevTools panel.

> Loading mutates the on-disk `manifest.json` (Lilo's background preparer rewrites `service_worker`
> to a generated wrapper) and may drop a `lilo-background-wrapper.js`. Those are build artifacts:
> re-checkout to restore the clean source. The committed source points the worker at `sw.js`.

## What it probes

| Area | How |
|------|-----|
| **Namespace presence** | `sw.js` reflects every `chrome.*` namespace/method that exists *in the service worker* (the matrix). |
| **Gap transport (SW to native)** | Calls `chrome.history.search` over the worker's channel to Lilo; persisted as a heartbeat so the popup reads SW state even if popup-SW messaging is flaky. |
| **`chrome.tabGroups` + `tabs.group/ungroup`** | `probeTabGroups()` groups two real window tabs, checks `query`/`get`/`update`/`tab.groupId`, then ungroups and asserts the empty group auto-removed. |
| **Native to extension pushed gap events** | SW listens for `tabGroups.onCreated/onUpdated/onRemoved` and `history.onVisited`; `probeTabGroups()` asserts the tabGroups lifecycle events were actually delivered (`eventsFired`). This exercises the worker channel's event delivery end to end. |
| **popup to SW messaging** | Three channels tested live: sync `sendResponse`, async `return true`, and a `port`. |
| **DNR** | Static block rule (`rules.json`) + dynamic + session rules; verifies a matching `fetch` is blocked. |
| **scripting / storage / cookies / identity** | Dynamic content-script (un)register; local/sync/session/managed RW; cookie count; `identity.getRedirectURL`. |
| **Content scripts** | ISOLATED (`content-isolated.js`, document_idle) + MAIN world (`content-main.js`, document_start) report back; proves world isolation, `getURL` scheme, i18n. |
| **Lifecycle** | `onInstalled`/`onStartup`, an `alarms` periodic alarm, a `contextMenus` item, the `omnibox` keyword `liloprobe`, the `Ctrl+Shift+Y` command, `externally_connectable`, `storage.onChanged`, `webNavigation`. |
| **DevTools / WAR / newer surfaces** | A DevTools panel; a web-accessible `war.js`; presence detection for `offscreen`/`userScripts`/`declarativeContent`. |

## Files

- `manifest.json` - MV3 manifest declaring the full surface.
- `sw.js` - service worker: all probing + persistence + native-pushed event capture.
- `probe-page.js` + `styles.css` - shared dashboard for `popup.html` / `options.html` / `devtools-panel.html`.
- `content-isolated.js` / `content-main.js` - the two content-script worlds.
- `devtools.html` / `devtools.js` / `devtools-panel.html` - DevTools panel.
- `rules.json` - DNR static ruleset. `war.js` - web-accessible resource. `_locales/en/messages.json` - i18n.

## Reading the report

Green pill = works. Red = absent/failed. Amber = partial/skipped. The header shows whether the
report came from a **live `getReport`** round-trip or the **storage.local fallback** (and why). The
native-to-extension pushed gap events section is the proof that the gap-event infra is delivering;
if `tabGroups.onCreated/onUpdated/onRemoved` show green there, the worker channel works on this
machine.
