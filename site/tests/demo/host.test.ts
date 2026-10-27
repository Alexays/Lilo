import assert from "node:assert/strict";
import { test } from "node:test";

import type { AnyBridgeEventEnvelope } from "../../../lilo-ui/src/lib/bridge/protocol";
import { createDemoHost } from "../../src/demo/host.ts";

test("background links preserve the selection, split and recent-tab order", () => {
  const host = createDemoHost("en");
  host.dispatch("splitURL", {
    side: "right",
    targetTabId: host.snapshot().activeTabId,
    url: "https://notes.example.com/split",
  });
  const before = host.snapshot();
  const recent = host.recentTabRows().map((tab) => tab.id);
  host.openLinkTab("https://radio.example.com/background", true);
  const after = host.snapshot();
  assert.equal(after.activeTabId, before.activeTabId);
  assert.deepEqual(after.splitIds, before.splitIds);
  assert.equal(after.tabs.length, before.tabs.length + 1);
  assert.deepEqual(
    host
      .recentTabRows()
      .filter((tab) => recent.includes(tab.id))
      .map((tab) => tab.id),
    recent
  );
  host.openLinkTab("https://notes.example.com/foreground");
  assert.equal(host.activeTab()?.url, "https://notes.example.com/foreground");
  const count = host.snapshot().tabs.length;
  host.openLinkTab("file:///private/example.txt", true);
  assert.equal(host.snapshot().tabs.length, count);
});

test("new tabs, closing the last tab, and restore keep a usable selection", () => {
  const host = createDemoHost("en");
  const original = host.snapshot().activeTabId;
  host.dispatch("createTab", { url: "https://notes.example.com/new" });
  const created = host.snapshot().activeTabId;
  assert.notEqual(created, original);
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === created)?.url,
    "https://notes.example.com/new"
  );
  host.dispatch("closeTab", { id: created });
  assert.equal(host.snapshot().activeTabId, original);
  host.dispatch("restoreClosedTab", {});
  assert.equal(host.snapshot().activeTabId, created);

  for (const tab of host.snapshot().tabs) {
    host.dispatch("closeTab", { id: tab.id });
  }

  assert.ok(host.snapshot().activeTabId);
  assert.equal(host.snapshot().tabs.filter((tab) => !tab.isClosed).length, 1);
});

test("local navigation history tracks back, forward, and replacement after going back", () => {
  const host = createDemoHost("en");

  const original = host
    .snapshot()
    .tabs.find((tab) => tab.id === host.snapshot().activeTabId)?.url;

  host.dispatch("navigate", { url: "https://notes.example.com/one" });
  host.dispatch("navigate", { url: "https://notes.example.com/two" });
  host.dispatch("goBack", {});
  assert.equal(host.activeTab()?.url, "https://notes.example.com/one");
  host.dispatch("goBack", {});
  assert.equal(host.activeTab()?.url, original);
  host.dispatch("goForward", {});
  host.dispatch("navigate", { url: "https://notes.example.com/three" });
  assert.equal(host.activeTab()?.canGoForward, false);
});

test("settings survive reopening the surface and remain isolated between demos", () => {
  const host = createDemoHost("fr");
  host.dispatch("setSetting", { key: "searchEngine", value: "duckduckgo" });
  host.dispatch("getSettings", {});
  assert.equal(host.snapshot().settings.searchEngine, "duckduckgo");
  assert.equal(host.snapshot().settings.locale, "fr");
  assert.equal(createDemoHost("en").snapshot().settings.locale, "en");
  assert.notEqual(
    createDemoHost("en").snapshot().settings.searchEngine,
    "duckduckgo"
  );
});

test("changing a setting does not resend unchanged browser state", () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  host.dispatch("setSetting", { key: "theme", value: "dark" });
  assert.equal(
    events.filter((event) => event.event === "settingsLoaded").length,
    1
  );
  assert.equal(
    events.some((event) => event.event === "browserStateChanged"),
    false
  );
});

test("tab layouts echo native defaults, address overrides and the right-edge constraint", () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  host.dispatch("setSetting", { key: "tabPosition", value: "bottom" });
  assert.deepEqual(events.at(-1), {
    address: "page",
    event: "tabLayoutChanged",
    position: "bottom",
  });
  host.dispatch("setSetting", { key: "addressPlacement", value: "tabs" });
  assert.equal(host.initialState().addressPlacement, "tabs");
  host.dispatch("setSetting", { key: "tabPosition", value: "right" });
  assert.deepEqual(events.at(-1), {
    address: "page",
    event: "tabLayoutChanged",
    position: "right",
  });
  const count = events.length;
  host.dispatch("setSetting", { key: "tabPosition", value: "right" });
  assert.equal(events.length, count);
  host.dispatch("setSetting", { key: "tabPosition", value: "top" });
  assert.equal(host.initialState().addressPlacement, "tabs");
});

test("Space color modes survive create and edit, and page colors follow navigation history", () => {
  const host = createDemoHost("en");
  host.dispatch("createSpace", { colorMode: "time", name: "Colors" });
  const id = host.snapshot().activeSpaceId;
  assert.equal(
    host.snapshot().spaces.find((space) => space.id === id)?.colorMode,
    "time"
  );
  host.dispatch("updateSpace", { colorMode: "page", id });
  assert.equal(
    host.snapshot().spaces.find((space) => space.id === id)?.colorMode,
    "page"
  );
  host.dispatch("navigate", { url: "https://slowtravel.example.com/lisbon" });
  const travelColor = host.activeTab()?.faviconDominantColor;
  host.dispatch("navigate", { url: "https://notes.example.com" });
  assert.notEqual(host.activeTab()?.faviconDominantColor, travelColor);
  host.dispatch("goBack", {});
  assert.equal(host.activeTab()?.faviconDominantColor, travelColor);
});

test("editing a saved tab's home follows it only when the tab is at home", () => {
  const host = createDemoHost("en");
  const id = host.snapshot().activeTabId;
  host.dispatch("setTabHomeURL", { id, url: "https://notes.example.com/one" });
  assert.equal(host.activeTab()?.url, "https://notes.example.com/one");
  host.dispatch("navigate", { url: "https://slowtravel.example.com/lisbon" });
  host.dispatch("setTabHomeURL", { id, url: "https://notes.example.com/two" });
  assert.equal(host.activeTab()?.url, "https://slowtravel.example.com/lisbon");
  host.dispatch("returnTabHome", { id });
  assert.equal(host.activeTab()?.url, "https://notes.example.com/two");
  host.dispatch("setTabHomeURL", { id, url: "data:text/html,invalid" });
  assert.equal(host.getTabHomeURL(id), "https://notes.example.com/two");
});

test("agent activity uses the current per-profile space contract", () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  host.openPlayground("mcp");
  host.setAgentBusy(false);
  host.setAgentSession(true);
  const activity = events.findLast((event) => event.event === "agentActivity");
  assert.ok(activity);
  assert.deepEqual(activity.agentsSpaceIds, ["playground-agents"]);
  assert.deepEqual(activity.clients[0]?.spaceIds, activity.agentsSpaceIds);
  assert.deepEqual(activity.hiddenAgentsSpaceIds, []);
});

test("creating and deleting a Space also maintains its tabs and selection", () => {
  const host = createDemoHost("en");
  host.dispatch("createSpace", {
    color: "#5278dd",
    icon: "🔬",
    name: "Research",
    profileId: "profile-personal",
  });
  const spaceId = host.snapshot().activeSpaceId;
  assert.equal(
    host.snapshot().spaces.find((space) => space.id === spaceId)?.name,
    "Research"
  );
  host.dispatch("createTab", { url: "https://research.example.com" });
  const tabId = host.snapshot().activeTabId;
  host.dispatch("deleteSpace", { id: spaceId });
  assert.notEqual(host.snapshot().activeSpaceId, spaceId);
  assert.ok(host.snapshot().activeTabId);
  assert.equal(
    host.snapshot().tabs.some((tab) => tab.id === tabId),
    false
  );
  assert.equal(
    host.snapshot().spaces.some((space) => space.id === spaceId),
    false
  );
});

test("malicious addresses cannot become executable content or external navigation", () => {
  const host = createDemoHost("en");
  const original = host.activeTab()?.url;

  for (const url of [
    // oxlint-disable-next-line no-script-url -- Exercise rejection of executable URLs.
    "javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "file:///etc/passwd",
    "//evil.example/path",
  ]) {
    host.dispatch("navigate", { url });
    assert.equal(host.activeTab()?.url, original);
  }

  host.dispatch("navigate", {
    url: "https://example.com/<img onerror=alert(1)>",
  });
  assert.ok(host.activeTab()?.url.startsWith("https://example.com/"));
});

test("a tab can move between Spaces without losing selection or duplicating tree items", () => {
  const host = createDemoHost("en");
  const tabId = host.snapshot().activeTabId;

  const target = host
    .snapshot()
    .spaces.find((space) => space.id !== host.snapshot().activeSpaceId);

  assert.ok(target);

  host.dispatch("moveTabToSpace", { spaceId: target.id, tabId });
  host.dispatch("switchSpace", { id: target.id });
  assert.equal(
    host.snapshot().tabs.filter((tab) => tab.id === tabId).length,
    1
  );
  assert.equal(
    host.snapshot().treeItems.filter((item) => item.itemId === tabId).length,
    1
  );
});
