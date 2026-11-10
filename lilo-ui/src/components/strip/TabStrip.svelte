<script lang="ts">
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import NavControls from "../sidebar/NavControls.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import StripTab from "./StripTab.svelte";
  import StripFolder from "./StripFolder.svelte";
  import StripSpaceMenu from "./StripSpaceMenu.svelte";
  import StripPopover from "./StripPopover.svelte";
  import { getRecentArchivedTabs } from "../../stores/archivedTabs.svelte";
  import MediaCard from "../sidebar/MediaCard.svelte";
  import UpdateCard from "../sidebar/UpdateCard.svelte";
  import { getCallCardTab, getMediaCardTab } from "../../stores/media.svelte";
  import { getChosenAppIcon, getReadyUpdate, getSetting } from "../../stores/settings.svelte";
  import { getMeeting } from "../../stores/meeting.svelte";
  import { getConversationTab } from "../../stores/folders.svelte";
  import { chromeActions, tabActions } from "../../lib/bridge/actions";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTabId, type TabState } from "../../stores/tabs.svelte";
  import { getAddressPlacement, isAddressInPageToolbar, isAddressVisible } from "../../stores/tabLayout.svelte";
  import { getActiveUrlBarDrawer } from "../../stores/urlBarDrawer.svelte";
  import { areTrafficLightsVisible, isSidebarVisible } from "../../stores/ui.svelte";
  import {
    closePageShell,
    getPageShell,
    isDownloadsVisible,
    openDownloadsPanel,
  } from "../../stores/panels.svelte";
  import { LINE_ICONS } from "../commandbar/commandBarIcons";
  import Icon from "../ui/Icon.svelte";
  import { hasSessionDownloads } from "../../stores/downloads.svelte";
  import { isDownloadUiEnabled } from "../../stores/extensions.svelte";
  import { sidebarActions } from "../../lib/bridge/actions";
  import { dndItem, dndZone } from "../../lib/dndEngine/action";
  import { dndItemsForFolderTabs, dndItemsForSidebarItems, FLIP_MAX_ANIMATED_ITEMS, flipDurationForSidebarDndItem, type SidebarDndItem } from "../../lib/dndEngine/adapters/sidebar";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { isUserScrolling, trackUserScroll } from "../../lib/motion/userScroll";
  import { translateFlip } from "../../lib/motion/translateFlip";
  import { springEase } from "../../lib/motion/spring";
  import { tick } from "svelte";
  import { isShadowItem } from "../../lib/dndEngine/projection";
  import { commitSidebarDrop, getRecentlyDroppedId, getSidebarDrag, getZoneItems, resetSidebarDrag, type SidebarZoneRef } from "../../stores/sidebarDnd.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let { edge }: { edge: "top" | "bottom" } = $props();

  const spaceId = $derived(getActiveSpaceId());
  const view = $derived(getSpaceSidebar(spaceId).view);
  const activeTabId = $derived(getActiveTabId(spaceId));
  const recentArchived = $derived(getRecentArchivedTabs());
  let archiveButton: HTMLButtonElement | undefined = $state();
  let archiveOpen = $state(false);
  // A system screen opens over the page as a surface of its own: its pill is the active tab, the page's tab steps back.
  const SURFACES = {
    settings: { icon: LINE_ICONS.gear, labelKey: "settings.panelTitle" },
    history: { icon: LINE_ICONS.history, labelKey: "historyPage.title" },
    downloads: { icon: LINE_ICONS.download, labelKey: "downloadsPanel.title" },
    processes: {
      icon: "M4.5 4.5h7v7h-7zM6.5 2v2.5M9.5 2v2.5M6.5 11.5V14M9.5 11.5V14M2 6.5h2.5M2 9.5h2.5M11.5 6.5H14M11.5 9.5H14",
      labelKey: "processManager.title",
    },
    diagnostics: { icon: LINE_ICONS.pulse, labelKey: "diagnostics.title" },
  } as const;
  const surface = $derived.by(() => {
    const shell = getPageShell();
    return shell ? { icon: SURFACES[shell].icon, label: t(SURFACES[shell].labelKey), close: closePageShell } : null;
  });
  const shownActiveId = $derived(surface ? "" : activeTabId);
  const editsAddress = $derived(getAddressPlacement() === "tabs");
  // The address field itself shows only when it has something to say (a permission prompt), or while
  // the strip floats in for hidden tabs and the page toolbar that holds it is gone.
  const addressInActiveTab = $derived(isAddressVisible() && !isAddressInPageToolbar() && (getActiveUrlBarDrawer() !== null || !isSidebarVisible()));
  let callOpen = $state(false);
  let callButton: HTMLButtonElement | undefined = $state();
  let mediaOpen = $state(false);
  let mediaButton: HTMLButtonElement | undefined = $state();
  let meetingOpen = $state(false);
  let meetingButton: HTMLButtonElement | undefined = $state();
  let updateOpen = $state(false);
  let updateButton: HTMLButtonElement | undefined = $state();

  // The same drop commit as the sidebar's lists: reorder, and move between favorites, pinned and today.
  type StripSection = "bookmarked" | "pinned" | "unpinned";
  const zoneRef = (section: StripSection): SidebarZoneRef => ({ id: `strip-root-${section}-${spaceId}`, section, parentFolderId: null });
  // The sidebar's section colors: a drag shows which list the tab lands in.
  const ZONE_COLORS: Record<StripSection, string> = { bookmarked: "var(--color-bookmark)", pinned: "var(--color-pin)", unpinned: "var(--accent)" };
  const drag = $derived(getSidebarDrag());
  // Only a change of list is worth a tint: a reorder within one already shows by its placeholder.
  const crossedZoneId = $derived(drag?.target && drag.target.section !== drag.source.section ? drag.target.id : undefined);
  /** The color a divider takes while the drag carries an item across it, from one side's list to the other's. */
  function crossingColor(left: StripSection, right: StripSection): string | undefined {
    const from = drag?.source.section;
    const to = drag?.target?.section;
    if (!from || !to || drag?.target?.parentFolderId) return undefined;
    return (from === left && to === right) || (from === right && to === left) ? ZONE_COLORS[left] : undefined;
  }
  const pinnedDividerColor = $derived(crossingColor("bookmarked", "pinned"));
  const todayDividerColor = $derived(crossingColor(view.rootItems.pinned.length ? "pinned" : "bookmarked", "unpinned"));
  // Keyed on the structure: a tab's runtime patch hands out a new view, and new items would re-run the animated
  // each below, a FLIP measure of every pill.
  const rootPinned = $derived(view.rootItems.pinned);
  const rootUnpinned = $derived(view.rootItems.unpinned);
  const bookmarkIdsKey = $derived(view.bookmarked.map((tab) => tab.id).join("\n"));
  const baseItems = $derived({
    bookmarked: dndItemsForFolderTabs(bookmarkIdsKey ? bookmarkIdsKey.split("\n").map((id) => ({ id })) : []),
    pinned: dndItemsForSidebarItems(rootPinned, "pinned"),
    unpinned: dndItemsForSidebarItems(rootUnpinned, "unpinned"),
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
  let compactSpace = $state(false);
  let spaceChipWidth = 0;
  // Today's inactive pills fold to their icon once their titles would go under FOLD_MIN_WIDTH.
  let folded = $state(false);
  const FOLD_MIN_WIDTH = 96;
  const FOLDED_WIDTH = 32;
  const FOLDABLE = ".today-list > .strip-slot:not(.active, .icon-only):not(:has(> .strip-folder, > .strip-split, > .strip-conversation.active))";

  function measureEdges(): void {
    if (!scrollerEl) return;
    overflowStart = scrollerEl.scrollLeft > 1;
    overflowEnd = scrollerEl.scrollLeft + scrollerEl.clientWidth < scrollerEl.scrollWidth - 1;
  }

  // Scrolling leaves the fit unchanged: only a resize or a new set of pills measures it again.
  // Out of room, the Space chip drops its name, then today's pills fold to their icon, then the row scrolls.
  // Each step comes back only once it fits beside the rest, so the row cannot flip between two states.
  function measureOverflow(): void {
    measureEdges();
    if (!scrollerEl) return;
    const chip = stripEl?.querySelector<HTMLElement>(".space-chip");
    if (scrollerEl.scrollWidth > scrollerEl.clientWidth + 1) {
      if (chip && !compactSpace) {
        spaceChipWidth = chip.offsetWidth;
        compactSpace = true;
        // Still out of room once the chip is compact: the pills fold too.
        void tick().then(measureOverflow);
      } else {
        folded = true;
      }
      return;
    }
    const list = scrollerEl.querySelector(".today-list");
    if (!list) return;
    const end = list.lastElementChild?.getBoundingClientRect().right ?? list.getBoundingClientRect().left;
    const room = list.getBoundingClientRect().right - end;
    if (folded) {
      if (room >= scrollerEl.querySelectorAll(FOLDABLE).length * (FOLD_MIN_WIDTH - FOLDED_WIDTH)) folded = false;
      return;
    }
    if (chip && compactSpace && room >= spaceChipWidth - chip.offsetWidth) compactSpace = false;
  }

  $effect(() => {
    const el = scrollerEl;
    if (!el) return;
    const resize = new ResizeObserver(measureOverflow);
    resize.observe(el);
    el.addEventListener("scroll", measureEdges, { passive: true });
    const stopTracking = trackUserScroll(el);
    return () => {
      resize.disconnect();
      el.removeEventListener("scroll", measureEdges);
      stopTracking();
    };
  });

  // A mouse wheel scrolls vertically: the strip turns it sideways. It has to be non-passive to keep the page
  // still, so it is attached only while the pills overflow: a non-passive listener holds every wheel scroll back.
  const overflowing = $derived(overflowStart || overflowEnd);
  $effect(() => {
    const el = scrollerEl;
    if (!el || !overflowing) return;
    const wheel = (event: WheelEvent) => {
      if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
      event.preventDefault();
      el.scrollLeft += event.deltaY;
    };
    el.addEventListener("wheel", wheel, { passive: false });
    return () => el.removeEventListener("wheel", wheel);
  });

  // The active pill comes into view, and the strip keeps exactly one tab stop.
  $effect(() => {
    void shownActiveId;
    void baseItems;
    void tick().then(() => {
      if (scrollerEl && !isUserScrolling(scrollerEl)) scrollerEl.querySelector(surface ? ".strip-surface" : `[data-tab-id="${activeTabId}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest", behavior: prefersReducedMotion() ? "auto" : "smooth" });
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
  {@const zoneItems = getZoneItems(zone, baseItems[section])}
  {#snippet slotContent(item: SidebarDndItem)}
    {#if isShadowItem(item)}
      <div class="strip-placeholder" aria-hidden="true"></div>
    {:else if item.kind === "folder"}
      {@const folder = view.foldersById.get(item.id)}
      {@const conversation = folder ? getConversationTab(folder.id, spaceId) : undefined}
      {#if folder && conversation}
        {#await import("./StripConversation.svelte") then { default: StripConversation }}
          <StripConversation {folder} tab={conversation} pages={folderTabs(folder.id).filter((tab) => tab.id !== conversation.id)} activeTabId={shownActiveId} />
        {/await}
      {:else if folder}
        <StripFolder {folder} tabs={folderTabs(folder.id)} activeTabId={shownActiveId} {spaceId} childItems={folderChildItems(folder.id, section === "pinned" ? "pinned" : "unpinned")} section={section === "pinned" ? "pinned" : "unpinned"} />
      {/if}
    {:else}
      {@const tab = view.tabsById.get(item.id)}
      {#if tab && !(tab.id === activeTabId && addressInActiveTab && !iconOnly)}
        <StripTab {tab} active={tab.id === shownActiveId} {iconOnly} {editsAddress} />
      {/if}
    {/if}
  {/snippet}
  {#if baseItems[section].length > FLIP_MAX_ANIMATED_ITEMS}
    {#each zoneItems as item (item.id)}
      <div
        class="strip-slot"
        class:icon-only={iconOnly}
        class:active={item.id === shownActiveId && item.kind !== "folder" && !isShadowItem(item) && view.tabsById.has(item.id) && !(addressInActiveTab && !iconOnly)}
        use:dndItem={{ item, zoneId: zone.id, disabled: isShadowItem(item), onCancel: resetSidebarDrag }}
      >
        {@render slotContent(item)}
      </div>
    {/each}
  {:else}
    {#each zoneItems as item (item.id)}
      <div
        class="strip-slot"
        class:icon-only={iconOnly}
        class:active={item.id === shownActiveId && item.kind !== "folder" && !isShadowItem(item) && view.tabsById.has(item.id) && !(addressInActiveTab && !iconOnly)}
        animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(item, { recentlyDraggedId: getRecentlyDroppedId(), itemCount: zoneItems.length }), easing: springEase }}
        use:dndItem={{ item, zoneId: zone.id, disabled: isShadowItem(item), onCancel: resetSidebarDrag }}
      >
        {@render slotContent(item)}
      </div>
    {/each}
  {/if}
{/snippet}

{#snippet zoneOf(section: StripSection)}
  {@const zone = zoneRef(section)}
  <div
    class={section === "unpinned" ? "today-list" : "group"}
    class:targeted={crossedZoneId === zone.id}
    style:--zone-color={ZONE_COLORS[section]}
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
  class:bottom={edge === "bottom"}
  aria-label={t("strip.ariaLabel")}
  onkeydown={handleArrows}
  onpointerdown={startWindowDrag}
  ondblclick={(event) => {
    if (!(event.target as HTMLElement).closest("button, .strip-tab, .url-display")) chromeActions.maximizeWindow();
  }}
  oncontextmenu={showSidebarMenu}
>
  {#if edge === "top" && areTrafficLightsVisible()}<div class="lights-spacer"></div>{/if}
  <StripSpaceMenu compact={compactSpace} />
  <!-- The window's tools share one capsule, apart from the Space and the tabs. -->
  <div class="tools">
    <NavControls show="toggle" />
    {#if edge === "top" || !isSidebarVisible() || !isAddressInPageToolbar()}
      <span class="tools-separator" aria-hidden="true"></span>
      <NavControls show="history" />
    {/if}
  </div>

  <!-- Laid out by the strip; only the tabs are in the list. -->
  <div class="strip-tabs" role="tablist" aria-orientation="horizontal" aria-label={t("strip.ariaLabel")}>
  <!-- The active tab's address heads the row, outside its scroller: its drawers and cards must not be clipped. -->
  {#if addressInActiveTab}
    <div class="strip-address"><URLDisplay /></div>
  {/if}

  <!-- Every tab scrolls as one row, as in the sidebar. -->
  <div class="scroller" class:folded class:overflow-start={overflowStart} class:overflow-end={overflowEnd} bind:this={scrollerEl}>
    {#if view.bookmarked.length}
      {@render zoneOf("bookmarked")}
    {/if}

    {#if view.rootItems.pinned.length}
      <span class="divider" class:lit={!!pinnedDividerColor} style:--zone-color={pinnedDividerColor} aria-hidden="true"></span>
      {@render zoneOf("pinned")}
    {/if}

    <span class="divider" class:lit={!!todayDividerColor} style:--zone-color={todayDividerColor} aria-hidden="true"></span>

    {@render zoneOf("unpinned")}
    {#if surface}
      <div class="strip-surface">
        <button class="strip-surface-main" role="tab" aria-selected="true" tabindex="0" data-roving>
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true">
            <path d={surface.icon} stroke-linejoin="round" />
          </svg>
          {surface.label}
        </button>
        <button class="strip-surface-close" tabindex="-1" aria-label={t("common.close")} onclick={surface.close}>
          <Icon name="close" size={12} />
        </button>
      </div>
    {/if}
    <button
      class="strip-btn new-tab"
      aria-label={t("tabItem.newTab")}
      use:tooltip={{ text: t("tabItem.newTab"), shortcut: shortcutKeys("tab.new"), placement: edge === "top" ? "bottom" : "top" }}
      onclick={() => tabActions.create()}
    >
      <Icon name="plus" size={14} />
    </button>
    {#if recentArchived.length > 0}
      <button
        bind:this={archiveButton}
        class="strip-btn archive-btn"
        class:on={archiveOpen}
        aria-label={t("archivedTabs.buttonLabel", { count: recentArchived.length })}
        aria-expanded={archiveOpen}
        use:tooltip={{ text: t("archivedTabs.title"), placement: edge === "top" ? "bottom" : "top" }}
        onclick={() => (archiveOpen = !archiveOpen)}
      >
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <rect class="archive-lid" x="2.5" y="3" width="11" height="3" rx="1" stroke="currentColor" stroke-width="1.3" />
          <path d="M3.5 6v6a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V6M6.5 8.5h3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
        </svg>
        <span>{recentArchived.length}</span>
      </button>
      <!-- Loaded on first open: the menu costs the chrome's first frame nothing. -->
      {#if archiveOpen && archiveButton}
        {#await import("../sidebar/ArchivedTabsMenu.svelte") then menu}
          <menu.default anchor={archiveButton} tabs={recentArchived} downloads={null} onclose={() => (archiveOpen = false)} />
        {/await}
      {/if}
    {/if}
  </div>

  </div>

  <div class="trailing">
    {#if getMeeting()}
      <!-- Like the call card, the meeting card opens from its icon. -->
      <button
        bind:this={meetingButton}
        class="strip-btn"
        class:on={meetingOpen}
        aria-label={getMeeting()?.title || t("meetingCard.untitled")}
        aria-expanded={meetingOpen}
        use:tooltip={{ text: getMeeting()?.title || t("meetingCard.untitled"), placement: edge === "top" ? "bottom" : "top" }}
        onclick={() => (meetingOpen = !meetingOpen)}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true">
          <rect x="2" y="3" width="12" height="11" rx="2.5" />
          <path d="M2 6.5h12M5.5 1.8v2.4M10.5 1.8v2.4" />
        </svg>
      </button>
      {#if meetingOpen && meetingButton}
        <StripPopover anchor={meetingButton} label={getMeeting()?.title ?? ""} role="dialog" onclose={() => (meetingOpen = false)}>
          {#await import("../sidebar/MeetingCard.svelte") then card}
            <card.default />
          {/await}
        </StripPopover>
      {/if}
    {/if}
    {#if getCallCardTab()}
      {@const call = getCallCardTab()}
      <!-- Like the media card, the call card opens from its icon; a muted microphone shows on it. -->
      <button
        bind:this={callButton}
        class="strip-btn"
        class:on={callOpen}
        class:off={call?.microphoneMuted}
        aria-label={call?.title}
        aria-expanded={callOpen}
        onclick={() => (callOpen = !callOpen)}
      >
        <svg width="14" height="14" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path d="M4 2.8C4 1.8 4.8 1 5.8 1H6.2C7.2 1 8 1.8 8 2.8V5.2C8 6.2 7.2 7 6.2 7H5.8C4.8 7 4 6.2 4 5.2V2.8Z" fill="currentColor" />
          <path d="M2.6 5.2C2.6 7 4.1 8.4 6 8.4C7.9 8.4 9.4 7 9.4 5.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
          <path d="M6 8.4V10.2M4.6 10.2H7.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
          {#if call?.microphoneMuted}
            <path d="M2 2L10 10" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
          {/if}
        </svg>
      </button>
      {#if callOpen && callButton}
        <StripPopover anchor={callButton} label={call?.title ?? ""} role="dialog" onclose={() => (callOpen = false)}>
          {#await import("../sidebar/CallCard.svelte") then card}
            <card.default />
          {/await}
        </StripPopover>
      {/if}
    {/if}
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
        <StripPopover anchor={mediaButton} label={getMediaCardTab()?.title ?? ""} role="dialog" onclose={() => (mediaOpen = false)}>
          <MediaCard />
        </StripPopover>
      {/if}
    {/if}
    {#if getReadyUpdate()}
      <!-- Like the media card, the update card opens from its icon. -->
      <button
        bind:this={updateButton}
        class="strip-btn update-btn"
        class:on={updateOpen}
        aria-label={t("updateCard.restartLabel", { version: getReadyUpdate() ?? "" })}
        aria-expanded={updateOpen}
        use:tooltip={{ text: t("updateCard.ready"), placement: edge === "top" ? "bottom" : "top" }}
        onclick={() => (updateOpen = !updateOpen)}
      >
        {#if getChosenAppIcon()}<img src={getChosenAppIcon()} alt="" width="18" height="18" />{/if}
      </button>
      {#if updateOpen && updateButton}
        <StripPopover anchor={updateButton} label={t("updateCard.ready")} role="dialog" onclose={() => (updateOpen = false)}>
          <UpdateCard />
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
          <path class="download-arrow" d="M8 2v8M5 7l3 3 3-3" />
          <path d="M3 12h10" />
        </svg>
      </button>
    {/if}
    <!-- Loaded only once the feature is on: no conversation code ships to the chrome otherwise. -->
    {#if getSetting("agentsEnabled", "false") === "true"}
      {#await import("../agents/AgentsBadge.svelte") then badge}
        <badge.default />
      {/await}
    {/if}
  </div>
</nav>

<style>
  .tab-strip {
    height: calc(var(--top-strip-height) - var(--content-inset));
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 10px 0 12px;
    box-sizing: border-box;
    min-width: 0;
  }

  /* The sidebar header spreads its controls; the strip keeps them together. */
  .tab-strip :global(.nav-controls) {
    flex: none;
  }

  /* The Space, the tools and the tabs are three groups, the same 12px apart. */
  .tab-strip > :global(.space-chip),
  .tools {
    margin-right: 6px;
  }

  /* The buttons' own height, so a hovered one fills the capsule's ends. */
  .tools {
    flex: none;
    display: flex;
    align-items: center;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--text-primary) 6%, transparent);
  }

  .tools-separator {
    width: 1px;
    height: 14px;
    margin: 0 2px;
    background: var(--separator);
  }

  /* The Space stands 14px from the lights, as the toggle does in the sidebar header. */
  .lights-spacer {
    width: 67px;
    flex: none;
  }

  .strip-tabs {
    display: contents;
  }

  .group {
    display: flex;
    align-items: center;
    gap: 4px;
    flex: none;
  }

  .divider {
    width: 0.5px;
    height: 18px;
    margin: 0 4px;
    flex: none;
    border-radius: var(--radius-chip);
    background: var(--separator);
    transition: background-color var(--motion-duration-fast) ease, width var(--motion-duration-fast) var(--motion-ease-spring);
  }

  /* The sidebar's pinned gate, turned on its side. */
  .divider.lit {
    width: 3px;
    margin: 0 3px;
    background: var(--zone-color);
  }

  /* Today's pills shrink, fold to their icon, then the whole row scrolls sideways. */
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
    min-width: 96px;
  }

  /* FOLDABLE in the script: an inactive tab or conversation pill, folded to its icon. */
  .folded .today-list > .strip-slot:not(.active, .icon-only):not(:has(> :global(.strip-folder), > :global(.strip-split), > :global(.strip-conversation.active))) {
    flex: none;
    width: 32px;
    min-width: 32px;
  }

  /* A width, not just a flex basis: WebKit sizes a group on its slots' widths and would leave the active pill overflowing. */
  .strip-slot.active {
    flex: none;
    width: 260px;
  }

  .strip-slot.icon-only,
  .strip-slot:has(> :global(.strip-folder)),
  .strip-slot:has(> :global(.strip-split)) {
    flex: none;
    min-width: 32px;
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
    left: -2.25px;
    top: 9px;
    bottom: 9px;
    width: 0.5px;
    background: var(--separator);
  }

  .today-list .strip-slot.active + .strip-slot::before,
  .today-list .strip-slot.active::before,
  .today-list .strip-slot:hover::before,
  .today-list .strip-slot:hover + .strip-slot::before {
    display: none;
  }

  .strip-slot > :global(.strip-tab) {
    flex: 1;
  }

  .group,
  .today-list {
    border-radius: var(--radius-sm);
    transition: background-color var(--motion-duration-fast) ease, box-shadow var(--motion-duration-fast) ease;
  }

  /* The list a drop lands in, tinted inside its own box: an outer ring would be clipped by the scroller. */
  .targeted {
    background: color-mix(in srgb, var(--zone-color) 11%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--zone-color) 36%, transparent);
  }

  .strip-placeholder {
    width: 100%;
    height: 32px;
    border-radius: var(--radius-md);
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--zone-color) 42%, transparent);
    background: color-mix(in srgb, var(--zone-color) 12%, transparent);
  }

  /* The active pill's look, sized to its label. */
  .strip-surface {
    flex: none;
    height: 32px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-md);
    background: var(--sidebar-sel);
    color: var(--text-primary);
    box-shadow: inset 0 0 0 0.5px var(--sidebar-sel-ring);
  }

  .strip-surface-main {
    height: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 6px 0 8px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: var(--font-size-md);
    cursor: default;
  }

  .strip-surface-close {
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

  .strip-surface-main:focus-visible {
    border-radius: var(--radius-md);
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .strip-surface-close:hover {
    background: var(--bg-hover);
  }

  .strip-surface-close:active {
    background: var(--bg-active);
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
  .tab-strip:not(.bottom) .strip-address {
    align-self: flex-start;
    margin-top: calc((var(--top-strip-height) - var(--content-inset) - 32px) / 2);
  }

  .bottom .strip-address {
    align-self: flex-end;
    margin-bottom: calc((var(--top-strip-height) - var(--content-inset) - 32px) / 2);
  }

  .bottom .strip-address > :global(.url-display) {
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

  .strip-btn:active {
    background: var(--bg-active);
  }

  .strip-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .strip-surface-close :global(.icon),
  .new-tab :global(.icon),
  .archive-lid,
  .download-arrow {
    transform-box: fill-box;
    transform-origin: center;
    transition: transform var(--motion-duration-slow) var(--motion-ease-spring);
  }

  .archive-lid {
    transform-origin: left bottom;
  }

  .strip-surface-close:hover :global(.icon),
  .new-tab:hover :global(.icon) {
    transform: rotate(90deg);
  }

  .strip-btn:hover .archive-lid {
    transform: translateY(-1.5px) rotate(-10deg);
  }

  .strip-btn:hover .download-arrow {
    transform: translateY(1.5px);
  }

  /* The call card's own off state: the others are not hearing you, even with the card closed. */
  .strip-btn.off,
  .strip-btn.off:hover {
    background: var(--danger);
    color: var(--on-color);
  }

  .archive-btn {
    width: auto;
    padding: 0 8px;
    display: flex;
    gap: 4px;
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .update-btn {
    position: relative;
    animation: update-btn-pop 640ms var(--motion-ease-bounce) both;
  }

  .update-btn img {
    border-radius: var(--radius-xs);
  }

  /* An accent dot says it waits for a relaunch. */
  .update-btn::after {
    content: "";
    position: absolute;
    top: 6px;
    right: 6px;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 2px var(--sidebar-bg);
  }

  @keyframes update-btn-pop {
    from {
      transform: scale(0.3) rotate(-30deg);
      opacity: 0;
    }
  }
</style>
