import assert from "node:assert/strict";
import test from "node:test";

import {
  buildSites,
  formatDownloadsFolderLabel,
  isToggleOn,
  matchesSearch,
  parseBlockerSites,
  parseLinkRules,
  searchSettings,
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
    ["general", "appearance", "tabs", "privacy", "extensions", "terminal", "agents", "advanced"],
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
    { groupKey: "settings.groups.search", settings: ["searchEngine", "searchSuggestions", "searchEngines"] },
    { groupKey: "settings.groups.downloads", settings: ["downloadsFolder", "askDownloadLocation"] },
    { groupKey: "settings.groups.media", settings: ["autoPictureInPicture", "autoplay", "autoDevices", "deviceSetup"] },
    { groupKey: "settings.groups.lilo", settings: ["appUpdates", "autoUpdate", "shortcuts"] },
  ]);
  assert.deepEqual(sectionGroups("terminal"), []);
});

test("settings under a switch that is off drop out of their group", () => {
  const values: Record<string, string> = { agentControlEnabled: "false" };
  const get = (key: string, fallback: string) => values[key] ?? fallback;
  const visible = sectionGroups("agents", (setting) => !setting.requires || isToggleOn(setting.requires, get));
  assert.deepEqual(visible, [{ groupKey: "settings.groups.agentAccess", settings: ["agentControl"] }]);

  values.agentControlEnabled = "true";
  assert.equal(sectionGroups("agents", (setting) => !setting.requires || isToggleOn(setting.requires, get)).length, 2);
});

test("cross-site tracking prevention is a protection switch, off until set", () => {
  const protection = sectionGroups("privacy").find((group) => group.groupKey === "settings.groups.protection");
  assert.ok(protection?.settings.includes("preventCrossSiteTracking"));

  const values: Record<string, string> = {};
  const get = (key: string, fallback: string) => values[key] ?? fallback;
  assert.equal(isToggleOn("preventCrossSiteTracking", get), false);
  values.preventCrossSiteTracking = "true";
  assert.equal(isToggleOn("preventCrossSiteTracking", get), true);
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
  assert.equal(matchesSearch("Mémoire des onglets", "memoire"), true);
  assert.equal(matchesSearch("Mémoire des onglets", "ONGLETS mem"), true);
  assert.equal(matchesSearch("Mémoire des onglets", "onglets zoom"), false);
  assert.equal(matchesSearch("Mémoire des onglets", "   "), false);
});

test("settings search reaches hidden keywords and section names", () => {
  const catalog: Record<string, string> = {
    "settings.items.clearData.keywords": "cookies cache",
    "settings.sections.appearance": "Appearance",
  };
  const resolve = (key: string) => catalog[key] ?? "";

  assert.deepEqual(searchSettings("cookies", resolve).map((setting) => setting.id), ["clearData"]);
  assert.deepEqual(searchSettings("appearance", resolve).map((setting) => setting.id), ["theme", "appIcon", "defaultZoom", "minimumFontSize"]);
});

test("folds permissions, data, and zoom into one row per site", () => {
  const sites = buildSites(
    [
      { id: "1", origin: "https://meet.google.com", type: "camera", decision: "allow", updatedAt: 1 },
      { id: "2", origin: "https://www.zoom.us", type: "microphone", decision: "deny", updatedAt: 2 },
    ],
    [{ name: "google.com", kinds: ["cookies"] }],
    [
      { host: "www.google.com", zoom: 1.25 },
      { host: "notion.so", zoom: 0.9 },
    ],
  );

  assert.deepEqual(
    sites.map((site) => [site.key, site.permissions.length, site.dataName, site.zoomLevels.length]),
    [
      ["google.com", 1, "google.com", 1],
      ["notion.so", 0, null, 1],
      ["zoom.us", 1, null, 0],
    ],
  );
});
