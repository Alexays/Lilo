import type { BridgeFeatureFlagSnapshot } from "../../lib/bridge/protocol";
import { t } from "../../lib/i18n/state.svelte";
import { type ExtensionState, getExtensions } from "../../stores/extensions.svelte";
import { getSettingsQuery, type SettingsSectionId } from "../../stores/panels.svelte";
import {
  getFeatureFlags,
  getSetting,
  getSitePermissions,
  getWebsiteData,
  getZoomLevels,
} from "../../stores/settings.svelte";
import { getSpaces, type SpaceState } from "../../stores/spaces.svelte";
import { resolveDisplayName } from "../extensions/extensionPanelModel";
import {
  buildSites,
  isToggleOn,
  matchesSearch,
  type SettingModel,
  searchSettings,
  type SiteSummary,
} from "./settingsPanelModel";

interface SettingsSearchResults {
  settings: SettingModel[];
  spaces: SpaceState[];
  sites: SiteSummary[];
  extensions: ExtensionState[];
  flags: BridgeFeatureFlagSnapshot[];
  countBySection: Partial<Record<SettingsSectionId, number>>;
}

// Settings plus the entities the sections list (spaces, sites, extensions, flags), for the shell's
// query. Shared so the section counts and the results list run one search per keystroke.
const results = $derived.by((): SettingsSearchResults => {
  const query = getSettingsQuery();
  // A setting is hidden while its switch is off, so it can't be a hit either.
  const settings = searchSettings(query, (key) => t(key)).filter(
    (setting) => !setting.requires || isToggleOn(setting.requires, getSetting),
  );
  const spaces = getSpaces().filter((space) => matchesSearch(space.name, query));
  // A site also matches on what it holds, so "camera" or "zoom" lists the sites concerned.
  const sites = buildSites(getSitePermissions(), getWebsiteData(), getZoomLevels()).filter((site) =>
    matchesSearch(
      [
        site.key,
        ...site.permissions.map((permission) => t(`sitePermissions.${permission.type}`)),
        site.zoomLevels.length > 0 ? t("settings.groups.zoom") : "",
        site.dataName ? t("settings.sites.dataSummary") : "",
      ].join(" "),
      query,
    ),
  );
  const extensions = getExtensions().filter((extension) =>
    matchesSearch(`${resolveDisplayName(extension)} ${extension.description ?? ""}`, query),
  );
  const flags = getFeatureFlags().filter((flag) =>
    matchesSearch(`${flag.name} ${flag.key} ${flag.details}`, query),
  );

  const countBySection: Partial<Record<SettingsSectionId, number>> = {};
  const add = (section: SettingsSectionId, count: number) => {
    if (count > 0) countBySection[section] = (countBySection[section] ?? 0) + count;
  };
  for (const setting of settings) add(setting.section, 1);
  add("tabs", spaces.length);
  add("privacy", sites.length);
  add("extensions", extensions.length);
  add("advanced", flags.length);

  return { settings, spaces, sites, extensions, flags, countBySection };
});

export function getSettingsSearchResults(): SettingsSearchResults {
  return results;
}
