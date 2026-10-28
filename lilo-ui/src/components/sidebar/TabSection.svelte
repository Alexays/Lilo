<script lang="ts" module>
  // A static :root token: read once, not per list change.
  let bounceEasing: string | undefined;
</script>

<script lang="ts">
  import { folderColorStyle } from "../../stores/theme.svelte";
  import { onDestroy, tick, untrack } from "svelte";
  import { translateFlip } from "../../lib/motion/translateFlip";
  import { springEase } from "../../lib/motion/spring";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";
  import { tabSlide } from "../../lib/motion/tabSlide";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import {
    dndItem,
    dndZone,
  } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import type { DndTargetContext } from "../../lib/dndEngine/types";
  import TabItem from "./TabItem.svelte";
  import SavedTabEditor from "./SavedTabEditor.svelte";
  import { closeTabEditor, getEditingTab } from "../../stores/tabRename.svelte";
  import type { BridgeSplitLayout } from "../../lib/bridge/protocol";
  import type { TabState } from "../../stores/tabs.svelte";
  import TabFolderItem from "./TabFolderItem.svelte";
  import { getActiveTab, getActiveTabId, getTabsById, isBlankTab } from "../../stores/tabs.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { tabActions, folderActions, sidebarActions } from "../../lib/bridge/actions";
  import { openCommandBar, closeCommandBar } from "../../stores/commandBar.svelte";
  import {
    dndItemsForSidebarItems,
    flipDurationForSidebarDndItem,
    sidebarDndKey,
    type SidebarDndItem,
  } from "../../lib/dndEngine/adapters/sidebar";
  import { isShadowItem } from "../../lib/dndEngine/projection";
  import {
    folderZoneAcceptsPoint,
    rootZoneAcceptsPoint,
    type FolderTargetRow,
  } from "../../lib/sidebarDnd/folderTargeting";
  import {
    commitSidebarDrop,
    getRecentlyDroppedId,
    getSidebarDrag,
    getZoneItems,
    isSidebarDragActive,
    resetSidebarDrag,
    type SidebarZoneRef,
  } from "../../stores/sidebarDnd.svelte";
  import {
    getFolders,
    getFoldersById,
    getRootItems,
    getVisibleFolderChildren,
    countVisibleFolderChildren,
    canNestFolder,
    type FolderState,
  } from "../../stores/folders.svelte";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { on } from "../../lib/bridge";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";

  let {
    section,
    spaceId,
    interactive,
    scroller,
    scrollerHeight = 0,
  }: {
    section: "pinned" | "unpinned";
    spaceId: string;
    interactive: boolean;
    /** Shared space scroller, supplied to the unpinned section for windowed rendering. */
    scroller?: HTMLElement;
    scrollerHeight?: number;
  } = $props();

  const isPinned = $derived(section === "pinned");

  // Both Maps are precomputed per store write (view.tabsById / view.foldersById),
  // re-deriving them here would rebuild a Map in every rendered section on every tab patch.
  const tabsById = $derived(getTabsById(spaceId));
  const rootItems = $derived(getRootItems(spaceId, isPinned));
  const rowCount = $derived(rootItems.length);
  const folders = $derived(getFolders(spaceId));
  const foldersById = $derived(getFoldersById(spaceId));
  const activeTabId = $derived(getActiveTabId(spaceId));
  const slotClass = $derived(isPinned ? "pinned-tab-slot" : "tab-drop-slot");
  const sidebarDrag = $derived(getSidebarDrag());
  const dragActive = $derived(isSidebarDragActive());
  const dragTargetsRoot = $derived(
    sidebarDrag !== null && sidebarDrag.target?.parentFolderId === null,
  );
  const pinnedTransferReturnActive = $derived(
    !isPinned &&
      dragTargetsRoot &&
      sidebarDrag?.source.section === "pinned" &&
      sidebarDrag?.target?.section === "unpinned",
  );
  const pinnedTransferTargetActive = $derived(
    isPinned && dragTargetsRoot && sidebarDrag?.target?.section === "pinned",
  );
  const pinnedTransferSourceActive = $derived(
    !isPinned && dragTargetsRoot && sidebarDrag?.target?.section === "pinned",
  );
  const pinnedRootCount = $derived(
    isPinned ? 0 : getRootItems(spaceId, true).length,
  );
  // The gate and the pinned list only open around existing pins: an empty pinned section is
  // a SidebarDropDock target, and growing it here would push the rows under the pointer.
  const pinnedTransferGateActive = $derived(
    !isPinned && pinnedRootCount > 0 && (pinnedTransferSourceActive || pinnedTransferReturnActive),
  );
  const hasTabs = $derived(rootItems.length > 0 || (dragActive && !isPinned));
  const rootZone: SidebarZoneRef = $derived({
    id: `sidebar-root-${section}-${spaceId}`,
    section,
    parentFolderId: null,
  });
  const rootBaseItems = $derived(dndItemsForSidebarItems(rootItems, section));
  const rootZoneItems = $derived(getZoneItems(rootZone, rootBaseItems));
  const rootZoneIsEmpty = $derived(rootZoneItems.length === 0);
  const rootHasShadow = $derived(rootZoneItems.some(isShadowItem));
  const recentlyDraggedId = $derived(getRecentlyDroppedId());

  const activeTab = $derived(getActiveTab(spaceId));
  const isNewTabActive = $derived(isBlankTab(activeTab));
  const showNewTabRow = $derived(!isPinned && interactive && !isNewTabActive);
  // Not gated on `interactive`: a neighbour pane must lay out like the active one, or its
  // divider pops in the moment its Space becomes active.
  const canClear = $derived(!isPinned && rootItems.some((item) => item.kind === "tab"));
  // Divider anchors the bottom of the pinned section. Without pins its line only shows during a drag,
  // but its row stays over tabs Clear can archive so the list doesn't shift when a drag starts.
  const showPinnedDivider = $derived(
    (!isPinned && (pinnedRootCount > 0 || canClear || dragActive)) || pinnedTransferGateActive,
  );
  const pinnedDividerHidden = $derived(pinnedRootCount === 0 && !dragActive);
  const folderContentUnmountDelayMs = MOTION.folderCollapseMs;
  let renamingFolderId: string | null = $state(null);
  const editingTab = $derived(interactive ? getEditingTab() : null);
  let tabListBodyEl: HTMLDivElement | undefined = $state();
  let tabListEl: HTMLDivElement | undefined = $state();
  let pinnedListEl: HTMLDivElement | undefined = $state();

  // Rows outside the scroll window collapse into spacers; disabled during a sidebar drag so the dnd engine's layout
  // snapshot measures every row.
  const VIRTUALIZE_MIN_ROWS = 80;
  const VIRTUAL_BUFFER_PX = 320;
  // The window moves in steps of this many pixels, so a scroll frame inside a step re-renders nothing.
  const VIRTUAL_WINDOW_STEP_PX = 160;
  // Mirror the row CSS (28px rows, 2px --sidebar-tab-row-gap, 2px folder-contents
  // top margin, 26px empty-folder placeholder); the buffer absorbs small drift.
  const VIRTUAL_ROW_H = 28;
  const VIRTUAL_ROW_GAP = 2;
  const VIRTUAL_FOLDER_TOP_MARGIN = 2;
  const VIRTUAL_EMPTY_FOLDER_H = 26;

  type ListSegment =
    | { spacer: true; key: string; height: number }
    | { spacer: false; key: string; entry: SidebarDndItem };

  // How far the list's top sits above the shared scroller's viewport top, floored to a window step.
  let listScrollTop = $state(0);
  let focusedItemId = $state<string | null>(null);
  const listWindowFrame = createFrameScheduler();

  const virtualize = $derived(
    !isPinned && !dragActive && rootZoneItems.length > VIRTUALIZE_MIN_ROWS,
  );

  // The panes of a split in reading order, stacked one row each in the sidebar.
  function splitPanes(node: BridgeSplitLayout, into: string[] = []): string[] {
    if ("tabId" in node) {
      into.push(node.tabId);
    } else {
      splitPanes(node.first, into);
      splitPanes(node.second, into);
    }
    return into;
  }

  function estimatedRowHeight(entry: SidebarDndItem): number {
    if (entry.kind !== "folder") return VIRTUAL_ROW_H;
    const folder = foldersById.get(entry.id);
    if (folder?.splitLayout) return splitPanes(folder.splitLayout).length * VIRTUAL_ROW_H;
    return expandedFolderHeights.get(entry.id) ?? VIRTUAL_ROW_H;
  }

  // An open folder's rows, its open subfolders' rows included.
  function openFolderHeight(folderId: string): number {
    const childCount = countVisibleFolderChildren(folderId, spaceId, isPinned, tabsById);
    if (childCount === 0) {
      return VIRTUAL_ROW_H + VIRTUAL_FOLDER_TOP_MARGIN + VIRTUAL_EMPTY_FOLDER_H;
    }
    let height =
      VIRTUAL_ROW_H +
      VIRTUAL_FOLDER_TOP_MARGIN +
      childCount * VIRTUAL_ROW_H +
      (childCount - 1) * VIRTUAL_ROW_GAP;
    for (const child of childrenByFolderId.get(folderId) ?? []) {
      if (child.kind !== "folder" || child.section !== section) continue;
      const folder = foldersById.get(child.itemId);
      if (folder && !folder.isCollapsed) height += openFolderHeight(child.itemId) - VIRTUAL_ROW_H;
    }
    return height;
  }

  // Whether `itemId` sits anywhere inside the folder.
  function folderHolds(folderId: string, itemId: string | null): boolean {
    if (!itemId) return false;
    return childrenByFolderId.get(folderId)?.some((item) =>
      item.itemId === itemId || (item.kind === "folder" && folderHolds(item.itemId, itemId))
    ) === true;
  }

  // Identity stable across runtime tab patches, unlike tabsById.
  const childrenByFolderId = $derived(
    getSpaceSidebar(spaceId).view.treeIndex.childrenByFolderId,
  );

  // Non-reactive memo: reruns on every tab patch but hands back the previous Map while heights match, so listSegments reruns only when a height changes.
  let lastExpandedFolderHeights = new Map<string, number>();
  const expandedFolderHeights = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole per run, never mutated after
    const heights = new Map<string, number>();
    let changed = false;
    for (const entry of rootZoneItems) {
      if (entry.kind !== "folder") continue;
      const folder = foldersById.get(entry.id);
      if (!folder || folder.splitLayout || folder.isCollapsed || folder.isSplit) continue;
      const height = openFolderHeight(entry.id);
      heights.set(entry.id, height);
      if (lastExpandedFolderHeights.get(entry.id) !== height) changed = true;
    }
    if (!changed && heights.size === lastExpandedFolderHeights.size) {
      return lastExpandedFolderHeights;
    }
    lastExpandedFolderHeights = heights;
    return heights;
  });

  const listSegments: ListSegment[] | null = $derived.by(() => {
    if (!virtualize) return null;
    const minY = listScrollTop - VIRTUAL_BUFFER_PX;
    const maxY = listScrollTop + VIRTUAL_WINDOW_STEP_PX + scrollerHeight + VIRTUAL_BUFFER_PX;
    const segments: ListSegment[] = [];
    let top = 0;
    let hiddenHeight = 0;
    let hiddenCount = 0;
    let spacerOrdinal = 0;
    const flushSpacer = () => {
      if (hiddenCount === 0) return;
      // The flex gap supplies the boundary gaps around the spacer, so it only
      // carries the hidden rows' own heights plus the gaps between them.
      segments.push({
        spacer: true,
        key: `spacer-${spacerOrdinal++}`,
        height: hiddenHeight + (hiddenCount - 1) * VIRTUAL_ROW_GAP,
      });
      hiddenHeight = 0;
      hiddenCount = 0;
    };
    for (const entry of rootZoneItems) {
      const height = estimatedRowHeight(entry);
      // The active and focused rows stay mounted wherever the scroll sits, so
      // tab switching and keyboard focus never land on an unmounted row. Hidden
      // children count too: keeping one extra folder mounted is harmless.
      const keep =
        (top + height >= minY && top <= maxY) ||
        entry.id === activeTabId ||
        entry.id === focusedItemId ||
        (entry.kind === "folder" &&
          (folderHolds(entry.id, activeTabId) || folderHolds(entry.id, focusedItemId)));
      if (keep) {
        flushSpacer();
        segments.push({ spacer: false, key: sidebarDndKey(entry), entry });
      } else {
        hiddenHeight += height;
        hiddenCount += 1;
      }
      top += height + VIRTUAL_ROW_GAP;
    }
    flushSpacer();
    return segments;
  });

  function handleListFocusIn(event: FocusEvent): void {
    const target = event.target instanceof Element ? event.target : null;
    focusedItemId =
      target?.closest("[data-dnd-item-id]")?.getAttribute("data-dnd-item-id") ??
      null;
  }

  function handleListFocusOut(event: FocusEvent): void {
    const next = event.relatedTarget;
    if (!(next instanceof Node) || !(event.currentTarget as HTMLElement).contains(next)) {
      focusedItemId = null;
    }
  }

  let newTabRowExiting = $state(false);
  // Suppress enter transitions on first paint (launch / space switch) so rows don't cascade.
  let ready = $state(false);
  $effect(() => {
    void tick().then(() => {
      ready = true;
    });
  });

  function itemMotion(entry: SidebarDndItem, duration: number) {
    return {
      disabled:
        !ready || dragActive || isShadowItem(entry) || prefersReducedMotion(),
      duration,
    };
  }
  let mountedFolderContentIds: Set<string> = $state(new Set());
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- holds setTimeout handles, intentionally non-reactive
  const folderContentUnmountTimers = new Map<string, ReturnType<typeof setTimeout>>();

  $effect(() => {
    if (showNewTabRow) newTabRowExiting = false;
  });

  // A closing row leaves the flow at once (Svelte fixes outroing rows of an animated each), so the
  // new tab row below the list follows the FLIPped rows with its own FLIP instead of jumping.
  let newTabLineEl: HTMLElement | undefined = $state();
  let newTabLineTop = 0;
  $effect.pre(() => {
    void rootZoneItems;
    untrack(() => {
      // Forced layout read: only taken when the post effect can animate.
      newTabLineTop =
        newTabLineEl && ready && !dragActive && !listSegments
          ? newTabLineEl.getBoundingClientRect().top
          : 0;
    });
  });
  $effect(() => {
    void rootZoneItems;
    untrack(() => {
      const el = newTabLineEl;
      if (!el || !newTabLineTop || listSegments || !ready || dragActive || prefersReducedMotion()) return;
      const dy = newTabLineTop - el.getBoundingClientRect().top;
      if (dy <= 0) return;
      el.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], {
        duration: MOTION.reorderMs,
        easing: (bounceEasing ??=
          getComputedStyle(el).getPropertyValue("--motion-ease-bounce").trim() || "ease-out"),
      });
    });
  });

  // Rows above the list (pinned section, divider) shift it under the viewport, so the
  // window is re-measured whenever the list moves, not only when the scroller moves.
  $effect(() => {
    if (isPinned) return;
    void rowCount;
    void showNewTabRow;
    void scrollerHeight;
    void tick().then(measureListWindow);
  });

  $effect(() => {
    if (isPinned) return;
    const el = scroller;
    if (!el) return;
    el.addEventListener("scroll", handleListScroll, { passive: true });
    // The pinned section above the list resizes as its folders collapse and expand,
    // which moves the list under the viewport without a scroll event.
    const observer = new ResizeObserver(handleListScroll);
    if (el.firstElementChild) observer.observe(el.firstElementChild);
    return () => {
      el.removeEventListener("scroll", handleListScroll);
      observer.disconnect();
    };
  });

  function handleListScroll(): void {
    listWindowFrame.schedule(measureListWindow);
  }

  function measureListWindow(): void {
    if (!scroller || !tabListEl) return;
    const offset = scroller.getBoundingClientRect().top - tabListEl.getBoundingClientRect().top;
    listScrollTop = Math.floor(offset / VIRTUAL_WINDOW_STEP_PX) * VIRTUAL_WINDOW_STEP_PX;
  }

  $effect(() => {
    return on("editTabFolder", (data) => {
      if (typeof data.id === "string" && foldersById.has(data.id)) {
        renamingFolderId = data.id;
      }
    });
  });

  // Child rows only play their entrance animation on a real expand (collapsed to open), not
  // on initial paint or when they re-enter the virtual window.
  let expandingFolderIds = $state<ReadonlySet<string>>(new Set());
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- holds setTimeout handles, intentionally non-reactive
  const folderExpandTimers = new Map<string, ReturnType<typeof setTimeout>>();
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- plain bookkeeping, intentionally non-reactive
  const lastCollapsedByFolderId = new Map<string, boolean>();

  function markFolderExpanding(folderId: string): void {
    clearTimeout(folderExpandTimers.get(folderId));
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
    expandingFolderIds = new Set(expandingFolderIds).add(folderId);
    folderExpandTimers.set(folderId, setTimeout(() => {
      folderExpandTimers.delete(folderId);
      // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
      const next = new Set(expandingFolderIds);
      next.delete(folderId);
      expandingFolderIds = next;
    }, 340));
  }

  $effect(() => {
    const currentFolderIds = new Set(folders.map((folder) => folder.id));
    // Only the folders drive this effect: it writes both id sets, and a read of them here would
    // re-run it on its own writes and on every unmount timer.
    const mounted = untrack(() => mountedFolderContentIds);
    let nextMountedFolderContentIds = mounted;
    for (const folder of folders) {
      if (!folder.isCollapsed && lastCollapsedByFolderId.get(folder.id) === true) {
        untrack(() => markFolderExpanding(folder.id));
      }
      lastCollapsedByFolderId.set(folder.id, folder.isCollapsed);
      if (folder.isCollapsed) {
        if (mounted.has(folder.id) && !folderContentUnmountTimers.has(folder.id)) {
          folderContentUnmountTimers.set(folder.id, setTimeout(() => {
            removeMountedFolderContent(folder.id);
          }, folderContentUnmountDelayMs));
        }
        continue;
      }
      const timer = folderContentUnmountTimers.get(folder.id);
      if (timer) {
        clearTimeout(timer);
        folderContentUnmountTimers.delete(folder.id);
      }
      if (!nextMountedFolderContentIds.has(folder.id)) {
        // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
        nextMountedFolderContentIds = new Set(nextMountedFolderContentIds).add(folder.id);
      }
    }
    for (const folderId of lastCollapsedByFolderId.keys()) {
      if (!currentFolderIds.has(folderId)) lastCollapsedByFolderId.delete(folderId);
    }
    for (const folderId of folderItemsCache.keys()) {
      if (!currentFolderIds.has(folderId)) folderItemsCache.delete(folderId);
    }
    for (const folderId of mounted) {
      if (!currentFolderIds.has(folderId)) {
        const timer = folderContentUnmountTimers.get(folderId);
        if (timer) {
          clearTimeout(timer);
          folderContentUnmountTimers.delete(folderId);
        }
        if (nextMountedFolderContentIds === mounted) {
          // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
          nextMountedFolderContentIds = new Set(nextMountedFolderContentIds);
        }
        nextMountedFolderContentIds.delete(folderId);
      }
    }
    if (nextMountedFolderContentIds !== mounted) mountedFolderContentIds = nextMountedFolderContentIds;
  });

  onDestroy(() => {
    listWindowFrame.cancel();
    for (const timer of folderContentUnmountTimers.values()) clearTimeout(timer);
    folderContentUnmountTimers.clear();
    for (const timer of folderExpandTimers.values()) clearTimeout(timer);
    folderExpandTimers.clear();
  });

  function removeMountedFolderContent(folderId: string): void {
    const timer = folderContentUnmountTimers.get(folderId);
    if (timer) {
      clearTimeout(timer);
      folderContentUnmountTimers.delete(folderId);
    }
    if (!mountedFolderContentIds.has(folderId)) return;
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
    const next = new Set(mountedFolderContentIds);
    next.delete(folderId);
    mountedFolderContentIds = next;
  }

  function shouldRenderFolderContents(folder: FolderState): boolean {
    return !folder.isCollapsed || mountedFolderContentIds.has(folder.id);
  }

  function folderZone(folderId: string): SidebarZoneRef {
    return {
      id: `sidebar-folder-${section}-${spaceId}-${folderId}`,
      section,
      parentFolderId: folderId,
    };
  }

  function folderTargetRows(context: DndTargetContext): FolderTargetRow[] {
    return context.zone.items.map((item) => {
      const folder = foldersById.get(item.id);
      return {
        id: item.id,
        top: item.rect.top,
        bottom: item.rect.bottom,
        isFolder: folder !== undefined,
        isCollapsed: folder?.isCollapsed === true,
      };
    });
  }

  function canResolveRootZone(context: DndTargetContext): boolean {
    // A collapsed, empty pinned list keeps a zero-height rect on the section boundary; it must
    // not win the pointer there (SidebarDropDock takes that drop).
    if (!hasTabs) return false;
    return rootZoneAcceptsPoint({
      pointY: context.point.y,
      rows: folderTargetRows(context),
      dragKind: context.dragSource.kind,
    });
  }

  function canResolveFolderZone(folderId: string, context: DndTargetContext): boolean {
    const folder = foldersById.get(folderId);
    if (!folder) return false;
    const source = context.dragSource;
    return folderZoneAcceptsPoint({
      pointY: context.point.y,
      zoneTop: context.zone.rect.top,
      zoneBottom: context.zone.rect.bottom,
      isCollapsed: folder.isCollapsed,
      refusesDrag:
        folder.isLocked === true ||
        (source.kind === "folder" && !canNestFolder(source.id, folderId, spaceId)),
      dragKind: source.kind,
      rows: folderTargetRows(context),
    });
  }

  // A tab dropped outside the window opens in a new window where it was dropped.
  function moveTabOutOfWindow(drag: DndActiveDrag, point: { screenX: number; screenY: number }): void {
    resetSidebarDrag();
    if (drag.source.item.kind !== "tab") return;
    tabActions.moveToNewWindow(drag.source.item.id, point.screenX, point.screenY);
  }

  function handleRootDrop(drag: DndActiveDrag): void {
    commitSidebarDrop(rootZone, rootBaseItems, sidebarActions.commitDrop, drag);
  }

  function handleFolderDrop(folderId: string, drag: DndActiveDrag): void {
    commitSidebarDrop(
      folderZone(folderId),
      folderBaseItems(folderId),
      sidebarActions.commitDrop,
      drag,
    );
  }

  function toggleNewTab(): void {
    if (!interactive) return;
    if (isNewTabActive && activeTab) {
      tabActions.close(activeTab.id);
      closeCommandBar();
    } else {
      newTabRowExiting = true;
      setTimeout(() => {
        newTabRowExiting = false;
      }, 220);
      tabActions.create();
      openCommandBar("", "default", true);
    }
  }

  function commitRename(folder: FolderState, name: string, color: string): void {
    renamingFolderId = null;
    folderActions.update({ id: folder.id, name, color });
  }

  function visibleChildren(folderId: string) {
    return getVisibleFolderChildren(folderId, spaceId, isPinned, tabsById);
  }

  const parentFolderIdById = $derived(getSpaceSidebar(spaceId).view.treeIndex.parentFolderIdById);

  // The tree is one Tab stop, as in a Finder sidebar: the focused row, else the active tab when
  // every folder above it is open, else the first row.
  const tabStopId = $derived.by((): string | null => {
    if (focusedItemId) return focusedItemId;
    let rootId: string | undefined = activeTabId;
    for (let id = parentFolderIdById.get(activeTabId); id; id = parentFolderIdById.get(id)) {
      const folder = foldersById.get(id);
      if (!folder || (!folder.isSplit && (folder.isCollapsed || folder.isLocked))) {
        rootId = undefined;
        break;
      }
      rootId = id;
    }
    if (rootId && rootItems.some((item) => item.id === rootId)) return activeTabId;
    return rootItems[0]?.id ?? null;
  });

  function rowElement(id: string): HTMLElement | null {
    const holder = (isPinned ? pinnedListEl : tabListEl)?.querySelector(
      `[data-dnd-item-id="${CSS.escape(id)}"]:not([data-is-dnd-shadow-item-hint="true"])`,
    );
    return holder?.querySelector<HTMLElement>("[role=treeitem]") ?? null;
  }

  // A moved row remounts in its new place once the host echoes the move: focus follows it there.
  let pendingFocusId: string | null = null;
  $effect(() => {
    void rootItems;
    void childrenByFolderId;
    const id = pendingFocusId;
    if (!id) return;
    void tick().then(() => {
      if (pendingFocusId !== id) return;
      pendingFocusId = null;
      rowElement(id)?.focus();
    });
  });

  type InsertAnchors = { fallbackIndex: number; insertAfterId: string | null; insertBeforeId: string | null };

  function anchorsAt(items: { id: string }[], at: number): InsertAnchors {
    return { fallbackIndex: at, insertAfterId: items[at - 1]?.id ?? null, insertBeforeId: items[at]?.id ?? null };
  }

  // Option-arrows move the focused row as a drag would: up or down among its siblings, right into
  // the folder just above it, left out of its folder.
  function moveRow(id: string, kind: "tab" | "folder", key: string): void {
    const parentId = parentFolderIdById.get(id) ?? null;
    if (parentId && foldersById.get(parentId)?.isSplit) return;
    const items = parentId ? visibleChildren(parentId) : rootItems;
    const index = items.findIndex((item) => item.id === id);
    if (index < 0) return;
    const others = items.filter((item) => item.id !== id);
    let parentFolderId = parentId;
    let anchors: InsertAnchors;
    if (key === "ArrowUp" && index > 0) {
      anchors = anchorsAt(others, index - 1);
    } else if (key === "ArrowDown" && index < items.length - 1) {
      anchors = anchorsAt(others, index + 1);
    } else if (key === "ArrowRight" && items[index - 1]?.kind === "folder") {
      const target = foldersById.get(items[index - 1].id);
      if (!target || target.isSplit || target.isLocked) return;
      if (kind === "folder" && !canNestFolder(id, target.id, spaceId)) return;
      const children = visibleChildren(target.id);
      parentFolderId = target.id;
      anchors = anchorsAt(children, children.length);
      if (target.isCollapsed) folderActions.setCollapsed(target.id, false);
    } else if (key === "ArrowLeft" && parentId) {
      parentFolderId = parentFolderIdById.get(parentId) ?? null;
      const outer = parentFolderId ? visibleChildren(parentFolderId) : rootItems;
      anchors = anchorsAt(outer, outer.findIndex((item) => item.id === parentId) + 1);
    } else {
      return;
    }
    pendingFocusId = id;
    sidebarActions.commitDrop(
      parentFolderId
        ? { type: "insert", kind, id, section, parentFolderId, ...anchors }
        : { type: "insert", kind, id, section, parentFolderId: null, ...anchors },
    );
  }

  // Arrow keys walk the visible rows, as in a Finder sidebar; Option-arrows move the row.
  function handleListKeydown(event: KeyboardEvent): void {
    if (event.defaultPrevented || !interactive) return;
    const row = event.target instanceof HTMLElement ? event.target : null;
    if (!row?.matches("[role=treeitem]")) return;
    const isFolder = row.matches(".folder-row");
    if ((event.key === "F10" && event.shiftKey) || event.key === "ContextMenu") {
      event.preventDefault();
      const rect = row.getBoundingClientRect();
      row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: rect.left, clientY: rect.top }));
      return;
    }
    const id = row.closest("[data-dnd-item-id]")?.getAttribute("data-dnd-item-id");
    if (event.altKey && !event.metaKey && !event.ctrlKey && id && event.key.startsWith("Arrow")) {
      event.preventDefault();
      moveRow(id, isFolder ? "folder" : "tab", event.key);
      return;
    }
    if (event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return;
    // The shown rows of the whole Space, pinned and unpinned, as in a Finder sidebar.
    const rows = Array.from((row.closest(".space-page") ?? document).querySelectorAll<HTMLElement>("[role=treeitem]"))
      .filter((candidate) => candidate.getClientRects().length > 0 && !candidate.closest("[aria-hidden=true], [inert]"));
    const index = rows.indexOf(row);
    let next: HTMLElement | null | undefined;
    if (event.key === "ArrowDown") next = rows[index + 1];
    else if (event.key === "ArrowUp") next = rows[index - 1];
    else if (event.key === "Home") next = rows[0];
    else if (event.key === "End") next = rows.at(-1);
    else if (event.key === "ArrowRight" && isFolder && row.getAttribute("aria-expanded") === "true") {
      const child = rows[index + 1];
      if (child && Number(child.getAttribute("aria-level")) > Number(row.getAttribute("aria-level"))) next = child;
    } else if (event.key === "ArrowLeft") {
      // An open subfolder closes first (its own handler), then Left moves to the parent folder's row.
      next = row.closest(".child-tab-wrapper")?.closest(".folder-drop-zone")?.querySelector<HTMLElement>(".folder-row");
    }
    if (!next) return;
    event.preventDefault();
    next.focus();
    next.scrollIntoView({ block: "nearest" });
  }

  // Reused while a folder's visible children stay the same: a new item array on every tab patch would re-run the
  // folder's animated each, a FLIP measure of every child row in each expanded folder.
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- plain memo cache, intentionally non-reactive
  const folderItemsCache = new Map<string, SidebarDndItem[]>();

  function folderBaseItems(
    folderId: string,
    children = visibleChildren(folderId),
  ): SidebarDndItem[] {
    const cached = folderItemsCache.get(folderId);
    if (
      cached &&
      cached.length === children.length &&
      cached.every((item, index) => item.id === children[index].id && item.section === section)
    ) {
      return cached;
    }
    const items = dndItemsForSidebarItems(children, section, folderId);
    folderItemsCache.set(folderId, items);
    return items;
  }

  function childZoneItems(
    folderId: string,
    children?: ReturnType<typeof visibleChildren>,
  ): SidebarDndItem[] {
    return getZoneItems(folderZone(folderId), folderBaseItems(folderId, children));
  }

</script>

{#snippet rootItemContent(entry: SidebarDndItem)}
  {#if isShadowItem(entry)}
    <div
      class="sidebar-dnd-placeholder"
      class:held={sidebarDrag?.intoCollapsedFolder}
      data-variant={section}
      aria-hidden="true"
    ></div>
  {:else if entry.kind === "folder" && foldersById.get(entry.id)?.splitLayout}
    {@const layout = foldersById.get(entry.id)?.splitLayout}
    <!-- One card, its panes stacked full width whatever their arrangement on the page. Panes
         rearrange by dropping on the page, and dragging one out to the list takes it out of the
         split. Tooltips sit beside the whole block, never over another pane. -->
    <div
      class="split-row"
      role="group"
      aria-label={t("tabSection.splitView")}
      use:dndZone={{
        id: folderZone(entry.id).id,
        axis: "vertical",
        meta: { section, spaceId: spaceId, parentFolderId: entry.id },
        getItems: () => childZoneItems(entry.id),
        canResolve: () => false,
        onDrop: (drag) => handleFolderDrop(entry.id, drag),
        onCancel: resetSidebarDrag,
      }}
    >
      {#if layout}
        {#each splitPanes(layout) as tabId (tabId)}
          {@const tab = tabsById.get(tabId)}
          {#if tab}
            {@render splitPane(entry.id, tab)}
          {/if}
        {/each}
      {/if}
    </div>
  {:else if entry.kind === "folder"}
      {@const folder = foldersById.get(entry.id)}
      {#if folder}
        {@render folderBlock(folder, true, 1)}
      {/if}
    {:else}
      {@const tab = tabsById.get(entry.id)}
      {#if tab && editingTab?.id === tab.id}
        <SavedTabEditor {tab} homeURL={editingTab.homeURL} onclose={closeTabEditor} />
      {:else if tab}
        <TabItem
          {tab}
          isActive={tab.id === activeTabId}
          interactive={interactive}
          disableTooltip={dragActive}
          actionsInert={dragActive}
          tabStop={tab.id === tabStopId}
        />
      {/if}
  {/if}
{/snippet}

<!-- `shown`: every folder above this one is open. Subfolders render through this same snippet,
     one indent and one branch of their parent's line deeper. -->
{#snippet folderBlock(folder: FolderState, shown: boolean, level: number)}
  {@const childZoneEntries = childZoneItems(folder.id, visibleChildren(folder.id))}
  {@const childrenShown = shown && !folder.isCollapsed}

  <div
    class="folder-drop-zone"
    use:dndZone={{
      id: folderZone(folder.id).id,
      axis: "vertical",
      meta: {
        section,
        spaceId: spaceId,
        parentFolderId: folder.id,
        isCollapsed: folder.isCollapsed,
      },
      getItems: () => childZoneItems(folder.id),
      canResolve: (context) => canResolveFolderZone(folder.id, context),
      onDrop: (drag) => handleFolderDrop(folder.id, drag),
      onCancel: resetSidebarDrag,
    }}
  >
    <div
      role="presentation"
      class="folder-header-drop"
      class:drop-into={sidebarDrag?.intoCollapsedFolder && sidebarDrag.target?.parentFolderId === folder.id}
    >
      <TabFolderItem
        {folder}
        isRenaming={renamingFolderId === folder.id}
        {level}
        tabStop={folder.id === tabStopId}
        onCollapse={(collapsed) =>
          folderActions.setCollapsed(folder.id, collapsed)}
        onRename={() => (renamingFolderId = folder.id)}
        onRenameCommit={({ name, color }) => commitRename(folder, name, color)}
        onRenameCancel={() => (renamingFolderId = null)}
        onDelete={() => folderActions.delete(folder.id)}
        onContextMenu={(rect) => folderActions.showContextMenu(folder.id, rect.left, rect.top, rect.width, rect.height)}
      />
    </div>

    <div
      class="folder-contents-shell"
      class:open={!folder.isCollapsed}
      class:collapsed={folder.isCollapsed}
      class:expanding={expandingFolderIds.has(folder.id)}
      aria-hidden={folder.isCollapsed}
      style={`--folder-collapse-duration: ${folderContentUnmountDelayMs}ms;`}
    >
      <div class="folder-contents-clip">
        {#if shouldRenderFolderContents(folder)}
          <div
            class="folder-contents"
            role="group"
            class:drag-active={dragActive}
            class:is-empty={childZoneEntries.length === 0}
          >
            {#each childZoneEntries as childEntry, childIndex (sidebarDndKey(childEntry))}
              {@const childFolder = childEntry.kind === "folder" && !isShadowItem(childEntry) ? foldersById.get(childEntry.id) : undefined}
              <div
                animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(childEntry, { recentlyDraggedId, itemCount: childZoneEntries.length }), easing: springEase }}
                class="child-tab-wrapper"
                class:child-folder={childFolder !== undefined}
                class:recent-drop={childEntry.id === recentlyDraggedId}
                data-is-dnd-shadow-item-hint={isShadowItem(childEntry)}
                role="presentation"
                style={`--folder-child-index: ${Math.min(childIndex, 6)};`}
                use:dndItem={{
                  item: childEntry,
                  zoneId: folderZone(folder.id).id,
                  disabled: isShadowItem(childEntry) || !interactive || !childrenShown,
                  onCancel: resetSidebarDrag,
                  onDropOutsideWindow: moveTabOutOfWindow,
                }}
              >
                {#if isShadowItem(childEntry)}
                  <div
                    class="sidebar-dnd-placeholder folder"
                    class:held={sidebarDrag?.intoCollapsedFolder}
                    data-variant="folder"
                    aria-hidden="true"
                  ></div>
                {:else if childFolder}
                  <div
                    class="indented-tab-wrapper"
                    class:folder-open-rail={!childFolder.isCollapsed}
                    style={folderColorStyle(childFolder.color)}
                  >
                    {@render folderBlock(childFolder, childrenShown, level + 1)}
                  </div>
                {:else}
                  {@const tab = tabsById.get(childEntry.id)}
                  {#if tab && editingTab?.id === tab.id}
                    <SavedTabEditor {tab} homeURL={editingTab.homeURL} onclose={closeTabEditor} />
                  {:else if tab}
                    <div class="indented-tab-wrapper">
                      <TabItem
                        {tab}
                        isActive={tab.id === activeTabId}
                        interactive={interactive && childrenShown}
                        disableTooltip={dragActive || !childrenShown}
                        actionsInert={dragActive}
                        level={level + 1}
                        tabStop={tab.id === tabStopId}
                      />
                    </div>
                  {/if}
                {/if}
              </div>
            {/each}
            {#if childZoneEntries.length === 0}
              <div class="folder-empty-placeholder">{t("tabSection.folderEmpty")}</div>
            {/if}
          </div>
        {/if}
      </div>
    </div>
  </div>
{/snippet}

{#snippet splitPane(folderId: string, tab: TabState)}
  {@const childEntry = folderBaseItems(folderId).find((item) => item.id === tab.id)}
  {#if childEntry}
      <div
        class="split-pane"
        use:dndItem={{
          item: childEntry,
          zoneId: folderZone(folderId).id,
          disabled: !interactive,
          onCancel: resetSidebarDrag,
          onDropOutsideWindow: moveTabOutOfWindow,
        }}
      >
        <TabItem
          {tab}
          isActive={tab.id === activeTabId}
          interactive={interactive}
          disableTooltip={dragActive}
          tooltipAnchor=".split-row"
          actionsInert={dragActive}
          tabStop={tab.id === tabStopId}
        />
      </div>
  {/if}
{/snippet}

{#snippet newTabRowBody()}
  <span class="new-tab-icon">
    <span class="new-tab-plus">+</span>
  </span>
  <span>{t("tabSection.newTab")}</span>
{/snippet}

{#snippet newTabRow()}
  {#if !isPinned}
    {#if newTabRowExiting}
      <div class="new-tab-line exiting" aria-hidden="true">
        <div class="new-tab-row">
          {@render newTabRowBody()}
        </div>
      </div>
    {:else if showNewTabRow}
      <div class="new-tab-line" bind:this={newTabLineEl}>
        <button
          class="new-tab-row"
          use:tooltip={{ text: t("tabSection.newTab"), shortcut: shortcutKeys("tab.new") }}
          onclick={toggleNewTab}
        >
          {@render newTabRowBody()}
        </button>
        {#if getSetting("terminalEnabled", "true") !== "false"}
          <button
            class="new-terminal-button"
            aria-label={t("tabSection.newTerminal")}
            use:tooltip={{ text: t("tabSection.newTerminal"), shortcut: shortcutKeys("terminal.newTab") }}
            disabled={!interactive}
            onclick={() => tabActions.newTerminal()}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path d="M2.5 4.5 6 8l-3.5 3.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>
              <path d="M8 12h5.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
            </svg>
          </button>
        {/if}
      </div>
    {/if}
  {/if}
{/snippet}

{#snippet virtualRow(entry: SidebarDndItem)}
  {@const entryFolder = entry.kind === "folder" ? foldersById.get(entry.id) : undefined}
  <div
    class={slotClass}
    class:recent-drop={entry.id === recentlyDraggedId}
    class:folder-open-rail={entry.kind === "folder" && !!entryFolder && !entryFolder.isCollapsed && !entryFolder.isSplit}
    data-is-dnd-shadow-item-hint={isShadowItem(entry)}
    style={entry.kind === "folder" ? folderColorStyle(entryFolder?.color) : undefined}
    use:dndItem={{
      item: entry,
      zoneId: rootZone.id,
      disabled: isShadowItem(entry) || !interactive,
      onCancel: resetSidebarDrag,
      onDropOutsideWindow: moveTabOutOfWindow,
    }}
  >
    {@render rootItemContent(entry)}
  </div>
{/snippet}

{#snippet zoneItems()}
  {#if listSegments}
    <!-- Windowed: no animate:flip or transitions; FLIP is duration-0 at this
         list size anyway, and rows entering the window must not slide in. -->
    {#each listSegments as segment (segment.key)}
      {#if segment.spacer}
        <div
          class="virtual-spacer"
          style:height={`${segment.height}px`}
          aria-hidden="true"
        ></div>
      {:else}
        {@render virtualRow(segment.entry)}
      {/if}
    {/each}
  {:else}
    {#each rootZoneItems as entry (sidebarDndKey(entry))}
      {@const entryFolder = entry.kind === "folder" ? foldersById.get(entry.id) : undefined}
      <div
        animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(entry, { recentlyDraggedId, itemCount: rootZoneItems.length }), easing: springEase }}
        in:tabSlide={itemMotion(entry, MOTION.itemEnterMs)}
        out:tabSlide={itemMotion(entry, MOTION.itemExitMs)}
        class={slotClass}
        class:recent-drop={entry.id === recentlyDraggedId}
        class:folder-open-rail={entry.kind === "folder" && !!entryFolder && !entryFolder.isCollapsed && !entryFolder.isSplit}
        data-is-dnd-shadow-item-hint={isShadowItem(entry)}
        style={entry.kind === "folder" ? folderColorStyle(entryFolder?.color) : undefined}
        use:dndItem={{
          item: entry,
          zoneId: rootZone.id,
          disabled: isShadowItem(entry) || !interactive,
          onCancel: resetSidebarDrag,
          onDropOutsideWindow: moveTabOutOfWindow,
        }}
      >
        {@render rootItemContent(entry)}
      </div>
    {/each}
  {/if}
{/snippet}

{#if isPinned}
  <div
    class="pinned-section"
    class:has-tabs={hasTabs}
  >
    <div
      class="pinned-section-body"
      class:idle-empty={!hasTabs}
    >
      <div
        class="pinned-list"
        class:drag-active={dragActive && hasTabs}
        class:is-empty={rootZoneIsEmpty}
        class:has-shadow={rootHasShadow}
        class:idle-empty={!hasTabs}
        class:pinned-transfer-target={pinnedTransferTargetActive}
        data-drop-label={t("tabSection.dropToPin")}
        bind:this={pinnedListEl}
        role="tree"
        tabindex="-1"
        aria-label={t("tabSection.pinnedTabs")}
        onkeydown={handleListKeydown}
        onfocusin={handleListFocusIn}
        onfocusout={handleListFocusOut}
        use:dndZone={{
          id: rootZone.id,
          axis: "vertical",
          meta: { section, spaceId: spaceId, parentFolderId: null },
          getItems: () => rootZoneItems,
          canResolve: canResolveRootZone,
          onDrop: handleRootDrop,
          onCancel: resetSidebarDrag,
        }}
      >
        {@render zoneItems()}
      </div>
    </div>
  </div>
{:else}
  <div class="tab-list-shell">
    <div
      class="tab-list-body"
      class:has-pinned-divider={showPinnedDivider}
      bind:this={tabListBodyEl}
      onfocusin={handleListFocusIn}
      onfocusout={handleListFocusOut}
      use:dndZone={{
        id: rootZone.id,
        axis: "vertical",
        meta: { section, spaceId: spaceId, parentFolderId: null },
        getItems: () => rootZoneItems,
        canResolve: canResolveRootZone,
        onDrop: handleRootDrop,
        onCancel: resetSidebarDrag,
      }}
    >
      {#if showPinnedDivider}
        <div
          class="pinned-tab-divider-shell"
          class:pinned-transfer-gate={pinnedTransferGateActive}
          class:collapsed={pinnedDividerHidden}
        >
          <div
            class="pinned-tab-divider"
            class:pinned-transfer-gate={pinnedTransferGateActive}
            class:pinned-transfer-return={pinnedTransferReturnActive}
            class:hidden-line={pinnedDividerHidden}
            aria-hidden="true"
          ></div>
          {#if canClear && !dragActive && !pinnedDividerHidden}
            <button
              class="clear-unpinned"
              disabled={!interactive}
              use:tooltip={{ text: t("tabSection.clearUnpinnedTooltip"), shortcut: shortcutKeys("tab.clearUnpinned") }}
              onclick={() => tabActions.clearUnpinned()}
            >
              {t("tabSection.clearUnpinned")}
            </button>
          {/if}
        </div>
      {/if}

      <div
        class="tab-list"
        bind:this={tabListEl}
        class:drag-active={dragActive}
        class:is-empty={rootZoneIsEmpty}
        class:pinned-transfer-source={pinnedTransferSourceActive}
        role="tree"
        tabindex="-1"
        aria-label={t("tabSection.openTabs")}
        onkeydown={handleListKeydown}
      >
        {@render zoneItems()}
      </div>

      {@render newTabRow()}
    </div>
  </div>
{/if}

<style>
  .pinned-section {
    --sidebar-tab-row-gap: 2px;
    position: relative;
    flex-shrink: 0;
    min-height: 0;
  }

  .pinned-section-body {
    display: grid;
    gap: 6px;
    padding: 4px var(--sidebar-right-pad, 10px) 4px 10px;
    box-sizing: border-box;
    transition: padding 150ms var(--motion-ease-spring);
  }

  .pinned-section-body.idle-empty {
    padding-top: 0;
    padding-bottom: 0;
  }

  .pinned-section.has-tabs .pinned-section-body {
    padding-bottom: 0;
  }

  .pinned-list {
    --sidebar-zone-color: var(--color-pin);
    position: relative;
    display: grid;
    gap: var(--sidebar-tab-row-gap);
    min-height: 0;
    min-width: 0;
    border: none;
    border-radius: var(--radius-md);
    box-sizing: border-box;
    outline: none;
    opacity: 1;
    transform: scaleY(1);
    transform-origin: top;
    transition:
      height 150ms var(--motion-ease-spring),
      min-height 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform 150ms var(--motion-ease-spring),
      background var(--motion-duration-fast) ease,
      border-color var(--motion-duration-fast) ease,
      box-shadow var(--motion-duration-fast) ease;
  }

  .pinned-list.idle-empty {
    height: 0;
    min-height: 0;
    opacity: 0;
    transform: scaleY(0.92);
    overflow: hidden;
  }

  .pinned-list.drag-active.is-empty {
    height: 28px;
    min-height: 28px;
    overflow: hidden;
    border-color: transparent;
    background: transparent;
    box-shadow: none;
    animation: sidebar-dz-breathe 1.35s ease-in-out infinite;
    transform-origin: center;
    will-change: opacity, transform;
  }

  .pinned-list.drag-active.is-empty.has-shadow {
    display: grid;
    grid-template-columns: 1fr;
    align-items: stretch;
    justify-content: stretch;
  }

  .pinned-list.drag-active.is-empty::before,
  .pinned-list.drag-active.is-empty::after {
    position: absolute;
    top: 50%;
    z-index: 1;
    opacity: 1;
    pointer-events: none;
  }

  .pinned-list.drag-active.is-empty.has-shadow::before,
  .pinned-list.drag-active.is-empty.has-shadow::after {
    opacity: 0;
  }

  .pinned-list.drag-active.is-empty.has-shadow::before {
    transform: translate(-58px, calc(-50% - 2px)) scale(0.96);
  }

  .pinned-list.drag-active.is-empty.has-shadow::after {
    transform: translate(-34px, calc(-50% - 2px)) scale(0.98);
  }

  .pinned-list.drag-active.is-empty::before {
    content: "";
    left: 50%;
    width: 14px;
    height: 14px;
    background: color-mix(in srgb, var(--sidebar-zone-color) 82%, var(--text-primary));
    -webkit-mask: url("data:image/svg+xml,%3Csvg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath fill='black' d='M14 2l8 8-3 3-2-2-3.7 3.7V20l-1 1-4-4-5 5-1-1 5-5-4-4 1-1h5.3L14 7.3l-2-2 2-3.3zm5 1v2h2v2h-2v2h-2V7h-2V5h2V3h2z'/%3E%3C/svg%3E") center / contain no-repeat;
    mask: url("data:image/svg+xml,%3Csvg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath fill='black' d='M14 2l8 8-3 3-2-2-3.7 3.7V20l-1 1-4-4-5 5-1-1 5-5-4-4 1-1h5.3L14 7.3l-2-2 2-3.3zm5 1v2h2v2h-2v2h-2V7h-2V5h2V3h2z'/%3E%3C/svg%3E") center / contain no-repeat;
    transform: translate(-58px, -50%);
  }

  .pinned-list.drag-active.is-empty::after {
    content: attr(data-drop-label);
    left: 50%;
    color: color-mix(in srgb, var(--sidebar-zone-color) 78%, var(--text-primary));
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
    letter-spacing: 0;
    white-space: nowrap;
    transform: translate(-34px, -50%);
  }

  .tab-list-shell {
    --sidebar-tab-row-gap: 2px;
    flex: 1 0 auto;
    position: relative;
    /* Paint containment would clip the sticky divider against the shared scroller. */
    contain: layout style;
  }

  .tab-list-body {
    position: relative;
    padding: 4px var(--sidebar-right-pad, 10px) 4px 10px;
  }

  .tab-list-body.has-pinned-divider {
    padding-top: 0;
  }

  .tab-list {
    display: flex;
    flex-direction: column;
    gap: var(--sidebar-tab-row-gap);
    position: relative;
    min-height: 0;
    opacity: 1;
    transform: scaleY(1);
    transform-origin: top;
    transition:
      min-height 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform 150ms var(--motion-ease-spring);
    contain: layout style;
  }

  .tab-list.is-empty {
    opacity: 0;
    transform: scaleY(0.96);
  }

  .tab-list.drag-active.is-empty {
    min-height: 28px;
    opacity: 1;
    transform: scaleY(1);
    overflow: hidden;
  }

  .tab-list.pinned-transfer-source {
    opacity: 0.86;
    transform: translateY(2px) scale(0.996);
  }

  .pinned-tab-slot,
  .tab-drop-slot {
    position: relative;
    min-width: 0;
  }

  .virtual-spacer {
    flex: none;
    pointer-events: none;
  }

  /* Only the shadow slot gets a compositor layer: promoting every slot during a drag
     costs O(tabs) GPU layers. */
  .pinned-tab-slot[data-is-dnd-shadow-item-hint="true"],
  .tab-drop-slot[data-is-dnd-shadow-item-hint="true"] {
    will-change: transform;
  }

  .pinned-tab-slot.recent-drop .sidebar-dnd-placeholder,
  .tab-drop-slot.recent-drop .sidebar-dnd-placeholder,
  .child-tab-wrapper.recent-drop .sidebar-dnd-placeholder {
    animation: sidebar-dz-placeholder-absorb 230ms var(--motion-ease-spring);
  }

  /* Paint only, no padding: VIRTUAL_ROW_* mirrors the folder's layout height. */
  .folder-drop-zone {
    border-radius: var(--radius-md);
    transition: background var(--motion-duration-normal) var(--motion-ease-spring);
  }

  /* Child combinator: an open subfolder draws its lines in its own color. */
  .folder-open-rail > .folder-drop-zone {
    --folder-rail-color: color-mix(in srgb, var(--folder-accent) 58%, var(--text-primary) 14%);
    background: var(--folder-open-bg);
  }

  /* One tinted block per root folder: subfolders inside it show through their lines alone. */
  .indented-tab-wrapper.folder-open-rail > .folder-drop-zone {
    background: none;
  }

  /* The trunk drops from the folder glyph's left edge (centered on the favicon column) so
     children only indent 12px. Middle children draw a straight trunk plus a tick, the last one
     an L, so no strokes overlap. */
  .folder-open-rail .child-tab-wrapper::before,
  .folder-open-rail .child-tab-wrapper:not(:last-child)::after {
    content: "";
    position: absolute;
    pointer-events: none;
  }

  .folder-open-rail .child-tab-wrapper::before {
    left: 7.5px;
    top: calc(-1 * var(--sidebar-tab-row-gap));
    bottom: 0;
    border-left: 1px solid var(--folder-rail-color);
  }

  .folder-open-rail .child-tab-wrapper:first-child::before {
    top: -9px;
  }

  .folder-open-rail .child-tab-wrapper:not(:last-child)::after {
    left: 8.5px;
    top: calc(50% - 0.5px);
    width: 8px;
    border-top: 1px solid var(--folder-rail-color);
  }

  .folder-open-rail .child-tab-wrapper:last-child::before {
    bottom: calc(50% - 0.5px);
    width: 9px;
    border-bottom: 1px solid var(--folder-rail-color);
    border-bottom-left-radius: var(--radius-sm);
  }

  /* A subfolder's branch meets its header row, not the middle of its open block. */
  .folder-open-rail .child-tab-wrapper.child-folder:not(:last-child)::after {
    top: 13.5px;
  }

  .folder-open-rail .child-tab-wrapper.child-folder:last-child::before {
    bottom: calc(100% - 14.5px);
  }

  @media (prefers-color-scheme: dark) {
    .folder-open-rail > .folder-drop-zone {
      --folder-rail-color: color-mix(in srgb, var(--folder-accent) 62%, var(--text-primary) 12%);
    }
  }

  .folder-header-drop {
    border-radius: var(--radius-md);
    transition: background var(--transition-fast), box-shadow var(--transition-fast);
  }

  /* A collapsed folder shows no placeholder, so its header carries the drop feedback. */
  .folder-header-drop.drop-into {
    background: color-mix(in srgb, var(--folder-accent) 16%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--folder-accent) 45%, transparent);
  }

  .folder-contents-shell {
    display: grid;
    grid-template-rows: 0fr;
    opacity: 0;
    transform: translateY(-3px);
    transform-origin: top;
    transition:
      grid-template-rows var(--folder-collapse-duration, 230ms) var(--motion-ease-spring),
      opacity var(--motion-duration-normal) ease,
      transform var(--folder-collapse-duration, 230ms) var(--motion-ease-spring);
    overflow: hidden;
  }

  .folder-contents-shell.open {
    grid-template-rows: 1fr;
    opacity: 1;
    transform: translateY(0);
  }

  .folder-contents-shell.collapsed {
    transition-duration: 150ms;
  }

  .folder-contents-clip {
    min-height: 0;
    overflow: hidden;
  }

  .folder-contents {
    display: flex;
    flex-direction: column;
    gap: var(--sidebar-tab-row-gap);
    margin-top: 2px;
    min-width: 0;
    overflow: hidden;
  }

  .folder-contents-shell.expanding .child-tab-wrapper {
    animation: folder-child-rise 300ms var(--motion-ease-bounce) both;
    animation-delay: calc(var(--folder-child-index, 0) * 16ms);
  }

  .folder-contents.drag-active.is-empty {
    min-height: 26px;
  }

  .folder-empty-placeholder {
    margin-left: 12px;
    height: 26px;
    display: flex;
    align-items: center;
    padding: 0 10px;
    box-sizing: border-box;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    border: 1px dashed color-mix(in srgb, var(--folder-accent, var(--text-primary)) 24%, transparent);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--folder-accent, var(--text-primary)) 5%, transparent);
  }

  .indented-tab-wrapper {
    width: 100%;
    min-width: 0;
    padding-left: 12px;
    box-sizing: border-box;
  }

  .child-tab-wrapper {
    position: relative;
    width: 100%;
    min-width: 0;
  }

  @keyframes folder-child-rise {
    from {
      opacity: 0;
      transform: translateY(-4px) scale(0.985);
    }
    to {
      opacity: 1;
      transform: translateY(0) scale(1);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .folder-contents-shell {
      transition: none;
      transform: none;
    }

    .folder-contents-shell.expanding .child-tab-wrapper {
      animation: none;
    }
  }

  /* Keeps its slot while a collapsed folder takes the drop, so nothing reflows. */
  .sidebar-dnd-placeholder.held {
    visibility: hidden;
  }

  .sidebar-dnd-placeholder {
    height: 28px;
    width: 100%;
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--text-primary) 18%, transparent);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, white 7%, transparent);
    pointer-events: none;
    transform-origin: center;
    will-change: opacity, transform;
  }

  .sidebar-dnd-placeholder[data-variant="pinned"] {
    border-color: color-mix(in srgb, var(--color-pin) 42%, transparent);
    background: color-mix(in srgb, var(--color-pin) 12%, transparent);
    animation: sidebar-dz-placeholder-breathe 1.35s ease-in-out infinite;
  }

  .pinned-transfer-target .pinned-tab-slot[data-is-dnd-shadow-item-hint="true"] > .sidebar-dnd-placeholder {
    animation:
      pinned-transfer-placeholder-enter 190ms var(--motion-ease-spring),
      sidebar-dz-placeholder-breathe 1.35s ease-in-out 190ms infinite;
  }

  .sidebar-dnd-placeholder.folder {
    margin-left: 12px;
    width: calc(100% - 12px);
  }

  .new-tab-line {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .new-tab-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    height: 28px;
    padding: 6px;
    border: none;
    background: none;
    color: var(--text-muted);
    cursor: pointer;
    border-radius: var(--radius-md);
    font-size: var(--font-size-md);
    text-align: left;
    box-sizing: border-box;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .tab-list:not(:empty) + .new-tab-line {
    margin-top: var(--sidebar-tab-row-gap);
  }

  /* The tab rows' hover recipe (TabItem). */
  .new-tab-row:hover,
  .new-terminal-button:hover:not(:disabled) {
    background: color-mix(in srgb, var(--bg-selected) 20%, transparent);
  }

  .new-tab-row:focus-visible,
  .new-terminal-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* The margin centers it on the rows' close buttons (20px, inset by the row's 6px padding). */
  .new-terminal-button {
    width: 28px;
    height: 28px;
    margin-right: 2px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: none;
    background: none;
    color: var(--text-muted);
    cursor: pointer;
    border-radius: var(--radius-md);
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .new-terminal-button:hover:not(:disabled) {
    color: var(--text-primary);
  }

  .new-tab-line.exiting {
    height: 0 !important;
    opacity: 0;
    pointer-events: none;
    overflow: hidden;
  }

  .new-tab-icon {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .new-tab-plus {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--font-size-xl);
    line-height: 1;
  }

  /* Inset by the rows' 6px padding: from the favicon column to the close buttons' edge. */
  .pinned-tab-divider {
    height: 1px;
    margin: 0 6px;
    background: var(--text-primary-tint-10);
    border-radius: var(--radius-chip);
    opacity: 0.9;
    transform: scaleX(1);
    transform-origin: center;
    transition:
      height 160ms var(--motion-ease-spring),
      background var(--motion-duration-fast) ease,
      opacity var(--motion-duration-fast) ease,
      transform 160ms var(--motion-ease-spring),
      box-shadow var(--motion-duration-fast) ease;
  }

  .pinned-tab-divider.hidden-line {
    opacity: 0;
  }

  .pinned-tab-divider.pinned-transfer-gate {
    height: 3px;
    background: color-mix(in srgb, var(--color-pin) 72%, var(--accent));
    opacity: 1;
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-pin) 16%, transparent);
    animation: pinned-transfer-gate-open 190ms var(--motion-ease-spring);
  }

  .pinned-tab-divider.pinned-transfer-gate.pinned-transfer-return {
    animation: pinned-transfer-gate-return 190ms var(--motion-ease-spring);
  }

  @keyframes pinned-transfer-gate-open {
    from {
      opacity: 0.45;
      transform: scaleX(0.72) scaleY(0.75);
    }

    to {
      opacity: 1;
      transform: scaleX(1) scaleY(1);
    }
  }

  @keyframes pinned-transfer-gate-return {
    from {
      opacity: 0.52;
      transform: translateY(-1px) scaleX(0.82) scaleY(0.8);
    }

    to {
      opacity: 1;
      transform: translateY(0) scaleX(1) scaleY(1);
    }
  }

  @keyframes pinned-transfer-placeholder-enter {
    from {
      opacity: 0.36;
      transform: translateY(5px) scale(0.985);
    }

    to {
      opacity: 1;
      transform: translateY(0) scale(1);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .pinned-list.drag-active.is-empty,
    .sidebar-dnd-placeholder,
    .pinned-tab-slot.recent-drop .sidebar-dnd-placeholder,
    .tab-drop-slot.recent-drop .sidebar-dnd-placeholder,
    .child-tab-wrapper.recent-drop .sidebar-dnd-placeholder,
    .pinned-tab-divider.pinned-transfer-gate,
    .pinned-transfer-target .pinned-tab-slot[data-is-dnd-shadow-item-hint="true"] > .sidebar-dnd-placeholder {
      animation: none;
    }
  }

  /* Sticks to the top of the shared scroller so the pinned/unpinned boundary stays
     legible once the pinned rows have scrolled away. */
  .pinned-tab-divider-shell {
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: calc(var(--sidebar-tab-row-gap) + 2px) 0;
    position: sticky;
    top: 0;
    z-index: 1;
    background: var(--sidebar-bg);
    transition: padding 160ms var(--motion-ease-spring);
    /* Holds Clear with 4px to spare on each side, with or without it, so the line never moves
       when Clear comes or goes. */
    min-height: 24px;
  }

  /* No pins and no drag: no line to show, and Clear stays on its shortcut and menu, so the row would
     only read as an empty gap. A drag grows it back, animated. */
  .pinned-tab-divider-shell.collapsed {
    min-height: 0;
    padding: calc(var(--sidebar-tab-row-gap) / 2) 0;
  }

  .pinned-tab-divider-shell.pinned-transfer-gate {
    padding: 8px 0;
  }

  /* Sits on the divider line, shown while the pointer is over the list. */
  .clear-unpinned {
    position: absolute;
    top: 50%;
    right: 10px;
    height: 16px;
    padding: 0 6px;
    border: none;
    border-radius: var(--radius-sm);
    background: var(--sidebar-bg);
    color: var(--text-muted);
    font: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
    opacity: 0;
    transform: translateY(-50%);
    transition:
      opacity var(--motion-duration-fast) ease,
      color var(--transition-fast);
  }

  .tab-list-shell:hover .clear-unpinned,
  .clear-unpinned:focus-visible {
    opacity: 1;
  }

  .clear-unpinned:hover {
    color: var(--text-primary);
  }

  .clear-unpinned:focus-visible {
    outline: var(--focus-outline);
  }

  /* The stacked panes share one card. */
  .split-row {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 2px;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-hover) 70%, transparent);
  }

  .split-pane {
    display: flex;
    min-width: 0;
  }

  .split-pane > :global(*) {
    flex: 1 1 auto;
    min-width: 0;
  }
</style>
