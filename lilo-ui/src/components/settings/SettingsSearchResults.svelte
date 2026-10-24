<script lang="ts">
  import { extensionActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { openSettingsSubpage, revealSetting } from "../../stores/panels.svelte";
  import ExtensionRow from "../extensions/ExtensionRow.svelte";
  import SettingsFlagRow from "./SettingsFlagRow.svelte";
  import { SETTINGS_SECTIONS, settingTitleKey } from "./settingsPanelModel";
  import { getSettingsSearchResults } from "./settingsSearch.svelte";
  import SettingsSiteRow from "./SettingsSiteRow.svelte";
  import SettingsSpaceRow from "./SettingsSpaceRow.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiLinkRow from "../ui/UiLinkRow.svelte";

  let { query }: { query: string } = $props();

  const results = $derived(getSettingsSearchResults());
  const sections = $derived(SETTINGS_SECTIONS.filter((section) => results.countBySection[section.id]));
</script>

<!-- A setting hit leads to the setting in its section, so the next visit knows where it lives. -->
{#each sections as section (section.id)}
  <UiInsetList title={t(section.labelKey)}>
    {#each results.settings.filter((setting) => setting.section === section.id) as setting (setting.id)}
      <UiLinkRow
        title={t(settingTitleKey(setting.id))}
        description={t(setting.groupKey)}
        onclick={() => revealSetting(setting.section, setting.id)}
      />
    {/each}
    {#if section.id === "tabs"}
      {#each results.spaces as space (space.id)}<SettingsSpaceRow {space} />{/each}
    {:else if section.id === "privacy"}
      {#each results.sites as site (site.key)}<SettingsSiteRow {site} />{/each}
    {:else if section.id === "extensions"}
      {#each results.extensions as extension (extension.id)}
        <ExtensionRow
          {extension}
          onopen={() => openSettingsSubpage("extensions", `extension:${extension.id}`)}
          onmenu={(anchor) => extensionActions.showContextMenu(extension.id, anchor.x, anchor.y, anchor.width, anchor.height)}
        />
      {/each}
    {:else if section.id === "advanced"}
      {#each results.flags as flag (flag.key)}<SettingsFlagRow {flag} />{/each}
    {/if}
  </UiInsetList>
{:else}
  <p class="search-empty">{t("settings.searchEmpty", { query: query.trim() })}</p>
{/each}

<style>
  .search-empty {
    margin: 0;
    padding: 24px 0;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
  }
</style>
