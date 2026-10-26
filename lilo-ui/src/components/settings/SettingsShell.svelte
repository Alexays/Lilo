<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getShownExtensions, showProfileExtensions } from "../../stores/extensions.svelte";
  import {
    closeSettingsShell,
    closeSettingsSubpage,
    getSettingsQuery,
    getSettingsShellSection,
    getSettingsSubpage,
    isSettingsShellOpen,
    setSettingsQuery,
  } from "../../stores/panels.svelte";
  import { loadSettingsSurface } from "../../stores/settings.svelte";
  import ClearDataSheet from "./ClearDataSheet.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import { SETTINGS_SECTIONS, settingTitleKey } from "./settingsPanelModel";
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
  onback={subpage && !query.trim() ? closeSettingsSubpage : undefined}
  nav={isVerticalLayout() ? undefined : settingsNav}
>
  <SettingsSectionContent {section} {subpage} {query} />
  <ClearDataSheet />
</UiShellFrame>
