<script lang="ts">
  import { t, getLocale } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { on, type BridgeDownloadSnapshot } from "../../lib/bridge";
  import { downloadActions } from "../../lib/bridge/actions";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import DownloadsList from "./DownloadsList.svelte";
  import {
    closeActivePanel,
    isDownloadsVisible,
  } from "../../stores/panels.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { filterDownloads, groupDownloads } from "./downloadsPanelModel";

  type Download = BridgeDownloadSnapshot;

  let _downloads = $state.raw<Download[]>([]);
  let _snapshotLoaded = $state(false);
  let searchQuery = $state("");
  let selectedDownloadId = $state<number | null>(null);

  $effect(() => {
    const unsubSnapshot = on("downloadsSnapshot", (data) => {
      _downloads = [...data.items].sort((a, b) => b.startedAt - a.startedAt);
      _snapshotLoaded = true;
    });

    const unsubUpdated = on("downloadUpdated", (data) => {
      const idx = _downloads.findIndex((d) => d.id === data.id);
      if (idx >= 0) {
        // One write, no re-sort: a progress tick never changes startedAt, so order is invariant.
        _downloads = _downloads.with(idx, data);
      } else {
        _downloads = [data, ..._downloads];
      }
    });

    const unsubErased = on("downloadErased", (data) => {
      _downloads = _downloads.filter((d) => d.id !== data.id);
    });

    return () => {
      unsubSnapshot();
      unsubUpdated();
      unsubErased();
    };
  });

  $effect(() => {
    if (isDownloadsVisible()) downloadActions.requestSnapshot();
  });

  $effect(() =>
    on("downloadMenuAction", (data) => {
      const dl = _downloads.find((d) => d.id === data.id);
      if (!dl) return;
      switch (data.action) {
        case "open":
          downloadActions.open(dl.id);
          break;
        case "quickLook":
          downloadActions.quickLook(dl.id);
          break;
        case "showInFinder":
          downloadActions.showInFinder(dl.id);
          break;
        case "deleteFile":
          downloadActions.removeFile(dl.id);
          break;
        case "removeFromList":
          erase(dl);
          break;
        case "cancel":
          downloadActions.cancel(dl.id);
          break;
        case "retry":
          downloadActions.retry(dl.id);
          break;
      }
    }),
  );

  const filtered = $derived(filterDownloads(_downloads, searchQuery));
  const groups = $derived(groupDownloads(filtered, Date.now(), getLocale()));

  const hasFinishedDownloads = $derived(
    _downloads.some((d) => d.state === "complete" || d.state === "interrupted"),
  );

  // Selection follows the list: reset when the selected item disappears.
  $effect(() => {
    if (
      selectedDownloadId !== null &&
      !_downloads.some((d) => d.id === selectedDownloadId)
    ) {
      selectedDownloadId = null;
    }
  });

  function showMenu(dl: Download, anchor: DOMRect): void {
    downloadActions.showContextMenu(
      dl.id,
      anchor.x,
      anchor.y,
      anchor.width,
      anchor.height,
      dl.state,
      dl.fileMissing,
    );
  }

  function erase(dl: Download): void {
    downloadActions.erase(dl.id);
    _downloads = _downloads.filter((d) => d.id !== dl.id);
  }

  function clearFinished(): void {
    const finished = _downloads.filter(
      (d) => d.state === "complete" || d.state === "interrupted",
    );
    finished.forEach((d) => downloadActions.erase(d.id));
    _downloads = _downloads.filter(
      (d) => d.state !== "complete" && d.state !== "interrupted",
    );
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (!isDownloadsVisible() || e.defaultPrevented) return;
    const target = e.target as HTMLElement;
    if (e.key === "Escape") {
      if (target instanceof HTMLInputElement && target.value) return;
      e.preventDefault();
      closeActivePanel();
      return;
    }
    if (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable) return;
    if (e.code === "Space" && selectedDownloadId !== null) {
      e.preventDefault();
      downloadActions.quickLook(selectedDownloadId);
    }
  }
</script>

<svelte:window onkeydown={handleKeyDown} />

{#if isDownloadsVisible()}
  <div class="panel-shell downloads-panel" role="dialog" aria-label={t("downloadsPanel.title")}>
    <PanelHeader title={t("downloadsPanel.title")} onclose={closeActivePanel}>
      {#snippet actions()}
        <button
          class="hdr-ctl"
          type="button"
          onclick={downloadActions.showFolder}
          use:tooltip={{ text: t("downloadsPanel.showFolder"), placement: "bottom" }}
          aria-label={t("downloadsPanel.showFolder")}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.5 1.5h4.9A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" /></svg>
        </button>
        <button
            class="hdr-ctl"
            type="button"
            disabled={!hasFinishedDownloads}
            onclick={clearFinished}
            use:tooltip={{ text: t("downloadsPanel.clearFinished"), placement: "bottom" }}
            aria-label={t("downloadsPanel.clearFinished")}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" /></svg>
          </button>
      {/snippet}
    </PanelHeader>

    <div class="downloads-filter" {@attach (node) => node.querySelector("input")?.focus({ preventScroll: true })}>
      <UiSearchField
        placeholder={t("downloadsPanel.searchPlaceholder")}
        ariaLabel={t("downloadsPanel.searchPlaceholder")}
        value={searchQuery}
        onchange={(value) => (searchQuery = value)}
      />
    </div>

    {#if _snapshotLoaded}
      <DownloadsList
        {groups}
        hasAnyDownloads={_downloads.length > 0}
        hasFilteredResults={filtered.length > 0}
        selectedId={selectedDownloadId}
        onselect={(id) => (selectedDownloadId = id)}
        onmenu={showMenu}
      />
    {:else}
      <p class="downloads-loading">{t("downloadsPanel.loading")}</p>
    {/if}
  </div>
{/if}

<style>
  .downloads-panel {
    background: transparent;
  }

  .downloads-filter {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px 4px;
    flex-shrink: 0;
  }

  .downloads-filter :global(.ui-search-field) {
    flex: 1;
    min-width: 0;
  }

  .downloads-loading {
    margin: 0;
    padding: 32px 16px;
    text-align: center;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }
</style>
