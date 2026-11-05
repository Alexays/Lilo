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
  import { MAX_SPLIT_PANES, type BridgeSplitLayout } from "../../lib/bridge/protocol";
  import type { TabState } from "../../stores/tabs.svelte";
  import TabFolderItem from "./TabFolderItem.svelte";
  import { getActiveTab, getActiveTabId, getTabsById, isBlankTab } from "../../stores/tabs.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { hostOf } from "../../lib/url";
  import {
    arrangeRows,
    nextStackHosts,
    stackName,
    type ArrangedRow,
    type ArrangeEntry,
    type RowType,
  } from "./tabSectionModel";
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
    getConversationTab,
    type FolderState,
  } from "../../stores/folders.svelte";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { on } from "../../lib/bridge";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { isUndoRevealing } from "../../stores/undoToast.svelte";

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
  const splitDropTabId = $derived(interactive ? sidebarDrag?.onItemId : undefined);
  const hidePlaceholder = $derived(sidebarDrag?.intoCollapsedFolder || !!sidebarDrag?.onItemId);
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
  // Site stacks and the agents and terminals trays: a view of the open tabs, their order untouched.
  const stackTabs = $derived(!isPinned && getSetting("sidebarStackTabs", "true") !== "false");
  const groupByType = $derived(!isPinned && getSetting("sidebarGroupByType", "false") === "true");
  const neverStack = $derived(new Set(getSetting("sidebarNeverStack", "").split(",").filter(Boolean)));
  const arrangeEntries = $derived.by((): ArrangeEntry[] => {
    if (isPinned || (!stackTabs && !groupByType)) return [];
    return rootItems.map((item) => {
      if (item.kind === "folder") return { id: item.id, type: getConversationTab(item.id, spaceId) ? "agent" : "web", host: null };
      const tab = tabsById.get(item.id);
      const type: RowType = tab?.kind === "terminal" ? "terminal" : tab?.kind === "agent" ? "agent" : "web";
      return { id: item.id, type, host: stackTabs && type === "web" ? hostOf(tab?.url) : null };
    });
  });

  // The list never reshapes under the pointer: stacks form and dissolve once it leaves, unless the
  // user changed how tabs stack.
  let pointerInList = $state(false);
  // Derived in the same pass as the rows, so tabs never show unstacked for a frame first.
  let lastStackHosts: ReadonlySet<string> = new Set();
  let stackSettings: string | null = null;
  const stackHosts = $derived.by(() => {
    const next = nextStackHosts(arrangeEntries, lastStackHosts, neverStack);
    const settings = `${stackTabs}|${[...neverStack]}`;
    if (pointerInList && settings === stackSettings) return lastStackHosts;
    stackSettings = settings;
    if (next.size !== lastStackHosts.size || [...next].some((host) => !lastStackHosts.has(host))) lastStackHosts = next;
    return lastStackHosts;
  });

  // How long a folder's rows take to rise in once it opens, their stagger included.
  const FOLDER_EXPAND_MS = 340;

  let openStacks = $state<ReadonlySet<string>>(new Set());
  const foldedTraysKey = $derived(`sidebarFoldedTrays.${spaceId}`);
  const foldedTrays = $derived(new Set(getSetting(foldedTraysKey, "").split(",").filter(Boolean)));

  // A stack or a tray opens and closes like a folder, its rows in one shell that grows or folds
  // whole: closing keeps them mounted through the fold, opening has them rise in as a folder's do.
  let groupMotion: { key: string; open: boolean } | null = $state(null);
  let groupMotionTimer: ReturnType<typeof setTimeout> | undefined;
  function startGroupMotion(key: string, open: boolean): void {
    groupMotion = { key, open };
    clearTimeout(groupMotionTimer);
    groupMotionTimer = setTimeout(() => (groupMotion = null), FOLDER_EXPAND_MS);
  }
  onDestroy(() => clearTimeout(groupMotionTimer));

  function setStackOpen(host: string, open: boolean): void {
    startGroupMotion(`stack:${host}`, open);
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
    const next = new Set(openStacks);
    if (open) next.add(host);
    else next.delete(host);
    openStacks = next;
  }

  function setTrayFolded(tray: string, folded: boolean): void {
    startGroupMotion(`tray:${tray}`, !folded);
    const next = [...foldedTrays].filter((entry) => entry !== tray);
    setSetting(foldedTraysKey, (folded ? [...next, tray] : next).join(","));
  }

  // The heads load once a list has a stack or a tray: most first frames have neither. Their slots
  // keep the heads' 32px height meanwhile, so nothing moves when they land.
  let heads = $state.raw<{
    StackRow: typeof import("./TabStackRow.svelte").default;
    TrayHeader: typeof import("./TabTrayHeader.svelte").default;
  } | null>(null);
  $effect(() => {
    if (heads || !segments.some((segment) => segment.kind !== "row")) return;
    void Promise.all([import("./TabStackRow.svelte"), import("./TabTrayHeader.svelte")]).then(([stack, tray]) => {
      heads = { StackRow: stack.default, TrayHeader: tray.default };
    });
  });

  const arranged = $derived(arrangeEntries.length > 0 ? arrangeRows(arrangeEntries, stackHosts, groupByType) : null);

  // A stack opens on the tabs an undo puts back in it, so they come back in sight.
  let seenRowIds: ReadonlySet<string> = new Set();
  $effect(() => {
    const rows = arranged ?? [];
    if (isUndoRevealing()) {
      const hosts = new Set(rows.flatMap((row) => (row.stack && !seenRowIds.has(row.id) ? [row.stack] : [])));
      untrack(() => {
        for (const host of hosts) if (!openStacks.has(host)) setStackOpen(host, true);
      });
    }
    seenRowIds = new Set(rows.map((row) => row.id));
  });

  // A closed stack or a folded tray hides its rows; the active one stays out of a folded tray, and a
  // closed stack shows it as its own face.
  function rowShown(row: ArrangedRow): boolean {
    if (row.id === activeTabId) return !row.stack || openStacks.has(row.stack);
    if (row.type === "agent" && folderHolds(row.id, activeTabId)) return true;
    if (row.tray && foldedTrays.has(row.tray)) return false;
    return !row.stack || openStacks.has(row.stack);
  }

  // Same array while the shown rows stay the same: a new one would re-run the list's animated each.
  let lastShownRootItems: typeof rootItems = [];
  const shownRootItems = $derived.by(() => {
    if (!arranged) return rootItems;
    const byId = new Map(rootItems.map((item) => [item.id, item]));
    const next = arranged.filter(rowShown).flatMap((row) => byId.get(row.id) ?? []);
    const last = lastShownRootItems;
    if (next.length === last.length && next.every((item, index) => item.id === last[index].id && item.kind === last[index].kind)) return last;
    lastShownRootItems = next;
    return next;
  });

  const stackInfo = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole per run, never mutated after
    const info = new Map<string, { name: string; tabs: TabState[] }>();
    for (const row of arranged ?? []) {
      const tab = row.stack ? tabsById.get(row.id) : undefined;
      if (!row.stack || !tab) continue;
      const entry = info.get(row.stack) ?? { name: "", tabs: [] };
      entry.tabs.push(tab);
      info.set(row.stack, entry);
    }
    for (const [host, entry] of info) entry.name = stackName(entry.tabs.map((tab) => tab.title), host);
    return info;
  });

  // An open stack is tinted with its site's color, read once off the favicon, as a folder is with its own.
  let faviconColors = $state.raw<ReadonlyMap<string, string | undefined>>(new Map());
  $effect(() => {
    for (const host of openStacks) {
      const src = stackInfo.get(host)?.tabs[0]?.faviconDataURL;
      if (!src || faviconColors.has(src)) continue;
      void faviconColor(src).then((color) => {
        // eslint-disable-next-line svelte/prefer-svelte-reactivity -- immutable copy reassigned to $state
        faviconColors = new Map(faviconColors).set(src, color);
      });
    }
  });

  // The open stack a segment paints, once its color is known: the block then comes in whole.
  function stackTintOf(segment: Segment): string | null {
    const host = segment.kind === "stack" ? segment.host : segment.kind === "row" ? segment.stack : null;
    if (!host || !openStacks.has(host)) return null;
    const src = stackInfo.get(host)?.tabs[0]?.faviconDataURL;
    return !src || faviconColors.has(src) ? host : null;
  }

  // The mean of the icon's colored pixels, each weighed by its saturation: a monochrome icon has none.
  async function faviconColor(src: string): Promise<string | undefined> {
    const image = new Image();
    image.src = src;
    await image.decode().catch(() => undefined);
    const context = image.naturalWidth ? new OffscreenCanvas(16, 16).getContext("2d") : null;
    if (!context) return undefined;
    context.drawImage(image, 0, 0, 16, 16);
    const data = context.getImageData(0, 0, 16, 16).data;
    const sum = [0, 0, 0];
    let weight = 0;
    for (let index = 0; index < data.length; index += 4) {
      const [red, green, blue, alpha] = [data[index], data[index + 1], data[index + 2], data[index + 3]];
      const pixel = ((Math.max(red, green, blue) - Math.min(red, green, blue)) / 255) * (alpha / 255);
      sum[0] += red * pixel;
      sum[1] += green * pixel;
      sum[2] += blue * pixel;
      weight += pixel;
    }
    if (weight < 4) return undefined;
    return `#${sum.map((channel) => Math.round(channel / weight).toString(16).padStart(2, "0")).join("")}`;
  }

  const trayTabs = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole per run, never mutated after
    const tabs = new Map<string, TabState[]>();
    for (const row of arranged ?? []) {
      const tab = row.tray ? (getConversationTab(row.id, spaceId) ?? tabsById.get(row.id)) : undefined;
      if (!row.tray || !tab) continue;
      tabs.set(row.tray, [...(tabs.get(row.tray) ?? []), tab]);
    }
    return tabs;
  });

  const rootBaseItems = $derived(dndItemsForSidebarItems(shownRootItems, section));
  const rootZoneItems = $derived(getZoneItems(rootZone, rootBaseItems));

  type Tray = Exclude<RowType, "web">;
  type Segment =
    | { kind: "row"; key: string; entry: SidebarDndItem; tray: Tray | null; stack: string | null; trayEnd: boolean; stackEnd: boolean }
    | { kind: "stack"; key: string; host: string; tray: Tray | null; trayEnd: boolean; stackEnd: boolean }
    | { kind: "tray"; key: string; tray: Tray; trayEnd: boolean };

  // The rows in display order with the heads of stacks and trays among them. The drop placeholder
  // joins the stack or tray of the row above it.
  let lastSegments: Segment[] = [];
  let lastSegmentsSignature = "";
  const segments = $derived.by((): Segment[] => {
    const zone = rootZoneItems;
    const row = (entry: SidebarDndItem, tray: Tray | null, stack: string | null): Segment =>
      ({ kind: "row", key: sidebarDndKey(entry), entry, tray, stack, trayEnd: false, stackEnd: false });
    let next: Segment[];
    if (!arranged) {
      next = zone.map((entry) => row(entry, null, null));
    } else {
      const shadow = zone.find(isShadowItem);
      const shadowAfter = shadow ? (zone[zone.indexOf(shadow) - 1]?.id ?? null) : undefined;
      // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole per run, never mutated after
      const unplaced = new Map(zone.filter((entry) => !isShadowItem(entry)).map((entry) => [entry.id, entry]));
      next = shadow && shadowAfter === null ? [row(shadow, null, null)] : [];
      let tray: Tray | null = null;
      let stack: string | null = null;
      const place = (entry: SidebarDndItem) => {
        next.push(row(entry, tray, stack));
        if (shadow && entry.id === shadowAfter) next.push(row(shadow, tray, stack));
      };
      for (const arrangedRow of arranged) {
        if (arrangedRow.tray !== tray) {
          tray = arrangedRow.tray;
          stack = null;
          if (tray) next.push({ kind: "tray", key: `tray:${tray}`, tray, trayEnd: false });
        }
        if (arrangedRow.stack !== stack) {
          stack = arrangedRow.stack;
          if (stack) next.push({ kind: "stack", key: `stack:${stack}`, host: stack, tray, trayEnd: false, stackEnd: false });
        }
        const entry = unplaced.get(arrangedRow.id);
        if (!entry) continue;
        unplaced.delete(arrangedRow.id);
        place(entry);
      }
      tray = null;
      stack = null;
      // Rows the arrangement has not seen yet, as a tab dragged in from another section.
      for (const entry of unplaced.values()) place(entry);
      const stackOf = (segment: Segment | undefined) =>
        segment?.kind === "stack" ? segment.host : segment?.kind === "row" ? segment.stack : null;
      for (let index = 0; index < next.length; index += 1) {
        const segment = next[index];
        const trayEnd = !!segment.tray && next[index + 1]?.tray !== segment.tray;
        const stackEnd = !!stackOf(segment) && stackOf(next[index + 1]) !== stackOf(segment);
        if (segment.kind !== "tray" && (trayEnd || stackEnd)) next[index] = { ...segment, trayEnd, stackEnd };
        else if (trayEnd) next[index] = { ...segment, trayEnd };
      }
    }
    const signature = next.map((segment) => `${segment.key}|${segment.tray}|${segment.kind === "row" ? segment.stack : ""}|${segment.trayEnd}|${segment.kind !== "tray" && segment.stackEnd}`).join(",");
    if (signature === lastSegmentsSignature) return lastSegments;
    lastSegmentsSignature = signature;
    lastSegments = next;
    return next;
  });

  // The segments as the animated list draws them: a stack or a tray is one block, its head over
  // a shell holding its rows, like a folder.
  type RowSegment = Extract<Segment, { kind: "row" }>;
  type GroupHead = Exclude<Segment, RowSegment>;
  type Block = { kind: "row"; key: string; segment: RowSegment } | { kind: "group"; key: string; head: GroupHead; rows: RowSegment[] };
  const blocks = $derived.by((): Block[] => {
    const next: Block[] = [];
    let group: Extract<Block, { kind: "group" }> | null = null;
    for (const segment of segments) {
      if (segment.kind !== "row") {
        group = { kind: "group", key: segment.key, head: segment, rows: [] };
        next.push(group);
      } else if (group && group.key === (segment.stack ? `stack:${segment.stack}` : `tray:${segment.tray}`)) {
        group.rows.push(segment);
      } else {
        group = null;
        next.push({ kind: "row", key: segment.key, segment });
      }
    }
    return next;
  });

  function groupOpen(head: GroupHead): boolean {
    return head.kind === "stack" ? openStacks.has(head.host) : !foldedTrays.has(head.tray);
  }

  // A folding group's rows, out of the list already, drawn on through the fold; the active one
  // stays shown above the shell.
  function foldingRows(block: Extract<Block, { kind: "group" }>): SidebarDndItem[] {
    const shown = new Set(block.rows.map((row) => row.entry.id));
    const head = block.head;
    const ids = new Set(
      (arranged ?? [])
        .filter((row) => (head.kind === "stack" ? row.stack === head.host : row.tray === head.tray) && !shown.has(row.id))
        .map((row) => row.id),
    );
    return dndItemsForSidebarItems(rootItems.filter((item) => ids.has(item.id)), section);
  }
  // A closed stack's or a folded tray's head is all a list may show: it is not empty then.
  const listIsEmpty = $derived(segments.length === 0);
  const rootHasShadow = $derived(rootZoneItems.some(isShadowItem));
  const recentlyDraggedId = $derived(getRecentlyDroppedId());

  const activeTab = $derived(getActiveTab(spaceId));
  // Native keeps the archive of the window's Space only.
  const isNewTabActive = $derived(isBlankTab(activeTab));
  // Not gated on `interactive` either: the Space sliding away keeps its row through the swipe.
  const showNewTabRow = $derived(!isPinned && !isNewTabActive);
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
  // The color picked in a folder's editor, painted on its block and rail before it is applied, and kept until the
  // applied color comes back from native so the block never flashes its old color.
  let draftFolderColor: { id: string; color: string } | null = $state(null);
  const shownFolderColor = (folder: FolderState | undefined): string | undefined =>
    folder && draftFolderColor?.id === folder.id ? draftFolderColor.color : folder?.color;
  $effect(() => {
    if (draftFolderColor && renamingFolderId !== draftFolderColor.id && foldersById.get(draftFolderColor.id)?.color === draftFolderColor.color) {
      draftFolderColor = null;
    }
  });
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
  // Mirror the row CSS (32px rows, 2px --sidebar-tab-row-gap, the same gap above a folder's
  // contents, 32px empty-folder placeholder); the buffer absorbs small drift.
  const VIRTUAL_ROW_H = 32;
  const VIRTUAL_ROW_GAP = 2;
  const VIRTUAL_FOLDER_TOP_MARGIN = 2;
  const VIRTUAL_EMPTY_FOLDER_H = 32;

  type ListSegment = Segment | { kind: "spacer"; key: string; height: number };

  // How far the list's top sits above the shared scroller's viewport top, floored to a window step.
  let listScrollTop = $state(0);
  let focusedItemId = $state<string | null>(null);
  const listWindowFrame = createFrameScheduler();

  const virtualize = $derived(
    !isPinned && !dragActive && segments.length > VIRTUALIZE_MIN_ROWS,
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
    const shown: ListSegment[] = [];
    let top = 0;
    let hiddenHeight = 0;
    let hiddenCount = 0;
    let spacerOrdinal = 0;
    const flushSpacer = () => {
      if (hiddenCount === 0) return;
      // The flex gap supplies the boundary gaps around the spacer, so it only
      // carries the hidden rows' own heights plus the gaps between them.
      shown.push({
        kind: "spacer",
        key: `spacer-${spacerOrdinal++}`,
        height: hiddenHeight + (hiddenCount - 1) * VIRTUAL_ROW_GAP,
      });
      hiddenHeight = 0;
      hiddenCount = 0;
    };
    for (const segment of segments) {
      const entry = segment.kind === "row" ? segment.entry : null;
      const height = entry ? estimatedRowHeight(entry) : VIRTUAL_ROW_H;
      // The active and focused rows stay mounted wherever the scroll sits, so
      // tab switching and keyboard focus never land on an unmounted row. Hidden
      // children count too: keeping one extra folder mounted is harmless.
      const keep =
        (top + height >= minY && top <= maxY) ||
        (entry !== null &&
          (entry.id === activeTabId ||
            entry.id === focusedItemId ||
            (entry.kind === "folder" &&
              (folderHolds(entry.id, activeTabId) || folderHolds(entry.id, focusedItemId)))));
      if (keep) {
        flushSpacer();
        shown.push(segment);
      } else {
        hiddenHeight += height;
        hiddenCount += 1;
      }
      top += height + VIRTUAL_ROW_GAP;
    }
    flushSpacer();
    return shown;
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
    }, FOLDER_EXPAND_MS));
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
      // A tab dropped on a conversation is not filed into it; its own pages still reorder.
      refusesDrag:
        folder.isLocked === true ||
        (getConversationTab(folderId, spaceId) !== undefined && parentFolderIdById.get(source.id) !== folderId) ||
        (source.kind === "folder" && !canNestFolder(source.id, folderId, spaceId)),
      dragKind: source.kind,
      rows: folderTargetRows(context),
    });
  }

  function splitTargetAt({ point, zone, dragSource }: DndTargetContext): string | undefined {
    if (!interactive || dragSource.kind !== "tab") return undefined;
    const source = tabsById.get(dragSource.id);
    if (!source || source.isClosed || source.isBookmarked) return undefined;
    const row = zone.items.find(({ rect }) => {
      const edge = rect.height / 3;
      return point.y >= rect.top + edge && point.y <= rect.bottom - edge && point.x >= rect.left && point.x <= rect.right;
    });
    const tab = row && tabsById.get(row.id);
    if (!tab || tab.isClosed || tab.id === editingTab?.id) return undefined;
    const layout = tab.groupId ? foldersById.get(tab.groupId)?.splitLayout : undefined;
    if (layout && source.groupId !== tab.groupId && splitPanes(layout).length >= MAX_SPLIT_PANES) return undefined;
    return tab.id;
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
      openCommandBar("", true);
    }
  }

  function commitRename(folder: FolderState, name: string, color: string): void {
    renamingFolderId = null;
    draftFolderColor = color === folder.color ? null : { id: folder.id, color };
    folderActions.update({ id: folder.id, name, color });
  }

  // A conversation's own tab is its folder's row, not one of its children.
  function visibleChildren(folderId: string) {
    const children = getVisibleFolderChildren(folderId, spaceId, isPinned, tabsById);
    const conversation = getConversationTab(folderId, spaceId);
    return conversation ? children.filter((child) => child.id !== conversation.id) : children;
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
      if (!target || target.isSplit || target.isLocked || getConversationTab(target.id, spaceId)) return;
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
    next.focus({ preventScroll: true });
    // Only the Space's own list scrolls: scrollIntoView would also nudge the pager under it.
    const scroller = next.closest<HTMLElement>(".space-scroll");
    if (!scroller) return;
    const rowRect = next.getBoundingClientRect();
    const viewRect = scroller.getBoundingClientRect();
    if (rowRect.top < viewRect.top) scroller.scrollTop += rowRect.top - viewRect.top;
    else if (rowRect.bottom > viewRect.bottom) scroller.scrollTop += rowRect.bottom - viewRect.bottom;
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

{#snippet rootItemContent(entry: SidebarDndItem, stack: string | null)}
  {#if isShadowItem(entry)}
    <div
      class="sidebar-dnd-placeholder"
      class:held={hidePlaceholder}
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
        resolveOnItem: splitTargetAt,
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
      {:else if tab && stack}
        <div class="indented-tab-wrapper">
          <TabItem
            {tab}
            isActive={tab.id === activeTabId}
            interactive={interactive}
            disableTooltip={dragActive}
            actionsInert={dragActive}
            splitDropTarget={splitDropTabId === tab.id}
            level={2}
            stackName={stackInfo.get(stack)?.name}
            tabStop={tab.id === tabStopId}
          />
        </div>
      {:else if tab}
        <TabItem
          {tab}
          isActive={tab.id === activeTabId}
          interactive={interactive}
          disableTooltip={dragActive}
          actionsInert={dragActive}
          splitDropTarget={splitDropTabId === tab.id}
          tabStop={tab.id === tabStopId}
        />
      {/if}
  {/if}
{/snippet}

<!-- `shown`: every folder above this one is open. Subfolders render through this same snippet,
     one indent deeper. -->
{#snippet folderBlock(folder: FolderState, shown: boolean, level: number)}
  {@const conversation = getConversationTab(folder.id, spaceId)}
  {@const children = visibleChildren(folder.id)}
  {@const childZoneEntries = childZoneItems(folder.id, children)}
  {@const childrenShown = shown && !folder.isCollapsed}

  <div
    class="folder-drop-zone"
    class:conversation={!!conversation}
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
      resolveOnItem: (context) => childrenShown && !folder.isLocked ? splitTargetAt(context) : undefined,
      onDrop: (drag) => handleFolderDrop(folder.id, drag),
      onCancel: resetSidebarDrag,
    }}
  >
    <div
      role="presentation"
      class="folder-header-drop"
      class:drop-into={sidebarDrag?.intoCollapsedFolder && sidebarDrag.target?.parentFolderId === folder.id}
    >
      {#if conversation}
        <!-- Loaded with the first conversation, out of the chrome's first frame. -->
        {#await import("./ConversationRow.svelte") then { default: ConversationRow }}
        <ConversationRow
          {folder}
          tab={conversation}
          pageCount={children.length}
          isActive={conversation.id === activeTabId}
          interactive={interactive && shown}
          {level}
          tabStop={folder.id === tabStopId}
          onCollapse={(collapsed) => folderActions.setCollapsed(folder.id, collapsed)}
          onContextMenu={(rect) => folderActions.showContextMenu(folder.id, rect.left, rect.top, rect.width, rect.height)}
        />
        {/await}
      {:else}
      <TabFolderItem
        {folder}
        isRenaming={renamingFolderId === folder.id}
        {level}
        tabStop={folder.id === tabStopId}
        containsActiveTab={folderHolds(folder.id, activeTabId)}
        onCollapse={(collapsed) =>
          folderActions.setCollapsed(folder.id, collapsed)}
        onRename={() => (renamingFolderId = folder.id)}
        onRenameCommit={({ name, color }) => commitRename(folder, name, color)}
        onRenameCancel={() => {
          renamingFolderId = null;
          draftFolderColor = null;
        }}
        onDraftColor={(color) => (draftFolderColor = { id: folder.id, color })}
        onDelete={() => folderActions.delete(folder.id)}
        onContextMenu={(rect) => folderActions.showContextMenu(folder.id, rect.left, rect.top, rect.width, rect.height)}
      />
      {/if}
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
            class:conversation-contents={!!conversation}
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
                    class:held={hidePlaceholder}
                    data-variant="folder"
                    aria-hidden="true"
                  ></div>
                {:else if childFolder}
                  <div
                    class="indented-tab-wrapper"
                    class:folder-open-rail={!childFolder.isCollapsed}
                    style={folderColorStyle(shownFolderColor(childFolder))}
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
                        splitDropTarget={splitDropTabId === tab.id}
                        level={level + 1}
                        tabStop={tab.id === tabStopId}
                      />
                    </div>
                  {/if}
                {/if}
              </div>
            {/each}
            {#if childZoneEntries.length === 0 && !conversation}
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
          splitDropTarget={splitDropTabId === tab.id}
          tabStop={tab.id === tabStopId}
        />
      </div>
  {/if}
{/snippet}

{#snippet newTabRowBody()}
  <span class="new-tab-icon">
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true">
      <path d="M6 1.5v9M1.5 6h9" />
    </svg>
  </span>
  <span class="new-tab-label">{t("tabSection.newTab")}</span>
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
          disabled={!interactive}
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
        {#if getSetting("agentsEnabled", "false") === "true"}
          <!-- Sized up front, so the row holds still while the badge's chunk loads. -->
          <span class="new-agents-slot">
            {#await import("../agents/AgentsBadge.svelte") then badge}
              <badge.default row />
            {/await}
          </span>
        {/if}
      </div>
    {/if}
  {/if}
{/snippet}

{#snippet segmentHead(segment: Segment)}
  {#if !heads}
    <!-- The slot holds the head's height until it loads. -->
  {:else if segment.kind === "tray"}
    {@const folded = foldedTrays.has(segment.tray)}
    <heads.TrayHeader
      tray={segment.tray}
      {folded}
      tabs={trayTabs.get(segment.tray) ?? []}
      {interactive}
      tabStop={false}
      onToggle={(next) => setTrayFolded(segment.tray, next)}
    />
  {:else if segment.kind === "stack"}
    {@const info = stackInfo.get(segment.host)}
    {#if info}
      {@const open = openStacks.has(segment.host)}
      <heads.StackRow
        name={info.name}
        tabs={info.tabs}
        face={open ? undefined : info.tabs.find((tab) => tab.id === activeTabId)}
        {open}
        {interactive}
        tabStop={false}
        onToggle={(next) => setStackOpen(segment.host, next)}
        onClose={() => tabActions.closeMany(info.tabs.map((tab) => tab.id))}
        onContextMenu={(rect) => folderActions.showStackContextMenu(info.tabs.map((tab) => tab.id), segment.host, info.name, rect)}
      />
    {/if}
  {/if}
{/snippet}

<!-- Rows and the heads of stacks and trays share one slot: a head is a disabled drag item, so it
     moves with the list but is never picked up nor hit tested (it is not in the zone's items).
     The animated list below repeats this markup: animate: must sit on the each's own child. -->
{#snippet slot(segment: Segment, entry: SidebarDndItem)}
  {@const entryFolder = entry.kind === "folder" ? foldersById.get(entry.id) : undefined}
  {@const stackTint = stackTintOf(segment)}
  <div
    class={segment.kind === "row" ? slotClass : "group-head-slot"}
    class:in-tray={!!segment.tray}
    class:tray-head={segment.kind === "tray"}
    class:tray-end={segment.trayEnd}
    class:stack-block={!!stackTint}
    class:stack-head={!!stackTint && segment.kind === "stack"}
    class:stack-end={!!stackTint && segment.kind !== "tray" && segment.stackEnd}
    class:recent-drop={entry.id === recentlyDraggedId}
    class:folder-open-rail={entry.kind === "folder" && !!entryFolder && !entryFolder.isCollapsed && !entryFolder.isSplit}
    data-is-dnd-shadow-item-hint={isShadowItem(entry)}
    style={entry.kind === "folder" ? folderColorStyle(shownFolderColor(entryFolder)) : stackTint ? folderColorStyle(faviconColors.get(stackInfo.get(stackTint)?.tabs[0]?.faviconDataURL ?? "")) : undefined}
    use:dndItem={{
      item: entry,
      zoneId: rootZone.id,
      disabled: segment.kind !== "row" || isShadowItem(entry) || !interactive,
      onCancel: resetSidebarDrag,
      onDropOutsideWindow: moveTabOutOfWindow,
    }}
  >
    {#if segment.kind === "row"}
      {@render rootItemContent(entry, segment.stack)}
    {:else}
      {@render segmentHead(segment)}
    {/if}
  </div>
{/snippet}

{#snippet zoneItems()}
  {#if listSegments}
    <!-- Windowed: no animate:flip or transitions; FLIP is duration-0 at this
         list size anyway, and rows entering the window must not slide in. -->
    {#each listSegments as segment (segment.key)}
      {#if segment.kind === "spacer"}
        <div
          class="virtual-spacer"
          style:height={`${segment.height}px`}
          aria-hidden="true"
        ></div>
      {:else}
        {@render slot(segment, segment.kind === "row" ? segment.entry : { id: segment.key, kind: "tab", section, parentFolderId: null })}
      {/if}
    {/each}
  {:else}
    {#each blocks as block (block.key)}
      {@const entry = block.kind === "row" ? block.segment.entry : { id: block.key, kind: "tab" as const, section, parentFolderId: null }}
      {@const entryFolder = entry.kind === "folder" ? foldersById.get(entry.id) : undefined}
      {@const head = block.kind === "group" ? block.head : null}
      {@const tint = head?.kind === "stack" ? stackTintOf(head) : null}
      <!-- A row's slot, or a group's block: animate: needs one element per entry. -->
      <div
        animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(entry, { recentlyDraggedId, itemCount: rootZoneItems.length }), easing: springEase }}
        in:tabSlide={itemMotion(entry, MOTION.itemEnterMs)}
        out:tabSlide={itemMotion(entry, MOTION.itemExitMs)}
        class={head ? "group-block" : slotClass}
        class:tray-block={head?.kind === "tray"}
        class:stack-open={!!tint}
        class:recent-drop={entry.id === recentlyDraggedId}
        class:folder-open-rail={entry.kind === "folder" && !!entryFolder && !entryFolder.isCollapsed && !entryFolder.isSplit}
        data-is-dnd-shadow-item-hint={isShadowItem(entry)}
        style={entry.kind === "folder" ? folderColorStyle(shownFolderColor(entryFolder)) : tint ? folderColorStyle(faviconColors.get(stackInfo.get(tint)?.tabs[0]?.faviconDataURL ?? "")) : undefined}
        use:dndItem={{
          item: entry,
          zoneId: rootZone.id,
          disabled: !!head || isShadowItem(entry) || !interactive,
          onCancel: resetSidebarDrag,
          onDropOutsideWindow: moveTabOutOfWindow,
        }}
      >
        {#if block.kind === "row"}
          {@render rootItemContent(entry, null)}
        {:else if head}
          {@const open = groupOpen(head)}
          {@const motion = groupMotion?.key === block.key ? groupMotion : null}
          <div class="group-head-slot">
            {@render segmentHead(head)}
          </div>
          {#if !open}
            <!-- What a folded tray keeps shown: its active row. -->
            {#each block.rows as row (row.key)}
              <div
                class={slotClass}
                use:dndItem={{
                  item: row.entry,
                  zoneId: rootZone.id,
                  disabled: isShadowItem(row.entry) || !interactive,
                  onCancel: resetSidebarDrag,
                  onDropOutsideWindow: moveTabOutOfWindow,
                }}
              >
                {@render rootItemContent(row.entry, null)}
              </div>
            {/each}
          {/if}
          <div
            class="folder-contents-shell"
            class:open
            class:collapsed={!open}
            class:expanding={motion?.open}
            aria-hidden={!open}
            style={`--folder-collapse-duration: ${folderContentUnmountDelayMs}ms;`}
          >
            <div class="folder-contents-clip">
              {#if open}
                <div class="folder-contents" role="group">
                  {#each block.rows as row, rowIndex (row.key)}
                    {@const rowEntry = row.entry}
                    {@const rowFolder = rowEntry.kind === "folder" ? foldersById.get(rowEntry.id) : undefined}
                    <div
                      animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(rowEntry, { recentlyDraggedId, itemCount: rootZoneItems.length }), easing: springEase }}
                      in:tabSlide={motion ? { disabled: true } : itemMotion(rowEntry, MOTION.itemEnterMs)}
                      out:tabSlide={motion ? { disabled: true } : itemMotion(rowEntry, MOTION.itemExitMs)}
                      class="{slotClass} child-tab-wrapper"
                      class:recent-drop={rowEntry.id === recentlyDraggedId}
                      class:folder-open-rail={rowEntry.kind === "folder" && !!rowFolder && !rowFolder.isCollapsed && !rowFolder.isSplit}
                      data-is-dnd-shadow-item-hint={isShadowItem(rowEntry)}
                      style={`--folder-child-index: ${Math.min(rowIndex, 6)};${rowEntry.kind === "folder" ? folderColorStyle(shownFolderColor(rowFolder)) : ""}`}
                      use:dndItem={{
                        item: rowEntry,
                        zoneId: rootZone.id,
                        disabled: isShadowItem(rowEntry) || !interactive,
                        onCancel: resetSidebarDrag,
                        onDropOutsideWindow: moveTabOutOfWindow,
                      }}
                    >
                      {@render rootItemContent(rowEntry, row.stack)}
                    </div>
                  {/each}
                </div>
              {:else if motion}
                <div class="folder-contents" role="group">
                  {#each foldingRows(block) as folding (sidebarDndKey(folding))}
                    <div class="{slotClass} child-tab-wrapper">
                      {@render rootItemContent(folding, head.kind === "stack" ? head.host : null)}
                    </div>
                  {/each}
                </div>
              {/if}
            </div>
          </div>
        {/if}
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
        class:is-empty={listIsEmpty}
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
          resolveOnItem: splitTargetAt,
          onDrop: handleRootDrop,
          onCancel: resetSidebarDrag,
        }}
      >
        {@render zoneItems()}
      </div>
    </div>
  </div>
{:else}
  <div class="tab-list-shell" role="none" onpointerenter={() => (pointerInList = true)} onpointerleave={() => (pointerInList = false)}>
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
        resolveOnItem: splitTargetAt,
        onDrop: handleRootDrop,
        onCancel: resetSidebarDrag,
      }}
    >
      {#if showPinnedDivider}
        <div
          class="pinned-tab-divider-shell"
          class:pinned-transfer-gate={pinnedTransferGateActive}
          class:collapsed={pinnedDividerHidden}
          class:with-actions={!dragActive && !pinnedDividerHidden}
          class:with-clear={canClear}
        >
          <div
            class="pinned-tab-divider"
            class:pinned-transfer-gate={pinnedTransferGateActive}
            class:pinned-transfer-return={pinnedTransferReturnActive}
            class:hidden-line={pinnedDividerHidden}
            aria-hidden="true"
          ></div>
          {#if !dragActive && !pinnedDividerHidden}
            <button
              class="divider-action list-options"
              disabled={!interactive}
              use:tooltip={{ text: t("tabSection.listOptions") }}
              aria-label={t("tabSection.listOptions")}
              onclick={(event) => sidebarActions.showTabListMenu(spaceId, event.currentTarget.getBoundingClientRect())}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true">
                <path class="sort-line" d="M1.5 3h9" />
                <path class="sort-line" d="M3 6h6" />
                <path class="sort-line" d="M4.75 9h2.5" />
              </svg>
            </button>
          {/if}
          {#if canClear && !dragActive && !pinnedDividerHidden}
            <button
              class="divider-action clear-unpinned"
              disabled={!interactive}
              use:tooltip={{ text: t("tabSection.clearUnpinnedTooltip"), shortcut: shortcutKeys("tab.clearUnpinned") }}
              aria-label={t("tabSection.clearUnpinnedTooltip")}
              onclick={() => tabActions.clearUnpinned()}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <rect class="archive-lid" x="1" y="2" width="10" height="2.5" rx="0.8" />
                <path d="M2 4.5v4.5a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.5" />
                <path class="archive-slot" d="M4.75 6.75h2.5" />
              </svg>
            </button>
          {/if}
        </div>
      {/if}

      <div
        class="tab-list"
        bind:this={tabListEl}
        class:drag-active={dragActive}
        class:is-empty={listIsEmpty}
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
    padding: 4px var(--sidebar-right-pad, 8px) 4px 8px;
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
    height: 32px;
    min-height: 32px;
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
    padding: 4px var(--sidebar-right-pad, 8px) 4px 8px;
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
    min-height: 32px;
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

  /* A tray is one tinted card: its head and rows paint it, rounded at its two ends. */
  .in-tray {
    background: var(--text-primary-tint-10);
  }

  .tray-head {
    border-radius: var(--radius-md) var(--radius-md) 0 0;
  }

  /* The rows' gap would cut a card into strips: each row but the last paints it too. */
  .in-tray:not(.tray-end) {
    box-shadow: 0 var(--sidebar-tab-row-gap) 0 var(--text-primary-tint-10);
  }

  .in-tray.tray-end {
    border-radius: 0 0 var(--radius-md) var(--radius-md);
  }

  .tray-head.tray-end {
    border-radius: var(--radius-md);
  }

  .tab-drop-slot {
    transition:
      background var(--motion-duration-normal) ease,
      box-shadow var(--motion-duration-normal) ease;
  }

  /* A head squares its bottom corners as the rows grow in under it, so an opening block never shows a square
     edge. */
  .group-head-slot {
    transition:
      background var(--motion-duration-normal) ease,
      box-shadow var(--motion-duration-normal) ease,
      border-radius var(--motion-duration-fast) ease-out;
  }

  /* No specificity, so a block's own corners win. */
  :where(.group-head-slot) {
    border-radius: var(--radius-md);
  }

  /* A stack or a tray as the animated list draws it: one block like a folder, tinted whole. */
  .group-block {
    min-width: 0;
    border-radius: var(--radius-md);
    transition: background var(--motion-duration-normal) ease;
  }

  .group-block.tray-block {
    background: var(--text-primary-tint-10);
  }

  .group-block.stack-open {
    background: var(--folder-open-bg);
  }

  /* An open stack is one block like an open folder, painted by its head and rows. */
  .stack-block {
    background: var(--folder-open-bg);
  }

  .stack-block:not(.stack-end) {
    box-shadow: 0 var(--sidebar-tab-row-gap) 0 var(--folder-open-bg);
  }

  .stack-block.stack-head {
    border-radius: var(--radius-md) var(--radius-md) 0 0;
  }

  .stack-block.stack-end {
    border-radius: 0 0 var(--radius-md) var(--radius-md);
  }

  .stack-block.stack-head.stack-end {
    border-radius: var(--radius-md);
  }

  .group-head-slot {
    position: relative;
    min-width: 0;
    min-height: 32px;
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

  /* One tinted block per open root folder, the only mark of what it holds: subfolders inside it show through. */
  .folder-open-rail > .folder-drop-zone {
    background: var(--folder-open-bg);
  }

  .indented-tab-wrapper.folder-open-rail > .folder-drop-zone,
  .folder-open-rail > .folder-drop-zone.conversation {
    background: none;
  }

  /* A conversation's pages hang on one straight violet rail under the agent's tile. */
  .folder-open-rail .conversation-contents > .child-tab-wrapper::before {
    content: "";
    position: absolute;
    left: 15px;
    top: 0;
    bottom: 0;
    border-left: 2px solid color-mix(in srgb, var(--agents) 70%, transparent);
    pointer-events: none;
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
    padding-top: var(--sidebar-tab-row-gap);
    min-width: 0;
    overflow: hidden;
  }

  .folder-contents-shell.expanding .child-tab-wrapper {
    animation: folder-child-rise 300ms var(--motion-ease-bounce) both;
    animation-delay: calc(var(--folder-child-index, 0) * 16ms);
  }

  .folder-contents.drag-active.is-empty {
    min-height: 32px;
  }

  .folder-empty-placeholder {
    margin-left: 24px;
    height: 32px;
    display: flex;
    align-items: center;
    padding: 0 8px;
    box-sizing: border-box;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    border: 1px dashed color-mix(in srgb, var(--folder-accent, var(--text-primary)) 24%, transparent);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--folder-accent, var(--text-primary)) 5%, transparent);
  }

  /* Children's icons line up under their folder's title: a 16px icon and its 8px gap. */
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

  /* Keep the slot while a row takes the drop, so it stays under the pointer. */
  .sidebar-dnd-placeholder.held {
    visibility: hidden;
  }

  .sidebar-dnd-placeholder {
    height: 32px;
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
    margin-left: 24px;
    width: calc(100% - 24px);
  }

  .new-tab-line {
    display: flex;
    align-items: center;
  }

  .new-tab-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    height: 32px;
    padding: 0 8px;
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

  /* The buttons after it keep the label off the edge, so its last 8 px go to the label in long locales. */
  .new-tab-row:not(:last-child) {
    padding-right: 0;
  }

  .tab-list:not(:empty) + .new-tab-line {
    margin-top: var(--sidebar-tab-row-gap);
  }

  /* The tab rows' hover recipe (TabItem). */
  .new-tab-row:hover,
  .new-terminal-button:hover:not(:disabled) {
    background: var(--bg-hover);
  }

  .new-tab-row:focus-visible,
  .new-terminal-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* Centered on the rows' accessory slot: 20px, inset by the row's 8px padding. */
  .new-terminal-button {
    width: 32px;
    height: 32px;
    margin-left: 2px;
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

  .new-agents-slot {
    display: flex;
    flex: none;
    width: 32px;
    margin-right: 2px;
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

  .new-tab-label {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  /* Inset by the rows' 8px padding: from the favicon column to the close buttons' edge. */
  .pinned-tab-divider {
    height: 0.5px;
    margin: 0 8px;
    background: var(--separator);
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
    padding: 4px 0;
    position: sticky;
    top: 0;
    z-index: 1;
    background: var(--sidebar-bg);
    transition: padding 160ms var(--motion-ease-spring);
    /* Holds Clear with 4px to spare on each side, with or without it, so the line never moves
       when Clear comes or goes. */
    min-height: 24px;
  }

  /* An opaque band would cut across glass or grain. */
  :global(html[data-material='glass']) .pinned-tab-divider-shell,
  :global(html[data-material='grain']) .pinned-tab-divider-shell {
    background: transparent;
  }

  /* No pins and no drag: no line to show, and Clear stays on its shortcut and menu, so the row would
     only read as an empty gap. A drag grows it back, animated. */
  .pinned-tab-divider-shell.collapsed {
    min-height: 0;
    padding: 0;
  }

  .pinned-tab-divider-shell.pinned-transfer-gate {
    padding: 8px 0;
  }

  /* Sit on the divider line's ends, popping in while the pointer is over the list. Inset like the
     rows' 20px close buttons, so both share one vertical axis. */
  /* The archive lid tilts past the 12 px box. */
  .divider-action svg {
    overflow: visible;
  }

  .divider-action {
    position: absolute;
    top: 50%;
    display: grid;
    place-items: center;
    width: 20px;
    height: 16px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    opacity: 0;
    transform: translateY(-50%) scale(0.6);
    transition:
      opacity var(--motion-duration-fast) ease,
      transform 220ms var(--motion-ease-spring),
      color var(--transition-fast);
  }

  .list-options {
    left: 8px;
  }

  .clear-unpinned {
    right: 8px;
  }

  .tab-list-shell:hover .divider-action,
  .divider-action:focus-visible {
    opacity: 1;
    transform: translateY(-50%);
  }

  .divider-action:hover {
    color: var(--text-primary);
  }

  .divider-action:focus-visible {
    outline: var(--focus-outline);
  }

  .sort-line,
  .archive-lid,
  .archive-slot {
    transform-box: fill-box;
    transform-origin: center;
    transition: transform 320ms var(--motion-ease-spring);
  }

  .archive-lid {
    transform-origin: left bottom;
  }

  /* Hovered, the funnel turns into an ascending sort: its lines trade lengths, a beat apart. */
  .list-options:hover .sort-line:nth-child(1) {
    transform: scaleX(0.28);
  }

  .list-options:hover .sort-line:nth-child(3) {
    transform: scaleX(3.6);
    transition-delay: 40ms;
  }

  /* Hovered, the box opens: the lid lifts and tilts, the handle drops into it. */
  .clear-unpinned:hover .archive-lid {
    transform: translateY(-1.5px) rotate(-10deg);
  }

  .clear-unpinned:hover .archive-slot {
    transform: translateY(1px);
    transition-delay: 40ms;
  }

  /* The line draws back from the ends to make room for the actions coming in. */
  .with-actions .pinned-tab-divider {
    clip-path: inset(0);
    transition-property: height, background, opacity, transform, box-shadow, clip-path;
  }

  .tab-list-shell:hover .with-actions .pinned-tab-divider,
  .with-actions:focus-within .pinned-tab-divider {
    clip-path: inset(0 0 0 24px);
  }

  .tab-list-shell:hover .with-actions.with-clear .pinned-tab-divider,
  .with-actions.with-clear:focus-within .pinned-tab-divider {
    clip-path: inset(0 24px);
  }

  @media (prefers-reduced-motion: reduce) {
    .divider-action {
      transform: translateY(-50%);
    }

    .divider-action:hover :is(.sort-line, .archive-lid, .archive-slot) {
      transform: none;
    }
  }

  /* The stacked panes share one card. */
  .split-row {
    position: relative;
    display: flex;
    flex-direction: column;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
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
