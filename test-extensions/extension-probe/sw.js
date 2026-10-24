// Lilo MV3 compat probe, service worker context.
//
// Discovers what the engine supports in the SW (where MV3 extensions live), exercises the gap
// transport (SW to native via lilo-gap://), logs received messages (delivery proof), captures
// native-pushed gap events (tabGroups.on*, history.onVisited), and persists a full report +
// heartbeat to storage.local so the popup/options page can render the real SW state even if
// popup-SW runtime messaging is flaky.

const PERSIST_KEY = "liloProbe.sw";

function nowISO() { try { return new Date().toISOString(); } catch { return String(Date.now()); } }

async function readPersisted() {
  try { const v = await chrome.storage.local.get(PERSIST_KEY); return v[PERSIST_KEY] || {}; } catch { return {}; }
}
function deepMerge(a, b) {
  const out = { ...a };
  for (const [k, v] of Object.entries(b)) out[k] = v && typeof v === "object" && !Array.isArray(v) ? deepMerge(a[k] || {}, v) : v;
  return out;
}
async function patchPersisted(patch) {
  try { await chrome.storage.local.set({ [PERSIST_KEY]: deepMerge(await readPersisted(), patch) }); } catch { /* */ }
}
function withTimeout(promise, ms, onTimeout) {
  return Promise.race([Promise.resolve(promise).catch((e) => ({ error: String(e) })), new Promise((r) => setTimeout(() => r(onTimeout), ms))]);
}

// ---- gap-event capture: proves the native-to-SW pushed-event infra (tabGroups.on*, history.onVisited).
// These fire only if Lilo's channel to the worker delivers them end to end. ----
const capturedGapEvents = [];
function captureGapEvent(type, detail) {
  capturedGapEvents.push({ type, at: Date.now(), detail });
  if (capturedGapEvents.length > 60) capturedGapEvents.shift();
  patchPersisted({ gapEvents: capturedGapEvents.slice(-20).map((e) => ({ type: e.type, at: nowISO(), detail: e.detail })) });
}
try { chrome.tabGroups.onCreated.addListener((g) => captureGapEvent("tabGroups.onCreated", { id: g && g.id, title: g && g.title })); } catch (e) { /* */ }
try { chrome.tabGroups.onUpdated.addListener((g) => captureGapEvent("tabGroups.onUpdated", { id: g && g.id, title: g && g.title, color: g && g.color, collapsed: g && g.collapsed })); } catch (e) { /* */ }
try { chrome.tabGroups.onRemoved.addListener((g) => captureGapEvent("tabGroups.onRemoved", { id: g && g.id })); } catch (e) { /* */ }
try { chrome.history.onVisited.addListener((h) => captureGapEvent("history.onVisited", { url: h && h.url })); } catch (e) { /* */ }
try { chrome.history.onVisitRemoved.addListener((r) => captureGapEvent("history.onVisitRemoved", { allHistory: r && r.allHistory, count: r && r.urls && r.urls.length })); } catch (e) { /* */ }
try { chrome.bookmarks.onCreated.addListener((id, node) => captureGapEvent("bookmarks.onCreated", { id, title: node && node.title })); } catch (e) { /* */ }
try { chrome.bookmarks.onChanged.addListener((id, info) => captureGapEvent("bookmarks.onChanged", { id, info })); } catch (e) { /* */ }
try { chrome.bookmarks.onMoved.addListener((id, info) => captureGapEvent("bookmarks.onMoved", { id, info })); } catch (e) { /* */ }
try { chrome.bookmarks.onRemoved.addListener((id) => captureGapEvent("bookmarks.onRemoved", { id })); } catch (e) { /* */ }
try { chrome.downloads.onCreated.addListener((d) => captureGapEvent("downloads.onCreated", { id: d && d.id, state: d && d.state })); } catch (e) { /* */ }
try { chrome.downloads.onChanged.addListener((delta) => captureGapEvent("downloads.onChanged", { id: delta && delta.id, fields: delta ? Object.keys(delta).filter((k) => k !== "id") : [] })); } catch (e) { /* */ }
try { chrome.downloads.onErased.addListener((id) => captureGapEvent("downloads.onErased", { id })); } catch (e) { /* */ }
try { chrome.notifications.onClicked.addListener((id) => captureGapEvent("notifications.onClicked", { id })); } catch (e) { /* */ }
try { chrome.notifications.onButtonClicked.addListener((id, idx) => captureGapEvent("notifications.onButtonClicked", { id, idx })); } catch (e) { /* */ }
try { chrome.notifications.onClosed.addListener((id, byUser) => captureGapEvent("notifications.onClosed", { id, byUser })); } catch (e) { /* */ }
// Omnibox is user-driven (type "liloprobe <text>" in the address bar); capture so manual tests show.
try { chrome.omnibox.setDefaultSuggestion({ description: "Lilo probe: type anything, then Enter" }); } catch (e) { /* */ }
try { chrome.omnibox.onInputStarted.addListener(() => captureGapEvent("omnibox.onInputStarted", {})); } catch (e) { /* */ }
try {
  chrome.omnibox.onInputChanged.addListener((text, suggest) => {
    captureGapEvent("omnibox.onInputChanged", { text });
    patchPersisted({ omnibox: { lastInputChanged: { text, at: nowISO() } } });
    try { suggest([{ content: text + " probe", description: "Lilo probe suggestion for " + text }]); } catch (e2) { /* */ }
  });
} catch (e) { /* */ }
try {
  chrome.omnibox.onInputEntered.addListener((text, disposition) => {
    captureGapEvent("omnibox.onInputEntered", { text, disposition });
    patchPersisted({ omnibox: { lastInputEntered: { text, at: nowISO() } } });
  });
} catch (e) { /* */ }

function detectContext() {
  let kind = "unknown";
  try {
    if (typeof ServiceWorkerGlobalScope !== "undefined" && self instanceof ServiceWorkerGlobalScope) kind = "service-worker";
    else if (typeof window !== "undefined") kind = "window";
  } catch { /* */ }
  return {
    kind,
    hasWindow: typeof window !== "undefined",
    userAgent: (self.navigator && self.navigator.userAgent) || "n/a",
    at: nowISO()
  };
}

// ---- namespace presence (the headline: which chrome.* exist HERE in the SW) ----
const NAMESPACE_METHODS = {
  runtime: ["sendMessage", "connect", "getManifest", "getURL", "id", "onInstalled", "onStartup", "onMessage", "onConnect", "onMessageExternal", "onConnectExternal", "getPlatformInfo", "lastError"],
  storage: ["local", "sync", "session", "managed", "onChanged"],
  tabs: ["query", "get", "create", "update", "remove", "sendMessage", "group", "ungroup", "captureVisibleTab", "discard", "onUpdated", "onActivated"],
  tabGroups: ["get", "query", "update", "move", "onCreated", "onUpdated", "onMoved", "onRemoved"],
  scripting: ["executeScript", "insertCSS", "removeCSS", "registerContentScripts", "updateContentScripts", "getRegisteredContentScripts"],
  declarativeNetRequest: ["getEnabledRulesets", "updateEnabledRulesets", "updateDynamicRules", "getDynamicRules", "updateSessionRules", "getMatchedRules", "setExtensionActionOptions"],
  alarms: ["create", "get", "getAll", "clear", "onAlarm"],
  cookies: ["get", "getAll", "set", "remove", "onChanged"],
  contextMenus: ["create", "update", "remove", "onClicked"],
  i18n: ["getMessage", "getUILanguage", "getAcceptLanguages"],
  permissions: ["request", "remove", "contains", "getAll", "onAdded", "onRemoved"],
  windows: ["get", "getAll", "create", "update", "remove", "onCreated", "onFocusChanged"],
  action: ["setBadgeText", "setBadgeBackgroundColor", "setBadgeTextColor", "getBadgeBackgroundColor", "setIcon", "setTitle", "setPopup", "getUserSettings", "openPopup", "onClicked"],
  commands: ["getAll", "onCommand"],
  webNavigation: ["onCommitted", "onCompleted", "getAllFrames", "onHistoryStateUpdated"],
  webRequest: ["onBeforeRequest", "onBeforeSendHeaders", "onCompleted"],
  omnibox: ["onInputChanged", "onInputEntered", "setDefaultSuggestion"],
  notifications: ["create", "clear", "getAll", "update", "getPermissionLevel", "onClicked", "onButtonClicked"],
  sessions: ["getRecentlyClosed", "restore", "getDevices"],
  topSites: ["get"],
  idle: ["queryState", "setDetectionInterval", "onStateChanged"],
  // Newer or less common MV3 surfaces: presence only.
  offscreen: ["createDocument", "closeDocument", "hasDocument"],
  userScripts: ["register", "getScripts", "configureWorld"],
  declarativeContent: ["onPageChanged"],
  devtools: ["inspectedWindow", "panels", "network"],
  // Lilo "gap" APIs (Chrome defines these in the SW; Lilo bridges them):
  history: ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll", "onVisited"],
  bookmarks: ["getTree", "get", "getSubTree", "create", "search", "remove", "onCreated"],
  downloads: ["download", "search", "cancel", "erase", "open", "show", "removeFile", "getFileIcon", "showDefaultFolder", "onChanged"],
  identity: ["getAuthToken", "removeCachedAuthToken", "launchWebAuthFlow", "getRedirectURL"],
  management: ["getSelf", "getAll", "get", "setEnabled", "getPermissionWarningsByManifest", "onInstalled", "onEnabled"],
  sidePanel: ["open", "setOptions", "getOptions", "setPanelBehavior"]
};

function probeNamespaces() {
  const out = {};
  for (const [ns, methods] of Object.entries(NAMESPACE_METHODS)) {
    const obj = chrome[ns];
    const present = !!obj;
    const missing = [];
    if (present) {
      // `in`, as runtime.lastError reads undefined without an error.
      for (const m of methods) if (!(m in obj)) missing.push(m);
    }
    out[ns] = { present, total: methods.length, missing };
  }
  return out;
}

// ---- lifecycle instrumentation (persisted; surfaced in the report) ----
chrome.runtime.onInstalled.addListener((details) => {
  patchPersisted({ lifecycle: { onInstalled: { reason: details.reason, at: nowISO() } } });
  setupAlarms();
  setupContextMenus();
});
chrome.runtime.onStartup.addListener(() => patchPersisted({ lifecycle: { onStartup: { at: nowISO() } } }));

function setupAlarms() {
  try {
    chrome.alarms.create("liloProbeAlarm", { periodInMinutes: 0.5 });
    patchPersisted({ alarms: { created: nowISO() } });
  } catch (e) { patchPersisted({ alarms: { createError: String(e) } }); }
}
try {
  chrome.alarms.onAlarm.addListener((alarm) => {
    patchPersisted({ alarms: { lastFired: nowISO(), name: alarm.name } });
    // Refresh the report + heartbeat on each alarm so the popup reads a fresh SW state w/o messaging.
    recordGapHeartbeat();
    buildFullReport().then((r) => patchPersisted({ fullReport: r })).catch(() => {});
  });
} catch (e) { /* */ }

function setupContextMenus() {
  try {
    chrome.contextMenus.removeAll(() => {
      chrome.contextMenus.create({ id: "liloProbeMenu", title: "Lilo probe context item", contexts: ["all"] });
      patchPersisted({ contextMenus: { created: nowISO() } });
    });
  } catch (e) { patchPersisted({ contextMenus: { createError: String(e) } }); }
}
try { chrome.contextMenus.onClicked.addListener((info) => patchPersisted({ contextMenus: { lastClick: { menuItemId: info.menuItemId, at: nowISO() } } })); } catch (e) { /* */ }

// commands (Ctrl+Shift+Y)
try { chrome.commands.onCommand.addListener((command) => patchPersisted({ commands: { lastCommand: { command, at: nowISO() } } })); } catch (e) { /* */ }

// messaging: content reports + inbox (delivery proof) + sync/async sendResponse + getReport channel.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "contentReport") {
    patchPersisted({ contentScripts: { lastReport: msg.data, at: nowISO() } });
    return; // no response
  }
  if (msg && msg.type === "inbox") {
    patchPersisted({ inbox: { lastSync: { payload: msg.payload, at: nowISO() } } });
    sendResponse({ ok: true, channel: "sync", echoedAt: nowISO() });
    return; // synchronous sendResponse
  }
  if (msg && msg.type === "inboxAsync") {
    patchPersisted({ inbox: { lastAsync: { payload: msg.payload, at: nowISO() } } });
    setTimeout(() => sendResponse({ ok: true, channel: "async", at: nowISO() }), 10);
    return true; // keep the channel open for the async sendResponse
  }
  if (msg && msg.type === "getReport") {
    buildFullReport().then(sendResponse);
    return true;
  }
});

try {
  chrome.runtime.onMessageExternal.addListener((msg, sender, sendResponse) => {
    patchPersisted({ external: { lastExternal: { origin: sender.origin || sender.url || "?", at: nowISO() } } });
    sendResponse({ ok: true, from: "sw" });
  });
} catch (e) { /* */ }

try {
  chrome.runtime.onConnect.addListener((port) => {
    patchPersisted({ inbox: { lastPort: { name: port.name, at: nowISO() } } });
    port.onMessage.addListener((m) => { try { port.postMessage({ echo: m, at: nowISO() }); } catch { /* */ } });
  });
} catch (e) { /* */ }

try { chrome.storage.onChanged.addListener((changes, area) => { if (area !== "local") patchPersisted({ storageEvents: { lastChange: { area, keys: Object.keys(changes), at: nowISO() } } }); }); } catch (e) { /* */ }

try {
  chrome.webNavigation.onCompleted.addListener((d) => { if (d.frameId === 0) patchPersisted({ webNavigation: { lastCompleted: { url: d.url, at: nowISO() } } }); });
} catch (e) { /* */ }

// ---- async probes ----
async function probeDNR() {
  const out = {};
  try { out.enabledRulesets = await chrome.declarativeNetRequest.getEnabledRulesets(); } catch (e) { out.enabledRulesetsError = String(e); }
  try {
    out.dynamicRuleCount = (await chrome.declarativeNetRequest.getDynamicRules()).length;
    await chrome.declarativeNetRequest.updateDynamicRules({ addRules: [{ id: 1001, priority: 1, action: { type: "block" }, condition: { urlFilter: "lilo-dyn-probe", resourceTypes: ["xmlhttprequest"] } }], removeRuleIds: [1001] });
    out.updateDynamicRules = "ok";
  } catch (e) { out.updateDynamicRules = "error: " + String(e); }
  try { await chrome.declarativeNetRequest.updateSessionRules({ addRules: [{ id: 2001, priority: 1, action: { type: "block" }, condition: { urlFilter: "lilo-sess-probe", resourceTypes: ["xmlhttprequest"] } }], removeRuleIds: [2001] }); out.updateSessionRules = "ok"; } catch (e) { out.updateSessionRules = "error: " + String(e); }
  try { const r = await fetch("https://example.com/lilo-dnr-block-probe-" + Date.now(), { cache: "no-store" }); out.staticBlockWorked = false; out.fetchStatus = r.status; } catch (e) { out.staticBlockWorked = true; out.fetchError = String(e); }
  try { out.matchedRules = await chrome.declarativeNetRequest.getMatchedRules({}); } catch (e) { out.matchedRulesError = String(e); }
  return out;
}
async function probeScripting() {
  const out = {};
  try {
    await chrome.scripting.registerContentScripts([{ id: "lilo-probe-dynamic", matches: ["https://example.com/*"], js: ["content-isolated.js"], runAt: "document_idle" }]);
    out.registerContentScripts = (await chrome.scripting.getRegisteredContentScripts()).some((s) => s.id === "lilo-probe-dynamic") ? "ok" : "registered-but-not-listed";
    await chrome.scripting.unregisterContentScripts({ ids: ["lilo-probe-dynamic"] });
  } catch (e) { out.registerContentScripts = "error: " + String(e); }
  return out;
}
async function probeStorage() {
  const out = {};
  for (const area of ["local", "sync", "session"]) {
    try { await chrome.storage[area].set({ liloProbeRW: "v" }); out[area] = (await chrome.storage[area].get("liloProbeRW")).liloProbeRW === "v" ? "ok" : "mismatch"; } catch (e) { out[area] = "error: " + String(e); }
  }
  try { out.sessionAccessLevel = typeof chrome.storage.session.setAccessLevel; } catch { /* */ }
  try { out.managed = await chrome.storage.managed.get(null); } catch (e) { out.managedError = String(e); }
  return out;
}
async function probeCookies() { try { return { totalCount: (await chrome.cookies.getAll({})).length }; } catch (e) { return { error: String(e) }; } }
async function probeIdentityRedirect() { try { return { redirectURL: chrome.identity.getRedirectURL() }; } catch (e) { return { error: String(e) }; } }

// tabGroups + tabs.group/ungroup: functional round-trip against real window tabs (no tab churn:
// groups existing tabs, verifies, then ungroups to leave the window as it was), and confirms the
// native-to-SW lifecycle events were delivered.
async function probeTabGroups() {
  const out = {};
  try {
    if (!chrome.tabGroups || !chrome.tabs) return { available: false };
    // tabs.group is patched once WebKit has injected chrome.tabs, which can lag the SW prelude: give
    // it up to ~1s to appear before concluding it's absent (avoids a false "available:false" on a
    // freshly-woken worker).
    for (let i = 0; i < 20 && typeof chrome.tabs.group !== "function"; i++) await new Promise((r) => setTimeout(r, 50));
    if (typeof chrome.tabs.group !== "function") return { available: false, reason: "tabs.group not patched in time" };
    out.available = true;
    const evStart = Date.now();
    const tabs = await chrome.tabs.query({ currentWindow: true });
    out.windowTabCount = tabs.length;
    const targets = tabs.filter((t) => !t.pinned).slice(0, 2).map((t) => t.id);
    if (targets.length === 0) { out.skipped = "no groupable tabs in window"; return out; }
    out.targetTabIds = targets;
    const groupId = await chrome.tabs.group({ tabIds: targets });
    out.groupId = groupId;
    out.groupIdIsNumber = typeof groupId === "number";
    const afterGroup = await chrome.tabs.query({ currentWindow: true });
    out.tabGroupIdAfterGroup = afterGroup.filter((t) => targets.includes(t.id)).map((t) => t.groupId);
    const groups = await chrome.tabGroups.query({});
    out.queryCount = groups.length;
    out.queriedGroupFound = groups.some((g) => g.id === groupId);
    const updated = await chrome.tabGroups.update(groupId, { title: "LiloProbe", color: "cyan", collapsed: false });
    out.updated = updated ? { title: updated.title, color: updated.color, collapsed: updated.collapsed, windowId: updated.windowId } : null;
    const got = await chrome.tabGroups.get(groupId);
    out.got = got ? { id: got.id, title: got.title, color: got.color } : null;
    await chrome.tabs.ungroup(targets);
    const afterUngroup = await chrome.tabs.query({ currentWindow: true });
    out.tabGroupIdAfterUngroup = afterUngroup.filter((t) => targets.includes(t.id)).map((t) => t.groupId);
    out.groupRemovedOnEmpty = !(await chrome.tabGroups.query({})).some((g) => g.id === groupId);
    // Give the native-to-SW push a moment, then confirm the lifecycle events were actually delivered.
    await new Promise((r) => setTimeout(r, 1500));
    const fired = capturedGapEvents.filter((e) => e.at >= evStart).map((e) => e.type);
    out.eventsFired = fired;
    out.onCreatedFired = fired.includes("tabGroups.onCreated");
    out.onUpdatedFired = fired.includes("tabGroups.onUpdated");
    out.onRemovedFired = fired.includes("tabGroups.onRemoved");
  } catch (e) { out.error = String(e); }
  return out;
}

// bookmarks events: functional round-trip (create, update, remove), asserting the on* events fired.
async function probeBookmarks() {
  const out = {};
  try {
    if (!chrome.bookmarks || typeof chrome.bookmarks.create !== "function") return { available: false };
    out.available = true;
    const evStart = Date.now();
    const node = await chrome.bookmarks.create({ title: "LiloProbeBM", url: "https://example.com/lilo-probe-bm" });
    out.created = node ? { id: node.id, title: node.title } : null;
    if (node && node.id) {
      const updated = await chrome.bookmarks.update(node.id, { title: "LiloProbeBM2" });
      out.updated = updated ? { title: updated.title } : null;
      await chrome.bookmarks.remove(node.id);
      out.removed = true;
    }
    await new Promise((r) => setTimeout(r, 1500));
    const fired = capturedGapEvents.filter((e) => e.at >= evStart).map((e) => e.type);
    out.onCreatedFired = fired.includes("bookmarks.onCreated");
    out.onChangedFired = fired.includes("bookmarks.onChanged");
    out.onRemovedFired = fired.includes("bookmarks.onRemoved");
  } catch (e) { out.error = String(e); }
  return out;
}

// history.onVisitRemoved: addUrl then deleteUrl, assert the removal event fired.
async function probeHistoryRemoval() {
  const out = {};
  try {
    if (!chrome.history || typeof chrome.history.deleteUrl !== "function") return { available: false };
    out.available = true;
    const evStart = Date.now();
    const u = "https://example.com/lilo-probe-history-" + Date.now();
    try { await chrome.history.addUrl({ url: u }); } catch (e) { /* */ }
    await chrome.history.deleteUrl({ url: u });
    await new Promise((r) => setTimeout(r, 1200));
    out.onVisitRemovedFired = capturedGapEvents.filter((e) => e.at >= evStart).some((e) => e.type === "history.onVisitRemoved");
  } catch (e) { out.error = String(e); }
  return out;
}

// sessions: getRecentlyClosed shape check (read-only, no tab churn); getDevices should be empty.
async function probeSessions() {
  const out = {};
  try {
    if (!chrome.sessions || typeof chrome.sessions.getRecentlyClosed !== "function") return { available: false };
    out.available = true;
    const closed = await chrome.sessions.getRecentlyClosed({ maxResults: 5 });
    out.recentlyClosedCount = Array.isArray(closed) ? closed.length : null;
    out.firstHasTabOrWindow = Array.isArray(closed) && closed.length > 0 ? !!(closed[0].tab || closed[0].window) : null;
    out.restoreIsFunction = typeof chrome.sessions.restore === "function";
    try { out.deviceCount = (await chrome.sessions.getDevices()).length; } catch (e) { out.devicesError = String(e); }
  } catch (e) { out.error = String(e); }
  return out;
}

// topSites: get() returns [{url,title}] ranked by visit count.
async function probeTopSites() {
  const out = {};
  try {
    if (!chrome.topSites || typeof chrome.topSites.get !== "function") return { available: false };
    out.available = true;
    const sites = await chrome.topSites.get();
    out.count = Array.isArray(sites) ? sites.length : null;
    out.firstHasUrl = Array.isArray(sites) && sites.length > 0 ? typeof sites[0].url === "string" : null;
  } catch (e) { out.error = String(e); }
  return out;
}

// notifications: create with two buttons + getPermissionLevel. Button taps are user-driven (captured
// via onButtonClicked above); here we prove create-with-buttons resolves and permission reports.
async function probeNotificationButtons() {
  const out = {};
  try {
    if (!chrome.notifications || typeof chrome.notifications.create !== "function") return { available: false };
    out.available = true;
    try { out.permissionLevel = await new Promise((r) => chrome.notifications.getPermissionLevel(r)); } catch (e) { out.permissionLevelError = String(e); }
    const id = await new Promise((resolve) => chrome.notifications.create("liloProbeButtons", {
      type: "basic", iconUrl: "styles.css", title: "Lilo probe", message: "Tap a button",
      buttons: [{ title: "One" }, { title: "Two" }]
    }, resolve));
    out.created = id === "liloProbeButtons";
    const all = await new Promise((resolve) => chrome.notifications.getAll(resolve));
    out.getAllHasButtons = !!(all && all.liloProbeButtons && Array.isArray(all.liloProbeButtons.buttons) && all.liloProbeButtons.buttons.length === 2);
    await new Promise((resolve) => chrome.notifications.clear("liloProbeButtons", resolve));
  } catch (e) { out.error = String(e); }
  return out;
}

// action.openPopup: presence only (opening a popup from a probe would steal focus).
function probeActionOpenPopup() {
  try { return { available: !!chrome.action, openPopupIsFunction: typeof (chrome.action && chrome.action.openPopup) === "function" }; }
  catch (e) { return { error: String(e) }; }
}

// Gap transport: call a gap API from the SW (chrome.history.search) over Lilo's worker channel.
async function probeSWGapCall() {
  try {
    if (!chrome.history || typeof chrome.history.search !== "function") return { available: false };
    const p = chrome.history.search({ text: "", maxResults: 1 });
    const items = p && typeof p.then === "function" ? await p
      : await new Promise((res, rej) => { try { chrome.history.search({ text: "", maxResults: 1 }, (r) => { const e = chrome.runtime.lastError; e ? rej(new Error(e.message)) : res(r); }); } catch (err) { rej(err); } });
    return { available: true, worked: Array.isArray(items), sample: Array.isArray(items) ? items.length : null };
  } catch (e) { return { available: true, worked: false, error: String(e) }; }
}
async function recordGapHeartbeat() {
  const gapCall = await withTimeout(probeSWGapCall(), 2500, { available: true, worked: false, timedOut: true });
  await patchPersisted({ gapHeartbeat: { at: nowISO(), gapCall } });
}

async function buildFullReport() {
  const persisted = await readPersisted();
  const [dnr, scripting, storage, cookies, identity, tabGroups, bookmarks, historyRemoval, sessions, topSites, notificationButtons, gapCall] = await Promise.all([
    probeDNR(), probeScripting(), probeStorage(), probeCookies(), probeIdentityRedirect(),
    withTimeout(probeTabGroups(), 4000, { available: true, timedOut: true }),
    withTimeout(probeBookmarks(), 4000, { available: true, timedOut: true }),
    withTimeout(probeHistoryRemoval(), 3000, { available: true, timedOut: true }),
    withTimeout(probeSessions(), 3000, { available: true, timedOut: true }),
    withTimeout(probeTopSites(), 3000, { available: true, timedOut: true }),
    withTimeout(probeNotificationButtons(), 3000, { available: true, timedOut: true }),
    withTimeout(probeSWGapCall(), 2500, { available: true, worked: false, timedOut: true }),
  ]);
  return {
    context: detectContext(), generatedAt: nowISO(), namespaces: probeNamespaces(),
    staticCompatLoaded: typeof chrome?.tabs?.TabStatus === "object",
    gapCall, dnr, scripting, storage, cookies, identity, tabGroups, bookmarks, historyRemoval,
    sessions, topSites, notificationButtons, actionOpenPopup: probeActionOpenPopup(),
    lifecycle: persisted.lifecycle || {}, alarms: persisted.alarms || {}, contextMenus: persisted.contextMenus || {},
    omnibox: persisted.omnibox || {}, commands: persisted.commands || {}, inbox: persisted.inbox || {},
    external: persisted.external || {}, contentScripts: persisted.contentScripts || {}, storageEvents: persisted.storageEvents || {},
    webNavigation: persisted.webNavigation || {}, gapEvents: persisted.gapEvents || [],
  };
}

// Startup: arm timers, take a heartbeat, and persist a fresh full report so the popup has data even
// before any messaging happens.
setupAlarms();
setupContextMenus();
recordGapHeartbeat();
buildFullReport().then((r) => patchPersisted({ lastStartupReport: { at: r.generatedAt }, fullReport: r }));
