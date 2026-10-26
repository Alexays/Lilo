import assert from "node:assert/strict";
import { test } from "node:test";

import type {
  AnyBridgeEventEnvelope,
  BridgeCommandName,
  BridgeCommandPayloadMap,
  BridgeEventName,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import { installNativeCopy } from "../../src/demo/native-copy.ts";
import {
  createDemoSettings,
  demoTerminalOptions,
} from "../../src/demo/settings-state.ts";
import type { NativeShortcutAction } from "../../src/demo/settings-state.ts";

const shortcuts: NativeShortcutAction[] = [
  {
    category: "Lilo",
    defaults: ["⌘,"],
    id: "app.settings",
    title: "Settings…",
  },
  { category: "File", defaults: ["⌘t"], id: "tab.new", title: "New Tab" },
  {
    category: "File",
    defaults: ["⌘s"],
    id: "page.save",
    title: "Save Page As…",
  },
  {
    category: "File",
    defaults: ["⌘d"],
    id: "terminal.newBeside",
    title: "New Terminal Beside",
  },
  {
    category: "View",
    defaults: ["⇧⌘s"],
    id: "sidebar.toggle",
    title: "Toggle Sidebar",
  },
  {
    args: [1],
    category: "Spaces",
    defaults: ["⌃1"],
    id: "space.select1",
    title: "Space %d",
  },
  {
    category: "Tab",
    defaults: ["⇧⌘[", "⌥⌘left"],
    id: "tab.previous",
    title: "Show Previous Tab",
  },
  {
    category: "Tab",
    defaults: ["⇧⌘]", "⌥⌘right"],
    id: "tab.next",
    title: "Show Next Tab",
  },
  {
    category: "Tab",
    defaults: ["⌃tab"],
    id: "tab.recentNext",
    title: "Switch to Recent Tab",
  },
  {
    category: "Tab",
    defaults: ["⌃⇧tab"],
    id: "tab.recentPrevious",
    title: "Switch to Recent Tab Backwards",
  },
  { category: "Tab", defaults: [], id: "tab.pin", title: "Pin Tab" },
];

const keyboard = (key: string, modifiers: Partial<KeyboardEvent> = {}) => ({
  altKey: false,
  ctrlKey: false,
  isComposing: false,
  key,
  metaKey: false,
  shiftKey: false,
  ...modifiers,
});

const createSettings = () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const clearedHistory: string[] = [];

  const settings = createDemoSettings({
    activeURL: () => "https://notes.example.com/document",
    clearHistory: (range) => clearedHistory.push(range),
    emit: (event, payload) => {
      // SAFETY: the factory pairs each event name with its protocol payload.
      events.push(
        structuredClone({ event, ...payload }) as AnyBridgeEventEnvelope
      );
    },
    locale: "en",
    onChange: () => {},
    shortcuts,
    version: "1.2.3",
  });

  const latest = <K extends BridgeEventName>(name: K) => {
    const event = events.findLast((candidate) => candidate.event === name);
    assert.ok(event, `Expected ${name}`);

    // SAFETY: the lookup selects the requested event discriminant and the assertion excludes undefined.
    return event as Extract<AnyBridgeEventEnvelope, { event: K }>;
  };

  const send = <K extends BridgeCommandName>(
    name: K,
    payload: BridgeCommandPayloadMap[K]
  ) => {
    const handler = settings.commands[name];
    assert.ok(handler, `Missing ${name}`);
    handler(payload);
  };

  const load = (name: BridgeCommandName) => {
    const reply = settings.replies[name];
    assert.ok(reply, `Missing ${name}`);
    reply();
  };

  return { clearedHistory, events, latest, load, send, settings };
};

test("clearing sample data mutates future snapshots and preserves permissions for limited ranges", () => {
  const { latest, load, send } = createSettings();
  send("setSitePermission", {
    allow: true,
    origin: "https://notes.example.com",
    type: "camera",
  });
  const [permission] = latest("sitePermissionsLoaded").permissions;
  send("setSitePermission", {
    allow: false,
    origin: permission.origin,
    type: permission.type,
  });
  assert.equal(latest("sitePermissionsLoaded").permissions.length, 1);
  assert.equal(
    latest("sitePermissionsLoaded").permissions[0].id,
    permission.id
  );
  assert.equal(latest("sitePermissionsLoaded").permissions[0].decision, "deny");

  send("clearSiteData", { range: "hour" });
  assert.deepEqual(
    latest("websiteDataLoaded").sites.map((site) => site.name),
    ["slowtravel.example.com"]
  );
  load("getSitePermissions");
  assert.equal(latest("sitePermissionsLoaded").permissions.length, 1);
  send("clearCache", { range: "all" });
  assert.deepEqual(latest("websiteDataLoaded").sites[0].kinds, [
    "cookies",
    "storage",
  ]);
  send("clearCookies", { range: "all" });
  assert.deepEqual(latest("websiteDataLoaded").sites[0].kinds, ["storage"]);
  send("clearSiteData", { range: "all" });
  load("getWebsiteData");
  assert.deepEqual(latest("websiteDataLoaded").sites, []);
  assert.deepEqual(latest("sitePermissionsLoaded").permissions, []);
});

test("site removal, permission revocation and blocker exceptions remain local to their demo", () => {
  const first = createSettings();
  const second = createSettings();
  first.send("removeWebsiteData", { name: "notes.example.com" });
  first.load("getWebsiteData");
  second.load("getWebsiteData");
  assert.equal(first.latest("websiteDataLoaded").sites.length, 1);
  assert.equal(second.latest("websiteDataLoaded").sites.length, 2);
  first.send("setSitePermission", {
    allow: true,
    origin: "https://example.com",
    type: "location",
  });
  first.send("revokeSitePermission", {
    id: first.latest("sitePermissionsLoaded").permissions[0].id,
  });
  assert.deepEqual(first.latest("sitePermissionsLoaded").permissions, []);
  first.send("toggleBlockerAllowlist", { host: "example.com" });
  assert.deepEqual(first.latest("blockerAllowlistChanged").allowlist, [
    "example.com",
  ]);
  first.send("toggleBlockerAllowlist", { host: "example.com" });
  assert.deepEqual(first.latest("blockerAllowlistChanged").allowlist, []);
  assert.equal(second.settings.values.contentBlockerAllowlist, undefined);
});

test("host zoom follows the default, clamps user zoom and supports both reset paths", () => {
  const { latest, load, send, settings } = createSettings();
  send("setSetting", { key: "defaultZoom", value: "1.25" });
  assert.equal(settings.zoomFor("https://example.com"), 1.25);
  send("zoomIn", {});
  assert.equal(
    settings.zoomFor("https://notes.example.com/another-page"),
    1.35
  );
  assert.equal(settings.zoomFor("https://example.com"), 1.25);

  for (let step = 0; step < 40; step += 1) {
    send("zoomOut", {});
  }

  assert.equal(latest("zoomChanged").level, 0.5);
  send("resetZoomLevel", { host: "notes.example.com" });
  assert.equal(settings.zoomFor("https://notes.example.com"), 1.25);
  send("zoomIn", {});
  send("zoomReset", {});
  assert.equal(latest("zoomChanged").level, 1);
  assert.equal(settings.zoomFor("https://notes.example.com/document"), 1);
  load("getZoomLevels");
  assert.deepEqual(latest("zoomLevelsLoaded").levels, []);
  settings.navigated("https://notes.example.com/document");
  assert.equal(settings.zoomFor("https://notes.example.com/document"), 1.25);
});

test("shortcut recording reports conflicts and replacement takes the binding from its previous owner", () => {
  const { latest, load, send, settings } = createSettings();
  load("getShortcuts");
  assert.equal(settings.shortcutKeys()["app.settings"], "⌘,");
  assert.equal(settings.shortcutKeys()["sidebar.toggle"], "⇧⌘S");
  send("recordShortcut", { id: "sidebar.toggle" });
  assert.equal(settings.recordKeyboard(keyboard("t", { metaKey: true })), true);
  assert.deepEqual(latest("shortcutConflict"), {
    combo: "⌘t",
    event: "shortcutConflict",
    id: "sidebar.toggle",
    keys: "⌘T",
    owner: "New Tab",
  });
  assert.equal(
    settings.shortcutAction(keyboard("t", { metaKey: true })),
    "tab.new"
  );
  send("setShortcut", { combo: "⌘t", id: "sidebar.toggle" });
  assert.equal(
    settings.shortcutAction(keyboard("t", { metaKey: true })),
    "sidebar.toggle"
  );
  assert.equal(settings.shortcutKeys()["tab.new"], undefined);
  const rows = latest("shortcutsLoaded").groups.flatMap((group) => group.items);
  assert.equal(rows.find((row) => row.id === "tab.new")?.custom, true);
  send("resetShortcut", { id: "sidebar.toggle" });
  assert.equal(settings.shortcutKeys()["sidebar.toggle"], "⇧⌘S");
  send("applyShortcutPreset", { preset: "lilo" });
  assert.equal(settings.shortcutKeys()["tab.new"], "⌘T");
  assert.equal(settings.values.keyboardShortcuts, undefined);
});

test("recording cancels or unbinds cleanly and ignores typing keys until a valid combination", () => {
  const { latest, send, settings } = createSettings();
  send("recordShortcut", { id: "app.settings" });
  assert.equal(settings.recordKeyboard(keyboard("x")), true);
  assert.equal(settings.shortcutKeys()["app.settings"], "⌘,");
  settings.recordKeyboard(keyboard("Escape"));
  assert.equal(
    settings.recordKeyboard(keyboard("x", { metaKey: true })),
    false
  );
  send("recordShortcut", { id: "app.settings" });
  settings.recordKeyboard(keyboard("Backspace"));
  assert.equal(settings.shortcutKeys()["app.settings"], undefined);
  assert.ok(latest("shortcutsLoaded").groups[0].items[0].custom);
  send("recordShortcut", { id: "app.settings" });
  settings.recordKeyboard(keyboard("X", { metaKey: true, shiftKey: true }));
  assert.equal(settings.shortcutKeys()["app.settings"], "⇧⌘X");
  send("recordShortcut", { id: "app.settings" });
  settings.recordKeyboard(keyboard("F6"));
  assert.equal(settings.shortcutKeys()["app.settings"], "F6");
});

test("Arc preset and Control-Tab order update the same bindings used for dispatch and hints", () => {
  const { latest, send, settings } = createSettings();
  send("applyShortcutPreset", { preset: "arc" });
  assert.equal(settings.shortcutKeys()["sidebar.toggle"], "⌘S");
  assert.equal(settings.shortcutKeys()["page.save"], "⇧⌘S");
  assert.equal(settings.shortcutKeys()["terminal.newBeside"], undefined);
  assert.equal(
    settings.shortcutAction(keyboard("s", { metaKey: true })),
    "sidebar.toggle"
  );
  send("setControlTabOrder", { order: "sidebar" });
  assert.equal(latest("shortcutsLoaded").controlTabOrder, "sidebar");
  assert.equal(
    settings.shortcutAction(keyboard("Tab", { ctrlKey: true })),
    "tab.next"
  );
  assert.equal(
    settings.shortcutAction(keyboard("Tab", { ctrlKey: true, shiftKey: true })),
    "tab.previous"
  );
  send("setControlTabOrder", { order: "recent" });
  assert.equal(latest("shortcutsLoaded").controlTabOrder, "recent");
  assert.equal(
    settings.shortcutAction(keyboard("Tab", { ctrlKey: true })),
    "tab.recentNext"
  );
});

test("shortcut labels use native translation keys, including numbered tabs and Spaces", (context) => {
  installNativeCopy({
    en: {},
    fr: {
      File: "Fichier",
      "New Tab": "Nouvel onglet",
      "Settings…": "Réglages…",
      "Space %d": "Espace %d",
    },
  });
  context.after(() => installNativeCopy({ en: {}, fr: {} }));
  const { latest, load, send } = createSettings();
  send("setSetting", { key: "locale", value: "fr" });
  load("getShortcuts");
  const { groups } = latest("shortcutsLoaded");
  assert.equal(groups[1].title, "Fichier");
  const rows = groups.flatMap((group) => group.items);
  assert.equal(
    rows.find((row) => row.id === "space.select1")?.title,
    "Espace 1"
  );
  assert.equal(
    rows.find((row) => row.id === "app.settings")?.title,
    "Réglages…"
  );
});

test("onboarding progress and history clearing complete without an unavailable-action notice", () => {
  const { clearedHistory, events, latest, load, send, settings } =
    createSettings();

  send("setSetting", { key: "onboardingCompleted", value: "false" });
  send("setSetting", { key: "onboardingUsage", value: "develop" });
  send("setOnboardingStep", { step: 3 });
  load("getOnboardingState");
  assert.deepEqual(latest("onboardingState"), {
    event: "onboardingState",
    show: true,
    step: 3,
    usage: "develop",
  });
  send("completeOnboarding", {});
  load("getOnboardingState");
  assert.equal(latest("onboardingState").show, false);
  assert.equal(settings.values.onboardingStep, undefined);
  assert.equal(settings.values.didPromptDefaultBrowser, "true");
  assert.ok(!events.some((event) => event.event === "settingsActionCompleted"));
  send("clearHistory", { range: "week" });
  assert.deepEqual(clearedHistory, ["week"]);
  assert.equal(latest("settingsActionCompleted").action, "clearHistory");
});

test("terminal options use the native automatic theme id and preserve supplied native presets", () => {
  const light = demoTerminalOptions(false);

  const dark = demoTerminalOptions(true, [
    {
      background: "#112233",
      foreground: "#ddeeff",
      id: "sample-theme",
      name: "Sample theme",
      palette: Array.from({ length: 16 }, () => "#112233"),
    },
  ]);

  assert.equal(light.themes[0].id, "auto");
  assert.equal(light.themes[0].palette.length, 16);
  assert.notEqual(light.themes[0].background, dark.themes[0].background);
  assert.equal(dark.themes[1].id, "sample-theme");
  const { latest, load } = createSettings();
  load("getTerminalOptions");
  assert.equal(latest("terminalOptions").themes[0].id, "auto");
});

test("Mac-only actions return their required snapshots and completion status", () => {
  const { latest, send } = createSettings();
  send("updateFilterLists", {});
  assert.equal(latest("contentBlockerStatus").updating, false);
  assert.equal(latest("settingsActionCompleted").action, "updateFilterLists");
  send("forgetDeviceSetup", {});
  assert.deepEqual(latest("deviceSetupLoaded"), {
    event: "deviceSetupLoaded",
    label: "",
  });
  send("checkForUpdates", {});
  assert.equal(latest("updaterStatus").available, false);
  assert.equal(latest("updaterStatus").automatic, false);
  assert.equal(latest("settingsActionCompleted").action, "checkForUpdates");
});
