// Shared dashboard for popup.html / options.html / devtools-panel.html.
//
// The SW does the actual probing and persists a `fullReport` to storage.local. This page prefers a
// live `getReport` round-trip (which also tests popup-to-SW messaging) but falls back to the persisted
// report so the matrix reflects the real SW state even when messaging is flaky. It additionally runs
// three popup-to-SW channel tests (sync sendResponse / async return-true / port) to pin down messaging.

const PERSIST_KEY = "liloProbe.sw";
const $ = (id) => document.getElementById(id);

function esc(s) { return String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c])); }
function pill(ok, label) {
  const cls = ok === true ? "ok" : ok === false ? "bad" : "warn";
  return `<span class="pill ${cls}">${esc(label)}</span>`;
}

async function readPersisted() {
  try { const v = await chrome.storage.local.get(PERSIST_KEY); return v[PERSIST_KEY] || {}; } catch { return {}; }
}

function sendMessageWithTimeout(msg, ms) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => { if (!done) { done = true; resolve({ __timeout: true }); } }, ms);
    try {
      chrome.runtime.sendMessage(msg, (resp) => {
        if (done) return;
        done = true; clearTimeout(t);
        const err = chrome.runtime.lastError;
        resolve(err ? { __error: err.message } : (resp ?? { __empty: true }));
      });
    } catch (e) { if (!done) { done = true; clearTimeout(t); resolve({ __error: String(e) }); } }
  });
}

function testPort() {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => { if (!done) { done = true; resolve({ __timeout: true }); } }, 6000);
    try {
      const port = chrome.runtime.connect({ name: "probe-port" });
      port.onMessage.addListener((m) => { if (!done) { done = true; clearTimeout(t); resolve(m); } });
      port.postMessage({ ping: "port" });
    } catch (e) { if (!done) { done = true; clearTimeout(t); resolve({ __error: String(e) }); } }
  });
}

function channelOk(r) { return !!(r && !r.__timeout && !r.__error && !r.__empty); }

async function getReport() {
  const resp = await sendMessageWithTimeout({ type: "getReport" }, 8000);
  if (resp && resp.namespaces) return { report: resp, source: "getReport (live messaging)", messagingResult: "ok" };
  const persisted = await readPersisted();
  const why = resp.__timeout ? "timeout" : resp.__error ? ("error: " + resp.__error) : resp.__empty ? "empty response" : "no report";
  return { report: persisted.fullReport || null, source: "storage.local fallback (" + why + ")", messagingResult: why };
}

function renderNamespaces(ns) {
  if (!ns) return "<p>no namespace data</p>";
  const rows = Object.entries(ns).map(([name, info]) => {
    const ok = info.present && info.missing.length === 0;
    const label = info.present ? (info.missing.length ? `${info.total - info.missing.length}/${info.total}` : "full") : "absent";
    const miss = info.missing.length ? `<span class="miss">missing: ${esc(info.missing.join(", "))}</span>` : "";
    return `<tr><td>${esc(name)}</td><td>${pill(ok ? true : info.present ? "warn" : false, label)}</td><td>${miss}</td></tr>`;
  }).join("");
  return `<table class="ns"><thead><tr><th>namespace</th><th>state</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
}

function renderTabGroups(tg) {
  if (!tg) return "";
  if (tg.available === false) return `<p>${pill(false, "tabGroups absent")}</p>`;
  if (tg.skipped) return `<p>${pill("warn", "skipped")} ${esc(tg.skipped)}</p>`;
  if (tg.error) return `<p>${pill(false, "error")} ${esc(tg.error)}</p>`;
  return [
    pill(tg.groupIdIsNumber, "tabs.group returns an id"),
    pill(tg.queriedGroupFound, "query"),
    pill(!!tg.got, "get"),
    pill(tg.updated && tg.updated.title === "LiloProbe", "update"),
    pill(Array.isArray(tg.tabGroupIdAfterGroup) && tg.tabGroupIdAfterGroup.every((g) => g === tg.groupId), "tab.groupId set"),
    pill(Array.isArray(tg.tabGroupIdAfterUngroup) && tg.tabGroupIdAfterUngroup.every((g) => g === -1), "ungroup"),
    pill(tg.groupRemovedOnEmpty, "auto-remove empty"),
    "<br>",
    pill(tg.onCreatedFired, "event onCreated"),
    pill(tg.onUpdatedFired, "event onUpdated"),
    pill(tg.onRemovedFired, "event onRemoved"),
  ].join(" ");
}

function renderGapEvents(events) {
  if (!events || !events.length) return "<p class='dim'>no pushed gap events captured yet</p>";
  return "<ul class='log'>" + events.slice(-12).reverse().map((e) =>
    `<li><b>${esc(e.type)}</b> <span class='dim'>${esc(e.at)}</span> ${esc(JSON.stringify(e.detail || {}))}</li>`).join("") + "</ul>";
}

function kv(label, value) { return `<div class="kv"><span>${esc(label)}</span><code>${esc(JSON.stringify(value))}</code></div>`; }

function render(report, meta, channels) {
  const app = $("app");
  if (!report) {
    app.innerHTML = `<p class="bad">No report available.</p><p class="dim">source: ${esc(meta.source)}</p>` + controls();
    return;
  }
  const gh = report.gapHeartbeat || {};
  const html = [];
  html.push(`<h2>Lilo MV3 Compat Probe</h2>`);
  html.push(`<p class="dim">context: <b>${esc(report.context && report.context.kind)}</b> · generated ${esc(report.generatedAt)} · source: ${esc(meta.source)}</p>`);

  html.push(`<h3>popup to SW messaging</h3><p>`);
  html.push(pill(channelOk(channels.sync), "sync sendResponse") + " ");
  html.push(pill(channelOk(channels.async), "async return-true") + " ");
  html.push(pill(channelOk(channels.port), "port") + " ");
  html.push(pill(meta.messagingResult === "ok", "getReport round-trip"));
  html.push(`</p>`);

  html.push(`<h3>Gap transport (SW to native)</h3><p>`);
  html.push(pill(report.gapCall && report.gapCall.worked, "history.search") + " ");
  html.push(pill(!!gh.at, "heartbeat " + esc(gh.at || "none")));
  html.push(`</p>`);

  html.push(`<h3>chrome.tabGroups + tabs.group/ungroup + events</h3><p>${renderTabGroups(report.tabGroups)}</p>`);

  html.push(`<h3>Gap events pushed from native to the extension</h3>${renderGapEvents(report.gapEvents)}`);

  html.push(`<h3>Static compat</h3><p>${pill(report.staticCompatLoaded, "tabs.TabStatus")}</p>`);

  html.push(`<h3>Namespaces (in the SW)</h3>${renderNamespaces(report.namespaces)}`);

  html.push(`<h3>Lifecycle signals</h3>`);
  html.push(kv("onInstalled", (report.lifecycle && report.lifecycle.onInstalled) || null));
  html.push(kv("alarms", report.alarms || null));
  html.push(kv("contextMenus", report.contextMenus || null));
  html.push(kv("omnibox", report.omnibox || null));
  html.push(kv("commands", report.commands || null));
  html.push(kv("inbox", report.inbox || null));
  html.push(kv("external", report.external || null));
  html.push(kv("contentScripts", report.contentScripts || null));
  html.push(kv("webNavigation", report.webNavigation || null));

  html.push(`<h3>Subsystems</h3>`);
  html.push(kv("dnr", report.dnr || null));
  html.push(kv("scripting", report.scripting || null));
  html.push(kv("storage", report.storage || null));
  html.push(kv("cookies", report.cookies || null));
  html.push(kv("identity", report.identity || null));

  html.push(controls());
  app.innerHTML = html.join("");
  wireControls();
}

function controls() {
  return `<div class="controls">
    <button id="refresh">Refresh</button>
    <button id="openOptions">Open options page</button>
    <button id="copy">Copy JSON</button>
  </div>`;
}
let lastReport = null;
function wireControls() {
  const r = $("refresh"); if (r) r.onclick = () => main();
  const o = $("openOptions"); if (o) o.onclick = () => { try { chrome.runtime.openOptionsPage(); } catch (e) { /* */ } };
  const c = $("copy"); if (c) c.onclick = () => { try { navigator.clipboard.writeText(JSON.stringify(lastReport, null, 2)); } catch (e) { /* */ } };
}

async function main() {
  $("app").innerHTML = "<p>Probing...</p>";
  const { report, source, messagingResult } = await getReport();
  lastReport = report;
  const [sync, asyncR, port] = await Promise.all([
    sendMessageWithTimeout({ type: "inbox", payload: "ping-sync" }, 6000),
    sendMessageWithTimeout({ type: "inboxAsync", payload: "ping-async" }, 6000),
    testPort(),
  ]);
  render(report, { source, messagingResult }, { sync, async: asyncR, port });
}

document.addEventListener("DOMContentLoaded", main);
