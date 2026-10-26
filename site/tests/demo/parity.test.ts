import assert from "node:assert/strict";
import { test } from "node:test";

import type {
  AnyBridgeEventEnvelope,
  BridgeAgentAction,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import { createDemoHost } from "../../src/demo/host.ts";

test("closing saved tabs retains their homes and reopening never duplicates a saved row", () => {
  const host = createDemoHost("en");
  host.dispatch("closeTab", { id: "lilo" });
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "lilo")?.url,
    "https://github.com/Alexays/Lilo"
  );
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "lilo")?.isClosed,
    true
  );
  assert.notEqual(host.snapshot().activeTabId, "lilo");
  host.dispatch("restoreClosedTab", {});
  assert.equal(host.activeTab()?.id, "lilo");
  assert.equal(
    host.snapshot().tabs.filter((tab) => tab.id === "lilo").length,
    1
  );
  host.dispatch("navigate", { url: "https://github.com/other" });
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "lilo")?.homeTitle,
    "Alexays / Lilo"
  );
  host.dispatch("returnTabHome", { id: "lilo" });
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "lilo")?.homeTitle,
    ""
  );
  host.dispatch("closeTab", { id: "lilo" });
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "lilo")?.url,
    "https://github.com/Alexays/Lilo"
  );
  host.toggleTabPinned("lilo");
  assert.equal(
    host.snapshot().tabs.some((tab) => tab.id === "lilo"),
    false
  );
});

test("folder deletion deletes nested contents while duplicate and pin target the requested tab", () => {
  const host = createDemoHost("en");
  host.createFolderFromTab("notes");

  const folderId = host
    .snapshot()
    .treeItems.find((item) => item.itemId === "notes")?.parentFolderId;

  assert.ok(folderId);
  host.duplicateTab("notes");
  const duplicate = host.activeTab();
  assert.ok(duplicate);
  assert.equal(
    host.snapshot().treeItems.find((item) => item.itemId === duplicate.id)
      ?.parentFolderId,
    folderId
  );
  host.dispatch("switchTab", { id: "lilo" });
  host.toggleTabPinned(duplicate.id);
  assert.equal(host.activeTab()?.id, "lilo");
  host.dispatch("deleteTabFolder", { id: folderId });
  assert.equal(
    host.snapshot().tabs.some((tab) => tab.id === "notes"),
    false
  );
  assert.equal(
    host.snapshot().folders.some((folder) => folder.id === folderId),
    false
  );
  assert.ok(host.snapshot().tabs.some((tab) => tab.id === duplicate.id));
});

test("split views preserve a four-pane sidebar layout and detach panes using native pin semantics", () => {
  const host = createDemoHost("en");
  host.dispatch("switchTab", { id: "notes" });
  host.dispatch("splitTab", { side: "right", tabId: "lilo" });
  host.dispatch("splitTab", {
    side: "bottom",
    tabId: "travel",
    targetTabId: "lilo",
  });
  host.dispatch("createTab", { url: "https://notes.example.com/fourth" });
  const fourth = host.snapshot().activeTabId;
  host.dispatch("splitTab", {
    side: "left",
    tabId: fourth,
    targetTabId: "notes",
  });
  assert.equal(host.snapshot().splitPaneFrames.length, 4);
  const fullCount = host.snapshot().tabs.length;
  const focused = host.activeTab()?.id;
  host.dispatch("newSplitView", {});
  host.newTerminalSplit("horizontal");
  assert.equal(host.snapshot().tabs.length, fullCount);
  assert.equal(host.activeTab()?.id, focused);
  host.dispatch("splitTab", {
    side: "replace",
    tabId: fourth,
    targetTabId: "notes",
  });
  assert.equal(host.snapshot().splitPaneFrames.length, 4);
  assert.equal(new Set(host.snapshot().splitIds).size, 4);
  assert.equal(
    host.snapshot().folders.filter((folder) => folder.isSplit).length,
    1
  );
  assert.equal(
    host
      .snapshot()
      .splitPaneFrames.reduce((sum, pane) => sum + pane.width * pane.height, 0),
    1
  );
  host.dispatch("createTab", { url: "https://notes.example.com/fifth" });
  const fifth = host.snapshot().activeTabId;
  host.dispatch("splitTab", {
    side: "right",
    tabId: fifth,
    targetTabId: "notes",
  });
  host.dispatch("switchTab", { id: "notes" });
  assert.equal(host.snapshot().splitIds.length, 4);
  host.toggleTabPinned(fourth);
  assert.equal(host.snapshot().splitIds.length, 3);
  host.createFolderFromTab("travel");

  const parent = host
    .snapshot()
    .treeItems.find((item) => item.itemId === "travel")?.parentFolderId;

  assert.ok(parent);
  assert.equal(
    host.snapshot().treeItems.find((item) => item.itemId === parent)
      ?.parentFolderId,
    null
  );
  assert.equal(host.snapshot().splitIds.length, 2);
  host.dispatch("closeSplitView", {});
  assert.equal(
    host.snapshot().folders.some((folder) => folder.isSplit),
    false
  );
  assert.equal(host.snapshot().splitPaneFrames.length, 0);
});

test("extension changes are isolated by profile and every asynchronous action settles", () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  const [extension] = host.snapshot().extensions;
  const { id } = extension;
  host.dispatch("disableExtension", { id, profileId: "profile-work" });
  assert.equal(host.snapshot().extensions[0].isEnabled, true);
  host.dispatch("switchSpace", { id: "work" });
  assert.equal(host.snapshot().extensions[0].isEnabled, false);
  host.dispatch("setExtensionPrivateAccess", { allowed: true, id });
  host.dispatch("setExtensionSiteAccess", {
    hosts: ["https://example.com/*"],
    id,
  });
  assert.equal(host.snapshot().extensions[0].allowsPrivateAccess, true);
  assert.deepEqual(host.snapshot().extensions[0].siteAccess, [
    "https://example.com/*",
  ]);
  host.dispatch("checkExtensionUpdates", {});
  assert.ok(
    events.some(
      (event) =>
        event.event === "extensionsChanged" &&
        event.updateCheck?.checking === false
    )
  );
  host.dispatch("updateExtension", { id });
  assert.ok(
    events.some(
      (event) =>
        event.event === "extensionActionCompleted" &&
        event.action === "update" &&
        !event.success
    )
  );
  events.length = 0;
  host.dispatch("createSpace", {
    color: "#7868d8",
    icon: "🌱",
    name: "Fresh",
    newProfileName: "Fresh",
  });
  assert.ok(
    events.some(
      (event) =>
        event.event === "extensionsChanged" && event.extensions.length === 0
    )
  );
});

test("switching and deleting Spaces restores a valid selected split and open-tab sidebar order", () => {
  const host = createDemoHost("en");
  host.dispatch("switchTab", { id: "notes" });
  host.dispatch("splitTab", { side: "right", tabId: "lilo" });
  host.dispatch("switchSpace", { id: "work" });
  host.dispatch("switchSpace", { id: "home" });
  assert.equal(host.snapshot().splitIds.length, 2);
  host.dispatch("deleteSpace", { id: "home" });
  assert.equal(host.snapshot().splitIds.length, 0);
  assert.ok(host.activeTab());
  host.dispatch("bookmarkTab", { id: "work-notes" });
  host.dispatch("closeTab", { id: "board" });
  assert.equal(host.openTabs()[0].id, "work-notes");
  assert.equal(
    host.openTabs().some((tab) => tab.id === "board"),
    false
  );
});

test("agent approvals follow editable native settings and disabled terminals cannot be created", async () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));

  const action: BridgeAgentAction = {
    kind: "click",
    label: "Publish a sample update",
    site: "studio.example.com",
    tab: "Website launch",
  };

  host.dispatch("setSetting", {
    key: "agentAlwaysAllowedSites",
    value: '["example.com"]',
  });
  assert.equal(
    await host.requestAgentApproval(action, new AbortController().signal),
    true
  );
  host.dispatch("setSetting", { key: "agentAlwaysAllowedSites", value: "[]" });
  const controller = new AbortController();
  const pending = host.requestAgentApproval(action, controller.signal);
  assert.ok(events.some((event) => event.event === "agentControlRequested"));
  controller.abort();
  assert.equal(await pending, false);
  host.dispatch("setSetting", { key: "terminalEnabled", value: "false" });
  const count = host.snapshot().tabs.length;
  host.dispatch("newTerminal", {});
  host.newTerminalSplit("vertical");
  host.openPlayground("terminal");
  assert.equal(host.snapshot().tabs.length, count);
});

test("a blank saved split pane captures its first page as home", () => {
  const host = createDemoHost("en");
  host.dispatch("newSplitView", {});
  const id = host.snapshot().activeTabId;
  host.dispatch("navigate", { url: "https://notes.example.com/home" });
  host.dispatch("navigate", { url: "https://notes.example.com/away" });
  host.dispatch("closeTab", { id });
  host.dispatch("switchTab", { id });
  assert.equal(host.activeTab()?.url, "https://notes.example.com/home");
});
