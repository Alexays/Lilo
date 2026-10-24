<!-- The Site drawer: the active tab's permissions in use or decided, and its zoom when it is not
     100%. Opened from the address bar's site-controls button while the page captures. -->
<script lang="ts">
  import { settingsActions, tabActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { sitePermissionRows } from "../../lib/sitePermissions";
  import { openSettings, setSettingsQuery } from "../../stores/panels.svelte";
  import { getSitePermissions, getZoomLevels } from "../../stores/settings.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { getPageZoom, setSiteDrawerOpen } from "../../stores/urlBarDrawer.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import URLDrawerRow from "./URLDrawerRow.svelte";

  let { host, origin }: { host: string; origin: string } = $props();

  $effect(() => {
    settingsActions.loadSitePermissions();
    settingsActions.loadZoomLevels();
  });

  // Decided permissions, plus the devices the page is using right now even if never decided.
  const permissionRows = $derived.by(() => {
    const tab = getActiveTab();
    const inUse = new Set([
      ...(tab?.isCameraActive ? ["camera"] : []),
      ...(tab?.isMicrophoneActive ? ["microphone"] : []),
    ]);
    return sitePermissionRows(getSitePermissions(), origin).filter(
      (row) => row.state !== "ask" || inUse.has(row.type),
    );
  });

  const storedZoom = $derived(getZoomLevels().find((level) => level.host === host.toLowerCase())?.zoom ?? 1);
  const zoom = $derived(getPageZoom(storedZoom));
  const percent = $derived(new Intl.NumberFormat(getLocale(), { style: "percent" }));
</script>

{#each permissionRows as row (row.type)}
  <URLDrawerRow icon={row.type} label={t(`sitePermissions.${row.type}`)}>
    {#snippet trailing()}
      <UiSegmented
        value={row.state === "ask" ? "" : row.state}
        options={[
          { value: "allowed", label: t("sitePermissions.allow") },
          { value: "blocked", label: t("sitePermissions.block") },
        ]}
        ariaLabel={t(`sitePermissions.${row.type}`)}
        onchange={(value) => settingsActions.setSitePermission(origin, row.type, value === "allowed")}
      />
    {/snippet}
  </URLDrawerRow>
{/each}

{#if Math.abs(zoom - 1) > 0.001}
  <URLDrawerRow icon="zoom" label={t("siteDrawer.zoom")}>
    {#snippet trailing()}
      <button class="zoom-step" type="button" aria-label={t("siteDrawer.zoomOut")} onclick={() => tabActions.zoomOut()}>−</button>
      <button class="zoom-value" type="button" aria-label={t("siteDrawer.zoomReset")} onclick={() => tabActions.zoomReset()}>
        {percent.format(zoom)}
      </button>
      <button class="zoom-step" type="button" aria-label={t("siteDrawer.zoomIn")} onclick={() => tabActions.zoomIn()}>+</button>
    {/snippet}
  </URLDrawerRow>
{/if}

<URLDrawerRow
  label={t("siteDrawer.allPermissions")}
  onclick={() => {
    setSiteDrawerOpen(false);
    openSettings("privacy");
    setSettingsQuery(host.replace(/^www\./, ""));
  }}
/>

<style>
  .zoom-step,
  .zoom-value {
    min-width: 22px;
    height: 22px;
    padding: 0 6px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
    cursor: pointer;
  }

  .zoom-step:hover,
  .zoom-value:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
</style>
