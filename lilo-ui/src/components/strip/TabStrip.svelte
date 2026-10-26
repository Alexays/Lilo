<script lang="ts">
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import NavControls from "../sidebar/NavControls.svelte";
  import KeepAwakeIndicator from "../sidebar/KeepAwakeIndicator.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import StripTab from "./StripTab.svelte";
  import StripFolder from "./StripFolder.svelte";
  import StripSpaceMenu from "./StripSpaceMenu.svelte";
  import StripPopover from "./StripPopover.svelte";
  import MediaCard from "../sidebar/MediaCard.svelte";
  import { getMediaCardTab } from "../../stores/media.svelte";
  import { chromeActions, tabActions } from "../../lib/bridge/actions";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTabId, type TabState } from "../../stores/tabs.svelte";
  import { getAddressPlacement } from "../../stores/tabLayout.svelte";
  import { getActiveUrlBarDrawer } from "../../stores/urlBarDrawer.svelte";
  import { areTrafficLightsVisible, isSidebarVisible } from "../../stores/ui.svelte";
  import { closeSettingsShell, isDownloadsVisible, isSettingsShellOpen, openDownloadsPanel } from "../../stores/panels.svelte";
  import { LINE_ICONS } from "../commandbar/commandBarIcons";
  import { hasSessionDownloads } from "../../stores/downloads.svelte";
  import { isDownloadUiEnabled } from "../../stores/extensions.svelte";
  import { sidebarActions } from "../../lib/bridge/actions";
  import { dndItem, dndZone } from "../../lib/dndEngine/action";
  import { dndItemsForFolderTabs, dndItemsForSidebarItems, type SidebarDndItem } from "../../lib/dndEngine/adapters/sidebar";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tick } from "svelte";
  import { isShadowItem } from "../../lib/dndEngine/projection";
  import { commitSidebarDrop, getZoneItems, resetSidebarDrag, type SidebarZoneRef } from "../../stores/sidebarDnd.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let { edge }: { edge: "top" | "bottom" } = $props();

  const spaceId = $derived(getActiveSpaceId());
  const view = $derived(getSpaceSidebar(spaceId).view);
  const activeTabId = $derived(getActiveTabId(spaceId));
  // Settings is a page of its own here: its pill is the active one, the page's tab steps back.
  const settingsOpen = $derived(isSettingsShellOpen());
  const shownActiveId = $derived(settingsOpen ? "" : activeTabId);
  const editsAddress = $derived(getAddressPlacement() === "tabs");
  // The address field itself shows only when it has something to say (a permission prompt), or while
  // the strip floats in for hidden tabs and the page toolbar that holds it is gone.
  const addressInActiveTab = $derived((editsAddress && getActiveUrlBarDrawer() !== null) || !isSidebarVisible());
  let mediaOpen = $state(false);
  let mediaButton: HTMLButtonElement | undefined = $state();

  // The same drop commit as the sidebar's lists: reorder, and move between favorites, pinned and today.
  type StripSection = "bookmarked" | "pinned" | "unpinned";
  const zoneRef = (section: StripSection): SidebarZoneRef => ({ id: `strip-root-${section}-${spaceId}`, section, parentFolderId: null });
  const baseItems = $derived({
    bookmarked: dndItemsForFolderTabs(view.bookmarked),
    pinned: dndItemsForSidebarItems(view.rootItems.pinned, "pinned"),
    unpinned: dndItemsForSidebarItems(view.rootItems.unpinned, "unpinned"),
  });

  /** A folder's direct children, as the drop commit sees them. */
  function folderChildItems(folderId: string, section: "pinned" | "unpinned"): SidebarDndItem[] {
    const children = (view.treeIndex.childrenByFolderId.get(folderId) ?? []).map((item) => ({ id: item.itemId, kind: item.kind }));
    return dndItemsForSidebarItems(children, section, folderId);
  }

  let stripEl: HTMLElement | undefined = $state();
  let scrollerEl: HTMLDivElement | undefined = $state();
  let overflowStart = $state(false);
  let overflowEnd = $state(false);

  function measureOverflow(): void {
    if (!scrollerEl) return;
    overflowStart = scrollerEl.scrollLeft > 1;
    overflowEnd = scrollerEl.scrollLeft + scrollerEl.clientWidth < scrollerEl.scrollWidth - 1;
  }

  // A mouse wheel scrolls vertically: the strip turns it sideways. It has to be non-passive to keep the page still.
  $effect(() => {
    const el = scrollerEl;
    if (!el) return;
    const wheel = (event: WheelEvent) => {
      if (Math.abs(event.deltaY) <= Math.abs(event.deltaX) || el.scrollWidth <= el.clientWidth) return;
      event.preventDefault();
      el.scrollLeft += event.deltaY;
    };
    const resize = new ResizeObserver(measureOverflow);
    resize.observe(el);
    el.addEventListener("wheel", wheel, { passive: false });
    el.addEventListener("scroll", measureOverflow, { passive: true });
    return () => {
      resize.disconnect();
      el.removeEventListener("wheel", wheel);
      el.removeEventListener("scroll", measureOverflow);
    };
  });

  // The active pill comes into view, and the strip keeps exactly one tab stop.
  $effect(() => {
    void shownActiveId;
    void view;
    void tick().then(() => {
      scrollerEl?.querySelector(settingsOpen ? ".strip-settings" : `[data-tab-id="${activeTabId}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest", behavior: prefersReducedMotion() ? "auto" : "smooth" });
      const rovers = stripEl ? [...stripEl.querySelectorAll<HTMLElement>("[data-roving]")] : [];
      if (rovers.length && !rovers.some((rover) => rover.tabIndex === 0)) rovers[0].tabIndex = 0;
      measureOverflow();
    });
  });

  function handleArrows(event: KeyboardEvent): void {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    const rovers = [...(stripEl?.querySelectorAll<HTMLElement>("[data-roving]") ?? [])];
    const index = rovers.indexOf(document.activeElement as HTMLElement);
    if (index < 0) return;
    event.preventDefault();
    const next = event.key === "Home" ? 0 : event.key === "End" ? rovers.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + rovers.length) % rovers.length;
    rovers[index].tabIndex = -1;
    rovers[next].tabIndex = 0;
    rovers[next].focus();
  }

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
    pressTabsHeader(event);
  }

  function showSidebarMenu(event: MouseEvent) {
    if ((event.target as HTMLElement).closest("button, .strip-tab, .url-display")) return;
    event.preventDefault();
    chromeActions.showSidebarContextMenu({ x: event.clientX, y: event.clientY, width: 1, height: 1, spaceId });
  }
</script>

{#snippet items(section: StripSection)}
  {@const zone = zoneRef(section)}
  {@const iconOnly = section !== "unpinned"}
  {#each getZoneItems(zone, baseItems[section]) as item (item.id)}
    <div
      class="strip-slot"
      class:icon-only={iconOnly}
      use:dndItem={{ item, zoneId: zone.id, disabled: isShadowItem(item), onCancel: resetSidebarDrag }}
    >
      {#if isShadowItem(item)}
        <div class="strip-placeholder" aria-hidden="true"></div>
      {:else if item.kind === "folder"}
        {@const folder = view.foldersById.get(item.id)}
        {#if folder}
          <StripFolder {folder} tabs={folderTabs(folder.id)} activeTabId={shownActiveId} {spaceId} childItems={folderChildItems(folder.id, section === "pinned" ? "pinned" : "unpinned")} section={section === "pinned" ? "pinned" : "unpinned"} />
        {/if}
      {:else}
        {@const tab = view.tabsById.get(item.id)}
        {#if tab && !(tab.id === activeTabId && addressInActiveTab && !iconOnly)}
          <StripTab {tab} active={tab.id === shownActiveId} {iconOnly} {editsAddress} />
        {/if}
      {/if}
    </div>
  {/each}
{/snippet}

{#snippet zoneOf(section: StripSection)}
  {@const zone = zoneRef(section)}
  <div
    class={section === "unpinned" ? "today-list" : "group"}
    use:dndZone={{
      id: zone.id,
      axis: "horizontal",
      meta: { section, spaceId, parentFolderId: null },
      getItems: () => getZoneItems(zone, baseItems[section]) as SidebarDndItem[],
      onDrop: (drag) => commitSidebarDrop(zone, baseItems[section], sidebarActions.commitDrop, drag),
      onCancel: resetSidebarDrag,
    }}
  >
    {@render items(section)}
  </div>
{/snippet}

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<nav
  bind:this={stripEl}
  class="tab-strip"
  class:dock={edge === "bottom"}
  aria-label={t("strip.ariaLabel")}
  onkeydown={handleArrows}
  onpointerdown={startWindowDrag}
  ondblclick={(event) => {
    if (!(event.target as HTMLElement).closest("button, .strip-tab, .url-display")) chromeActions.maximizeWindow();
  }}
  oncontextmenu={showSidebarMenu}
>
  {#if edge === "top" && areTrafficLightsVisible()}<div class="lights-spacer"></div>{/if}
  {#if edge === "top" || !isSidebarVisible()}
    <NavControls show="history" />
  {/if}

  <StripSpaceMenu />

  <!-- Laid out by the strip; only the tabs are in the list. -->
  <div class="strip-tabs" role="tablist" aria-orientation="horizontal" aria-label={t("strip.ariaLabel")}>
  <!-- The active tab's address heads the row, outside its scroller: its drawers and cards must not be clipped. -->
  {#if addressInActiveTab}
    <div class="strip-address"><URLDisplay /></div>
  {/if}

  <!-- Every tab scrolls as one row, as in the sidebar. -->
  <div class="scroller" class:overflow-start={overflowStart} class:overflow-end={overflowEnd} bind:this={scrollerEl}>
    {#if view.bookmarked.length}
      {@render zoneOf("bookmarked")}
    {/if}

    {#if view.rootItems.pinned.length}
      <span class="divider" aria-hidden="true"></span>
      {@render zoneOf("pinned")}
    {/if}

    <span class="divider" aria-hidden="true"></span>

    {@render zoneOf("unpinned")}
    {#if settingsOpen}
      <div class="strip-settings">
        <button class="strip-settings-main" role="tab" aria-selected="true" tabindex="0" data-roving>
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true">
            <path d={LINE_ICONS.gear} stroke-linejoin="round" />
          </svg>
          {t("settings.panelTitle")}
        </button>
        <button class="strip-settings-close" tabindex="-1" aria-label={t("common.close")} onclick={closeSettingsShell}>
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
          </svg>
        </button>
      </div>
    {/if}
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

  </div>

  <div class="trailing">
    {#if getMediaCardTab()}
      <!-- No room for the card in a strip: it opens from its icon. -->
      <button
        bind:this={mediaButton}
        class="strip-btn"
        class:on={mediaOpen}
        aria-label={getMediaCardTab()?.title}
        aria-expanded={mediaOpen}
        onclick={() => (mediaOpen = !mediaOpen)}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M6 12V3.5l7-1.5V10.5" />
          <circle cx="4.5" cy="12" r="1.5" />
          <circle cx="11.5" cy="10.5" r="1.5" />
        </svg>
      </button>
      {#if mediaOpen && mediaButton}
        <StripPopover anchor={mediaButton} label={getMediaCardTab()?.title ?? ""} onclose={() => (mediaOpen = false)}>
          <MediaCard />
        </StripPopover>
      {/if}
    {/if}
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
    <NavControls show="toggle" />
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
    border-radius: var(--radius-xl);
    background: color-mix(in srgb, var(--sidebar-bg) 55%, var(--bg-elevated));
    box-shadow: 0 0 0 0.5px var(--border), 0 6px 20px var(--sidebar-shadow);
  }

  /* The sidebar header spreads its controls; the strip keeps them together. */
  .tab-strip :global(.nav-controls) {
    flex: none;
  }

  .tab-strip > :global(.nav-controls) {
    margin-right: 6px;
  }

  .lights-spacer {
    width: 72px;
    flex: none;
  }

  .strip-tabs {
    display: contents;
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

  /* Today's pills shrink to their icon, then the whole row scrolls sideways. */
  .scroller {
    flex: 1 1 200px;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 4px;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .scroller::-webkit-scrollbar {
    display: none;
  }

  /* Pills scrolled out of sight fade at the edge they went past. */
  .scroller.overflow-start {
    mask-image: linear-gradient(to right, transparent, black 24px);
  }

  .scroller.overflow-end {
    mask-image: linear-gradient(to left, transparent, black 24px);
  }

  .scroller.overflow-start.overflow-end {
    mask-image: linear-gradient(to right, transparent, black 24px, black calc(100% - 24px), transparent);
  }

  /* Never narrower than its pills at their smallest: past that the row scrolls, rather than pills sliding under what follows. */
  .today-list {
    flex: 1;
    min-width: min-content;
    display: flex;
    align-items: center;
    gap: 4px;
  }

  /* The slot carries the pill's flex sizing so the drag engine sees the pill's own box. */
  .strip-slot {
    display: flex;
    flex: 0 1 170px;
    min-width: 32px;
  }

  /* A width, not just a flex basis: WebKit sizes a group on its slots' widths and would leave the active pill overflowing. */
  .strip-slot:has(> :global(.strip-tab.active)) {
    flex: none;
    width: 260px;
  }

  .strip-slot.icon-only,
  .strip-slot:has(> :global(.strip-folder)),
  .strip-slot:has(> :global(.strip-split)) {
    flex: none;
  }

  .strip-slot:empty {
    display: none;
  }

  /* A hairline between two resting pills, gone beside the active or hovered one. */
  .today-list .strip-slot + .strip-slot {
    position: relative;
  }

  .today-list .strip-slot + .strip-slot::before {
    content: "";
    position: absolute;
    left: -2.5px;
    top: 9px;
    bottom: 9px;
    width: 1px;
    background: var(--separator);
  }

  .today-list .strip-slot:has(> :global(.strip-tab.active)) + .strip-slot::before,
  .today-list .strip-slot:has(> :global(.strip-tab.active))::before,
  .today-list .strip-slot:hover::before,
  .today-list .strip-slot:hover + .strip-slot::before {
    display: none;
  }

  .strip-slot > :global(.strip-tab) {
    flex: 1;
  }

  .strip-placeholder {
    width: 100%;
    height: 32px;
    border-radius: var(--radius-sm);
    background: var(--accent-tint-12);
  }

  /* The active pill's look, sized to its label. */
  .strip-settings {
    flex: none;
    height: 32px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-sm);
    background: var(--bg-selected);
    color: var(--text-primary);
    box-shadow: var(--shadow-control);
  }

  .strip-settings-main {
    height: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 6px 0 8px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: default;
  }

  .strip-settings-close {
    flex: none;
    width: 20px;
    height: 20px;
    margin-right: 5px;
    border: 0;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    background: transparent;
    color: var(--text-secondary);
  }

  .strip-settings-close:hover {
    background: var(--bg-hover);
  }

  .strip-address {
    position: relative;
    flex: 0 1 260px;
    min-width: 160px;
  }

  .strip-address > :global(.url-display) {
    padding: 0;
  }

  /* An open drawer grows the address toward the page, never shifting the bar itself. */
  .tab-strip:not(.dock) .strip-address {
    align-self: flex-start;
    margin-top: calc((var(--top-strip-height) - 32px) / 2);
  }

  .dock .strip-address {
    align-self: flex-end;
    margin-bottom: calc((var(--bottom-dock-height) - 32px) / 2);
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
    width: 32px;
    height: 32px;
    border: 0;
    border-radius: var(--radius-sm);
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
