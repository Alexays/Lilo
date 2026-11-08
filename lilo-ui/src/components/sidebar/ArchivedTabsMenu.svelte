<!-- The tabs the idle sweep or Clear archived in the last day, one click from coming back; the command bar keeps the rest.
     Running and failed downloads sit on top when the downloads UI is on: both share the sidebar's bottom-left slot. -->
<script lang="ts">
  import { getFormatLocale, getLocale, t } from "../../lib/i18n/state.svelte";
  import { downloadActions, tabActions } from "../../lib/bridge/actions";
  import type { BridgeArchivedTab, BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { progress } from "../../lib/downloadFormat";
  import { isActiveDownload } from "../../stores/downloads.svelte";
  import { openDownloadsPanel } from "../../stores/panels.svelte";
  import { fileIconURL, inlineAction, metaLine, type InlineAction } from "../downloads/downloadsPanelModel";
  import { getArchivedFavicons } from "../../stores/archivedTabs.svelte";
  import { openCommandBar } from "../../stores/commandBar.svelte";
  import { tooltip } from "../../lib/tooltip";
  import Icon from "../ui/Icon.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "../strip/StripPopover.svelte";

  let { anchor, label, tabs, downloads, onclose }: {
    anchor: HTMLElement;
    label?: string;
    tabs: BridgeArchivedTab[];
    downloads: BridgeDownloadSnapshot[] | null;
    onclose: () => void;
  } = $props();

  const now = Date.now();
  const format = new Intl.RelativeTimeFormat(getFormatLocale(), { numeric: "auto", style: "narrow" });

  function age(archivedAt: number): string {
    const minutes = Math.round((archivedAt - now) / 60_000);
    return Math.abs(minutes) < 60 ? format.format(minutes, "minute") : format.format(Math.round(minutes / 60), "hour");
  }

  // Keyed as native keys it: the URL's host with its port, "www." kept.
  function favicon(url: string): string | undefined {
    try {
      return getArchivedFavicons()[new URL(url).host];
    } catch {
      return undefined;
    }
  }

  function restore(tab: BridgeArchivedTab): void {
    tabActions.restoreArchived([tab.id]);
    onclose();
  }

  const INLINE_LABEL_KEYS: Record<InlineAction, string> = {
    pause: "downloadsPanel.pause",
    resume: "downloadsPanel.resume",
    retry: "common.retry",
  };

  function runInlineAction(download: BridgeDownloadSnapshot, action: InlineAction): void {
    if (action === "pause") downloadActions.pause(download.id);
    if (action === "resume") downloadActions.resume(download.id);
    if (action === "retry") downloadActions.retry(download.id);
  }

  function showDownloads(): void {
    // The panel hands the focus back to what held it as it opened: the anchor, not this closing menu.
    anchor.focus({ preventScroll: true });
    onclose();
    openDownloadsPanel();
  }

  // Only what the menu lists: running downloads stay, as on the Downloads screen.
  function clearDownloads(): void {
    for (const download of downloads ?? []) if (!isActiveDownload(download)) downloadActions.erase(download.id);
  }

  function openDownload(download: BridgeDownloadSnapshot): void {
    if (download.state !== "complete" || download.error) return showDownloads();
    downloadActions.open(download.id);
    onclose();
  }

  function showAll(): void {
    onclose();
    openCommandBar("<");
  }
</script>

<StripPopover {anchor} {onclose} label={label ?? t("archivedTabs.title")}>
  {#if downloads}
    <div class="menu-header">
      <span>{t("downloadsPanel.title")}</span>
      <span class="header-actions">
        {#if downloads.some((download) => !isActiveDownload(download))}
          <button class="header-action" role="menuitem" aria-label={t("downloadsPanel.clearFinished")} use:tooltip={t("downloadsPanel.clearFinished")} onclick={clearDownloads}>
            <Icon name="trash" size={13} />
          </button>
        {/if}
        <button class="header-action" role="menuitem" aria-label={t("archivedTabs.showAllDownloads")} use:tooltip={t("archivedTabs.showAllDownloads")} onclick={showDownloads}>
          <Icon name="arrowUpRight" size={13} />
        </button>
      </span>
    </div>
    {#each downloads as download (download.id)}
      {@const action = inlineAction(download)}
      <div class="download-row" class:with-action={!!action}>
        <button class="menu-row download" role="menuitem" onclick={() => openDownload(download)}>
          <span class="file-tile"><img src={fileIconURL(download)} alt="" width="20" height="20" draggable="false" /></span>
          <span class="row-text">
            <span class="row-title">{download.filename}</span>
            {#if isActiveDownload(download)}
              <span class="row-status">
                <span class="row-progress" class:paused={download.state === "paused"} aria-hidden="true">
                  <span class="row-progress-fill" style={`transform: scaleX(${progress(download) / 100})`}></span>
                </span>
                <span class="row-meta">{Math.round(progress(download))}%</span>
              </span>
            {:else if download.state === "complete" && !download.error}
              <span class="row-meta detail">{metaLine(download, getLocale(), getFormatLocale(), now).detail}</span>
            {:else}
              <span class="row-meta failed">{t("downloadsPanel.stateFailed")}</span>
            {/if}
          </span>
        </button>
        {#if action}
          <button class="row-action" role="menuitem" aria-label={t(INLINE_LABEL_KEYS[action])} onclick={() => runInlineAction(download, action)}>
            <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              {#if action === "pause"}
                <path d="M5.5 3.5v9M10.5 3.5v9" />
              {:else if action === "resume"}
                <path d="M5 3.2v9.6L12.5 8z" />
              {:else}
                <path d="M13 8a5 5 0 1 1-1.6-3.7" /><path d="M13 2.5v3h-3" />
              {/if}
            </svg>
          </button>
        {/if}
      </div>
    {/each}
    {#if tabs.length > 0}
      <div class="menu-separator" role="separator"></div>
    {/if}
  {/if}
  {#if tabs.length > 0}
    <div class="menu-header">
      <span>{t("archivedTabs.title")}</span>
      <button class="header-action" role="menuitem" aria-label={t("archivedTabs.showAll")} use:tooltip={t("archivedTabs.showAll")} onclick={showAll}>
        <Icon name="arrowUpRight" size={13} />
      </button>
    </div>
    {#each tabs as tab (tab.id)}
      <button class="menu-row" role="menuitem" onclick={() => restore(tab)}>
        <SiteFavicon src={favicon(tab.url)} title={tab.title} url={tab.url} size={16} radius={4} />
        <span class="row-title">{tab.title || tab.url}</span>
        <span class="row-age">{age(tab.archivedAt)}</span>
        <span class="row-restore">{t("archivedTabs.restore")}</span>
      </button>
    {/each}
  {/if}
</StripPopover>

<style>
  .menu-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 4px 4px 2px 8px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .header-actions {
    display: flex;
    gap: 2px;
  }

  .header-action {
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
  }

  .header-action:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .header-action:focus-visible {
    outline: var(--focus-outline);
  }

  .download-row {
    position: relative;
    display: flex;
    align-items: center;
  }

  .download-row.with-action .menu-row {
    padding-right: 40px;
  }

  .row-action {
    position: absolute;
    right: 8px;
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-secondary);
  }

  .row-action:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .row-action:focus-visible {
    outline: var(--focus-outline);
  }

  .file-tile {
    flex: none;
    width: 32px;
    height: 32px;
    display: grid;
    place-items: center;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
  }

  .row-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .row-status {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .row-progress {
    flex: 1;
    height: 4px;
    overflow: hidden;
    border-radius: var(--radius-chip);
    background: var(--bg-hover);
  }

  .row-progress-fill {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left;
    transition: transform var(--motion-duration-slow) ease;
  }

  .row-progress.paused .row-progress-fill {
    background: var(--text-muted);
  }

  @media (prefers-reduced-motion: reduce) {
    .row-progress-fill {
      transition: none;
    }
  }

  .menu-row {
    width: 100%;
    height: 32px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 8px;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-md);
    text-align: left;
  }

  .menu-row.download {
    height: 56px;
    gap: 12px;
  }

  .menu-row:hover,
  .menu-row:focus-visible {
    background: var(--bg-hover);
  }

  .menu-row.download:hover .file-tile,
  .menu-row.download:focus-visible .file-tile {
    background: var(--float-surface);
  }

  .row-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .row-age,
  .row-meta,
  .row-restore {
    flex-shrink: 0;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .row-meta.detail {
    flex-shrink: 1;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .row-meta.failed {
    color: var(--danger-text);
  }

  .row-restore {
    color: var(--accent-ink);
  }

  .row-restore,
  .menu-row:hover .row-age,
  .menu-row:focus-visible .row-age {
    display: none;
  }

  .menu-row:hover .row-restore,
  .menu-row:focus-visible .row-restore {
    display: inline;
  }

  .menu-separator {
    height: 1px;
    margin: 6px 8px;
    background: var(--separator);
  }
</style>
