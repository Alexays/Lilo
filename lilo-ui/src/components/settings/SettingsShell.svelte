<script lang="ts">
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getAgentsProfileId, isAgentsSpace } from "../../stores/agents.svelte";
  import { getShownExtensions, getShownExtensionsProfileId, showProfileExtensions } from "../../stores/extensions.svelte";
  import {
    closeSettingsShell,
    closeSettingsSubpage,
    getSettingsQuery,
    getSettingsShellSection,
    getSettingsSubpage,
    isSettingsShellOpen,
    setSettingsQuery,
  } from "../../stores/panels.svelte";
  import { getActiveProfileId, getProfileById, getProfiles } from "../../stores/profiles.svelte";
  import { getSetting, loadSettingsSurface } from "../../stores/settings.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import { isToggleOn, SETTINGS_SECTIONS, settingTitleKey } from "./settingsPanelModel";
  import { getSettingsSearchResults } from "./settingsSearch.svelte";
  import { userProfiles } from "./profilesModel";
  import SettingsSectionContent from "./SettingsSectionContent.svelte";
  import SettingsPanel from "./SettingsPanel.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";

  const shellOpen = $derived(isSettingsShellOpen());
  const section = $derived(getSettingsShellSection());
  const subpage = $derived(getSettingsSubpage());
  const query = $derived(getSettingsQuery());

  const title = $derived.by(() => {
    if (query.trim()) return t("settings.searchResultsTitle");
    if (subpage === "engines") return t(settingTitleKey("searchEngines"));
    if (subpage === "shortcuts") return t(settingTitleKey("shortcuts"));
    if (subpage === "sites") return t(settingTitleKey("sites"));
    if (subpage === "blockerSites") return t(settingTitleKey("blockerSites"));
    if (subpage?.startsWith("site:")) return subpage.slice("site:".length);
    if (subpage?.startsWith("extension:")) {
      const extension = getShownExtensions()?.find((candidate) => `extension:${candidate.id}` === subpage);
      if (extension) return resolveDisplayName(extension);
    }
    const meta = SETTINGS_SECTIONS.find((candidate) => candidate.id === section);
    return meta ? t(meta.labelKey) : "";
  });

  const BLOCKER_KINDS = ["blockerTrackers", "blockerCookieNotices", "blockerBadware", "blockerAnnoyances", "blockerRegional"] as const;

  // The short count or note at the right of the page title.
  const note = $derived.by(() => {
    if (query.trim()) {
      const results = getSettingsSearchResults();
      const count = Object.values(results.countBySection).reduce((sum, value) => sum + (value ?? 0), 0);
      return count ? t("settings.notes.searchMatches", { count, query: query.trim() }) : "";
    }
    if (subpage === "shortcuts") return t("settings.shortcuts.note");
    if (subpage) return "";
    switch (section) {
      case "general":
      case "appearance":
      case "media":
        return t("settings.notes.live");
      case "tabs": {
        const spaces = getSpaces().filter((space) => !isAgentsSpace(space.id)).length;
        const profiles = userProfiles(getProfiles(), getAgentsProfileId()).length;
        return new Intl.ListFormat(getLocale(), { type: "unit" }).format([
          t("settings.notes.spaces", { count: spaces }),
          t("settings.notes.profiles", { count: profiles }),
        ]);
      }
      case "privacy": {
        if (!isToggleOn("contentBlocker", getSetting)) return t("settings.notes.blockingOff");
        const on = BLOCKER_KINDS.filter((kind) => isToggleOn(kind, getSetting)).length;
        return t("settings.notes.blocking", { count: on, total: BLOCKER_KINDS.length });
      }
      case "extensions": {
        const extensions = getShownExtensions();
        const profile = getProfileById(getShownExtensionsProfileId() || getActiveProfileId());
        return extensions && profile ? t("settings.notes.extensions", { count: extensions.length, profile: profile.name }) : "";
      }
      case "terminal":
        return t("settings.notes.terminal");
      case "agents":
        return t("settings.notes.agents");
      case "advanced":
        return t("settings.notes.advanced");
    }
    return "";
  });

  // Settings > Extensions opens on the window's own profile.
  $effect(() => {
    if (shellOpen) loadSettingsSurface();
    else showProfileExtensions("");
  });

  // Escape unwinds one level: the search, then a drill-in page, then the surface itself.
  function handleWindowKeydown(event: KeyboardEvent): void {
    if (!shellOpen || event.key !== "Escape" || event.defaultPrevented) return;
    event.preventDefault();
    if (query) setSettingsQuery("");
    else if (subpage) closeSettingsSubpage();
    else closeSettingsShell();
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

<!-- A tab strip has no sidebar to hold the navigation: the page's card does. -->
{#snippet settingsNav(compact: boolean)}<SettingsPanel {compact} />{/snippet}

<UiShellFrame
  active={shellOpen}
  ariaLabel={t("settings.panelTitle")}
  interactiveZoneId="settings-shell"
  {title}
  {note}
  onback={subpage && !query.trim() ? closeSettingsSubpage : undefined}
  nav={isVerticalLayout() ? undefined : settingsNav}
>
  <SettingsSectionContent {section} {subpage} {query} />
</UiShellFrame>
