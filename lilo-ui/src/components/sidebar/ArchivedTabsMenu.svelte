<!-- The tabs the idle sweep or Clear archived in the last day, one click from coming back; the command bar keeps the rest.
     Running and failed downloads sit on top when the downloads UI is on: both share the sidebar's bottom-left slot. -->
<script lang="ts">
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { downloadActions, tabActions } from "../../lib/bridge/actions";
  import type { BridgeArchivedTab, BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { progress } from "../../lib/downloadFormat";
  import { isActiveDownload } from "../../stores/downloads.svelte";
  import { openDownloadsPanel } from "../../stores/panels.svelte";
  import { fileIconURL, inlineAction, type InlineAction } from "../downloads/downloadsPanelModel";
  import { getArchivedFavicons } from "../../stores/archivedTabs.svelte";
  import { openCommandBar } from "../../stores/commandBar.svelte";
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
  const format = new Intl.RelativeTimeFormat(getLocale(), { numeric: "auto", style: "narrow" });

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

  function showAll(): void {
    onclose();
    openCommandBar("<");
  }
</script>

<StripPopover {anchor} {onclose} label={label ?? t("archivedTabs.title")}>
  {#if downloads}
    <div class="menu-header">
      <span>{t("downloadsPanel.title")}</span>
      <button class="header-link" role="menuitem" aria-label={t("archivedTabs.showAllDownloads")} onclick={showDownloads}>
        {t("common.showAll")}
      </button>
    </div>
    {#each downloads as download (download.id)}
      {@const action = inlineAction(download)}
      <div class="download-row" class:with-action={!!action}>
        <button class="menu-row" role="menuitem" onclick={showDownloads}>
          <img src={fileIconURL(download)} alt="" width="16" height="16" draggable="false" />
          <span class="row-title">
            {download.filename}
            {#if isActiveDownload(download)}
              <span class="row-progress" class:paused={download.state === "paused"} aria-hidden="true">
                <span class="row-progress-fill" style={`transform: scaleX(${progress(download) / 100})`}></span>
              </span>
            {/if}
          </span>
          <span class="row-meta" class:failed={!isActiveDownload(download)}>
            {isActiveDownload(download) ? `${Math.round(progress(download))}%` : t("downloadsPanel.stateFailed")}
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
      <button class="header-link" role="menuitem" aria-label={t("archivedTabs.showAll")} onclick={showAll}>
        {t("common.showAll")}
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
    align-items: baseline;
    justify-content: space-between;
    padding: 4px 8px 2px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .header-link {
    padding: 0;
    border: 0;
    background: none;
    color: var(--text-secondary);
    font: inherit;
  }

  .header-link:hover,
  .header-link:focus-visible {
    color: var(--text-primary);
  }

  .download-row {
    position: relative;
    display: flex;
    align-items: center;
  }

  .download-row.with-action .menu-row {
    padding-right: 34px;
  }

  .row-action {
    position: absolute;
    right: 6px;
    width: 22px;
    height: 22px;
    display: grid;
    place-items: center;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
  }

  .row-action:hover,
  .row-action:focus-visible {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .row-progress {
    display: block;
    height: 3px;
    margin-top: 4px;
    overflow: hidden;
    border-radius: var(--radius-full);
    background: var(--bg-hover);
  }

  .row-progress-fill {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left;
    transition: transform 0.3s ease;
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
    border-radius: calc(var(--float-radius-popover) - 6px);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .menu-row:hover,
  .menu-row:focus-visible {
    background: var(--bg-hover);
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
    font-size: var(--font-size-xs);
  }

  .row-meta.failed {
    color: var(--danger);
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
    margin: 4px 6px;
    background: var(--separator);
  }
</style>
