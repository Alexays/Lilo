<script lang="ts" module>
  import { on } from "../../lib/bridge";
  import { parseInput } from "../../lib/inputParser";

  // What the drag over the chrome would open, sent by the host as the drag enters it and emptied as it leaves:
  // WebKit's drag events tell neither a file's path nor, before the drop, the dragged text. Only what the address
  // bar opens counts.
  let draggedURLs = $state.raw<string[]>([]);
  on("linkDrag", ({ urls, text }) => {
    draggedURLs = (urls.length > 0 ? urls : [text]).flatMap((value) => {
      const parsed = parseInput(value);
      return parsed.type === "url" ? [parsed.url] : [];
    });
  });
</script>

<script lang="ts">
  import { tabActions } from "../../lib/bridge/actions";
  import type { BridgeLinkDropTarget } from "../../lib/bridge/protocol";
  import { dndEngineStore, type DndZoneParams } from "../../lib/dndEngine/store.svelte";
  import { getFoldersById } from "../../stores/folders.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";

  type Zone = DndZoneParams & { element: HTMLElement };
  type Box = { left: number; top: number; width: number; height: number };
  type Target = { box: Box; line: boolean; drop: BridgeLinkDropTarget };

  // The outer quarters of a row put the links beside it, its middle loads them in it, as on Chrome's tab strip.
  const EDGE_SHARE = 0.25;
  // The bottom of an open folder is the slot after it, as for a dragged tab.
  const FOLDER_END_BAND = 6;

  let target = $state.raw<Target | null>(null);
  // The active space's sidebar column under the drag, which the indicator joins so it stacks with the rows and moves
  // with the space's page; every dragover places it again, so it follows the list as it scrolls.
  let container = $state<HTMLElement | null>(null);

  function sameTarget(a: Target | null, b: Target | null): boolean {
    if (a === b) return true;
    if (!a || !b || a.line !== b.line) return false;
    return a.box.left === b.box.left && a.box.top === b.box.top && a.box.width === b.box.width && a.box.height === b.box.height;
  }

  // A row's own rect: a folder's header, a tab's row, a favorite's tile, not the slot around it.
  function rowRect(row: Element): DOMRect {
    return (row.querySelector("[role='treeitem'], .bookmark-tile") ?? row).getBoundingClientRect();
  }

  function itemsOf(zone: Zone) {
    return zone.getItems?.() ?? [];
  }

  function slot(zone: Zone, index: number): BridgeLinkDropTarget {
    const items = itemsOf(zone);
    return {
      section: zone.meta?.section ?? "unpinned",
      parentFolderId: zone.meta?.parentFolderId ?? null,
      fallbackIndex: index,
      insertBeforeId: items[index]?.id ?? null,
      insertAfterId: items[index - 1]?.id ?? null,
    };
  }

  // A line in the gap before the row at `index`, or after the last row; at the zone's top when it is empty.
  function slotTarget(zone: Zone, index: number): Target {
    const items = itemsOf(zone);
    const next = items[index] && dndEngineStore.itemElements.get(items[index].id);
    const previous = items[index - 1] && dndEngineStore.itemElements.get(items[index - 1].id);
    const nextRect = next ? rowRect(next) : null;
    const previousRect = previous ? rowRect(previous) : null;
    const anchor = nextRect ?? previousRect ?? zone.element.getBoundingClientRect();
    let box: Box;
    if (zone.axis === "grid") {
      const x = nextRect && previousRect && previousRect.top === nextRect.top
        ? (previousRect.right + nextRect.left) / 2
        : nextRect ? nextRect.left - 2 : anchor.right + 2;
      box = { left: x - 1, top: anchor.top, width: 2, height: anchor.height };
    } else {
      const y = nextRect && previousRect
        ? (previousRect.bottom + nextRect.top) / 2
        : nextRect ? nextRect.top - 1 : previousRect ? anchor.bottom + 1 : anchor.top;
      box = { left: anchor.left, top: y - 1, width: anchor.width, height: 2 };
    }
    return { box, line: true, drop: slot(zone, index) };
  }

  function highlight(rect: DOMRect, drop: BridgeLinkDropTarget): Target {
    return { box: { left: rect.left, top: rect.top, width: rect.width, height: rect.height }, line: false, drop };
  }

  // Before or after the row by the pointer's side of its middle, or onto it from its middle half when `onto` is given.
  function besideOrOnto(zone: Zone, index: number, rect: DOMRect, x: number, y: number, onto?: BridgeLinkDropTarget): Target {
    const grid = zone.axis === "grid";
    const share = grid ? (x - rect.left) / rect.width : (y - rect.top) / rect.height;
    if (onto && share >= EDGE_SHARE && share <= 1 - EDGE_SHARE) return highlight(rect, onto);
    return slotTarget(zone, share < 0.5 ? index : index + 1);
  }

  function zoneAround(node: Element | null, zones: Map<Element, Zone>): Zone | undefined {
    for (let n = node; n; n = n.parentElement) {
      const zone = zones.get(n);
      if (zone) return zone;
    }
    return undefined;
  }

  // The rendered row of the zone nearest the pointer, for a point in a gap between rows.
  function nearestRow(zone: Zone, x: number, y: number): { index: number; rect: DOMRect } | null {
    let best: { index: number; rect: DOMRect; distance: number } | null = null;
    for (const [index, item] of itemsOf(zone).entries()) {
      const element = dndEngineStore.itemElements.get(item.id);
      if (!element) continue;
      const rect = rowRect(element);
      const distance = Math.hypot(Math.max(rect.left - x, 0, x - rect.right), Math.max(rect.top - y, 0, y - rect.bottom));
      if (!best || distance < best.distance) best = { index, rect, distance };
    }
    return best;
  }

  function resolve(hit: Element, x: number, y: number): Target | null {
    const spaceId = getActiveSpaceId();
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt on each call, never rendered
    const zones = new Map<Element, Zone>();
    let unpinned: Zone | undefined;
    for (const zone of dndEngineStore.zones.values()) {
      if (zone.meta?.spaceId !== spaceId || !zone.meta.section) continue;
      zones.set(zone.element, zone);
      if (zone.meta.section === "unpinned" && !zone.meta.parentFolderId) unpinned = zone;
    }
    const folders = getFoldersById(spaceId);
    const zone = zoneAround(hit, zones);
    if (!zone) {
      // The empty sidebar under the list: a new tab at its end.
      if (!unpinned || y < unpinned.element.getBoundingClientRect().top) return null;
      return slotTarget(unpinned, itemsOf(unpinned).length);
    }
    const zoneFolder = zone.meta?.parentFolderId ? folders.get(zone.meta.parentFolderId) : undefined;
    if (zoneFolder?.splitLayout) {
      // A split's panes only take links into a pane: a new row there would be a new pane.
      const pane = nearestRow(zone, x, y);
      return pane && highlight(pane.rect, { tabId: itemsOf(zone)[pane.index].id });
    }
    const row = hit.closest<HTMLElement>("[data-dnd-item-id]");
    const rowId = row?.dataset.dndItemId;

    if (row && rowId && row.contains(zone.element)) {
      // In a folder, outside its rows: its header, or the space around its rows.
      const parent = zoneAround(row.parentElement, zones);
      const folder = folders.get(rowId);
      if (!parent || !folder) return null;
      const index = itemsOf(parent).findIndex((item) => item.id === rowId);
      const header = rowRect(row);
      if (y <= header.bottom) {
        if (folder.isLocked) return besideOrOnto(parent, index, header, x, y);
        if (y < header.top + header.height * EDGE_SHARE) return slotTarget(parent, index);
        return highlight(header, slot(zone, itemsOf(zone).length));
      }
      if (folder.isLocked || y > row.getBoundingClientRect().bottom - FOLDER_END_BAND) return slotTarget(parent, index + 1);
      const nearest = nearestRow(zone, x, y);
      return nearest ? besideOrOnto(zone, nearest.index, nearest.rect, x, y) : highlight(header, slot(zone, 0));
    }

    if (row && rowId && zone.element.contains(row)) {
      const index = itemsOf(zone).findIndex((item) => item.id === rowId);
      if (index < 0) return null;
      // The only folder row met here is a split's, around its panes.
      if (itemsOf(zone)[index].kind === "folder") return besideOrOnto(zone, index, row.getBoundingClientRect(), x, y);
      return besideOrOnto(zone, index, rowRect(row), x, y, { tabId: rowId });
    }

    const nearest = nearestRow(zone, x, y);
    if (!nearest) {
      if (!zoneFolder) return slotTarget(zone, 0);
      return zoneFolder.isLocked ? null : highlight(zone.element.getBoundingClientRect(), slot(zone, 0));
    }
    const item = itemsOf(zone)[nearest.index];
    const onto = item.kind === "tab" ? { tabId: item.id } : undefined;
    return besideOrOnto(zone, nearest.index, nearest.rect, x, y, onto);
  }

  // Listens only while a drag carries something to open.
  $effect(() => {
    if (draggedURLs.length === 0) return;
    const over = (event: DragEvent) => {
      const hit = document.elementFromPoint(event.clientX, event.clientY);
      const stack = hit?.closest<HTMLElement>(".space-stack");
      const next = hit && stack && resolve(hit, event.clientX, event.clientY);
      if (!next || !event.dataTransfer) {
        target = null;
        return;
      }
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      container = stack;
      if (!sameTarget(next, target)) target = next;
    };
    const leave = (event: DragEvent) => {
      if (event.relatedTarget === null) target = null;
    };
    const drop = (event: DragEvent) => {
      const current = target;
      target = null;
      if (!current) return;
      event.preventDefault();
      tabActions.openDroppedLinks(draggedURLs, current.drop);
      draggedURLs = [];
    };
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      target = null;
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  });

  const origin = $derived(target && container ? container.getBoundingClientRect() : null);
</script>

{#if target && container && origin}
  <div
    {@attach (node) => {
      container?.append(node);
      return () => node.remove();
    }}
    class="sidebar-link-drop"
    class:line={target.line}
    style:left="{target.box.left - origin.left}px"
    style:top="{target.box.top - origin.top}px"
    style:width="{target.box.width}px"
    style:height="{target.box.height}px"
    aria-hidden="true"
  ></div>
{/if}

<style>
  .sidebar-link-drop {
    position: absolute;
    z-index: 3;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--accent) 16%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 45%, transparent);
    pointer-events: none;
    animation: sidebar-link-drop-in var(--motion-duration-fast) var(--motion-ease-organic);
    transition:
      left var(--motion-duration-fast) var(--motion-ease-organic),
      top var(--motion-duration-fast) var(--motion-ease-organic),
      width var(--motion-duration-fast) var(--motion-ease-organic),
      height var(--motion-duration-fast) var(--motion-ease-organic);
  }

  .sidebar-link-drop.line {
    border-radius: var(--radius-2xs);
    background: var(--accent);
    box-shadow: none;
  }

  @keyframes sidebar-link-drop-in {
    from {
      opacity: 0;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .sidebar-link-drop {
      animation: none;
      transition: none;
    }
  }
</style>
