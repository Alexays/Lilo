<script lang="ts">
  import { extensionActions } from "../../lib/bridge/actions";
  import { showProfileExtensions } from "../../stores/extensions.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { openSettingsSubpage, revealSetting } from "../../stores/panels.svelte";
  import ExtensionRow from "../extensions/ExtensionRow.svelte";
  import SettingsFlagRow from "./SettingsFlagRow.svelte";
  import { SETTINGS_SECTIONS, settingTitleKey } from "./settingsPanelModel";
  import { getSettingsSearchResults } from "./settingsSearch.svelte";
  import SettingsSiteRow from "./SettingsSiteRow.svelte";
  import SettingsSpaceRow from "./SettingsSpaceRow.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";

  let { query }: { query: string } = $props();

  const results = $derived(getSettingsSearchResults());
  const sections = $derived(SETTINGS_SECTIONS.filter((section) => results.countBySection[section.id]));
  const terms = $derived(query.toLowerCase().split(/\s+/).filter(Boolean));

  // The title cut around each query term it contains, so the hit can be marked.
  function highlight(title: string): { text: string; hit: boolean }[] {
    const lower = title.toLowerCase();
    const hits = new Array<boolean>(title.length).fill(false);
    for (const term of terms) {
      for (let index = lower.indexOf(term); index !== -1; index = lower.indexOf(term, index + term.length)) {
        hits.fill(true, index, index + term.length);
      }
    }
    const parts: { text: string; hit: boolean }[] = [];
    for (let index = 0; index < title.length; index++) {
      const last = parts.at(-1);
      if (last?.hit === hits[index]) last.text += title[index];
      else parts.push({ text: title[index], hit: hits[index] });
    }
    return parts;
  }
</script>

<!-- A setting hit leads to the setting in its section, so the next visit knows where it lives. -->
{#each sections as section (section.id)}
  <UiInsetList title={t(section.labelKey)}>
    {#each results.settings.filter((setting) => setting.section === section.id) as setting (setting.id)}
      <button class="search-hit" type="button" onclick={() => revealSetting(setting.section, setting.id)}>
        <span class="search-hit-title">
          {#each highlight(t(settingTitleKey(setting.id))) as part, index (index)}{#if part.hit}<mark>{part.text}</mark>{:else}{part.text}{/if}{/each}
        </span>
        <span class="search-hit-group">{t(setting.groupKey)}</span>
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path d="m4.5 2.5 3.5 3.5-3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </button>
    {/each}
    {#if section.id === "tabs"}
      {#each results.spaces as space (space.id)}<SettingsSpaceRow {space} />{/each}
    {:else if section.id === "privacy"}
      {#each results.sites as site (site.key)}<SettingsSiteRow {site} />{/each}
    {:else if section.id === "extensions"}
      {#each results.extensions as extension (extension.id)}
        <ExtensionRow
          {extension}
          onopen={() => {
            // The search covers the window's profile: its detail page is there.
            showProfileExtensions("");
            openSettingsSubpage("extensions", `extension:${extension.id}`);
          }}
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
  .search-hit {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    width: 100%;
    min-height: 32px;
    padding: var(--space-4) 14px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    text-align: left;
    cursor: pointer;
  }

  .search-hit:hover {
    background: var(--bg-hover);
  }

  .search-hit:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .search-hit-title {
    flex: 1;
    min-width: 0;
    font-weight: var(--font-weight-medium);
  }

  mark {
    border-radius: var(--radius-2xs);
    background: var(--accent-tint-14);
    color: inherit;
  }

  .search-hit-group {
    flex: none;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .search-hit svg {
    flex: none;
    color: var(--text-muted);
  }

  .search-empty {
    margin: 0;
    padding: 24px 0;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
  }
</style>
