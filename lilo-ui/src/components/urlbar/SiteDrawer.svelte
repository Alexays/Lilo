<!-- The Site drawer: the page and its address, what the bar has no room for (connection, blocking,
     usage), then the site's permissions in use or decided and its zoom when it is not 100%. -->
<script lang="ts">
  import { settingsActions, tabActions } from "../../lib/bridge/actions";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { sitePermissionRows } from "../../lib/sitePermissions";
  import { openSettings, setSettingsQuery } from "../../stores/panels.svelte";
  import { getSitePermissions, getZoomLevels } from "../../stores/settings.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { getPageZoom, setSiteDrawerOpen } from "../../stores/urlBarDrawer.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import type { DetailLocation, DetailRow } from "./URLDetailsCard.svelte";
  import URLDrawerIcon from "./URLDrawerIcon.svelte";

  interface Props {
    host: string;
    origin: string;
    title: string;
    location: DetailLocation;
    rows: DetailRow[];
  }

  let { host, origin, title, location, rows }: Props = $props();

  $effect(() => {
    settingsActions.loadSitePermissions();
    settingsActions.loadZoomLevels();
  });

  const tab = $derived(getActiveTab());

  // Decided permissions, plus the devices the page is using right now even if never decided.
  const permissionRows = $derived.by(() => {
    const inUse = new Set([
      ...(tab?.isCameraActive ? ["camera"] : []),
      ...(tab?.isMicrophoneActive ? ["microphone"] : []),
    ]);
    return sitePermissionRows(getSitePermissions(), origin)
      .map((row) => ({ ...row, inUse: inUse.has(row.type) }))
      .filter((row) => row.state !== "ask" || row.inUse);
  });

  const storedZoom = $derived(getZoomLevels().find((level) => level.host === host.toLowerCase())?.zoom ?? 1);
  const zoom = $derived(getPageZoom(storedZoom));
  const zoomed = $derived(Math.abs(zoom - 1) > 0.001);
  const percent = $derived(new Intl.NumberFormat(getFormatLocale(), { style: "percent" }));
</script>

<div class="site-head">
  <SiteFavicon src={tab?.faviconDataURL} title={title} url={tab?.url ?? ""} size={32} radius={10} tile />
  <div class="site-head-text">
    <div class="site-title">{title}</div>
    <div class="site-address">{location.before}<b>{location.strong}</b>{location.after}</div>
  </div>
</div>

{#if rows.length > 0}
  <dl class="box">
    {#each rows as row (row.label)}
      <div class="box-row">
        <div class="row-text">
          <dt class="row-label">{row.label}</dt>
          <dd class="row-detail" class:danger={row.tone === "danger"}>
            {#if row.lock}
              <svg class="lock" width="10" height="11" viewBox="0 0 10 11" fill="none" aria-hidden="true">
                <rect x="1" y="4.5" width="8" height="6" rx="1.6" fill="currentColor"/>
                <path d="M3 4.5V3.2a2 2 0 0 1 4 0v1.3" stroke="currentColor" stroke-width="1.2"/>
              </svg>
            {/if}{row.value}{#if row.extra} · {row.extra}{/if}
          </dd>
        </div>
        {#if row.action}
          <button type="button" class="box-button" onclick={row.action.run}>{row.action.label}</button>
        {/if}
      </div>
    {/each}
  </dl>
{/if}

{#if permissionRows.length > 0 || zoomed}
  <div class="section-title">{t("sitePermissions.manage")}</div>
  <div class="box">
    {#each permissionRows as row (row.type)}
      <div class="box-row">
        <span class="row-icon"><URLDrawerIcon name={row.type} /></span>
        <div class="row-text">
          <div class="row-label">{t(`sitePermissions.${row.type}`)}</div>
          {#if row.inUse}<div class="row-detail">{t("siteDrawer.inUse")}</div>{/if}
        </div>
        <UiSelect
          value={row.state}
          options={[
            { value: "ask", label: t("sitePermissions.ask") },
            { value: "allowed", label: t("sitePermissions.allow") },
            { value: "blocked", label: t("sitePermissions.block") },
          ]}
          ariaLabel={t(`sitePermissions.${row.type}`)}
          onchange={(value) => {
            if (value !== "ask") settingsActions.setSitePermission(origin, row.type, value === "allowed");
            else if (row.id) settingsActions.revokeSitePermission(row.id);
          }}
        />
      </div>
    {/each}
    {#if zoomed}
      <div class="box-row">
        <span class="row-icon"><URLDrawerIcon name="zoom" /></span>
        <div class="row-text"><div class="row-label">{t("siteDrawer.zoom")}</div></div>
        <div class="zoom-stepper">
          <button type="button" aria-label={t("siteDrawer.zoomOut")} onclick={() => tabActions.zoomOut()}>-</button>
          <button type="button" class="zoom-value" aria-label={t("siteDrawer.zoomReset")} onclick={() => tabActions.zoomReset()}>
            {percent.format(zoom)}
          </button>
          <button type="button" aria-label={t("siteDrawer.zoomIn")} onclick={() => tabActions.zoomIn()}>+</button>
        </div>
      </div>
    {/if}
  </div>
{/if}

<button
  type="button"
  class="all-permissions"
  onclick={() => {
    setSiteDrawerOpen(false);
    openSettings("privacy");
    setSettingsQuery(host.replace(/^www\./, ""));
  }}
>
  {t("siteDrawer.allPermissions")}
  <svg width="7" height="12" viewBox="0 0 7 12" fill="none" aria-hidden="true">
    <path d="m1 1 5 5-5 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>
</button>

<style>
  .site-head {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 4px 12px;
  }

  .site-head-text {
    min-width: 0;
  }

  .site-title,
  .site-address {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .site-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .site-address {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .site-address b {
    color: var(--text-primary);
    font-weight: var(--font-weight-regular, 400);
  }

  .box {
    margin: 0;
    border: 1px solid var(--float-border);
    border-radius: var(--radius-box);
    background: var(--bg-hover);
    overflow: hidden;
  }

  .box-row {
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 52px;
    padding: 8px 12px 8px 16px;
    box-sizing: border-box;
  }

  .box-row + .box-row {
    border-top: 1px solid var(--float-border);
  }

  .row-icon {
    flex: none;
    display: grid;
    place-items: center;
    width: 20px;
    color: var(--text-secondary);
  }

  .row-text {
    flex: 1;
    min-width: 0;
  }

  .row-label {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .row-detail {
    margin: 0;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .row-detail.danger {
    color: var(--danger-text);
  }

  .lock {
    margin-right: 4px;
    vertical-align: -1px;
  }

  .box-button,
  .zoom-stepper {
    flex: none;
    height: var(--control-height-sm);
    border: 1px solid var(--float-border);
    border-radius: var(--radius-sm);
    background: var(--float-surface);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
  }

  /* Controls sit on the box's tint as the bordered buttons beside them. */
  .box-row :global(.ui-select select) {
    border: 1px solid var(--float-border);
    background-color: var(--float-surface);
  }

  .box-button {
    padding: 0 12px;
    cursor: pointer;
  }

  .zoom-stepper {
    display: flex;
    overflow: hidden;
  }

  .zoom-stepper button {
    min-width: 28px;
    padding: 0 8px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-variant-numeric: tabular-nums;
    cursor: pointer;
  }

  .zoom-stepper .zoom-value {
    border-inline: 1px solid var(--float-border);
  }

  .box-button:hover,
  .zoom-stepper button:hover {
    background: var(--bg-hover);
  }

  .box-button:focus-visible,
  .zoom-stepper button:focus-visible,
  .all-permissions:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .section-title {
    padding: 20px 4px 8px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .all-permissions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    margin-top: 8px;
    padding: 8px 4px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--accent-ink);
    font-family: inherit;
    font-size: var(--font-size-md);
    text-align: left;
    cursor: pointer;
  }
</style>
