<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { parseBlockerSites } from "./settingsPanelModel";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";

  const hosts = $derived(parseBlockerSites(getSetting("contentBlockerAllowlist", "")));
</script>

{#if hosts.length === 0}
  <div class="empty">
    <p class="empty-title">{t("settings.blockerSites.emptyTitle")}</p>
    <p class="empty-text">{t("settings.blockerSites.emptyText")}</p>
  </div>
{:else}
  <UiInsetList title={t("settings.blockerSites.listTitle", { count: hosts.length })}>
    {#each hosts as host (host)}
      <UiListRow title={host}>
        {#snippet icon()}
          <SiteFavicon url={`https://${host}`} title={host} size={16} />
        {/snippet}
        {#snippet action()}
          <UiButton onclick={() => settingsActions.toggleBlockerAllowlist(host)}>{t("settings.blockerSites.resume")}</UiButton>
        {/snippet}
      </UiListRow>
    {/each}
  </UiInsetList>
{/if}

<style>
  .empty {
    padding: 24px 0;
  }

  .empty-title {
    margin: 0 0 4px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .empty-text {
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }
</style>
