<script lang="ts">
  import NavControls from "../sidebar/NavControls.svelte";
  import KeepAwakeIndicator from "../sidebar/KeepAwakeIndicator.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import StripTab from "./StripTab.svelte";
  import StripFolder from "./StripFolder.svelte";
  import StripSpaceMenu from "./StripSpaceMenu.svelte";
  import { chromeActions, tabActions } from "../../lib/bridge/actions";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTabId, type TabState } from "../../stores/tabs.svelte";
  import { getAddressPlacement } from "../../stores/tabLayout.svelte";
  import { areTrafficLightsVisible } from "../../stores/ui.svelte";
  import { isDownloadsVisible, openDownloadsPanel } from "../../stores/panels.svelte";
  import { hasSessionDownloads } from "../../stores/downloads.svelte";
  import { isDownloadUiEnabled } from "../../stores/extensions.svelte";
  import type { RootItem } from "../../stores/sidebarView";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let { edge }: { edge: "top" | "bottom" } = $props();

  const spaceId = $derived(getActiveSpaceId());
  const view = $derived(getSpaceSidebar(spaceId).view);
  const activeTabId = $derived(getActiveTabId(spaceId));
  const addressInActiveTab = $derived(getAddressPlacement() === "tabs");

  /** A folder's tabs, nested folders flattened: the popover lists them in sidebar order. */
  function folderTabs(folderId: string): TabState[] {
    const tabs: TabState[] = [];
    for (const item of view.treeIndex.childrenByFolderId.get(folderId) ?? []) {
      if (item.kind === "folder") tabs.push(...folderTabs(item.itemId));
      else {
        const tab = view.tabsById.get(item.itemId);
        if (tab && !tab.isClosed) tabs.push(tab);
      }
    }
    return tabs;
  }

  function startWindowDrag(event: PointerEvent) {
    if (event.button !== 0) return;
    if ((event.target as HTMLElement | null)?.closest("button, a, input, [role='button'], .url-display, .strip-tab")) return;
    chromeActions.startWindowDrag();
  }

  function showSidebarMenu(event: MouseEvent) {
    if ((event.target as HTMLElement).closest("button, .strip-tab, .url-display")) return;
    event.preventDefault();
    chromeActions.showSidebarContextMenu({ x: event.clientX, y: event.clientY, width: 1, height: 1, spaceId });
  }
</script>

{#snippet items(list: RootItem[], iconOnly: boolean)}
  {#each list as item (item.id)}
    {#if item.kind === "folder"}
      {@const folder = view.foldersById.get(item.id)}
      {#if folder}
        <StripFolder {folder} tabs={folderTabs(folder.id)} {activeTabId} />
      {/if}
    {:else}
      {@const tab = view.tabsById.get(item.id)}
      {#if tab && !(tab.id === activeTabId && addressInActiveTab && !iconOnly)}
        <StripTab {tab} active={tab.id === activeTabId} {iconOnly} />
      {/if}
    {/if}
  {/each}
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<nav
  class="tab-strip"
  class:dock={edge === "bottom"}
  aria-label={t("strip.ariaLabel")}
  onpointerdown={startWindowDrag}
  ondblclick={(event) => {
    if (!(event.target as HTMLElement).closest("button, .strip-tab, .url-display")) chromeActions.maximizeWindow();
  }}
  oncontextmenu={showSidebarMenu}
>
  {#if edge === "top"}
    {#if areTrafficLightsVisible()}<div class="lights-spacer"></div>{/if}
    <NavControls />
  {/if}

  <StripSpaceMenu />

  {#if view.bookmarked.length}
    <div class="group">
      {#each view.bookmarked as tab (tab.id)}
        <StripTab {tab} active={tab.id === activeTabId} iconOnly />
      {/each}
    </div>
  {/if}

  {#if view.rootItems.pinned.length}
    <span class="divider" aria-hidden="true"></span>
    <div class="group">{@render items(view.rootItems.pinned, true)}</div>
  {/if}

  <span class="divider" aria-hidden="true"></span>

  <!-- The active tab's address heads the row, outside its scroller: its drawers and cards must not be clipped. -->
  {#if addressInActiveTab}
    <div class="strip-address"><URLDisplay /></div>
  {/if}

  <div class="today">
    {@render items(view.rootItems.unpinned, false)}
    <button
      class="strip-btn"
      aria-label={t("tabItem.newTab")}
      use:tooltip={{ text: t("tabItem.newTab"), shortcut: shortcutKeys("tab.new"), placement: edge === "top" ? "bottom" : "top" }}
      onclick={() => tabActions.create()}
    >
      <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
      </svg>
    </button>
  </div>

  <div class="trailing">
    {#if isDownloadUiEnabled() && hasSessionDownloads()}
      <button
        class="strip-btn"
        class:on={isDownloadsVisible()}
        aria-label={t("bottomBar.downloads")}
        use:tooltip={{ text: t("bottomBar.downloads"), shortcut: shortcutKeys("downloads.show"), placement: edge === "top" ? "bottom" : "top" }}
        onclick={() => openDownloadsPanel()}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M8 2v8M5 7l3 3 3-3" />
          <path d="M3 12h10" />
        </svg>
      </button>
    {/if}
    <KeepAwakeIndicator />
  </div>
</nav>

<style>
  .tab-strip {
    height: var(--top-strip-height);
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 10px 0 12px;
    box-sizing: border-box;
    min-width: 0;
  }

  /* Floating, off the window's edges, toward the page. */
  .tab-strip.dock {
    height: var(--bottom-dock-height);
    margin: 0 var(--bottom-dock-margin);
    padding: 0 10px;
    border-radius: 16px;
    background: color-mix(in srgb, var(--sidebar-bg) 82%, rgba(255, 255, 255, 0.5));
    box-shadow: 0 0 0 0.5px var(--border), 0 6px 20px var(--sidebar-shadow);
  }

  .lights-spacer {
    width: 64px;
    flex: none;
  }

  .group {
    display: flex;
    align-items: center;
    gap: 2px;
    flex: none;
  }

  .divider {
    width: 1px;
    height: 18px;
    margin: 0 4px;
    flex: none;
    background: var(--separator);
  }

  /* Pills shrink to their icon, then the row scrolls sideways. */
  .today {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 4px;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .today::-webkit-scrollbar {
    display: none;
  }

  .strip-address {
    position: relative;
    flex: 0 1 300px;
    min-width: 180px;
  }

  .strip-address > :global(.url-display) {
    padding: 0;
  }

  /* An open drawer grows the address toward the page, never shifting the bar itself. */
  .tab-strip:not(.dock) .strip-address {
    align-self: flex-start;
    margin-top: 7px;
  }

  .dock .strip-address {
    align-self: flex-end;
    margin-bottom: 9px;
  }

  .dock .strip-address > :global(.url-display) {
    display: flex;
    flex-direction: column-reverse;
  }

  .trailing {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: none;
  }

  .strip-btn {
    flex: none;
    width: 30px;
    height: 30px;
    border: 0;
    border-radius: 8px;
    display: grid;
    place-items: center;
    background: transparent;
    color: var(--text-secondary);
  }

  .strip-btn:hover,
  .strip-btn.on {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
</style>
