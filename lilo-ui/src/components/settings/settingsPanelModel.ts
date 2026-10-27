import type {
  BridgeBrowsingDataKind,
  BridgeSitePermissionSnapshot,
  BridgeWebsiteDataSnapshot,
  BridgeZoomLevelSnapshot,
} from "../../lib/bridge/protocol";
import type { SettingsSectionId } from "../../stores/panels.svelte";

// This model is intentionally i18n-free (it's unit-tested under tsx, which can't load the
// rune-based translator). It exposes catalog KEYS; the Svelte consumers resolve them with t(),
// which keeps the labels reactive to locale changes.

interface SettingsSectionModel {
  id: SettingsSectionId;
  labelKey: string;
}

// Terminal and agents sit under their own label; advanced sits apart (after a separator): it holds
// developer tooling, not everyday settings.
export const SETTINGS_NAV_GROUPS: { id: string; labelKey?: string; sections: SettingsSectionModel[] }[] = [
  {
    id: "main",
    sections: [
      { id: "general", labelKey: "settings.sections.general" },
      { id: "appearance", labelKey: "settings.sections.appearance" },
      { id: "tabs", labelKey: "settings.sections.tabs" },
      { id: "media", labelKey: "settings.sections.media" },
      { id: "privacy", labelKey: "settings.sections.privacy" },
      { id: "extensions", labelKey: "settings.sections.extensions" },
    ],
  },
  {
    id: "tools",
    labelKey: "settings.navGroups.tools",
    sections: [
      { id: "terminal", labelKey: "settings.sections.terminal" },
      { id: "agents", labelKey: "settings.sections.agents" },
    ],
  },
  { id: "advanced", sections: [{ id: "advanced", labelKey: "settings.sections.advanced" }] },
];

export const SETTINGS_SECTIONS: SettingsSectionModel[] = SETTINGS_NAV_GROUPS.flatMap((group) => group.sections);

export type SettingId =
  | "defaultBrowser"
  | "importBrowsers"
  | "replayOnboarding"
  | "language"
  | "searchEngine"
  | "searchSuggestions"
  | "preloadTopHit"
  | "askDownloadLocation"
  | "searchEngines"
  | "downloadsFolder"
  | "autoPictureInPicture"
  | "autoplay"
  | "fullBandMicrophone"
  | "autoDevices"
  | "deviceSetup"
  | "appUpdates"
  | "autoUpdate"
  | "shortcuts"
  | "theme"
  | "tabPosition"
  | "addressPlacement"
  | "appIcon"
  | "defaultZoom"
  | "minimumFontSize"
  | "newSpace"
  | "newProfile"
  | "lifecyclePreset"
  | "singleWindow"
  | "littleWindowHotKey"
  | "externalLinkDefault"
  | "externalLinkRules"
  | "peekPinnedTabLinks"
  | "developMenu"
  | "contentBlocker"
  | "blockerTrackers"
  | "blockerCookieNotices"
  | "blockerBadware"
  | "blockerAnnoyances"
  | "blockerRegional"
  | "filterLists"
  | "blockerSites"
  | "blockerAllowedDomains"
  | "permissionNotifications"
  | "permissionMedia"
  | "permissionLocation"
  | "sites"
  | "httpsOnly"
  | "sendGPC"
  | "preventCrossSiteTracking"
  | "folderAutoLock"
  | "clearOnQuit"
  | "clearData"
  | "autoUpdateExtensions"
  | "checkExtensionUpdates"
  | "passwordManager"
  | "agentControl"
  | "agentAskBeforeActions"
  | "agentAlwaysAllowed"
  | "agentOther"
  | "processManager"
  | "diagnostics"
  | "designSystem"
  | "loadUnpacked";

export interface SettingModel {
  id: SettingId;
  section: SettingsSectionId;
  /** Catalog key of the group heading the setting sits under. */
  groupKey: SettingsGroupKey;
  /** The switch this setting only means something under: shown while it is on. */
  requires?: SettingId;
}

/** A SettingsIcon glyph: a section's own, or one drawn for a group heading. */
export type SettingsGlyph =
  | SettingsSectionId
  | "compass"
  | "arrowOutOfBox"
  | "magnifier"
  | "magnifierPlus"
  | "folder"
  | "play"
  | "petals"
  | "halfCircle"
  | "page"
  | "stack"
  | "person"
  | "noSign"
  | "hand"
  | "lock"
  | "clock"
  | "arrowsCircle"
  | "key"
  | "moon"
  | "grid"
  | "code"
  | "flag"
  | "globe"
  | "cylinder"
  | "text"
  | "command"
  | "laptop"
  | "microphone";

export interface SettingsGroupIcon {
  glyph: SettingsGlyph;
  tint: "blue" | "indigo" | "purple" | "orange" | "pink" | "green" | "teal" | "gray" | "lilo" | "agents";
}

// Every titled list in Settings, by its title's catalog key. The tint says what a group is about:
// blue the web, indigo organizing tabs and links, green protection, teal stored data, gray tools.
export const SETTINGS_GROUP_ICONS = {
  "settings.groups.browser": { glyph: "compass", tint: "blue" },
  "settings.groups.otherAppLinks": { glyph: "arrowOutOfBox", tint: "indigo" },
  "settings.groups.search": { glyph: "magnifier", tint: "orange" },
  "settings.groups.downloads": { glyph: "folder", tint: "teal" },
  "settings.groups.playback": { glyph: "play", tint: "pink" },
  "settings.groups.calls": { glyph: "microphone", tint: "pink" },
  "settings.groups.lilo": { glyph: "petals", tint: "lilo" },
  "settings.groups.theme": { glyph: "halfCircle", tint: "purple" },
  "settings.groups.tabLayout": { glyph: "tabs", tint: "indigo" },
  "settings.groups.pages": { glyph: "page", tint: "blue" },
  "settings.groups.spaces": { glyph: "stack", tint: "indigo" },
  "settings.groups.profiles": { glyph: "person", tint: "blue" },
  "settings.groups.tabsWindows": { glyph: "tabs", tint: "indigo" },
  "settings.groups.contentBlocking": { glyph: "noSign", tint: "green" },
  "settings.groups.blockerCategories": { glyph: "privacy", tint: "green" },
  "settings.groups.blockerExceptions": { glyph: "globe", tint: "green" },
  "settings.groups.sitePermissions": { glyph: "hand", tint: "blue" },
  "settings.groups.protection": { glyph: "lock", tint: "green" },
  "settings.groups.browsingData": { glyph: "clock", tint: "teal" },
  "settings.groups.updates": { glyph: "arrowsCircle", tint: "gray" },
  "settings.groups.passwords": { glyph: "key", tint: "green" },
  "settings.groups.agentAccess": { glyph: "agents", tint: "agents" },
  "settings.groups.agentClients": { glyph: "grid", tint: "agents" },
  "settings.groups.tools": { glyph: "code", tint: "gray" },
  "settings.groups.permissions": { glyph: "hand", tint: "blue" },
  "settings.groups.zoom": { glyph: "magnifierPlus", tint: "blue" },
  "settings.groups.siteData": { glyph: "cylinder", tint: "teal" },
  "settings.groups.sites": { glyph: "globe", tint: "blue" },
  "settings.blockerSites.listTitle": { glyph: "globe", tint: "green" },
  "settings.terminalAppearanceGroup": { glyph: "halfCircle", tint: "purple" },
  "settings.terminalBehaviorGroup": { glyph: "terminal", tint: "gray" },
  "settings.terminalSleepGroup": { glyph: "moon", tint: "indigo" },
  "settings.terminalLidGroup": { glyph: "laptop", tint: "indigo" },
  // The Shortcuts page titles each list with a menu's name, so they all share one tile.
  "settings.shortcuts": { glyph: "command", tint: "indigo" },
  "featureFlags.title": { glyph: "flag", tint: "gray" },
  "featureFlags.sectionExperimental": { glyph: "advanced", tint: "gray" },
  "extensions.detailDescription": { glyph: "text", tint: "gray" },
  "extensions.detailCapabilities": { glyph: "extensions", tint: "gray" },
  "extensions.detailPermissions": { glyph: "hand", tint: "blue" },
  "extensions.detailShortcuts": { glyph: "command", tint: "indigo" },
  "extensions.detailSiteAccess": { glyph: "globe", tint: "blue" },
} satisfies Record<string, SettingsGroupIcon>;

export type SettingsGroupKey = keyof typeof SETTINGS_GROUP_ICONS;

/** Boolean settings: stored key and the value an unset key means. */
export const SETTING_TOGGLES: Partial<Record<SettingId, { key: string; fallback: boolean }>> = {
  searchSuggestions: { key: "searchSuggestions", fallback: true },
  preloadTopHit: { key: "preloadTopHit", fallback: true },
  askDownloadLocation: { key: "askDownloadLocation", fallback: false },
  autoPictureInPicture: { key: "autoPictureInPicture", fallback: true },
  fullBandMicrophone: { key: "fullBandMicrophone", fallback: true },
  autoDevices: { key: "autoDeviceSwitching", fallback: false },
  singleWindow: { key: "singleWindow", fallback: false },
  littleWindowHotKey: { key: "littleWindowHotKey", fallback: true },
  peekPinnedTabLinks: { key: "peekPinnedTabLinks", fallback: true },
  contentBlocker: { key: "contentBlockerEnabled", fallback: true },
  blockerTrackers: { key: "blockerTrackers", fallback: true },
  blockerCookieNotices: { key: "blockerCookieNotices", fallback: true },
  blockerBadware: { key: "blockerBadware", fallback: true },
  blockerAnnoyances: { key: "blockerAnnoyances", fallback: false },
  blockerRegional: { key: "blockerRegional", fallback: true },
  httpsOnly: { key: "httpsOnly", fallback: false },
  sendGPC: { key: "sendGPC", fallback: true },
  preventCrossSiteTracking: { key: "preventCrossSiteTracking", fallback: true },
  clearOnQuit: { key: "clearSiteDataOnQuit", fallback: false },
  autoUpdateExtensions: { key: "autoUpdateExtensions", fallback: true },
  agentControl: { key: "agentControlEnabled", fallback: false },
  agentAskBeforeActions: { key: "agentAskBeforeActions", fallback: true },
  developMenu: { key: "showDevelopMenu", fallback: true },
};

/** Whether a boolean setting is on, read through `get(key, fallback)`. */
export function isToggleOn(id: SettingId, get: (key: string, fallback: string) => string): boolean {
  const toggle = SETTING_TOGGLES[id];
  return toggle ? get(toggle.key, String(toggle.fallback)) === "true" : false;
}

// Order is display order: groups appear in the order their first setting does.
export const SETTINGS: SettingModel[] = [
  { id: "defaultBrowser", section: "general", groupKey: "settings.groups.browser" },
  { id: "importBrowsers", section: "general", groupKey: "settings.groups.browser" },
  { id: "language", section: "general", groupKey: "settings.groups.browser" },
  { id: "externalLinkDefault", section: "general", groupKey: "settings.groups.otherAppLinks" },
  { id: "externalLinkRules", section: "general", groupKey: "settings.groups.otherAppLinks" },
  { id: "searchEngine", section: "general", groupKey: "settings.groups.search" },
  { id: "searchSuggestions", section: "general", groupKey: "settings.groups.search" },
  { id: "preloadTopHit", section: "general", groupKey: "settings.groups.search" },
  { id: "searchEngines", section: "general", groupKey: "settings.groups.search" },
  { id: "downloadsFolder", section: "general", groupKey: "settings.groups.downloads" },
  { id: "askDownloadLocation", section: "general", groupKey: "settings.groups.downloads" },
  { id: "autoPictureInPicture", section: "media", groupKey: "settings.groups.playback" },
  { id: "autoplay", section: "media", groupKey: "settings.groups.playback" },
  { id: "fullBandMicrophone", section: "media", groupKey: "settings.groups.calls" },
  { id: "autoDevices", section: "media", groupKey: "settings.groups.calls" },
  { id: "deviceSetup", section: "media", groupKey: "settings.groups.calls", requires: "autoDevices" },
  { id: "appUpdates", section: "general", groupKey: "settings.groups.lilo" },
  { id: "autoUpdate", section: "general", groupKey: "settings.groups.lilo" },
  { id: "shortcuts", section: "general", groupKey: "settings.groups.lilo" },
  { id: "theme", section: "appearance", groupKey: "settings.groups.theme" },
  { id: "appIcon", section: "appearance", groupKey: "settings.groups.theme" },
  { id: "tabPosition", section: "appearance", groupKey: "settings.groups.tabLayout" },
  { id: "addressPlacement", section: "appearance", groupKey: "settings.groups.tabLayout" },
  { id: "defaultZoom", section: "appearance", groupKey: "settings.groups.pages" },
  { id: "minimumFontSize", section: "appearance", groupKey: "settings.groups.pages" },
  { id: "newSpace", section: "tabs", groupKey: "settings.groups.spaces" },
  { id: "newProfile", section: "tabs", groupKey: "settings.groups.profiles" },
  { id: "lifecyclePreset", section: "tabs", groupKey: "settings.groups.tabsWindows" },
  { id: "singleWindow", section: "tabs", groupKey: "settings.groups.tabsWindows" },
  { id: "littleWindowHotKey", section: "tabs", groupKey: "settings.groups.tabsWindows" },
  { id: "peekPinnedTabLinks", section: "tabs", groupKey: "settings.groups.tabsWindows" },
  { id: "contentBlocker", section: "privacy", groupKey: "settings.groups.contentBlocking" },
  { id: "blockerTrackers", section: "privacy", groupKey: "settings.groups.blockerCategories", requires: "contentBlocker" },
  { id: "blockerCookieNotices", section: "privacy", groupKey: "settings.groups.blockerCategories", requires: "contentBlocker" },
  { id: "blockerBadware", section: "privacy", groupKey: "settings.groups.blockerCategories", requires: "contentBlocker" },
  { id: "blockerAnnoyances", section: "privacy", groupKey: "settings.groups.blockerCategories", requires: "contentBlocker" },
  { id: "blockerRegional", section: "privacy", groupKey: "settings.groups.blockerCategories", requires: "contentBlocker" },
  { id: "filterLists", section: "privacy", groupKey: "settings.groups.blockerExceptions", requires: "contentBlocker" },
  { id: "blockerSites", section: "privacy", groupKey: "settings.groups.blockerExceptions", requires: "contentBlocker" },
  { id: "blockerAllowedDomains", section: "privacy", groupKey: "settings.groups.blockerExceptions", requires: "contentBlocker" },
  { id: "permissionNotifications", section: "privacy", groupKey: "settings.groups.sitePermissions" },
  { id: "permissionMedia", section: "privacy", groupKey: "settings.groups.sitePermissions" },
  { id: "permissionLocation", section: "privacy", groupKey: "settings.groups.sitePermissions" },
  { id: "sites", section: "privacy", groupKey: "settings.groups.sitePermissions" },
  { id: "httpsOnly", section: "privacy", groupKey: "settings.groups.protection" },
  { id: "sendGPC", section: "privacy", groupKey: "settings.groups.protection" },
  { id: "preventCrossSiteTracking", section: "privacy", groupKey: "settings.groups.protection" },
  { id: "folderAutoLock", section: "privacy", groupKey: "settings.groups.protection" },
  { id: "clearOnQuit", section: "privacy", groupKey: "settings.groups.browsingData" },
  { id: "clearData", section: "privacy", groupKey: "settings.groups.browsingData" },
  { id: "autoUpdateExtensions", section: "extensions", groupKey: "settings.groups.updates" },
  { id: "checkExtensionUpdates", section: "extensions", groupKey: "settings.groups.updates" },
  { id: "passwordManager", section: "extensions", groupKey: "settings.groups.passwords" },
  { id: "agentControl", section: "agents", groupKey: "settings.groups.agentAccess" },
  { id: "agentAskBeforeActions", section: "agents", groupKey: "settings.groups.agentAccess", requires: "agentControl" },
  { id: "agentAlwaysAllowed", section: "agents", groupKey: "settings.groups.agentAccess", requires: "agentControl" },
  { id: "agentOther", section: "agents", groupKey: "settings.groups.agentClients", requires: "agentControl" },
  { id: "developMenu", section: "advanced", groupKey: "settings.groups.tools" },
  { id: "processManager", section: "advanced", groupKey: "settings.groups.tools" },
  { id: "diagnostics", section: "advanced", groupKey: "settings.groups.tools" },
  { id: "designSystem", section: "advanced", groupKey: "settings.groups.tools" },
  { id: "loadUnpacked", section: "advanced", groupKey: "settings.groups.tools" },
  { id: "replayOnboarding", section: "advanced", groupKey: "settings.groups.tools" },
];

export function settingTitleKey(id: SettingId): string {
  return `settings.items.${id}.title`;
}

export function settingDescriptionKey(id: SettingId): string {
  return `settings.items.${id}.description`;
}

interface SettingsGroupModel {
  groupKey: SettingsGroupKey;
  settings: SettingId[];
}

/** A section's groups in display order; `visible` drops settings whose switch is off. */
export function sectionGroups(
  section: SettingsSectionId,
  visible: (setting: SettingModel) => boolean = () => true,
): SettingsGroupModel[] {
  const groups: SettingsGroupModel[] = [];
  for (const setting of SETTINGS) {
    if (setting.section !== section || !visible(setting)) continue;
    const group = groups.find((candidate) => candidate.groupKey === setting.groupKey);
    if (group) group.settings.push(setting.id);
    else groups.push({ groupKey: setting.groupKey, settings: [setting.id] });
  }
  return groups;
}

function normalizeSearchText(text: string): string {
  return text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
}

/** Every whitespace-separated query term must appear somewhere in the haystack. */
export function matchesSearch(haystack: string, query: string): boolean {
  const terms = normalizeSearchText(query).split(/\s+/).filter(Boolean);
  if (terms.length === 0) return false;
  const text = normalizeSearchText(haystack);
  return terms.every((term) => text.includes(term));
}

/** Settings whose title, description, group, section, or keywords match, in display order. */
export function searchSettings(query: string, resolve: (key: string) => string): SettingModel[] {
  return SETTINGS.filter((setting) => {
    const section = SETTINGS_SECTIONS.find((candidate) => candidate.id === setting.section);
    const haystack = [
      resolve(settingTitleKey(setting.id)),
      resolve(settingDescriptionKey(setting.id)),
      // Extra search terms (synonyms, the other surfaces' wording) that are never displayed.
      resolve(`settings.items.${setting.id}.keywords`),
      resolve(setting.groupKey),
      section ? resolve(section.labelKey) : "",
    ].join(" ");
    return matchesSearch(haystack, query);
  });
}

/** A rule sending links from other apps somewhere: `destination` is "little" or a Space id. */
export interface LinkRule {
  match: "host" | "contains";
  pattern: string;
  destination: string;
}

/** The `externalLinkRules` setting, a JSON array; malformed entries are dropped. */
export function parseLinkRules(stored: string): LinkRule[] {
  try {
    const parsed: unknown = JSON.parse(stored || "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((entry): entry is LinkRule => {
      const rule = entry as Partial<Record<keyof LinkRule, unknown>> | null;
      return (
        (rule?.match === "host" || rule?.match === "contains") &&
        typeof rule.pattern === "string" &&
        typeof rule.destination === "string"
      );
    });
  } catch {
    return [];
  }
}

/** The sites the content blocker skips, stored as a JSON array of hosts. */
export function parseBlockerSites(stored: string): string[] {
  try {
    const parsed: unknown = JSON.parse(stored || "[]");
    return Array.isArray(parsed) ? parsed.filter((host): host is string => typeof host === "string") : [];
  } catch {
    return [];
  }
}

export function formatDownloadsFolderLabel(
  path: string | undefined,
  fallback = "Downloads",
): string {
  const trimmed = path?.trim();
  if (!trimmed) return fallback;
  const parts = trimmed.split("/").filter(Boolean);
  return parts.at(-1) ?? fallback;
}

export const BROWSING_DATA_KINDS: BridgeBrowsingDataKind[] = ["history", "cookies", "cache", "siteData"];

export interface SiteSummary {
  /** Registrable domain when WebKit reports data for it, otherwise the bare host. */
  key: string;
  permissions: BridgeSitePermissionSnapshot[];
  /** WebKit data record name to remove, when the site stores data. */
  dataName: string | null;
  dataKinds: BridgeWebsiteDataSnapshot["kinds"];
  zoomLevels: BridgeZoomLevelSnapshot[];
}

function hostOf(origin: string): string {
  try {
    return new URL(origin).hostname.toLowerCase();
  } catch {
    return origin.toLowerCase();
  }
}

/**
 * One row per site. WebKit names data records by registrable domain, so a host joins the record it falls under
 * (meet.google.com joins google.com); hosts without data group by themselves, minus a leading "www.".
 */
export function buildSites(
  permissions: BridgeSitePermissionSnapshot[],
  websiteData: BridgeWebsiteDataSnapshot[],
  zoomLevels: BridgeZoomLevelSnapshot[],
): SiteSummary[] {
  const sites = new Map<string, SiteSummary>();
  const siteFor = (key: string): SiteSummary => {
    let site = sites.get(key);
    if (!site) {
      site = { key, permissions: [], dataName: null, dataKinds: [], zoomLevels: [] };
      sites.set(key, site);
    }
    return site;
  };
  for (const record of websiteData) {
    const site = siteFor(record.name.toLowerCase());
    site.dataName = record.name;
    site.dataKinds = record.kinds;
  }
  const keyForHost = (host: string): string => {
    for (const record of websiteData) {
      const name = record.name.toLowerCase();
      if (host === name || host.endsWith(`.${name}`)) return name;
    }
    return host.replace(/^www\./, "");
  };
  for (const permission of permissions) {
    siteFor(keyForHost(hostOf(permission.origin))).permissions.push(permission);
  }
  for (const level of zoomLevels) {
    siteFor(keyForHost(level.host.toLowerCase())).zoomLevels.push(level);
  }
  return [...sites.values()].sort((a, b) => a.key.localeCompare(b.key));
}
