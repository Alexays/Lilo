import assert from "node:assert/strict";
import test from "node:test";

import {
  buildSites,
  formatDownloadsFolderLabel,
  highlightSearch,
  isToggleOn,
  matchesSearch,
  parseBlockerSites,
  parseLinkRules,
  searchSettings,
  sitePermissionLabel,
  SETTINGS,
  SETTINGS_SECTIONS,
  sectionGroups,
} from "./settingsPanelModel";

test("formats the downloads label", () => {
  assert.equal(formatDownloadsFolderLabel("/Users/me/Work"), "Work");
  assert.equal(formatDownloadsFolderLabel(""), "Downloads");
  assert.equal(formatDownloadsFolderLabel("", "Téléchargements"), "Téléchargements");
});

test("sections follow the navigation order with advanced last", () => {
  assert.deepEqual(
    SETTINGS_SECTIONS.map((section) => section.id),
    ["general", "appearance", "tabs", "media", "privacy", "extensions", "terminal", "agents", "advanced"],
  );
});

test("every setting belongs to a known section", () => {
  const sectionIds = new Set(SETTINGS_SECTIONS.map((section) => section.id));
  for (const setting of SETTINGS) assert.ok(sectionIds.has(setting.section), setting.id);
});

test("groups a section's settings in display order", () => {
  assert.deepEqual(sectionGroups("general"), [
    { groupKey: "settings.groups.browser", settings: ["defaultBrowser", "importBrowsers", "language"] },
    { groupKey: "settings.groups.otherAppLinks", settings: ["externalLinkDefault", "externalLinkRules"] },
    { groupKey: "settings.groups.search", settings: ["searchEngine", "searchSuggestions", "preloadTopHit", "searchEngines"] },
    { groupKey: "settings.groups.downloads", settings: ["downloadsFolder", "askDownloadLocation"] },
    { groupKey: "settings.groups.lilo", settings: ["appUpdates", "autoUpdate", "shortcuts"] },
  ]);
  assert.deepEqual(sectionGroups("media"), [
    { groupKey: "settings.groups.playback", settings: ["autoPictureInPicture", "autoplay"] },
    { groupKey: "settings.groups.calls", settings: ["dockCallsInSidebar", "autoDevices", "deviceSetup"] },
  ]);
  assert.deepEqual(sectionGroups("terminal"), []);
});

test("settings under a switch that is off drop out of their group", () => {
  const values: Record<string, string> = { agentControlEnabled: "false" };
  const get = (key: string, fallback: string) => values[key] ?? fallback;
  const visible = sectionGroups("agents", (setting) => !setting.requires || isToggleOn(setting.requires, get));
  assert.deepEqual(visible, [
    { groupKey: "settings.groups.agentConversations", settings: ["agentsEnabled"] },
    { groupKey: "settings.groups.agentAccess", settings: ["agentControl"] },
  ]);

  values.agentControlEnabled = "true";
  values.agentsEnabled = "true";
  const shown = sectionGroups("agents", (setting) => !setting.requires || isToggleOn(setting.requires, get));
  assert.equal(shown.length, 3);
  assert.deepEqual(shown[0].settings, ["agentsEnabled", "agentsNotifyDone", "agentSystemPrompt", "agentSystemPromptText"]);
});

test("cross-site tracking prevention is a protection switch, on until turned off", () => {
  const protection = sectionGroups("privacy").find((group) => group.groupKey === "settings.groups.protection");
  assert.ok(protection?.settings.includes("preventCrossSiteTracking"));

  const values: Record<string, string> = {};
  const get = (key: string, fallback: string) => values[key] ?? fallback;
  assert.equal(isToggleOn("preventCrossSiteTracking", get), true);
  values.preventCrossSiteTracking = "false";
  assert.equal(isToggleOn("preventCrossSiteTracking", get), false);
});

test("reads the sites the blocker skips", () => {
  assert.deepEqual(parseBlockerSites('["figma.com","lemonde.fr"]'), ["figma.com", "lemonde.fr"]);
  assert.deepEqual(parseBlockerSites(""), []);
  assert.deepEqual(parseBlockerSites("not json"), []);
  assert.deepEqual(parseBlockerSites('{"a":1}'), []);
});

test("link rules keep well-formed entries in order", () => {
  const rule = { match: "host", pattern: "github.com", destination: "little" };
  assert.deepEqual(parseLinkRules(JSON.stringify([rule, { match: "regex", pattern: "x", destination: "little" }, 3, null])), [rule]);
  assert.deepEqual(parseLinkRules(""), []);
  assert.deepEqual(parseLinkRules("not json"), []);
});

test("search ignores case and accents and needs every term", () => {
  assert.equal(matchesSearch("Schriftgröße", "SCHRIFTGROSSE"), true);
  assert.equal(matchesSearch("Yazı tipi", "YAZI TİPİ"), true);
  assert.equal(matchesSearch("Mémoire des onglets", "memoire"), true);
  assert.equal(matchesSearch("Mémoire des onglets", "ONGLETS mem"), true);
  assert.equal(matchesSearch("Mémoire des onglets", "onglets zoom"), false);
  assert.equal(matchesSearch("Mémoire des onglets", "   "), false);
});

test("search marks each hit on the original text, accents and folded letters included", () => {
  const marked = (text: string, query: string) =>
    highlightSearch(text, query).map((part) => (part.hit ? `[${part.text}]` : part.text)).join("");
  assert.equal(marked("Écran partagé", "ecran"), "[Écran] partagé");
  assert.equal(marked("İzinler", "zin"), "İ[zin]ler");
  assert.equal(marked("Schriftgröße", "GROSSE"), "Schrift[größe]");
  assert.equal(marked("Mémoire des onglets", "onglets mem"), "[Mém]oire des [onglets]");
  assert.equal(marked("Tabs", "  "), "Tabs");
});

test("settings search reaches hidden keywords and section names", () => {
  const catalog: Record<string, string> = {
    "settings.items.clearData.keywords": "cookies cache",
    "settings.sections.appearance": "Appearance",
  };
  const resolve = (key: string) => catalog[key] ?? "";

  assert.deepEqual(searchSettings("cookies", resolve).map((setting) => setting.id), ["clearData"]);
  assert.deepEqual(searchSettings("appearance", resolve).map((setting) => setting.id), ["theme", "appIcon", "seasonalAppIcon", "interfaceSize", "tabPosition", "addressPlacement", "hideSpaceNames", "defaultZoom", "minimumFontSize", "fullRefreshRate"]);
});

test("folds permissions, data, and zoom into one row per site", () => {
  const sites = buildSites(
    [
      { id: "1", origin: "https://meet.google.com", type: "camera", decision: "allow", updatedAt: 1 },
      { id: "2", origin: "https://www.zoom.us", type: "microphone", decision: "deny", updatedAt: 2 },
      { id: "3", origin: "https://notgoogle.com", type: "camera", decision: "allow", updatedAt: 3 },
    ],
    [{ name: "google.com", kinds: ["cookies"] }],
    [
      { host: "www.google.com", zoom: 1.25 },
      { host: "notion.so", zoom: 0.9 },
    ],
    { "news.google.com": [".promo", "#banner"], "example.org": ["aside"] },
  );

  assert.deepEqual(
    sites.map((site) => [site.key, site.permissions.length, site.dataName, site.zoomLevels.length, site.hiddenElements.length]),
    [
      ["example.org", 0, null, 0, 1],
      ["google.com", 1, "google.com", 1, 2],
      ["notgoogle.com", 1, null, 0, 0],
      ["notion.so", 0, null, 1, 0],
      ["zoom.us", 1, null, 0, 0],
    ],
  );
});

test("the tab position sits under Appearance, found by what people call it", () => {
  const catalog: Record<string, string> = {
    "settings.items.tabPosition.title": "Tabs",
    "settings.items.tabPosition.keywords": "tab position sidebar left right top bottom",
  };
  const resolve = (key: string) => catalog[key] ?? "";

  assert.ok(searchSettings("sidebar top", resolve).some((setting) => setting.id === "tabPosition"));
});

test("sitePermissionLabel names the link scheme an external app decision covers", () => {
  const translate = (key: string, params?: Record<string, string | number>) => `${key}${params ? JSON.stringify(params) : ""}`;
  assert.equal(sitePermissionLabel("camera", translate), "sitePermissions.camera");
  assert.equal(sitePermissionLabel("external-scheme:zoommtg", translate), 'sitePermissions.externalScheme{"scheme":"zoommtg:"}');
});
