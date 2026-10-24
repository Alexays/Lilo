<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { formatTimestamp } from "../../lib/format";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { closeSettingsSubpage } from "../../stores/panels.svelte";
  import { getSitePermissions, getWebsiteData, getZoomLevels } from "../../stores/settings.svelte";
  import { buildSites } from "./settingsPanelModel";
  import SettingsSiteRow from "./SettingsSiteRow.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";

  let { subpage }: { subpage: string | null } = $props();

  // Rendering every row of a large store is costly; the settings search narrows it down instead.
  const ROW_LIMIT = 100;

  const sites = $derived(buildSites(getSitePermissions(), getWebsiteData(), getZoomLevels()));
  const siteKey = $derived(subpage?.startsWith("site:") ? subpage.slice("site:".length) : null);
  const site = $derived(siteKey ? sites.find((candidate) => candidate.key === siteKey) : undefined);
  const percent = $derived(new Intl.NumberFormat(getLocale(), { style: "percent" }));

  // Everything stored for the site was removed: there is nothing left to show.
  $effect(() => {
    if (siteKey && !site) closeSettingsSubpage();
  });
</script>

{#if site}
  {#if site.permissions.length > 0}
    <UiInsetList title={t("settings.groups.permissions")}>
      {#each site.permissions as permission (permission.id)}
        <UiListRow
          title={t(`sitePermissions.${permission.type}`)}
          description={t("settings.sites.permissionUpdated", { origin: permission.origin, time: formatTimestamp(permission.updatedAt) })}
        >
          {#snippet action()}
            <UiBadge tone={permission.decision === "deny" ? "danger" : "success"}>
              {t(permission.decision === "deny" ? "settings.permissionDeny" : "settings.permissionAllow")}
            </UiBadge>
            <UiButton onclick={() => settingsActions.revokeSitePermission(permission.id)}>{t("settings.revoke")}</UiButton>
          {/snippet}
        </UiListRow>
      {/each}
    </UiInsetList>
  {/if}
  {#if site.zoomLevels.length > 0}
    <UiInsetList title={t("settings.groups.zoom")}>
      {#each site.zoomLevels as level (level.host)}
        <UiListRow title={level.host} description={percent.format(level.zoom)}>
          {#snippet action()}
            <UiButton onclick={() => settingsActions.resetZoomLevel(level.host)}>{t("sitePermissions.reset")}</UiButton>
          {/snippet}
        </UiListRow>
      {/each}
    </UiInsetList>
  {/if}
  {#if site.dataName}
    {@const dataName = site.dataName}
    <UiInsetList title={t("settings.groups.siteData")}>
      <UiListRow
        title={t("settings.sites.dataSummary")}
        description={site.dataKinds.map((kind) => t(`settings.websiteDataKinds.${kind}`)).join(", ")}
      >
        {#snippet action()}
          <UiButton variant="danger" onclick={() => settingsActions.removeWebsiteData(dataName)}>{t("common.clear")}</UiButton>
        {/snippet}
      </UiListRow>
    </UiInsetList>
  {/if}
{:else if sites.length === 0}
  <div class="sites-empty">
    <p class="sites-empty-title">{t("settings.sites.emptyTitle")}</p>
    <p class="sites-empty-text">{t("settings.sites.emptyText")}</p>
  </div>
{:else}
  <UiInsetList title={t("settings.groups.sites", { count: sites.length })}>
    {#each sites.slice(0, ROW_LIMIT) as entry (entry.key)}
      <SettingsSiteRow site={entry} />
    {/each}
  </UiInsetList>
  {#if sites.length > ROW_LIMIT}
    <p class="sites-more">{t("settings.sites.more", { count: sites.length - ROW_LIMIT })}</p>
  {/if}
{/if}

<style>
  .sites-empty {
    padding: 24px 0;
  }

  .sites-empty-title {
    margin: 0 0 4px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .sites-empty-text,
  .sites-more {
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }
</style>
