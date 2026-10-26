<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { SETTINGS_NAV_GROUPS } from "./settingsPanelModel";
  import { getSettingsSearchResults } from "./settingsSearch.svelte";
  import { getDefaultBrowserStatus } from "../../stores/settings.svelte";
  import {
    closeSettingsShell,
    getSettingsQuery,
    getSettingsShellSection,
    setActiveSettingsSection,
    setSettingsQuery,
  } from "../../stores/panels.svelte";

  let { compact = false }: { compact?: boolean } = $props();

  const query = $derived(getSettingsQuery());
  const searching = $derived(query.trim().length > 0);
  const counts = $derived(searching ? getSettingsSearchResults().countBySection : {});
  // Resolved inside $derived so labels re-render on locale changes.
  const sectionGroups = $derived(
    SETTINGS_NAV_GROUPS.map((group) => ({
      id: group.id,
      label: group.labelKey ? t(group.labelKey) : undefined,
      sections: group.sections.map((section) => ({
        id: section.id,
        label: t(section.labelKey),
        icon: section.id,
        count: counts[section.id],
        dimmed: searching && !counts[section.id],
        attention: section.id === "general" && !getDefaultBrowserStatus().isDefault,
      })),
    })),
  );
</script>

<SectionNavPanel
  title={t("settings.panelTitle")}
  ariaLabel={t("settings.panelCategoriesLabel")}
  groups={sectionGroups}
  activeId={searching ? null : getSettingsShellSection()}
  onSelect={setActiveSettingsSection}
  onclose={closeSettingsShell}
  {compact}
>
  {#snippet toolbar()}
    <UiSearchField
      value={query}
      placeholder={t("settings.searchPlaceholder")}
      ariaLabel={t("settings.searchPlaceholder")}
      onchange={setSettingsQuery}
    />
  {/snippet}
</SectionNavPanel>
