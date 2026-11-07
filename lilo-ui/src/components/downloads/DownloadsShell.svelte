<script lang="ts">
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { on, type BridgeDownloadSnapshot } from "../../lib/bridge";
  import { downloadActions } from "../../lib/bridge/actions";
  import UiMoreMenu from "../ui/UiMoreMenu.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import DownloadsList from "./DownloadsList.svelte";
  import DownloadsNav from "./DownloadsNav.svelte";
  import { filterDownloads, groupDownloads } from "./downloadsPanelModel";
  import { closePageShell, isDownloadsVisible } from "../../stores/panels.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";
  import {
    arePageDownloadsLoaded,
    clearFinishedDownloads,
    eraseDownload,
    getDownloadsQuery,
    getPageDownloads,
    hasFinishedDownloads,
    loadPageDownloads,
    setDownloadsQuery,
  } from "../../stores/downloadsPage.svelte";

  const open = $derived(isDownloadsVisible());
  const downloads = $derived(getPageDownloads());
  const query = $derived(getDownloadsQuery());
  const filtered = $derived(filterDownloads(downloads, query));
  const groups = $derived(groupDownloads(filtered, Date.now(), getFormatLocale()));
  let selectedId = $state<number | null>(null);

  $effect(() => {
    if (open) loadPageDownloads();
    else selectedId = null;
  });

  // Selection follows the list: it goes with its download.
  $effect(() => {
    if (selectedId !== null && !downloads.some((d) => d.id === selectedId)) selectedId = null;
  });

  $effect(() =>
    on("downloadMenuAction", (data) => {
      const dl = downloads.find((d) => d.id === data.id);
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
          eraseDownload(dl);
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

  function showMenu(dl: BridgeDownloadSnapshot, anchor: DOMRect): void {
    downloadActions.showContextMenu(dl.id, anchor.x, anchor.y, anchor.width, anchor.height, dl.state, dl.fileMissing);
  }

  // Escape unwinds one level: the search, then the screen.
  function handleKeydown(event: KeyboardEvent): void {
    if (!open || event.defaultPrevented) return;
    const target = event.target as HTMLElement;
    if (event.key === "Escape") {
      if (target instanceof HTMLInputElement && target.value) return;
      event.preventDefault();
      if (query) setDownloadsQuery("");
      else closePageShell();
      return;
    }
    if (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable) return;
    if (event.code === "Space" && selectedId !== null) {
      event.preventDefault();
      downloadActions.quickLook(selectedId);
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#snippet downloadsNav(compact: boolean)}<DownloadsNav {compact} />{/snippet}

<UiShellFrame
  active={open}
  ariaLabel={t("downloadsPanel.title")}
  interactiveZoneId="downloads-shell"
  title={query.trim() ? t("downloadsPanel.searchResults") : t("downloadsPanel.allDownloads")}
  nav={isVerticalLayout() ? undefined : downloadsNav}
>
  {#snippet actions()}
    <UiMoreMenu
      label={t("downloadsPanel.moreActions")}
      items={[
        { label: t("downloadsPanel.showFolder"), onclick: () => downloadActions.showFolder() },
        { label: t("downloadsPanel.clearFinished"), onclick: clearFinishedDownloads, danger: true, disabled: !hasFinishedDownloads() },
      ]}
    />
  {/snippet}
  {#if arePageDownloadsLoaded()}
    <DownloadsList
      {groups}
      hasAnyDownloads={downloads.length > 0}
      hasFilteredResults={filtered.length > 0}
      {selectedId}
      onselect={(id) => (selectedId = id)}
      onmenu={showMenu}
    />
  {/if}
</UiShellFrame>
