<script lang="ts">
  import { untrack } from "svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import {
    MAX_SPLIT_PANES,
    type BridgeSplitPaneFrame,
    type SplitDropSide,
    type SplitSide,
  } from "../../lib/bridge/protocol";
  import { dndZone } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import type { DndTargetContext } from "../../lib/dndEngine/types";
  import { t } from "../../lib/i18n/state.svelte";
  import { getConversationTab } from "../../stores/folders.svelte";
  import { getSpaceSidebar } from "../../stores/sidebar.svelte";
  import { getSidebarDrag } from "../../stores/sidebarDnd.svelte";
  import { getSplitPanes } from "../../stores/splitPanes.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";

  type DropTarget = { tabId: string; side: SplitDropSide };

  let zoneEl: HTMLDivElement | null = $state(null);
  let isOver = $state(false);
  let hoveredTarget = $state.raw<DropTarget | null>(null);

  // A tab can land on the page when it would form, change or reorder a split: not the active
  // tab on its own, and never a bookmark or closed row.
  function acceptsTab(tabId: string): boolean {
    const sidebar = getSpaceSidebar(getActiveSpaceId());
    const tab = sidebar.view.tabsById.get(tabId);
    if (!tab || tab.isClosed || tab.isBookmarked) return false;
    if (tabId !== sidebar.activeTabId) return true;
    return !!tab.groupId && sidebar.view.foldersById.get(tab.groupId)?.isSplit === true;
  }

  // A conversation is dragged by its row, a folder heading its agent tab: that tab is what splits.
  function splitTabId(kind: string, id: string): string | null {
    if (kind === "tab") return id;
    return kind === "folder" ? (getConversationTab(id)?.id ?? null) : null;
  }

  const draggedTabId = $derived.by(() => {
    const drag = getSidebarDrag();
    return drag ? splitTabId(drag.kind, drag.itemId) : null;
  });
  const visible = $derived(draggedTabId !== null && untrack(() => acceptsTab(draggedTabId)));

  // Without a split, the whole page is the one pane, holding the active tab.
  const panes = $derived.by((): BridgeSplitPaneFrame[] => {
    const split = getSplitPanes();
    if (split.length > 0) return split;
    const activeTabId = getSpaceSidebar(getActiveSpaceId()).activeTabId;
    return activeTabId ? [{ tabId: activeTabId, x: 0, y: 0, width: 1, height: 1 }] : [];
  });

  // The pane under the pointer, and in it the nearest edge, each edge owning a triangle. A full
  // split has no edge left to cut: the whole pane is the target. A link only reaches the left
  // and right strips, and takes their side.
  function targetAt(x: number, y: number, droppedTabId: string | null, sideOnly?: boolean): DropTarget | null {
    if (!zoneEl) return null;
    const rect = zoneEl.getBoundingClientRect();
    const fx = (x - rect.left) / rect.width;
    const fy = (y - rect.top) / rect.height;
    const pane = panes.find((p) => fx >= p.x && fx <= p.x + p.width && fy >= p.y && fy <= p.y + p.height);
    if (!pane || pane.tabId === droppedTabId) return null;
    if (panes.length >= MAX_SPLIT_PANES) return { tabId: pane.tabId, side: "replace" };
    const dx = (fx - pane.x) / pane.width;
    const dy = (fy - pane.y) / pane.height;
    const side: SplitSide = sideOnly || Math.min(dx, 1 - dx) <= Math.min(dy, 1 - dy)
      ? dx < 0.5 ? "left" : "right"
      : dy < 0.5 ? "top" : "bottom";
    return { tabId: pane.tabId, side };
  }

  // Pointer and drag moves fire every frame; only a new pane or edge may re-render the targets.
  function sameTarget(a: DropTarget | null, b: DropTarget | null): boolean {
    return a === b || (!!a && !!b && a.tabId === b.tabId && a.side === b.side);
  }

  // The engine only reports entering and leaving an item-less zone, so the target under the
  // pointer is tracked here, and only while the drag is over the page.
  $effect(() => {
    if (!visible || !isOver) {
      hoveredTarget = null;
      return;
    }
    const track = (event: PointerEvent) => {
      const next = targetAt(event.clientX, event.clientY, draggedTabId);
      if (!sameTarget(next, hoveredTarget)) hoveredTarget = next;
    };
    window.addEventListener("pointermove", track);
    return () => window.removeEventListener("pointermove", track);
  });

  // A web link dragged to a pane's left or right edge: the native side routes only those strips
  // here, as HTML5 drag events, so any dragover with a link means its target is being aimed at.
  let linkTarget = $state.raw<DropTarget | null>(null);
  $effect(() => {
    const over = (event: DragEvent) => {
      const rect = zoneEl?.getBoundingClientRect();
      const overPage = rect && event.clientX >= rect.left && event.clientX <= rect.right
        && event.clientY >= rect.top && event.clientY <= rect.bottom;
      if (!overPage || !event.dataTransfer?.types.includes("text/uri-list")) {
        linkTarget = null;
        return;
      }
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      const next = targetAt(event.clientX, event.clientY, null, true);
      if (!sameTarget(next, linkTarget)) linkTarget = next;
    };
    const leave = (event: DragEvent) => {
      if (event.relatedTarget === null) linkTarget = null;
    };
    const drop = (event: DragEvent) => {
      const target = linkTarget;
      linkTarget = null;
      const url = event.dataTransfer?.getData("text/uri-list")
        .split(/\r?\n/)
        .find((line) => line.trim() && !line.startsWith("#"));
      if (!target || !url) return;
      event.preventDefault();
      tabActions.splitURL(url.trim(), target.side, target.tabId);
    };
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  });

  const showsTargets = $derived(visible || linkTarget !== null);
  const activeTarget = $derived(hoveredTarget ?? linkTarget);

  function canResolve(context: DndTargetContext): boolean {
    const tabId = splitTabId(context.dragSource.kind, context.dragSource.id);
    return tabId !== null && acceptsTab(tabId);
  }

  function handleDrop(drag: DndActiveDrag): void {
    const tabId = splitTabId(drag.source.item.kind, drag.source.item.id);
    const target = tabId ? targetAt(drag.currentPoint.x, drag.currentPoint.y, tabId) : null;
    isOver = false;
    if (tabId && target) tabActions.splitTab(tabId, target.side, target.tabId);
  }
</script>

<div
  bind:this={zoneEl}
  class="split-drop-zone"
  class:visible={showsTargets}
  class:sidebar-hidden={!isSidebarVisible()}
  aria-hidden="true"
  use:dndZone={{
    id: "split-drop-zone",
    axis: "horizontal",
    meta: { compactPreview: true },
    canResolve,
    onDragMove: (drag) => {
      isOver = true;
      hoveredTarget = targetAt(drag.currentPoint.x, drag.currentPoint.y, drag.source.item.id);
    },
    onDragLeave: () => (isOver = false),
    onDrop: handleDrop,
    onCancel: () => (isOver = false),
  }}
>
  {#if showsTargets}
    {#each panes as pane (pane.tabId)}
      {@const aimed = activeTarget?.tabId === pane.tabId ? activeTarget.side : null}
      {@const halves: SplitSide[] = aimed === "top" || aimed === "bottom" ? ["top", "bottom"] : ["left", "right"]}
      <div
        class="split-drop-pane"
        class:vertical={aimed === "top" || aimed === "bottom"}
        style:left="{pane.x * 100}%"
        style:top="{pane.y * 100}%"
        style:width="{pane.width * 100}%"
        style:height="{pane.height * 100}%"
      >
        {#if aimed === "replace"}
          <div class="split-drop-target active">
            <span class="split-drop-label">{t("splitDrop.replace")}</span>
          </div>
        {:else if aimed}
          {#each halves as side (side)}
            <div class="split-drop-target" class:active={aimed === side}>
              <span class="split-drop-label">{t(`splitDrop.${side}`)}</span>
            </div>
          {/each}
        {:else}
          <div class="split-drop-target idle"></div>
        {/if}
      </div>
    {/each}
  {/if}
</div>

<style>
  .split-drop-zone {
    position: fixed;
    top: var(--chrome-content-top);
    right: var(--chrome-content-right);
    bottom: var(--chrome-content-bottom);
    left: var(--chrome-content-left-visible);
    pointer-events: none;
    opacity: 0;
    transition: opacity var(--motion-duration-normal) var(--motion-ease-organic);
    z-index: 4;
  }

  .split-drop-zone.sidebar-hidden {
    left: var(--chrome-content-left-hidden);
  }

  .split-drop-zone.visible {
    opacity: 1;
  }

  /* Placed from the native pane frames, which already leave the dividers out. */
  .split-drop-pane {
    position: absolute;
    display: flex;
    gap: 8px;
    padding: 8px;
    box-sizing: border-box;
  }

  .split-drop-pane.vertical {
    flex-direction: column;
  }

  .split-drop-target {
    flex: 1 1 0;
    display: flex;
    /* Above center: the drag preview follows the pointer and would cover a centered label. */
    align-items: flex-start;
    justify-content: center;
    padding-top: 22%;
    border-radius: var(--radius-md);
    border: 1.5px dashed color-mix(in srgb, var(--text-primary) 22%, transparent);
    background: color-mix(in srgb, var(--bg-primary) 18%, transparent);
    backdrop-filter: blur(2px);
    animation: split-target-pop 380ms var(--motion-ease-bounce) both;
    transition:
      background var(--motion-duration-normal) var(--motion-ease-organic),
      border-color var(--motion-duration-normal) var(--motion-ease-organic),
      scale 360ms var(--motion-ease-bounce);
  }

  .split-drop-target + .split-drop-target {
    animation-delay: 50ms;
  }

  @keyframes split-target-pop {
    from {
      opacity: 0;
      scale: 0.96;
    }
  }

  .split-drop-target.idle {
    animation: none;
    opacity: 0.6;
  }

  .split-drop-target.active {
    border-style: solid;
    border-color: color-mix(in srgb, var(--accent) 80%, transparent);
    background: var(--accent-tint-22);
    scale: 0.985;
  }

  .split-drop-label {
    padding: 6px 12px;
    border-radius: var(--radius-chip);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
    background: color-mix(in srgb, var(--bg-primary) 82%, transparent);
    box-shadow: var(--shadow-sm);
  }

  @media (prefers-reduced-motion: reduce) {
    .split-drop-zone,
    .split-drop-target {
      animation: none;
      transition: none;
    }
  }
</style>
